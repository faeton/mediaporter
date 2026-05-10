// Pipeline orchestrator — manages file jobs through analyze → transcode → tag → sync.

import AppKit
import Foundation
import Observation

@MainActor
@Observable
public class PipelineController {
    public var jobs: [FileJob] = []
    public var selectedJobID: UUID?
    public var deviceName: String?
    public var isDeviceConnected = false
    public var deviceInfo: DeviceInfo?
    public var availableDevices: [DeviceInfo] = []
    /// User-chosen device UDID. When nil, we auto-pick the preferred (iPad first).
    public var selectedDeviceUDID: String?
    public var deviceFreeBytes: Int64?
    public var deviceTotalBytes: Int64?
    public var overallProgress: Double = 0
    public var overallStatus: String = ""
    public var isRunning = false
    public var lastRunStats: PipelineStats?

    /// Reentrancy guard for `analyzeAll`. Lets us safely call analyze from
    /// both the view (pickFiles/drag-drop) and `addFiles` without two loops
    /// stomping on the same jobs.
    private var isAnalyzing = false

    /// True while a cancel has been requested. Observed from runPipelined's loop
    /// (MainActor) and from the AFC uploader's 1 MB chunk check (Task.detached).
    /// Thread-safe wrapper so the detached upload Task can poll it cheaply.
    private let cancelFlag = AtomicBool()

    // Settings
    public var qualityPreset: QualityPreset = .balanced
    public var hwAccel = true
    public var tmdbAPIKey: String = ""

    /// Resolved show identity per cluster (`FileJob.clusterID`). Each entry is
    /// shared by every episode in the cluster — show name, year, network,
    /// poster, tmdb id. Per-episode fields (episode title, still) stay on the
    /// individual `EpisodeMetadata`.
    public var tvShowResolutions: [String: ResolvedShow] = [:]

    /// Clusters where TMDb couldn't auto-pick a show — surfaced to the UI so
    /// the user can pick once for the whole cluster instead of N times.
    public var pendingShowPicks: [PendingShowPick] = []

    /// Files that finished AFC upload in the last run but lost their ATC
    /// registration step. Set when the final batch register call throws; the
    /// AFC bytes are still on the device, only the MediaLibrary insert failed.
    /// Populated so the user can hit "Retry Registration" instead of
    /// re-uploading 19+ GB.
    var pendingRegistration: PendingRegistration?

    /// Convenience for the UI — the menu item enables when this is true.
    public var hasPendingRegistration: Bool { pendingRegistration != nil }
    public var pendingRegistrationCount: Int { pendingRegistration?.pairs.count ?? 0 }

    struct PendingRegistration {
        let deviceUDID: String
        var pairs: [(job: FileJob, prepared: PreparedSyncFile)]
    }

    // OpenSubtitles credentials — when all four are set, analyze will fetch
    // missing-language SRTs via moviehash/TMDb lookup into a per-user cache.
    public var openSubtitlesAPIKey: String = ""
    public var openSubtitlesUsername: String = ""
    public var openSubtitlesPassword: String = ""
    /// Comma-separated ISO 639-1 codes, e.g. "en,ru"
    public var openSubtitlesLanguages: String = ""

    private static let kSelectedDeviceUDID = "pipeline.selectedDeviceUDID"

    public init() {
        // Restore the user's preferred device so a returning user doesn't fall
        // back to iPad-first auto-pick every session.
        if let saved = UserDefaults.standard.string(forKey: Self.kSelectedDeviceUDID),
           !saved.isEmpty {
            self.selectedDeviceUDID = saved
        }

        // Reclaim /tmp on quit — transcoded outputs would otherwise linger for days.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cleanupTempOutputs() }
        }
    }

    /// True when every OpenSubtitles credential + at least one preferred language is set.
    public var openSubtitlesReady: Bool {
        !openSubtitlesAPIKey.isEmpty
            && !openSubtitlesUsername.isEmpty
            && !openSubtitlesPassword.isEmpty
            && !openSubtitlesLanguages.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// ~/Library/Caches/MediaPorter/opensubtitles — persists downloaded SRTs so
    /// re-analyzing the same file doesn't re-hit the API.
    public var openSubtitlesCacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MediaPorter/opensubtitles", isDirectory: true)
    }

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "avi", "m4v", "mov", "wmv", "flv", "webm", "ts",
        "mts", "m2ts", "mpg", "mpeg", "vob"
    ]

    public var selectedJob: FileJob? {
        jobs.first { $0.id == selectedJobID }
    }

    /// Jobs that are actionable (not yet synced/failed).
    public var activeJobs: [FileJob] {
        jobs.filter { $0.status != .synced && $0.status != .failed }
    }

    /// Whether there are jobs ready to sync.
    public var hasJobsToSync: Bool {
        !activeJobs.isEmpty && !isRunning
    }

    // MARK: - File Management

    public func addFiles(urls: [URL]) {
        let filtered = urls.filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
        let existing = Set(jobs.map(\.inputURL))
        let newJobs = filtered
            .filter { !existing.contains($0) }
            .map { FileJob(url: $0) }
        jobs.append(contentsOf: newJobs)
        if selectedJobID == nil, let first = jobs.first {
            selectedJobID = first.id
        }

        // Kick off analyze for any pending job without relying on the view's
        // kickOff path — that path is gated on !isRunning, so removing a file
        // during a transcode then re-adding it would leave the new job stuck
        // in .queued forever. analyzeAll is a no-op when nothing is pending
        // and guards its own isRunning, so calling it here is always safe.
        if !newJobs.isEmpty, jobs.contains(where: { $0.status == .pending }) {
            Task { await self.analyzeAll() }
        }
    }

    public func removeJob(_ job: FileJob) {
        jobs.removeAll { $0.id == job.id }
        if selectedJobID == job.id {
            selectedJobID = jobs.first?.id
        }
    }

    public func clearCompleted() {
        jobs.removeAll { $0.status == .synced }
        if let sel = selectedJobID, !jobs.contains(where: { $0.id == sel }) {
            selectedJobID = jobs.first?.id
        }
    }

    // MARK: - Device Monitoring

    public func startDeviceMonitoring() {
        DeviceMonitor.shared.start()

        Task { @MainActor [weak self] in
            var lastDiskQuery: Date = .distantPast
            var lastDiskUDID: String? = nil
            while let self {
                let all = DeviceMonitor.shared.allDevices
                self.availableDevices = all

                // Resolve the active device: user's pick if still connected,
                // otherwise fall back to the preferred (iPad first).
                let active: DeviceInfo? = {
                    if let udid = self.selectedDeviceUDID,
                       let d = all.first(where: { $0.udid == udid }) {
                        return d
                    }
                    return all.first
                }()

                if let device = active {
                    self.deviceName = device.displayName
                    self.deviceInfo = device
                    self.isDeviceConnected = true

                    // Reset cached disk numbers when the active device changes.
                    if lastDiskUDID != device.udid {
                        self.deviceFreeBytes = nil
                        self.deviceTotalBytes = nil
                        lastDiskQuery = .distantPast
                        lastDiskUDID = device.udid
                    }

                    // Poll disk space every 10 seconds — cheap lockdown query, but no
                    // reason to hammer it. Skip while running (session already in use).
                    if !self.isRunning, Date().timeIntervalSince(lastDiskQuery) >= 10 {
                        lastDiskQuery = Date()
                        let handle = device.handle
                        let result: (free: Int64, total: Int64)? = await Task.detached {
                            queryDeviceDiskSpace(device: handle)
                        }.value
                        if let result {
                            self.deviceFreeBytes = result.free
                            self.deviceTotalBytes = result.total
                        }
                    }
                } else {
                    self.deviceName = nil
                    self.deviceInfo = nil
                    self.deviceFreeBytes = nil
                    self.deviceTotalBytes = nil
                    self.isDeviceConnected = false
                    lastDiskUDID = nil
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Change which connected device the pipeline targets. Nil = auto (iPad first).
    public func selectDevice(udid: String?) {
        selectedDeviceUDID = udid
        if let udid {
            UserDefaults.standard.set(udid, forKey: Self.kSelectedDeviceUDID)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.kSelectedDeviceUDID)
        }
    }

    // MARK: - TV-show clustering
    //
    // The Python reference does one TMDb call per file. That's 25 calls for
    // a season drop, and 25 separate "Edit title" sheets when TMDb gets it
    // wrong. We instead group episodes by parsed show name + year (the
    // "cluster"), run the show search ONCE per cluster, cache the resolved
    // identity, and reuse it for every episode. Editing one episode's show
    // re-applies across the cluster — see `resolveCluster(...)`.

    /// Look up metadata for one job. TV files go through the cluster cache;
    /// movies use the existing per-file path.
    private func resolveJobMetadata(_ job: FileJob) async {
        let parsed = FilenameParser.parse(job.fileName)

        if parsed.mediaType == .tvShow {
            let clusterID = TVShowCluster.key(showName: parsed.title, year: parsed.year)
            job.clusterID = clusterID
            job.metadata = .tvEpisode(await resolveTVEpisode(parsed: parsed, clusterID: clusterID))
            return
        }

        // Movie path — unchanged from pre-clustering behavior.
        if !tmdbAPIKey.isEmpty {
            if let resolved = await MetadataLookup.lookup(path: job.inputURL, apiKey: tmdbAPIKey) {
                job.metadata = resolved
                return
            }
        }
        let fallbackPoster = PosterGenerator.generate(title: parsed.title, year: parsed.year)
        job.metadata = .movie(MovieMetadata(
            title: parsed.title, year: parsed.year,
            genre: nil, overview: nil, longOverview: nil, director: nil,
            posterURL: nil, posterData: fallbackPoster, tmdbID: nil
        ))
    }

    /// Build an `EpisodeMetadata` for a TV file. Resolves the cluster's show
    /// (cached after the first file) then fetches per-episode info.
    private func resolveTVEpisode(parsed: ParsedFilename, clusterID: String) async -> EpisodeMetadata {
        let season = parsed.season ?? 1
        let episode = parsed.episode ?? 1
        let episodeID = String(format: "S%02dE%02d", season, episode)

        let show = await resolveCluster(clusterID: clusterID, query: parsed.title, parsedYear: parsed.year)

        // Per-episode fetch — cheap, but only useful when we have a real TMDb
        // show id to query against.
        var epTitle: String? = nil
        var stillURL: String? = nil
        var overview: String? = nil
        if let id = show.tmdbShowID, !tmdbAPIKey.isEmpty {
            if let info = try? await TMDbClient.fetchEpisodeOnly(
                showID: id, season: season, episode: episode, apiKey: tmdbAPIKey
            ) {
                epTitle = info.title
                stillURL = info.stillURL
                overview = info.overview
            }
        }

        var posterData: Data? = nil
        if let url = stillURL {
            posterData = await TMDbClient.downloadPoster(urlString: url)
        }

        return EpisodeMetadata(
            showName: show.showName,
            season: season,
            episode: episode,
            episodeTitle: epTitle,
            episodeID: episodeID,
            year: show.year ?? parsed.year,
            genre: show.genre,
            overview: overview,
            longOverview: overview,
            network: show.network,
            posterURL: stillURL,
            posterData: posterData,
            showPosterURL: show.showPosterURL,
            showPosterData: show.showPosterData,
            tmdbShowID: show.tmdbShowID
        )
    }

    /// Get-or-create the show resolution for a cluster. Auto-picks the top
    /// candidate when it dominates; otherwise queues a `PendingShowPick`
    /// for the UI and falls back to filename-derived identity.
    @discardableResult
    private func resolveCluster(
        clusterID: String, query: String, parsedYear: Int?
    ) async -> ResolvedShow {
        if let cached = tvShowResolutions[clusterID] { return cached }

        // No TMDb key → fallback poster only, no network call.
        guard !tmdbAPIKey.isEmpty else {
            let fallback = ResolvedShow(
                showName: query,
                year: parsedYear,
                showPosterData: PosterGenerator.generate(title: query, year: parsedYear)
            )
            tvShowResolutions[clusterID] = fallback
            return fallback
        }

        let candidates = (try? await TMDbClient.searchTVShows(query: query, apiKey: tmdbAPIKey)) ?? []

        if TVShowCluster.shouldAutoPick(candidates), let top = candidates.first {
            let resolved = await materializeShow(from: top, fallbackQuery: query, fallbackYear: parsedYear)
            tvShowResolutions[clusterID] = resolved
            return resolved
        }

        // No clear winner — record the cluster as pending and use a fallback
        // identity so analyze can keep running. The UI surfaces the pick;
        // `applyShowToCluster` swaps the resolution in once the user chooses.
        recordPendingPick(clusterID: clusterID, query: query, candidates: candidates)
        let fallback = ResolvedShow(
            showName: query,
            year: parsedYear,
            showPosterData: PosterGenerator.generate(title: query, year: parsedYear)
        )
        tvShowResolutions[clusterID] = fallback
        return fallback
    }

    /// Turn a TMDb candidate into a fully populated `ResolvedShow` (genre,
    /// network, poster bytes). Used after the user picks from the sheet AND
    /// for the auto-pick path.
    private func materializeShow(
        from candidate: TVShowCandidate, fallbackQuery: String, fallbackYear: Int?
    ) async -> ResolvedShow {
        var resolved: ResolvedShow
        if let detail = try? await TMDbClient.fetchTVShow(id: candidate.id, apiKey: tmdbAPIKey) {
            resolved = detail
            // Detail's name/year tend to be richer; fall back to the search
            // candidate if the detail call returned an empty stub.
            if resolved.showName.isEmpty { resolved.showName = candidate.name }
            if resolved.year == nil { resolved.year = candidate.year }
            if resolved.showPosterURL == nil { resolved.showPosterURL = candidate.posterURL }
        } else {
            resolved = ResolvedShow(
                showName: candidate.name,
                year: candidate.year,
                showPosterURL: candidate.posterURL,
                tmdbShowID: candidate.id
            )
        }
        if let url = resolved.showPosterURL {
            resolved.showPosterData = await TMDbClient.downloadPoster(urlString: url)
        }
        if resolved.showPosterData == nil {
            resolved.showPosterData = PosterGenerator.generate(
                title: resolved.showName.isEmpty ? fallbackQuery : resolved.showName,
                year: resolved.year ?? fallbackYear
            )
        }
        return resolved
    }

    private func recordPendingPick(
        clusterID: String, query: String, candidates: [TVShowCandidate]
    ) {
        let affected = jobs.filter { $0.clusterID == clusterID }.map(\.id)
        let pick = PendingShowPick(
            id: clusterID, query: query, candidates: candidates, affectedJobIDs: affected
        )
        if let idx = pendingShowPicks.firstIndex(where: { $0.id == clusterID }) {
            pendingShowPicks[idx] = pick
        } else {
            pendingShowPicks.append(pick)
        }
    }

    /// User picked a show from the picker. Updates the cluster's resolution
    /// and re-fetches per-episode info for every job in the cluster.
    public func applyShowToCluster(
        clusterID: String, candidate: TVShowCandidate
    ) async {
        let resolved = await materializeShow(
            from: candidate, fallbackQuery: candidate.name, fallbackYear: candidate.year
        )
        tvShowResolutions[clusterID] = resolved
        pendingShowPicks.removeAll { $0.id == clusterID }
        await refreshEpisodes(in: clusterID, using: resolved)
    }

    /// User asked to keep the filename-derived identity. Drops the pending
    /// pick — the cluster's existing fallback ResolvedShow stays in place.
    public func dismissClusterPick(_ clusterID: String) {
        pendingShowPicks.removeAll { $0.id == clusterID }
    }

    /// Bulk action: assign a clusterID to a set of jobs (overwriting any
    /// existing one), then resolve. Used by multi-select "Set show…".
    public func reclusterJobs(jobIDs: [UUID], showName: String, year: Int?) async {
        let clusterID = TVShowCluster.key(showName: showName, year: year)
        for j in jobs where jobIDs.contains(j.id) {
            j.clusterID = clusterID
        }
        // Force a fresh resolution for this cluster so the picker re-runs.
        tvShowResolutions[clusterID] = nil
        _ = await resolveCluster(clusterID: clusterID, query: showName, parsedYear: year)
        if let resolved = tvShowResolutions[clusterID] {
            await refreshEpisodes(in: clusterID, using: resolved)
        }
    }

    /// Re-build EpisodeMetadata for every job in a cluster against the new
    /// resolution. Episode numbers come from the original parse (don't
    /// change), only show identity + per-episode TMDb fetch are re-run.
    private func refreshEpisodes(in clusterID: String, using show: ResolvedShow) async {
        for job in jobs where job.clusterID == clusterID {
            let parsed = FilenameParser.parse(job.fileName)
            let season = parsed.season ?? 1
            let episode = parsed.episode ?? 1
            let episodeID = String(format: "S%02dE%02d", season, episode)

            var epTitle: String? = nil
            var stillURL: String? = nil
            var overview: String? = nil
            var posterData: Data? = nil
            if let id = show.tmdbShowID, !tmdbAPIKey.isEmpty {
                if let info = try? await TMDbClient.fetchEpisodeOnly(
                    showID: id, season: season, episode: episode, apiKey: tmdbAPIKey
                ) {
                    epTitle = info.title
                    stillURL = info.stillURL
                    overview = info.overview
                }
                if let url = stillURL {
                    posterData = await TMDbClient.downloadPoster(urlString: url)
                }
            }

            job.metadata = .tvEpisode(EpisodeMetadata(
                showName: show.showName,
                season: season,
                episode: episode,
                episodeTitle: epTitle,
                episodeID: episodeID,
                year: show.year ?? parsed.year,
                genre: show.genre,
                overview: overview,
                longOverview: overview,
                network: show.network,
                posterURL: stillURL,
                posterData: posterData,
                showPosterURL: show.showPosterURL,
                showPosterData: show.showPosterData,
                tmdbShowID: show.tmdbShowID
            ))
        }
    }

    /// All jobs that belong to a cluster — used by the picker UI to render
    /// "applies to N episodes".
    public func jobs(inCluster clusterID: String) -> [FileJob] {
        jobs.filter { $0.clusterID == clusterID }
    }

    // MARK: - Recovery

    /// Re-run the ATC register step against files that finished uploading but
    /// failed registration in the last run. Cheap (one short ATC session, no
    /// re-upload of bytes). Requires the same device to still be connected.
    public func retryRegistration() async {
        guard let pending = pendingRegistration else {
            overallStatus = "Nothing to retry."
            return
        }
        guard let dev = deviceInfo, dev.udid == pending.deviceUDID else {
            overallStatus = "Reconnect the original device to retry registration."
            return
        }
        guard !isRunning else { return }

        isRunning = true
        overallStatus = "Retrying registration on device..."

        let preparedOnly = pending.pairs.map { $0.prepared }
        let devCopy = dev
        do {
            try await Task.detached {
                try registerUploadedFiles(device: devCopy, files: preparedOnly, verbose: false)
            }.value
            for (job, _) in pending.pairs {
                job.status = .synced
                job.error = nil
                job.progress = 1.0
                deleteTempOutput(for: job)
            }
            overallStatus = "\(pending.pairs.count)/\(pending.pairs.count) synced"
            pendingRegistration = nil
        } catch {
            overallStatus = "Retry failed: \(error.localizedDescription)"
        }
        isRunning = false
    }

    /// User decided not to retry — drop the pending state. Bytes are still on
    /// the device; "Clean Up Staged Media Files" reclaims them.
    public func discardPendingRegistration() {
        pendingRegistration = nil
    }

    /// Result bundle for `recoverOrphans` so the UI can pop a clear summary
    /// alert instead of just updating the status bar.
    public struct RecoveryResult {
        public let localFound: Int        // .m4v files in /tmp
        public let deviceFound: Int       // orphan files on the device
        public let registered: Int        // successfully matched + registered
        public let deviceUnmatched: Int   // device files with no local match
        public let candidatesUnmatched: Int // local files with no device match
        public let error: String?
    }

    @discardableResult
    public func recoverOrphans() async -> RecoveryResult {
        guard let dev = deviceInfo else {
            overallStatus = "Connect the original device to recover orphans."
            return RecoveryResult(localFound: 0, deviceFound: 0, registered: 0,
                                  deviceUnmatched: 0, candidatesUnmatched: 0,
                                  error: "No device connected")
        }
        guard !isRunning else {
            return RecoveryResult(localFound: 0, deviceFound: 0, registered: 0,
                                  deviceUnmatched: 0, candidatesUnmatched: 0,
                                  error: "Pipeline already running")
        }

        isRunning = true
        defer { isRunning = false }
        overallStatus = "Scanning local tempdir for transcoded files..."

        // Pull tags + size from every leftover .m4v in /tmp. Doesn't depend on
        // the in-memory FileJobs queue — the m4v files were tagged before
        // upload, so they carry full TMDb metadata themselves.
        let candidates = OrphanRecovery.scanLocalCandidates()

        overallStatus = "Scanning device for uploaded files..."
        let deviceFiles: [DeviceMediaFile]
        do {
            let devCopy = dev
            deviceFiles = try await Task.detached {
                try DeviceMaintenance.scanStagingMedia(device: devCopy)
            }.value
        } catch {
            overallStatus = "Device scan failed: \(error.localizedDescription)"
            return RecoveryResult(
                localFound: candidates.count, deviceFound: 0, registered: 0,
                deviceUnmatched: 0, candidatesUnmatched: candidates.count,
                error: error.localizedDescription
            )
        }

        let (pairs, deviceUnmatched, candUnmatched) = OrphanRecovery.match(
            candidates: candidates, deviceFiles: deviceFiles
        )

        guard !pairs.isEmpty else {
            overallStatus = "Nothing to recover (\(candidates.count) local, \(deviceFiles.count) on device, 0 matched)."
            return RecoveryResult(
                localFound: candidates.count, deviceFound: deviceFiles.count,
                registered: 0, deviceUnmatched: deviceUnmatched.count,
                candidatesUnmatched: candUnmatched.count, error: nil
            )
        }

        overallStatus = "Registering \(pairs.count) recovered file(s)..."
        let preparedList: [PreparedSyncFile] = pairs.map { (cand, dev) in
            PreparedSyncFile(
                item: OrphanRecovery.makeSyncItem(from: cand),
                assetID: ATCSession.generateAssetID(),
                devicePath: dev.path,
                slot: dev.slot
            )
        }
        let devCopy = dev
        do {
            try await Task.detached {
                try registerUploadedFiles(device: devCopy, files: preparedList, verbose: false)
            }.value
            // Clean up the local /tmp m4v copies we just registered.
            for (cand, _) in pairs {
                try? FileManager.default.removeItem(at: cand.localURL)
            }
            // Mark any matching FileJobs in the queue as synced so the row
            // colors update. (Match by inputURL filename stem inside the
            // tagged title — best-effort; not required for correctness.)
            pendingRegistration = nil
            overallStatus = "Recovered \(pairs.count) of \(deviceFiles.count) device files."
            return RecoveryResult(
                localFound: candidates.count, deviceFound: deviceFiles.count,
                registered: pairs.count, deviceUnmatched: deviceUnmatched.count,
                candidatesUnmatched: candUnmatched.count, error: nil
            )
        } catch {
            overallStatus = "Recovery failed: \(error.localizedDescription)"
            return RecoveryResult(
                localFound: candidates.count, deviceFound: deviceFiles.count,
                registered: 0, deviceUnmatched: deviceUnmatched.count,
                candidatesUnmatched: candUnmatched.count,
                error: error.localizedDescription
            )
        }
    }

    // MARK: - Pipeline Stages

    public func analyzeAll() async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }

        guard jobs.contains(where: { $0.status == .pending }) else { return }

        isRunning = true
        overallStatus = "Analyzing..."

        // Log OpenSubtitles readiness once so the user can tell whether
        // auto-fetch will even be attempted for this run.
        if openSubtitlesReady {
            let langs = openSubtitlesLanguages
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            NSLog("OpenSubtitles: enabled for languages %@", langs.joined(separator: ","))
        } else if !openSubtitlesAPIKey.isEmpty {
            NSLog("OpenSubtitles: API key set but username/password/languages missing — skipping auto-fetch. Fill them in Settings → Subtitles.")
        }

        // Re-query on each iteration so jobs added *during* analyze (e.g. a
        // second drag-drop while the first batch is still analyzing) get
        // picked up too.
        var processed = 0
        while let job = jobs.first(where: { $0.status == .pending }) {
            processed += 1
            let totalSoFar = processed + jobs.filter { $0.status == .pending }.count
            job.status = .analyzing
            do {
                var info = try await probeFile(url: job.inputURL)
                scanExternalSubtitles(mediaInfo: &info)
                let decision = evaluateCompatibility(mediaInfo: info)

                job.mediaInfo = info
                job.decision = decision

                // Auto-suggest resolution: use device recommendation if source is larger
                let srcHeight = info.videoStreams.first?.height ?? 0
                if let device = DeviceMonitor.shared.currentDevice {
                    let suggestion = device.suggestedResolution
                    // Only apply device suggestion if it would actually downscale
                    job.maxResolution = suggestion.wouldDownscale(from: srcHeight) ? suggestion : .original
                } else if srcHeight > 1920 {
                    // No device connected but 4K source → suggest 1080p
                    job.maxResolution = .fhd
                } else {
                    job.maxResolution = .original
                }

                job.selectedAudio = Array(0..<info.audioStreams.count)
                job.selectedSubtitles = info.subtitleStreams.enumerated().compactMap { idx, s in
                    isTextSubtitle(s.codecName) || s.codecName == "mov_text" ? idx : nil
                }
                job.selectedExternalSubs = Array(0..<info.externalSubtitles.count)

                await resolveJobMetadata(job)

                // OpenSubtitles: fetch missing-language SRTs into the per-user cache
                // and splice them into mediaInfo.externalSubtitles so they flow into
                // the existing embed path.
                if openSubtitlesReady {
                    let tmdbID: Int? = {
                        if case .movie(let m) = job.metadata { return m.tmdbID }
                        if case .tvEpisode(let e) = job.metadata { return e.tmdbShowID }
                        return nil
                    }()
                    let existingLangs: Set<String> = Set(
                        info.subtitleStreams.compactMap { $0.language?.lowercased() }
                        + info.externalSubtitles.map { $0.language.lowercased() }
                    )
                    let langs = openSubtitlesLanguages
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    let missing = langs.filter { l in
                        let iso3 = iso3FromIso2(openSubtitlesLangCode(l))
                        let iso2 = openSubtitlesLangCode(l)
                        return !existingLangs.contains(iso3) && !existingLangs.contains(iso2)
                    }
                    if missing.isEmpty {
                        NSLog("OpenSubtitles: \(job.fileName) — all requested languages already present, skipping")
                    } else {
                        overallStatus = "Looking up subtitles: \(job.fileName)"
                        NSLog("OpenSubtitles: querying %@ for %@", missing.joined(separator: ","), job.fileName)
                        let client = OpenSubtitlesClient(
                            apiKey: openSubtitlesAPIKey,
                            username: openSubtitlesUsername,
                            password: openSubtitlesPassword
                        )
                        let fetched = await fetchOpenSubtitles(
                            for: job.inputURL,
                            tmdbID: tmdbID,
                            languages: missing,
                            existingLanguages: existingLangs,
                            cacheDir: openSubtitlesCacheDir,
                            client: client
                        )
                        if fetched.isEmpty {
                            NSLog("OpenSubtitles: no matches for \(job.fileName)")
                        } else {
                            let picked = fetched.map(\.language).joined(separator: ",")
                            NSLog("OpenSubtitles: \(job.fileName) — added \(fetched.count) track(s): \(picked)")
                            info.externalSubtitles.append(contentsOf: fetched)
                            job.mediaInfo = info
                        }
                    }
                }

                // Re-derive selected-subs now that (possibly) new externals exist.
                job.selectedExternalSubs = Array(0..<info.externalSubtitles.count)

                job.status = .analyzed
            } catch {
                job.status = .failed
                job.error = error.localizedDescription
            }
            overallProgress = totalSoFar > 0 ? Double(processed) / Double(totalSoFar) : 0
        }

        overallStatus = "Analysis complete"
        isRunning = false
    }

    public func transcodeAll() async {
        let toProcess = jobs.filter { $0.status == .analyzed }
        guard !toProcess.isEmpty else { return }

        isRunning = true

        for (i, job) in toProcess.enumerated() {
            if job.needsWork {
                job.status = .transcoding
                job.progress = 0
                overallStatus = "Transcoding \(job.fileName)..."

                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("m4v")

                do {
                    guard let info = job.mediaInfo, let decision = job.decision else {
                        job.status = .failed
                        job.error = "Missing analysis data"
                        continue
                    }

                    let externalSubs = job.selectedExternalSubs.compactMap { idx -> ExternalSubtitle? in
                        guard idx < info.externalSubtitles.count else { return nil }
                        return info.externalSubtitles[idx]
                    }

                    var lastTranscodeUpdate = Date.distantPast
                    _ = try await Transcoder.transcode(
                        mediaInfo: info,
                        decision: decision,
                        outputPath: outputURL,
                        quality: qualityPreset,
                        hwAccel: hwAccel,
                        maxResolution: job.maxResolution,
                        selectedAudio: job.selectedAudio,
                        selectedSubtitles: job.selectedSubtitles,
                        externalSubs: externalSubs,
                        burnIn: job.burnInSubtitle,
                        progress: { pct in
                            let now = Date()
                            if pct < 1.0, now.timeIntervalSince(lastTranscodeUpdate) < 0.25 { return }
                            lastTranscodeUpdate = now
                            DispatchQueue.main.async { job.progress = pct }
                        }
                    )
                    job.progress = 1.0
                    job.outputURL = outputURL
                    job.status = .ready
                } catch {
                    job.status = .failed
                    job.error = error.localizedDescription
                }
            } else {
                job.outputURL = job.inputURL
                job.status = .ready
            }
            overallProgress = Double(i + 1) / Double(toProcess.count)
        }

        // Tag ready jobs
        for job in toProcess where job.status == .ready {
            if let meta = job.metadata, let output = job.outputURL, let info = job.mediaInfo {
                job.status = .tagging
                overallStatus = "Tagging \(job.fileName)..."
                do {
                    if output != job.inputURL {
                        try await Tagger.tag(file: output, metadata: meta, mediaInfo: info)
                    }
                    job.status = .ready
                } catch {
                    job.status = .ready
                }
            }
        }

        overallStatus = "Ready to sync"
        isRunning = false
    }

    public func syncToDevice() async {
        // Only sync jobs that are ready (not already synced)
        let readyJobs = jobs.filter { $0.status == .ready }
        guard !readyJobs.isEmpty else { return }

        isRunning = true
        overallStatus = "Syncing to device..."

        for job in readyJobs {
            job.status = .syncing
            job.progress = 0
        }

        // Build a map from title to job for progress updates
        let jobsByTitle: [String: FileJob] = Dictionary(
            readyJobs.map { job in
                let meta = job.metadata
                let title = meta?.title ?? job.fileName
                return (title, job)
            },
            uniquingKeysWith: { $1 }
        )

        let items = readyJobs.map { job -> SyncItem in
            let fileURL = job.outputURL ?? job.inputURL
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? job.fileSize
            let info = job.mediaInfo
            let meta = job.metadata

            var item = SyncItem(
                fileURL: fileURL,
                title: meta?.title ?? job.fileName,
                sortName: (meta?.title ?? job.fileName).lowercased(),
                durationMs: Int(info?.duration ?? 0) * 1000,
                fileSize: size
            )

            item.isHD = getHDFlag(
                width: info?.videoStreams.first?.width,
                height: info?.videoStreams.first?.height
            ) > 0

            item.channels = info?.audioStreams.first?.channels ?? 2
            item.posterData = meta?.posterData

            if case .tvEpisode(let e) = meta {
                item.isMovie = false
                item.isTVShow = true
                item.tvShowName = e.showName
                item.seasonNumber = e.season
                item.episodeNumber = e.episode
            }

            return item
        }

        let syncResult: Result<[SyncResult], Error> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var lastProgressUpdate = Date.distantPast
                    let results = try syncFiles(items: items, verbose: false) { title, sent, total in
                        let now = Date()
                        guard now.timeIntervalSince(lastProgressUpdate) >= 0.25 else { return }
                        lastProgressUpdate = now
                        let pct = total > 0 ? Double(sent) / Double(total) : 0
                        DispatchQueue.main.async {
                            self.overallStatus = "Uploading: \(title)"
                            self.overallProgress = pct
                            // Update per-file progress
                            if let job = jobsByTitle[title] {
                                job.progress = pct
                            }
                        }
                    }
                    continuation.resume(returning: .success(results))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }

        switch syncResult {
        case .success(let results):
            for (i, result) in results.enumerated() {
                if result.success {
                    readyJobs[i].status = .synced
                    readyJobs[i].progress = 1.0
                } else {
                    readyJobs[i].status = .failed
                    readyJobs[i].error = result.error ?? "Sync failed"
                }
            }
            let ok = results.filter(\.success).count
            overallStatus = "\(ok)/\(results.count) synced"

        case .failure(let error):
            for job in readyJobs {
                job.status = .failed
                job.error = error.localizedDescription
            }
            overallStatus = "Sync failed: \(error.localizedDescription)"
        }

        isRunning = false
    }

    /// Transcode a single already-analyzed job, tag it, and leave it at `.ready`.
    /// Useful for "prepare the file locally without syncing."
    /// - Parameter destinationURL: Where to write the transcoded file. If nil,
    ///   writes to the macOS tempdir (subject to cleanup).
    public func transcodeOne(_ job: FileJob, destinationURL: URL? = nil) async {
        // Accept .ready too so users can re-run with different settings
        // (resolution, burn-in selection) without removing and re-adding.
        guard job.status == .analyzed || job.status == .ready else { return }
        guard let info = job.mediaInfo, let decision = job.decision else { return }

        // Clean up the prior transcode output (only if it was ours in the
        // tempdir — never touches inputs or a user-picked save location).
        deleteTempOutput(for: job)

        isRunning = true
        defer { isRunning = false }

        if job.needsWork {
            job.status = .transcoding
            job.progress = 0

            let outputURL: URL = destinationURL ?? FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4v")
            // If the caller picked a real path and it already exists, remove it so
            // ffmpeg's -y overwrite works on a clean slate (ffmpeg's -y is fine too
            // but removing first makes half-written leftovers from a crashed prior
            // run go away predictably).
            if destinationURL != nil {
                try? FileManager.default.removeItem(at: outputURL)
            }

            let externalSubs = job.selectedExternalSubs.compactMap { idx -> ExternalSubtitle? in
                guard idx < info.externalSubtitles.count else { return nil }
                return info.externalSubtitles[idx]
            }

            do {
                var lastTranscodeUpdate = Date.distantPast
                _ = try await Transcoder.transcode(
                    mediaInfo: info,
                    decision: decision,
                    outputPath: outputURL,
                    quality: qualityPreset,
                    hwAccel: hwAccel,
                    maxResolution: job.maxResolution,
                    selectedAudio: job.selectedAudio,
                    selectedSubtitles: job.selectedSubtitles,
                    externalSubs: externalSubs,
                    burnIn: job.burnInSubtitle,
                    progress: { pct in
                        let now = Date()
                        if pct < 1.0, now.timeIntervalSince(lastTranscodeUpdate) < 0.25 { return }
                        lastTranscodeUpdate = now
                        DispatchQueue.main.async { job.progress = pct }
                    }
                )
                job.progress = 1.0
                job.outputURL = outputURL
                job.status = .ready
            } catch {
                job.status = .failed
                job.error = error.localizedDescription
                return
            }
        } else {
            job.outputURL = job.inputURL
            job.status = .ready
        }

        // Tag
        if let meta = job.metadata, let output = job.outputURL, output != job.inputURL {
            job.status = .tagging
            do {
                try await Tagger.tag(file: output, metadata: meta, mediaInfo: info)
            } catch {
                // Non-fatal — file is still usable
            }
            job.status = .ready
        }
    }

    /// Run the full pipeline: analyze → pipelined transcode+upload → register.
    public func runFullPipeline() async {
        await analyzeAll()
        await runPipelined()
    }

    /// Pipelined transcode + upload + register for every already-analyzed job.
    ///   - transcode file N+1 while uploading file N (single AFC conn, single registration)
    ///   - fail-fast disk preflight (Mac temp + device)
    ///   - collect PipelineStats into `lastRunStats`
    public func runPipelined() async {
        cancelFlag.set(false) // Fresh run — clear any stale cancel state.
        let analyzed = jobs.filter { $0.status == .analyzed }
        guard !analyzed.isEmpty else { return }
        guard let device = deviceInfo else {
            overallStatus = "No device connected"
            return
        }

        // ------------------------------------------------------------------
        // Preflight: fail fast if there isn't ~1.1× source size free locally
        // or on the device. Keeps long ffmpeg runs from dying mid-way.
        // ------------------------------------------------------------------
        let sourceBytes = analyzed.reduce(Int64(0)) { $0 + Int64($1.fileSize) }
        var stats = PipelineStats()
        stats.runStart = Date()
        stats.deviceName = device.displayName

        do {
            let r = try checkDiskSpace(sourceBytesTotal: sourceBytes, deviceHandle: device.handle)
            stats.macFreeBefore = r.macFree
            stats.deviceFreeBefore = r.deviceFree
            stats.deviceTotalBytes = r.deviceTotal
        } catch {
            overallStatus = error.localizedDescription
            return
        }

        isRunning = true
        overallStatus = "Preparing..."

        let uploader: AFCUploader
        do {
            uploader = try AFCUploader(device: device)
        } catch {
            overallStatus = "AFC connection failed: \(error.localizedDescription)"
            isRunning = false
            return
        }

        // Per-file bookkeeping, shared between transcode and upload coroutines.
        var preparedPairs: [(job: FileJob, prepared: PreparedSyncFile)] = []
        var prevUpload: Task<Void, Error>? = nil
        var uploadFailed: String? = nil

        for job in analyzed {
            if cancelFlag.get() { break }
            let transcodeStart = Date()
            await runTranscodeStep(for: job)

            if cancelFlag.get() {
                // ffmpeg terminated via Transcoder.cancelAll(); job is already .failed
                // with an "exit code 15" error. Overwrite with a cleaner message.
                if job.status == .failed { job.error = "Cancelled" }
                break
            }

            guard job.status == .ready, let fileURL = job.outputURL else { continue }

            let item = buildSyncItem(for: job, fileURL: fileURL)
            let prepared = prepareSyncFiles([item])[0]
            preparedPairs.append((job, prepared))

            var timing = stats.timingsByFile[job.fileName] ?? PipelineStats.FileTiming()
            timing.transcodeSeconds = Date().timeIntervalSince(transcodeStart)
            timing.uploadBytes = Int64(prepared.item.fileSize)
            stats.timingsByFile[job.fileName] = timing

            // Wait for the previous file's upload before starting this one — one AFC conn.
            if let prev = prevUpload {
                do { try await prev.value }
                catch { uploadFailed = error.localizedDescription }
            }

            if uploadFailed != nil { break }

            job.status = .syncing
            job.progress = 0
            overallStatus = "Uploading \(item.title)"

            let capJob = job
            let capPrepared = prepared
            let capCancel = cancelFlag
            let uploadStart = Date()
            prevUpload = Task.detached { [weak self] in
                var lastReport = Date.distantPast
                try uploader.upload(capPrepared, progress: { sent, total in
                    let now = Date()
                    guard now.timeIntervalSince(lastReport) >= 0.25 else { return }
                    lastReport = now
                    let pct = total > 0 ? Double(sent) / Double(total) : 0
                    Task { @MainActor in
                        capJob.progress = pct
                    }
                }, isCancelled: { capCancel.get() })
                let elapsed = Date().timeIntervalSince(uploadStart)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    var t = self.lastRunStats?.timingsByFile[capJob.fileName]
                        ?? stats.timingsByFile[capJob.fileName]
                        ?? PipelineStats.FileTiming()
                    t.uploadSeconds = elapsed
                    t.uploadBytes = Int64(capPrepared.item.fileSize)
                    stats.timingsByFile[capJob.fileName] = t
                    capJob.progress = 1.0
                    // Upload bytes are on the device but ATC register runs as
                    // a single batch at the end. Move out of `.syncing` so the
                    // active-upload counter only counts the file currently
                    // streaming.
                    capJob.status = .uploaded
                }
            }
        }

        if let prev = prevUpload {
            do { try await prev.value }
            catch { uploadFailed = error.localizedDescription }
        }
        uploader.close()

        if let err = uploadFailed {
            let wasCancel = cancelFlag.get()
            overallStatus = wasCancel ? "Cancelled" : "Upload failed: \(err)"
            for (job, _) in preparedPairs where job.status == .syncing {
                job.status = .failed
                job.error = wasCancel ? "Cancelled" : err
            }
            isRunning = false
            lastRunStats = stats
            cancelFlag.set(false)
            return
        }

        if cancelFlag.get() {
            // Loop exited via the cancel-check before the last transcode finished.
            // Nothing to register. Mark any mid-flight job.
            overallStatus = "Cancelled"
            for (job, _) in preparedPairs
                where job.status == .syncing || job.status == .uploaded || job.status == .transcoding
            {
                job.status = .failed
                job.error = "Cancelled"
            }
            isRunning = false
            lastRunStats = stats
            cancelFlag.set(false)
            return
        }

        // ------------------------------------------------------------------
        // Register: single short ATC session for every uploaded file.
        // ------------------------------------------------------------------
        overallStatus = "Finalizing on device..."
        do {
            let preparedOnly = preparedPairs.map { $0.prepared }
            let devCopy = device
            try await Task.detached {
                try registerUploadedFiles(device: devCopy, files: preparedOnly, verbose: false)
            }.value
            for (job, _) in preparedPairs {
                job.status = .synced
                job.progress = 1.0
            }
            overallStatus = "\(preparedPairs.count)/\(preparedPairs.count) synced"

            // Reclaim temp space — delete transcoded outputs that live in our tempdir.
            // Skip inputs and locally-saved files. Called after register succeeded so
            // we know the device copy is in place.
            for (job, _) in preparedPairs {
                deleteTempOutput(for: job)
            }
        } catch {
            // Bytes are on the device; only the ATC register call failed.
            // Keep the jobs in `.uploaded` so the user can hit "Retry
            // Registration" without re-uploading. If they never retry, the
            // existing "Clean Up Staged Media Files" menu item walks the AFC
            // dirs and frees the orphaned bytes.
            for (job, _) in preparedPairs {
                job.status = .uploaded
                job.error = error.localizedDescription
            }
            pendingRegistration = PendingRegistration(
                deviceUDID: device.udid,
                pairs: preparedPairs
            )
            overallStatus = "Registration failed — Retry Registration in the Device menu (\(error.localizedDescription))"
        }

        // Finalize stats
        stats.runEnd = Date()
        stats.macFreeAfter = DiskQuery.macTempFree
        if let result = refreshDeviceFreeSpace(device: device) {
            stats.deviceFreeAfter = result.free
        }
        lastRunStats = stats
        isRunning = false
    }

    /// Transcode + tag a single analyzed job in place. Shared between runPipelined and transcodeOne.
    private func runTranscodeStep(for job: FileJob) async {
        guard let info = job.mediaInfo, let decision = job.decision else {
            job.status = .failed
            job.error = "Missing analysis data"
            return
        }

        if job.needsWork {
            job.status = .transcoding
            job.progress = 0
            let verb = job.needsReencode ? "Transcoding" : "Remuxing"
            overallStatus = "\(verb) \(job.fileName)..."

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4v")

            let externalSubs = job.selectedExternalSubs.compactMap { idx -> ExternalSubtitle? in
                guard idx < info.externalSubtitles.count else { return nil }
                return info.externalSubtitles[idx]
            }

            do {
                var lastUpdate = Date.distantPast
                _ = try await Transcoder.transcode(
                    mediaInfo: info, decision: decision, outputPath: outputURL,
                    quality: qualityPreset, hwAccel: hwAccel,
                    maxResolution: job.maxResolution,
                    selectedAudio: job.selectedAudio,
                    selectedSubtitles: job.selectedSubtitles,
                    externalSubs: externalSubs,
                    burnIn: job.burnInSubtitle
                ) { pct in
                    let now = Date()
                    // Always let the final 1.0 through — the throttle would
                    // otherwise strand the bar at whatever the last tick was.
                    if pct < 1.0, now.timeIntervalSince(lastUpdate) < 0.25 { return }
                    lastUpdate = now
                    DispatchQueue.main.async { job.progress = pct }
                }
                job.progress = 1.0
                job.outputURL = outputURL
                job.status = .ready
            } catch {
                job.status = .failed
                job.error = error.localizedDescription
                return
            }
        } else {
            // No container change, no dropped tracks, all codecs compatible:
            // upload the source file as-is. No ffmpeg pass, no temp file.
            job.outputURL = job.inputURL
            job.status = .ready
        }

        if let meta = job.metadata, let output = job.outputURL, output != job.inputURL {
            job.status = .tagging
            overallStatus = "Tagging \(job.fileName)..."
            try? await Tagger.tag(file: output, metadata: meta, mediaInfo: info)
            job.status = .ready
        }
    }

    /// Build a SyncItem for a ready job.
    private func buildSyncItem(for job: FileJob, fileURL: URL) -> SyncItem {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? job.fileSize
        let info = job.mediaInfo
        let meta = job.metadata

        var item = SyncItem(
            fileURL: fileURL,
            title: meta?.title ?? job.fileName,
            sortName: (meta?.title ?? job.fileName).lowercased(),
            durationMs: Int(info?.duration ?? 0) * 1000,
            fileSize: size
        )
        item.isHD = getHDFlag(
            width: info?.videoStreams.first?.width,
            height: info?.videoStreams.first?.height
        ) > 0
        item.channels = info?.audioStreams.first?.channels ?? 2
        item.posterData = meta?.posterData
        if case .tvEpisode(let e) = meta {
            item.isMovie = false
            item.isTVShow = true
            item.tvShowName = e.showName
            item.seasonNumber = e.season
            item.episodeNumber = e.episode
        }
        return item
    }

    /// Cancel the active run. Kills any ffmpeg process, flags the upload loop
    /// to stop at its next 1 MB chunk boundary, and lets runPipelined() exit
    /// without launching further work. Safe to call from UI.
    public func cancel() {
        cancelFlag.set(true)
        Transcoder.cancelAll()
        overallStatus = "Cancelling..."
    }

    public var isCancelling: Bool { cancelFlag.get() }

    /// Reset a failed job to the latest state it successfully completed so the
    /// user can retry without re-adding the file. Delete any partial transcode
    /// output from the tempdir first so the next run starts clean.
    public func retry(_ job: FileJob) {
        guard job.status == .failed else { return }
        deleteTempOutput(for: job)
        job.error = nil
        job.progress = 0
        if job.mediaInfo != nil && job.decision != nil {
            // Analysis succeeded — a later stage failed. Resume from there.
            job.status = .analyzed
        } else {
            // Analysis itself failed (probe, TMDb, whatever). Start over.
            job.status = .pending
        }
    }

    /// Delete a job's transcoded output if it's a file we created in the tempdir.
    /// Never touches the user's original input or a locally-saved destination.
    private func deleteTempOutput(for job: FileJob) {
        guard let output = job.outputURL, output != job.inputURL else { return }
        let tempDir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let outputDir = output.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard outputDir == tempDir else { return }
        try? FileManager.default.removeItem(at: output)
        job.outputURL = nil
    }

    /// Remove any leftover transcoded outputs for all jobs — for use on app quit or
    /// explicit "clear temp" actions.
    ///
    /// Skips cleanup entirely when there's unfinished work (any job not in
    /// `.synced` or `.pending` state). This is the difference between a clean
    /// shutdown after a successful run and a shutdown after a registration
    /// failure — in the latter case the .m4v files in /tmp are the ONLY way
    /// to recover the 19+ GB of bytes already uploaded to the device, and
    /// nuking them on quit means the user has to re-transcode from scratch.
    public func cleanupTempOutputs() {
        let unfinished = jobs.contains { job in
            switch job.status {
            case .synced, .pending: return false
            default: return true
            }
        }
        if unfinished {
            NSLog("MediaPorter: skipping temp cleanup — \(jobs.count) jobs unfinished, "
                + ".m4v files preserved for Recover Orphaned Uploads")
            return
        }
        for job in jobs { deleteTempOutput(for: job) }
    }

    /// Enumerate leftover media files in /iTunes_Control/Music/F00..F49 on the
    /// connected device. These accumulate from interrupted syncs — the TV app
    /// can still play content whose files are gone (it reads the MediaLibrary
    /// cache), so the disk space is otherwise unreclaimable.
    public func scanStagedMedia() async -> [DeviceMediaFile] {
        guard let device = deviceInfo else { return [] }
        let handle = device
        return (try? await Task.detached {
            try DeviceMaintenance.scanStagingMedia(device: handle)
        }.value) ?? []
    }

    /// Delete the given absolute device paths. Returns the number successfully removed.
    /// Refreshes device free-space after.
    @discardableResult
    public func purgeStagedMedia(paths: [String]) async -> Int {
        guard let device = deviceInfo, !paths.isEmpty else { return 0 }
        let handle = device
        let deleted = (try? await Task.detached {
            try DeviceMaintenance.removeFiles(device: handle, paths: paths)
        }.value) ?? 0
        _ = refreshDeviceFreeSpace(device: device)
        return deleted
    }

    @discardableResult
    private func refreshDeviceFreeSpace(device: DeviceInfo) -> (free: Int64, total: Int64)? {
        guard let result = queryDeviceDiskSpace(device: device.handle) else { return nil }
        deviceFreeBytes = result.free
        deviceTotalBytes = result.total
        return result
    }

    /// Save transcoded files locally instead of syncing.
    public func saveLocally(to directory: URL) async {
        await analyzeAll()
        await transcodeAll()

        let fm = FileManager.default
        for job in jobs where job.status == .ready {
            guard let output = job.outputURL, output != job.inputURL else { continue }
            let dest = directory.appendingPathComponent(
                job.inputURL.deletingPathExtension().lastPathComponent + ".m4v"
            )
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: output, to: dest)
                job.status = .synced
                job.outputURL = dest
            } catch {
                job.status = .failed
                job.error = error.localizedDescription
            }
        }
    }
}

/// Tiny atomic-bool wrapper so a detached upload Task can poll the cancel flag
/// without hopping back to the MainActor between 1 MB chunks.
final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
