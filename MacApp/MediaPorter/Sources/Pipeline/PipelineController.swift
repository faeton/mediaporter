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
    /// User AirPlays/casts the device to a 4K screen, so the on-device-panel
    /// downscale recommendation is wrong for them. Drives the banner copy
    /// and skips the auto-downscale in `runAnalyze`.
    public var airplayTo4K = false
    public var tmdbAPIKey: String = ""

    /// Resolved show identity per cluster (`FileJob.clusterID`). Each entry is
    /// shared by every episode in the cluster — show name, year, network,
    /// poster, tmdb id. Per-episode fields (episode title, still) stay on the
    /// individual `EpisodeMetadata`.
    public var tvShowResolutions: [String: ResolvedShow] = [:]

    /// In-flight cluster resolves, keyed by clusterID. When parallel analyze
    /// (#10) runs N episodes of the same show concurrently, the first to
    /// reach `resolveCluster` plants a Task here; the others await its
    /// value instead of firing N parallel TMDb searches. Cleared once the
    /// resolved show lands in `tvShowResolutions`.
    private var clusterResolveTasks: [String: Task<ResolvedShow, Never>] = [:]

    /// Cluster-scoped user intent (#11a). Keyed by `FileJob.clusterID`. Set
    /// when the user opts to propagate a per-row change to all siblings, and
    /// read by `analyzeOne` so a freshly analyzed sibling adopts the cluster's
    /// established selection. In-memory only — not persisted across launches.
    public var clusterSelections: [String: ClusterSelection] = [:]

    /// External-track scan result per cluster (#11c). Populated once per
    /// `analyzeAll` run by walking each unique source directory present in
    /// the drop. Consumed by the cluster-header UI (11d) and the mux stage
    /// (11e). Empty when no dub / sub files were found alongside the videos.
    public var clusterExtras: [String: ReleaseExtras] = [:]

    /// Snapshot of the device's MediaLibrary used for duplicate detection
    /// (#10b). Loaded once per analyzeAll run when a device is connected,
    /// cleared after sync completes (rows we just added would otherwise
    /// flag the next batch as duplicates). Empty array = device offline or
    /// pull failed — analyze still works, just no dedup flags.
    public var deviceLibrarySnapshot: [DeviceLibraryEntry] = []

    /// Clusters where TMDb couldn't auto-pick a show — surfaced to the UI so
    /// the user can pick once for the whole cluster instead of N times.
    public var pendingShowPicks: [PendingShowPick] = []

    /// Latest known ffmpeg state. The ContentView banner observes this and
    /// stays visible while .missing; re-polls every 3s via the loop started
    /// in `startFFmpegMonitoring()` so a fresh `brew install ffmpeg`
    /// dismisses it without an app restart.
    public var ffmpegSource: FFmpegSource = Prerequisites.ffmpegSource

    /// Files that finished AFC upload in the last run but lost their ATC
    /// registration step. Set when the final batch register call throws; the
    /// AFC bytes are still on the device, only the MediaLibrary insert failed.
    /// Populated so the user can hit "Retry Registration" instead of
    /// re-uploading 19+ GB.
    var pendingRegistration: PendingRegistration?

    /// Convenience for the UI — the menu item enables when this is true.
    public var hasPendingRegistration: Bool { pendingRegistration != nil }
    public var pendingRegistrationCount: Int { pendingRegistration?.pairs.count ?? 0 }

    /// Tagged .m4v files left in the system tempdir from a previous session
    /// that aren't bound to any current FileJob. Refreshed lazily — see
    /// `refreshLeftovers()`. Used by the main-panel banner.
    public var leftoverTranscodes: [LeftoverTranscode] = []

    public var leftoverBytesTotal: Int64 {
        leftoverTranscodes.reduce(0) { $0 + $1.size }
    }

    public struct LeftoverTranscode: Identifiable, Sendable {
        public let url: URL
        public let size: Int64
        public let title: String
        /// "Show · S01E11" for TV episodes, nil for movies / untagged files.
        public let showLabel: String?
        public var id: URL { url }
    }

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
        // Expand dropped directories. Without this, dragging a season folder
        // ("Jujutsu Kaisen/") onto the app silently no-ops because the URL has
        // no video extension and gets filtered out below. Depth-bounded so a
        // dropped `~/Movies` tree doesn't take forever.
        let expanded = expandDroppedURLs(urls, maxDepth: 6)
        let filtered = expanded.filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
        let existing = Set(jobs.map(\.inputURL))
        let newURLs = filtered.filter { !existing.contains($0) }

        // Sibling-aware "Show Name NN" detection. The standard regex misses
        // plain-numbered anime / re-encode releases (no S##, no [Group], no
        // year). When ≥3 sibling video files in the same folder share a title
        // prefix and end in 1-3 digits, treat them as TV season 1 — drives
        // clustering + ExternalTrackScanner. Re-evaluated against the union of
        // existing jobs + new URLs so a second batch dropped into the same
        // folder counts toward the sibling floor.
        detectPlainNumberedSeasons(amongAll: existing.union(newURLs))

        let newJobs = newURLs.map { url -> FileJob in
            let job = FileJob(url: url)
            job.parsedOverride = filenameOverrides[url]
            return job
        }
        // Also retro-tag existing jobs that just became part of a sibling group
        // big enough to trigger plain-numbered detection (second-batch case).
        for job in jobs where filenameOverrides[job.inputURL] != nil {
            job.parsedOverride = filenameOverrides[job.inputURL]
        }
        jobs.append(contentsOf: newJobs)
        sortJobs()
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

    /// Per-parent-dir title prefixes for plain-numbered TV releases, populated
    /// by `detectPlainNumberedSeasons`. Used by `parseFilename(for:)` and by
    /// `ExternalTrackScanner` so sidecar subs in a `Subs/` subfolder match the
    /// same prefix rule as their sibling videos.
    public var clusterTitlePrefixes: [URL: Set<String>] = [:]

    /// URLs → forced ParsedFilename when sibling detection identified a TV
    /// release the regex parser couldn't. Lookup-driven so the existing
    /// `FilenameParser.parse(job.fileName)` call sites stay simple.
    /// (Internal: `ParsedFilename` is module-internal.)
    var filenameOverrides: [URL: ParsedFilename] = [:]

    /// Centralized filename → ParsedFilename for jobs. Always prefer the
    /// sibling-detected override; otherwise consult the parent folder for a
    /// "Season N" hint, then fall back to the regex parser.
    func parseFilename(for job: FileJob) -> ParsedFilename {
        if let forced = job.parsedOverride ?? filenameOverrides[job.inputURL] {
            return forced
        }
        let parentName = job.inputURL.deletingLastPathComponent().lastPathComponent
        return FilenameParser.parse(job.fileName, parentDir: parentName)
    }

    /// Re-order `jobs` so episodes of the same show stay together and the
    /// season / episode order matches viewer expectations (S01E01 before
    /// S01E02 before S01E16). FileManager.enumerator gives no ordering
    /// guarantee, so without this step a folder drop renders in inode order.
    /// Grouping uses `clusterID` once analyze ran, otherwise the parsed title
    /// (override-aware) — so plain-numbered "Show NN" files cluster visually
    /// even before TMDb resolves.
    func sortJobs() {
        jobs.sort { lhs, rhs in
            let lk = sortKey(for: lhs)
            let rk = sortKey(for: rhs)
            if lk.group != rk.group { return lk.group < rk.group }
            if lk.season != rk.season { return lk.season < rk.season }
            if lk.episode != rk.episode { return lk.episode < rk.episode }
            return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
        }
    }

    private func sortKey(for job: FileJob) -> (group: String, season: Int, episode: Int) {
        let parsed = parseFilename(for: job)
        let group: String
        if let cid = job.clusterID, !cid.isEmpty {
            group = cid.lowercased()
        } else if parsed.mediaType == .tvShow, !parsed.title.isEmpty {
            group = parsed.title.lowercased()
        } else {
            // Movies / unrecognized: group by parent dir so they at least stay
            // adjacent to anything else dropped from the same folder.
            group = job.inputURL.deletingLastPathComponent().path.lowercased()
        }
        return (group, parsed.season ?? Int.max, parsed.episode ?? Int.max)
    }

    /// Recursively expand any directory URLs in the drop. Files pass through
    /// unchanged. Symlinks are followed once, hidden files are skipped.
    private func expandDroppedURLs(_ urls: [URL], maxDepth: Int) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                out.append(url)
                continue
            }
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            while let any = enumerator.nextObject() {
                guard let child = any as? URL else { continue }
                if enumerator.level > maxDepth { enumerator.skipDescendants(); continue }
                if let isFile = try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                   isFile {
                    out.append(child)
                }
            }
        }
        return out
    }

    /// Look at every parent dir that holds ≥3 video files matching the same
    /// `<Title>[ ._-]+(\d{1,3})$` shape but no S## / year markers. For each
    /// such group, write a TV-tagged `ParsedFilename` into `filenameOverrides`
    /// and register the normalized title in `clusterTitlePrefixes[parentDir]`.
    /// The 3-sibling floor is the false-positive guard for stray titles like
    /// "Apollo 13.mkv" — anime / TV seasons are always 6+ episodes.
    private func detectPlainNumberedSeasons(amongAll allURLs: Set<URL>) {
        // Group every video URL (including jobs already present) by parent dir
        // so a second-batch drop into the same folder joins the existing
        // sibling set instead of being measured in isolation.
        let videoURLs = allURLs.filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
        let parents = Set(videoURLs.map { $0.deletingLastPathComponent().standardizedFileURL })

        // Enrich each parent's sibling list with every video file actually
        // present on disk in that folder. Without this, dropping a single
        // file (`Jujutsu Kaisen 01.avi`) yields a sibling group of 1, fails
        // the ≥3 floor, and never registers the title prefix — which means
        // ExternalTrackScanner can't match `Rus subs/Jujutsu Kaisen 01.srt`
        // either, because the sub matching also gates on the prefix. We
        // only scan parents that already have a drop, so an unrelated TV
        // folder elsewhere on disk doesn't get fingerprinted.
        var byParent: [URL: [URL]] = [:]
        for parent in parents {
            var set = Set<URL>(videoURLs.filter {
                $0.deletingLastPathComponent().standardizedFileURL == parent
            })
            if let items = try? FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for url in items
                    where Self.videoExtensions.contains(url.pathExtension.lowercased()) {
                    set.insert(url.standardizedFileURL)
                }
            }
            byParent[parent] = Array(set)
        }

        for (parent, siblings) in byParent {
            // Group siblings by normalized title prefix → list of (URL, episode).
            var prefixHits: [String: [(URL, Int, String)]] = [:]
            for url in siblings {
                let stdName = (url.lastPathComponent as NSString).deletingPathExtension
                let standard = FilenameParser.parse(url.lastPathComponent)
                // Skip files the regex parser already understood as TV — they
                // don't need help. Movies pass through (in case a folder
                // accidentally mixes 2 movies + 5 plain-numbered episodes
                // from the same show, but that's rare enough to ignore).
                if standard.mediaType == .tvShow,
                   standard.season != nil, standard.episode != nil {
                    continue
                }
                guard let (title, ep) = matchPlainNumberedShape(stdName) else { continue }
                let key = FilenameParser.normalizePrefix(title)
                guard !key.isEmpty else { continue }
                prefixHits[key, default: []].append((url, ep, title))
            }
            for (prefix, hits) in prefixHits where hits.count >= 3 {
                // Distinct trailing numbers — protect against a folder of
                // alternate-language dubs all named "Show 01.mkv".
                let distinctEpisodes = Set(hits.map(\.1))
                guard distinctEpisodes.count >= 3 else { continue }
                clusterTitlePrefixes[parent, default: []].insert(prefix)
                for (url, ep, title) in hits {
                    filenameOverrides[url] = ParsedFilename(
                        title: title,
                        year: nil,
                        season: 1,
                        episode: ep,
                        mediaType: .tvShow
                    )
                }
            }
        }
    }

    /// Plain-numbered shape match for a stem (no extension). Returns the
    /// cleaned title and the trailing episode number, or nil if it doesn't
    /// look like "<title>[ ._-]+<NN>".
    private func matchPlainNumberedShape(_ stem: String) -> (title: String, episode: Int)? {
        let pattern = #"^(.+?)[\s._-]+(\d{1,3})$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(stem.startIndex..., in: stem)
        guard let m = re.firstMatch(in: stem, range: range),
              let titleR = Range(m.range(at: 1), in: stem),
              let epR = Range(m.range(at: 2), in: stem),
              let ep = Int(stem[epR]) else { return nil }
        let raw = String(stem[titleR])
        let spaced = raw.replacingOccurrences(of: ".", with: " ")
                        .replacingOccurrences(of: "_", with: " ")
        let trimmed = spaced.trimmingCharacters(in: .whitespaces)
        return (trimmed, ep)
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

    // MARK: - ffmpeg monitoring

    /// Re-poll ffmpeg/ffprobe availability on a slow heartbeat. Lets the
    /// missing-ffmpeg banner self-dismiss the moment a user finishes
    /// `brew install ffmpeg` in another window without forcing a relaunch.
    /// Cheap when found (3s sleep, no work); cheap when missing (a couple
    /// of stat() calls). Never stops — the heartbeat also catches the
    /// inverse case (user uninstalls ffmpeg mid-session) so the banner
    /// reappears before the next pipeline call fails per-file.
    public func startFFmpegMonitoring() {
        Task { @MainActor [weak self] in
            while let self {
                FFmpegLocator.invalidateCache()
                let next = Prerequisites.ffmpegSource
                if next != self.ffmpegSource {
                    self.ffmpegSource = next
                    DebugLog.write("prereq.ffmpeg", "transition → \(next.label)")
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    // MARK: - Device Monitoring

    public func startDeviceMonitoring() {
        DeviceMonitor.shared.start()

        Task { @MainActor [weak self] in
            var lastDiskQuery: Date = .distantPast
            var lastDiskUDID: String? = nil
            while let self {
                // Re-query any devices whose lockdown values were unreadable at
                // attach time (Wi-Fi-discovered with stale trust, USB pre-handshake).
                // No-op when there are no pending devices, which is the common case.
                let pending = DeviceMonitor.shared.pendingUDIDs
                if !pending.isEmpty {
                    await Task.detached {
                        for udid in pending {
                            DeviceMonitor.shared.refreshIfPending(udid: udid)
                        }
                    }.value
                }

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
        let parsed = parseFilename(for: job)

        if parsed.mediaType == .tvShow {
            let clusterID = TVShowCluster.key(showName: parsed.title, year: parsed.year)
            job.clusterID = clusterID
            job.metadata = .tvEpisode(await resolveTVEpisode(
                parsed: parsed, clusterID: clusterID,
                sourceURL: job.inputURL, duration: job.mediaInfo?.duration
            ))
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
    private func resolveTVEpisode(
        parsed: ParsedFilename, clusterID: String, sourceURL: URL?, duration: TimeInterval?
    ) async -> EpisodeMetadata {
        let season = parsed.season ?? 1
        let episode = parsed.episode ?? 1
        let episodeID = String(format: "S%02dE%02d", season, episode)

        var show = await resolveCluster(clusterID: clusterID, query: parsed.title, parsedYear: parsed.year)

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

        // Race guard: if the user picked a show via the picker while our
        // episode fetch was in flight, the cluster cache now has a real
        // tmdbShowID. Without this re-check we'd overwrite refreshEpisodes'
        // good metadata with the stale fallback we captured before the pick.
        if show.tmdbShowID == nil,
           let promoted = tvShowResolutions[clusterID],
           promoted.tmdbShowID != nil {
            DebugLog.write("tmdb.resolve",
                "cluster=\(clusterID) promoted mid-analyze, re-fetching ep "
                + String(format: "S%02dE%02d", season, episode))
            show = promoted
            if let id = show.tmdbShowID, !tmdbAPIKey.isEmpty,
               let info = try? await TMDbClient.fetchEpisodeOnly(
                showID: id, season: season, episode: episode, apiKey: tmdbAPIKey
               ) {
                epTitle = info.title
                stillURL = info.stillURL
                overview = info.overview
            }
        }

        let posterData = await resolveEpisodePoster(
            stillURL: stillURL, sourceURL: sourceURL, duration: duration,
            showName: show.showName, season: season, episode: episode
        )

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
            showBackdropURL: show.showBackdropURL,
            showBackdropData: show.showBackdropData,
            tmdbShowID: show.tmdbShowID,
            originalLanguage: show.originalLanguage
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
        // Coalesce concurrent calls for the same cluster — the first one
        // does the TMDb lookup, everyone else awaits its result.
        if let inflight = clusterResolveTasks[clusterID] { return await inflight.value }

        let task = Task<ResolvedShow, Never> { @MainActor [tmdbAPIKey] in
            // No TMDb key → fallback poster only, no network call.
            guard !tmdbAPIKey.isEmpty else {
                return ResolvedShow(
                    showName: query, year: parsedYear,
                    showPosterData: PosterGenerator.generate(title: query, year: parsedYear)
                )
            }
            let candidates = (try? await TMDbClient.searchTVShows(query: query, apiKey: tmdbAPIKey)) ?? []
            if TVShowCluster.shouldAutoPick(candidates), let top = candidates.first {
                return await self.materializeShow(from: top, fallbackQuery: query, fallbackYear: parsedYear)
            }
            // No clear winner — record the cluster as pending and use a
            // fallback identity. UI surfaces the pick; `applyShowToCluster`
            // swaps the resolution in once the user chooses.
            self.recordPendingPick(clusterID: clusterID, query: query, candidates: candidates)
            return ResolvedShow(
                showName: query, year: parsedYear,
                showPosterData: PosterGenerator.generate(title: query, year: parsedYear)
            )
        }
        clusterResolveTasks[clusterID] = task
        let resolved = await task.value
        tvShowResolutions[clusterID] = resolved
        clusterResolveTasks.removeValue(forKey: clusterID)
        return resolved
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
            if resolved.originalLanguage == nil { resolved.originalLanguage = candidate.originalLanguage }
        } else {
            resolved = ResolvedShow(
                showName: candidate.name,
                year: candidate.year,
                showPosterURL: candidate.posterURL,
                tmdbShowID: candidate.id,
                originalLanguage: candidate.originalLanguage
            )
        }
        if let url = resolved.showPosterURL {
            resolved.showPosterData = await TMDbClient.downloadPoster(urlString: url)
        }
        if let url = resolved.showBackdropURL {
            resolved.showBackdropData = await TMDbClient.downloadPoster(urlString: url)
        }
        if resolved.showPosterData == nil {
            resolved.showPosterData = PosterGenerator.generate(
                title: resolved.showName.isEmpty ? fallbackQuery : resolved.showName,
                year: resolved.year ?? fallbackYear
            )
        }
        return resolved
    }

    /// Episode poster resolution chain — TMDb still → ffmpeg-extracted frame
    /// → 1280×720 landscape synthetic. The accessor at MetadataLookup falls
    /// through to `showPosterData` if this is nil, but that show portrait
    /// gets squished into TV.app's 16:9 episode tile, so we'd rather upload a
    /// landscape placeholder than let the show poster reach the device.
    private func resolveEpisodePoster(
        stillURL: String?,
        sourceURL: URL?,
        duration: TimeInterval?,
        showName: String,
        season: Int,
        episode: Int
    ) async -> Data? {
        let badge = MetadataLookup.episodeBadgeFormat(season: season, episode: episode)
        if let stillURL, let data = await TMDbClient.downloadPoster(urlString: stillURL) {
            return EpisodeStillStamper.stamp(data, label: badge)
        }
        if let sourceURL, let duration,
           let extracted = await StillExtractor.extract(from: sourceURL, duration: duration) {
            return EpisodeStillStamper.stamp(extracted, label: badge)
        }
        let label = String(format: "%@ S%02dE%02d", showName, season, episode)
        guard let synthetic = PosterGenerator.generateLandscape(title: label) else { return nil }
        return EpisodeStillStamper.stamp(synthetic, label: badge)
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

    /// Snapshot the user's current per-row selection on `job` as cluster
    /// intent, store under `job.clusterID`, optionally propagate to every
    /// sibling in the same cluster (#11a). The 11b popover calls this with
    /// `propagate: true` when the user clicks "Apply to all"; with
    /// `propagate: false` it only stores, so freshly analyzed siblings
    /// adopt the intent but already-analyzed ones stay untouched.
    public func captureClusterSelection(from job: FileJob, propagate: Bool) {
        guard let cid = job.clusterID else { return }
        let sel = ClusterSelection.capture(from: job)
        clusterSelections[cid] = sel
        if propagate {
            let extras = clusterExtras[cid]
            for sibling in jobs where sibling.clusterID == cid && sibling.id != job.id && sibling.mediaInfo != nil {
                sel.apply(to: sibling, extras: extras)
            }
        }
    }

    /// How many sibling jobs share `job`'s cluster (excluding `job` itself).
    /// UI uses this to decide whether to show the "apply to all" popover —
    /// zero siblings ⇒ no popover (movies, one-offs).
    public func clusterSiblingCount(of job: FileJob) -> Int {
        guard let cid = job.clusterID else { return 0 }
        return jobs.filter { $0.clusterID == cid && $0.id != job.id }.count
    }

    /// Bulk action: assign a clusterID to a set of jobs (overwriting any
    /// existing one), then resolve. Used by multi-select "Set show…".
    public func reclusterJobs(jobIDs: [UUID], showName: String, year: Int?) async {
        let clusterID = TVShowCluster.key(showName: showName, year: year)

        // Snapshot the old cluster IDs of the affected jobs BEFORE we mutate
        // them — we need the per-job before/after pair to migrate
        // clusterExtras / clusterSelections to the new key. Without this, the
        // header section and any propagated audio/sub intent disappear for
        // any job the user reassigns via "Set show…".
        let movedFrom: [String: String] = Dictionary(
            uniqueKeysWithValues: jobs
                .filter { jobIDs.contains($0.id) }
                .compactMap { j -> (String, String)? in
                    guard let old = j.clusterID, old != clusterID else { return nil }
                    return (old, clusterID)
                }
        )

        for j in jobs where jobIDs.contains(j.id) {
            j.clusterID = clusterID
        }

        // Carry forward extras + selections under the new key. If multiple
        // distinct old clusters merged into this one, last-write-wins on the
        // dict copy — same trade-off as Dictionary uniquing above.
        for (oldKey, newKey) in movedFrom where oldKey != newKey {
            if let extras = clusterExtras[oldKey], clusterExtras[newKey] == nil {
                clusterExtras[newKey] = extras
            }
            if let sel = clusterSelections[oldKey], clusterSelections[newKey] == nil {
                clusterSelections[newKey] = sel
            }
            // Drop the old entry only if no remaining job still references it.
            if !jobs.contains(where: { $0.clusterID == oldKey }) {
                clusterExtras[oldKey] = nil
                clusterSelections[oldKey] = nil
            }
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
        let matching = jobs.filter { $0.clusterID == clusterID }
        DebugLog.write("tmdb.refresh",
            "cluster=\(clusterID) showID=\(show.tmdbShowID.map(String.init) ?? "nil") "
            + "jobs=\(matching.count)")
        for job in matching {
            let parsed = parseFilename(for: job)
            let season = parsed.season ?? 1
            let episode = parsed.episode ?? 1
            let episodeID = String(format: "S%02dE%02d", season, episode)

            // Distinguish "TMDb returned, no still" from "TMDb call threw".
            // Transient errors must not silently downgrade a previously-good
            // still to a synthetic fallback — keep the existing poster on
            // network failure and only re-resolve when we got a real answer.
            var epTitle: String? = nil
            var stillURL: String? = nil
            var overview: String? = nil
            var fetchSucceeded = true
            if let id = show.tmdbShowID, !tmdbAPIKey.isEmpty {
                do {
                    let info = try await TMDbClient.fetchEpisodeOnly(
                        showID: id, season: season, episode: episode, apiKey: tmdbAPIKey
                    )
                    epTitle = info.title
                    stillURL = info.stillURL
                    overview = info.overview
                    DebugLog.write("tmdb.refresh",
                        "\(job.fileName) "
                        + String(format: "S%02dE%02d", season, episode)
                        + " title=\(info.title ?? "<nil>") "
                        + "still=\(info.stillURL == nil ? "<nil>" : "ok")")
                } catch {
                    fetchSucceeded = false
                    DebugLog.error("tmdb.refresh",
                        "fetchEpisodeOnly threw for \(job.fileName) "
                        + String(format: "S%02dE%02d", season, episode)
                        + ": \(String(describing: error))")
                }
            }

            let existing: EpisodeMetadata? = {
                if case .tvEpisode(let e) = job.metadata { return e }
                return nil
            }()

            let posterData: Data?
            if fetchSucceeded {
                posterData = await resolveEpisodePoster(
                    stillURL: stillURL,
                    sourceURL: job.inputURL,
                    duration: job.mediaInfo?.duration,
                    showName: show.showName, season: season, episode: episode
                )
            } else {
                // Keep whatever was there — don't replace a valid TMDb still
                // with a synthetic just because the network blipped.
                posterData = existing?.posterData
                epTitle = existing?.episodeTitle
                stillURL = existing?.posterURL
                overview = existing?.overview
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

    /// Scan /tmp for tagged .m4v files not associated with any FileJob in
    /// the current queue. Cheap (AVAsset metadata read, no subprocess).
    public func refreshLeftovers() {
        let known = Set(jobs.compactMap { $0.outputURL?.standardizedFileURL })
        Task { @MainActor in
            let candidates = await OrphanRecovery.scanLocalCandidates()
            self.leftoverTranscodes = candidates
                .filter { !known.contains($0.localURL.standardizedFileURL) }
                .map { c in
                    let label: String?
                    if c.isTVShow, let show = c.showName, let s = c.season, let e = c.episode {
                        label = String(format: "%@ · S%02dE%02d", show, s, e)
                    } else {
                        label = nil
                    }
                    return LeftoverTranscode(
                        url: c.localURL, size: c.size, title: c.title, showLabel: label
                    )
                }
        }
    }

    /// Throw away leftover .m4v files. Used by the banner's Discard action.
    public func discardLeftovers() {
        for item in leftoverTranscodes {
            try? FileManager.default.removeItem(at: item.url)
        }
        leftoverTranscodes = []
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
        let candidates = await OrphanRecovery.scanLocalCandidates()

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
            refreshLeftovers()
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
            DebugLog.write("opensubs", "enabled for languages \(langs.joined(separator: ","))")
        } else if !openSubtitlesAPIKey.isEmpty {
            DebugLog.write("opensubs",
                "API key set but username/password/languages missing — skipping auto-fetch. "
                + "Fill them in Settings → Subtitles.")
        }

        // Scan each source directory present in the drop for external
        // audio / sub tracks (#11c). Group pending jobs by parent dir, parse
        // their filenames once, hand the list to the scanner. Store per
        // cluster — multiple clusters under one dir each see only their own
        // matching episodes. We re-scan every analyze run so dropping a new
        // episode of an existing show picks up newly added dub files.
        let pendingByDir = Dictionary(grouping: jobs.filter { $0.status == .pending }) {
            $0.inputURL.deletingLastPathComponent().standardizedFileURL
        }
        for (dir, jobsInDir) in pendingByDir {
            let parsedFiles = jobsInDir.map { parseFilename(for: $0) }
            let titlePrefixes = clusterTitlePrefixes[dir.standardizedFileURL] ?? []
            let extras = ExternalTrackScanner.scanRelease(
                sourceDir: dir, episodes: parsedFiles, titlePrefixes: titlePrefixes
            )
            guard !extras.isEmpty else { continue }
            // Map clusters that live in this dir (parse-time only; the
            // resolver runs again post-TMDb so cluster IDs are stable).
            let dirClusters = Set(parsedFiles.compactMap { p -> String? in
                guard p.season != nil, p.episode != nil else { return nil }
                return TVShowCluster.key(showName: p.title, year: p.year)
            })
            for cid in dirClusters {
                clusterExtras[cid] = extras
            }
            if !dirClusters.isEmpty {
                DebugLog.write("extracts",
                    "\(dir.lastPathComponent) → \(extras.dubs.count) dub(s), "
                    + "\(extras.subs.count) sub(s) for cluster(s) "
                    + dirClusters.sorted().joined(separator: ","))
            }
        }

        // Refresh the device-library snapshot for duplicate detection
        // (#10b) once per analyze run. We do this BEFORE the waves so every
        // analyzeOne can tag its job with `duplicateOnDevice`. Run off the
        // MainActor — sqlite3 + AFC pull together take ~1-2 s.
        if let device = deviceInfo {
            let devCopy = device
            deviceLibrarySnapshot = (try? await Task.detached {
                try loadDeviceLibrary(device: devCopy)
            }.value) ?? []
            DebugLog.write("device.library", "snapshot \(deviceLibrarySnapshot.count) entries")
        } else {
            deviceLibrarySnapshot = []
        }

        // Process in waves: at each iteration, snapshot all currently-pending
        // jobs and run them concurrently (capped at `analyzeConcurrency`).
        // After the wave completes, recheck — jobs added mid-wave (a second
        // drag-drop while the first wave is still running) form the next.
        // Cluster resolution dedup happens inside `resolveCluster` so 8
        // episodes of the same show fire one TMDb search, not 8.
        let analyzeConcurrency = 4
        while jobs.contains(where: { $0.status == .pending }) {
            let wave = jobs.filter { $0.status == .pending }
            let waveTotal = wave.count
            var waveProcessed = 0

            await withTaskGroup(of: Void.self) { group in
                var iter = wave.makeIterator()
                for _ in 0..<min(analyzeConcurrency, waveTotal) {
                    if let job = iter.next() {
                        group.addTask { @MainActor [weak self] in
                            await self?.analyzeOne(job: job)
                        }
                    }
                }
                for await _ in group {
                    waveProcessed += 1
                    overallProgress = Double(waveProcessed) / Double(waveTotal)
                    if let job = iter.next() {
                        group.addTask { @MainActor [weak self] in
                            await self?.analyzeOne(job: job)
                        }
                    }
                }
            }
        }

        overallStatus = "Analysis complete"
        overallProgress = 1.0
        // Re-sort once clusterIDs land — addFiles only had the regex-parser
        // result, so plain-numbered files with the same title would group, but
        // jobs whose cluster was disambiguated by TMDb get repositioned now.
        sortJobs()
        isRunning = false
    }

    /// Analyze one job: probe + decision + metadata resolve + (optionally)
    /// OpenSubtitles fetch. Safe to run concurrently for distinct jobs —
    /// shared state (cluster cache, pending-pick map) is `@MainActor`-isolated
    /// and `resolveCluster` coalesces concurrent same-cluster calls.
    private func analyzeOne(job: FileJob) async {
        job.status = .analyzing
        do {
            var info = try await probeFile(url: job.inputURL)
            scanExternalSubtitles(mediaInfo: &info)
            let decision = evaluateCompatibility(mediaInfo: info)

            job.mediaInfo = info
            job.decision = decision

            let srcHeight = info.videoStreams.first?.height ?? 0
            if airplayTo4K {
                // User outputs to a 4K display via AirPlay/HDMI — the device
                // panel resolution is irrelevant. Keep originals.
                job.maxResolution = .original
            } else if let device = DeviceMonitor.shared.currentDevice {
                let suggestion = device.suggestedResolution
                job.maxResolution = suggestion.wouldDownscale(from: srcHeight) ? suggestion : .original
            } else if srcHeight > 1920 {
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
                    DebugLog.write("opensubs",
                        "\(job.fileName) — all requested languages already present, skipping")
                } else {
                    overallStatus = "Looking up subtitles: \(job.fileName)"
                    DebugLog.write("opensubs",
                        "querying \(missing.joined(separator: ",")) for \(job.fileName)")
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
                        DebugLog.notice("opensubs", "no matches for \(job.fileName)")
                    } else {
                        let picked = fetched.map(\.language).joined(separator: ",")
                        DebugLog.write("opensubs",
                            "\(job.fileName) — added \(fetched.count) track(s): \(picked)")
                        info.externalSubtitles.append(contentsOf: fetched)
                        job.mediaInfo = info
                    }
                }
            }

            job.selectedExternalSubs = Array(0..<info.externalSubtitles.count)

            // 11a: when the cluster already has a stored intent (another
            // sibling was edited and the user opted to propagate), apply
            // it now — overwrites the per-row defaults seeded above.
            // Without stored intent, only the external-track resolution
            // runs (cluster extras may exist before the user touches the
            // checkboxes) so the seed defaults for audio / subs /
            // resolution stay in place.
            if let cid = job.clusterID {
                if let sel = clusterSelections[cid] {
                    sel.apply(to: job, extras: clusterExtras[cid])
                } else if let extras = clusterExtras[cid] {
                    // Only the external-track side runs — seeds for audio,
                    // subs, resolution stand. (Empty cluster selection ⇒
                    // includedDubStudios/SubLabels empty ⇒ no externals
                    // muxed until the user picks some in the UI.)
                    ClusterSelection().applyExternals(to: job, extras: extras)
                }
            }

            // Duplicate check (#10b). Compute the same title SyncItem will
            // use, then look it up in the device snapshot by (title,
            // durationMs ±2 s). Off by default — no snapshot → nil.
            if !deviceLibrarySnapshot.isEmpty {
                let syncTitle: String
                if case .tvEpisode(let e) = job.metadata {
                    syncTitle = e.episodeTitle ?? "Episode \(e.episode)"
                } else {
                    syncTitle = job.metadata?.title ?? job.fileName
                }
                let durMs = Int((job.mediaInfo?.duration ?? 0) * 1000)
                job.duplicateOnDevice = deviceLibrarySnapshot.contains(
                    title: syncTitle, durationMs: durMs
                )
            }

            job.status = .analyzed
        } catch {
            job.status = .failed
            job.error = error.localizedDescription
        }
    }

    public func transcodeAll() async {
        let toProcess = jobs.filter { $0.status == .analyzed }
        guard !toProcess.isEmpty else { return }

        isRunning = true

        for (i, job) in toProcess.enumerated() {
            // 11e pre-mux: combine the source video with selected external
            // dubs / subs into an intermediate MKV in temp, then re-probe
            // so the existing transcode pipeline sees the new tracks as if
            // they were embedded all along.
            var muxIntermediate: URL? = nil
            if !job.externalTracksToMux.isEmpty {
                job.status = .muxing
                overallStatus = "Muxing extras: \(job.fileName)..."
                let intermediate = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mp-mux-\(UUID().uuidString).mkv")
                do {
                    try await ExternalMux.mux(
                        sourceVideo: job.inputURL,
                        extras: job.externalTracksToMux,
                        outputPath: intermediate
                    )
                    var newInfo = try await probeFile(url: intermediate)
                    scanExternalSubtitles(mediaInfo: &newInfo)
                    let newDecision = evaluateCompatibility(mediaInfo: newInfo)
                    job.mediaInfo = newInfo
                    job.decision = newDecision
                    muxIntermediate = intermediate
                    // Keep every audio (originals + dubs); text-only subs.
                    job.selectedAudio = Array(0..<newInfo.audioStreams.count)
                    job.selectedSubtitles = newInfo.subtitleStreams.enumerated().compactMap { idx, s in
                        isTextSubtitle(s.codecName) || s.codecName == "mov_text" ? idx : nil
                    }
                    // The mux step embedded the extras; transcode pass
                    // should not also pull them in as sidecars.
                    job.externalTracksToMux = []

                    // Resolve a deferred cluster-extras burn-in target now
                    // that the matching sub is embedded. Mirrors the path in
                    // runTranscodeStep — keep these two in sync.
                    if let target = job.pendingBurnInExtraLang {
                        let norm = target.lowercased()
                        if let idx = newInfo.subtitleStreams.firstIndex(where: {
                            let lang = ($0.language ?? "und").lowercased()
                            let isText = isTextSubtitle($0.codecName) || $0.codecName == "mov_text"
                            return isText && lang == norm
                        }) {
                            job.burnInSubtitle = .embedded(idx)
                        } else {
                            job.burnInSubtitle = nil
                        }
                        job.pendingBurnInExtraLang = nil
                    }
                } catch {
                    job.status = .failed
                    job.error = "External mux: \(error.localizedDescription)"
                    overallProgress = Double(i + 1) / Double(toProcess.count)
                    continue
                }
            }
            // Delete the mux intermediate (if any) after this job leaves
            // the transcode stage; the .m4v output is what gets synced.
            defer {
                if let u = muxIntermediate { try? FileManager.default.removeItem(at: u) }
            }

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
                        originalLanguageFallback: job.metadata?.originalLanguage,
                        audioLanguageOverrides: job.audioLanguageOverrides,
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

        let items = readyJobs.map { job -> SyncItem in
            let fileURL = job.outputURL ?? job.inputURL
            return self.buildSyncItem(for: job, fileURL: fileURL)
        }

        // Build a map from SyncItem title to job UUID for progress updates.
        // Sendable (UUID) so the closure can capture without warnings; we
        // resolve back to the FileJob on the main thread where mutation is
        // safe. Must use the SyncItem's title (episode title for TV) — using
        // ResolvedMetadata.title would collide all 25 episodes onto the
        // show name and only one row would tick.
        let jobIDByTitle: [String: UUID] = Dictionary(
            zip(items, readyJobs).map { ($0.title, $1.id) },
            uniquingKeysWith: { $1 }
        )

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
                            // Resolve job on main where FileJob access is safe.
                            if let id = jobIDByTitle[title],
                               let job = self.jobs.first(where: { $0.id == id }) {
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
                    originalLanguageFallback: job.metadata?.originalLanguage,
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
        // Accept `.ready` alongside `.analyzed` — the Send button counts both
        // (a previously-transcoded file sitting at .ready from a cancelled
        // run is "ready to send"). Without `.ready` here, clicking Send with
        // any `.ready` row would silently exit with "Nothing to sync".
        // runTranscodeStep short-circuits jobs that already have outputURL,
        // so accepting `.ready` doesn't trigger a re-transcode.
        let eligible = jobs.filter {
            ($0.status == .analyzed || $0.status == .ready)
                && !($0.duplicateOnDevice == true && !$0.syncDespiteDuplicate)
        }
        DebugLog.notice(
            "pipeline.runPipelined",
            "enter — total=\(jobs.count) eligible=\(eligible.count) " +
            "analyzed=\(jobs.filter { $0.status == .analyzed }.count) " +
            "ready=\(jobs.filter { $0.status == .ready }.count) " +
            "duplicate=\(jobs.filter { $0.duplicateOnDevice == true }.count) " +
            "syncDespiteDup=\(jobs.filter { $0.syncDespiteDuplicate }.count)"
        )
        guard !eligible.isEmpty else {
            // Tell the user *why* — common confusion: "I see Send N enabled,
            // but click does nothing." With this we get a real status line.
            let dups = jobs.filter { $0.duplicateOnDevice == true && !$0.syncDespiteDuplicate }.count
            let total = jobs.count
            overallStatus = total == 0
                ? "No files to sync — drop video files into the left column."
                : dups == total
                    ? "Nothing to sync — all \(total) files already on device. Click the \u{201c}on device\u{201d} badge to sync anyway."
                    : "Nothing to sync — files need to be analyzed first."
            DebugLog.notice("pipeline.runPipelined", "guard: eligible empty (status=\(overallStatus))")
            return
        }
        guard let device = deviceInfo else {
            overallStatus = "No device connected"
            DebugLog.notice("pipeline.runPipelined", "guard: deviceInfo nil")
            return
        }
        let analyzed = eligible

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
            DebugLog.error("pipeline.runPipelined", "preflight disk check failed: \(error.localizedDescription)")
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
            DebugLog.error("pipeline.runPipelined", "AFC connection failed: \(error.localizedDescription)")
            return
        }

        // ------------------------------------------------------------------
        // Pre-allocate sync identity for every analyzed job (assetID,
        // devicePath, slot). Build skeleton SyncItems using source file
        // values for fileURL/fileSize — those fields are unused by plist
        // building (only FileBegin reads fileSize, sent later per-file
        // with the real transcoded size). This is the #8 streaming-register
        // requirement: medialibraryd needs the full plist before it accepts
        // any FileBegin, so all files must be enumerated upfront.
        // ------------------------------------------------------------------
        var preparedPairs: [(job: FileJob, prepared: PreparedSyncFile)] = []
        for job in analyzed {
            let skeletonItem = buildSyncItem(for: job, fileURL: job.inputURL)
            let prepared = prepareSyncFiles([skeletonItem])[0]
            preparedPairs.append((job, prepared))
        }

        // Open the streaming register session BEFORE the upload loop. This
        // pays the handshake + AssetManifest wait once, up front, instead of
        // after every byte has shipped. Per-file FileBegin/FileComplete now
        // fires immediately after each AFC upload finishes — medialibraryd
        // commits the row within ~1 s (plan #8 gate-test).
        overallStatus = "Opening sync session…"
        let registerSession = RegisterSession(device: device, verbose: false)
        do {
            let infos = preparedPairs.map { $0.prepared.asSyncFileInfo }
            // RegisterSession.open emits stage labels — "Waiting for device
            // to settle…", "Connecting (ATC handshake)…", "Writing sync
            // manifest…", "Waiting for device library scan…", "Clearing
            // stale pending asset(s)…". Without this hook, overallStatus
            // sat at "Opening sync session…" for the whole 5-15 s and the
            // app looked frozen.
            try await Task.detached {
                try registerSession.open(files: infos) { stage in
                    DispatchQueue.main.async {
                        self.overallStatus = stage
                    }
                }
            }.value
        } catch {
            uploader.close()
            overallStatus = "Sync session failed: \(error.localizedDescription)"
            for (job, _) in preparedPairs { job.status = .analyzed }
            isRunning = false
            lastRunStats = stats
            cancelFlag.set(false)
            DebugLog.error("pipeline.runPipelined", "register session open failed: \(error.localizedDescription)")
            return
        }

        var prevWork: Task<Void, Error>? = nil
        var workFailed: String? = nil
        var registeredCount = 0

        // Background disk-space watchdog. The per-file check below
        // (`queryDeviceDiskSpace`) only fires between files, but a single
        // file's upload can take tens of minutes on a slow link — long enough
        // for iOS background traffic to eat several GB. Poll every 10 s and
        // trip the detector if free space drops below 256 MB; the upload's
        // isCancelled closure picks it up between 1 MB chunks and aborts.
        let diskDetector = DiskFullDetector()
        let diskHandle = device.handle
        let diskPoller = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                guard let r = queryDeviceDiskSpace(device: diskHandle) else { continue }
                if r.free < 256 * 1024 * 1024 {
                    diskDetector.trigger(
                        "Device filled up during upload (only \(ByteFormat.short(r.free)) free)."
                    )
                    break
                }
            }
        }

        // Parallel transcode lookahead. Without this, the upload pointer
        // sat idle waiting for the *next* file's transcode after every
        // upload — uploads on USB-C run at ~150 MB/s, transcodes at single-
        // file pace, so the upload phase finished in 1/N the time of one
        // transcode and then the whole pipeline stalled. Pre-spawn all
        // transcodes gated by a small concurrency limit so K-1 files are
        // already done by the time the upload loop arrives at them.
        //
        // K=2 is a deliberate floor: VideoToolbox media engines are a fixed
        // resource (1 on base Apple Silicon, 2 on Pro/Max), software
        // transcode is CPU-bound and benefits from full cores per file —
        // running 2 in parallel keeps the next output queued without
        // starving either path. Higher cores get a higher cap; capped at 4.
        // Per-job transcode start time. Written from the worker task on
        // MainActor (runTranscodeStep is @MainActor-isolated, the orchestrator
        // hops onto it via `await self.runTranscodeStep`), read in the upload
        // loop. Wall-clock per-file timing under parallelism is approximate
        // by definition; we surface it for stats only.
        var transcodeStartTimes: [Date] = Array(repeating: .distantPast, count: preparedPairs.count)
        let readyGates: [TranscodeReadyGate] = preparedPairs.map { _ in TranscodeReadyGate() }
        let parallelCap = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 4))

        // Orchestrator runs on MainActor so the transcodeStartTimes write
        // and the runTranscodeStep call stay on a single isolation domain —
        // no captures-across-actor warnings. The actual ffmpeg work happens
        // inside Transcoder.transcode (nonisolated async), so MainActor only
        // serializes the status flips around it.
        let weakSelf = self
        // Fire-and-forget — the upload loop awaits each readyGate, and
        // cancellation is checked via cancelFlag + ActiveProcesses inside
        // each task before spawning ffmpeg. No need to retain the handle.
        _ = Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                var pendingIdx = 0
                func enqueueNext(_ group: inout TaskGroup<Void>) {
                    while pendingIdx < preparedPairs.count {
                        let i = pendingIdx
                        pendingIdx += 1
                        let job = preparedPairs[i].job
                        if weakSelf.cancelFlag.get() {
                            Task { await readyGates[i].fire() }
                            continue
                        }
                        group.addTask { @MainActor in
                            transcodeStartTimes[i] = Date()
                            await weakSelf.runTranscodeStep(for: job)
                            await readyGates[i].fire()
                        }
                        return
                    }
                }
                for _ in 0..<parallelCap { enqueueNext(&group) }
                while await group.next() != nil {
                    enqueueNext(&group)
                }
            }
        }

        for (idx, pair) in preparedPairs.enumerated() {
            let job = pair.job
            if cancelFlag.get() { break }

            await readyGates[idx].wait()
            let transcodeStart = transcodeStartTimes[idx]

            if cancelFlag.get() {
                if job.status == .failed { job.error = "Cancelled" }
                registerSession.abandonAsset(assetID: pair.prepared.assetID)
                break
            }

            guard job.status == .ready, let fileURL = job.outputURL else {
                // Transcode failed or produced no output — drop the asset
                // from the sync so SyncFinished isn't blocked waiting for it.
                registerSession.abandonAsset(assetID: pair.prepared.assetID)
                continue
            }

            // Rebuild SyncItem with the real output URL/size so FileBegin
            // sends the right TotalSize and AFCUploader streams the right
            // bytes. Same assetID/devicePath/slot — those were committed in
            // the upfront plist.
            let realItem = buildSyncItem(for: job, fileURL: fileURL)
            let realPrepared = PreparedSyncFile(
                item: realItem,
                assetID: pair.prepared.assetID,
                devicePath: pair.prepared.devicePath,
                slot: pair.prepared.slot
            )
            preparedPairs[idx] = (job, realPrepared)

            var timing = stats.timingsByFile[job.fileName] ?? PipelineStats.FileTiming()
            timing.transcodeSeconds = Date().timeIntervalSince(transcodeStart)
            timing.uploadBytes = Int64(realPrepared.item.fileSize)
            stats.timingsByFile[job.fileName] = timing

            // Serialize against the previous file's upload+register chain —
            // one AFC connection for video bytes, one ATC session for
            // FileBegin/FileComplete, both must be used in order.
            if let prev = prevWork {
                do { try await prev.value }
                catch { workFailed = error.localizedDescription }
            }
            if workFailed != nil {
                registerSession.abandonAsset(assetID: pair.prepared.assetID)
                break
            }

            // Mid-sync disk poll (#9). Preflight at runPipelined start only
            // checks once; iOS background traffic (Photos sync, iCloud,
            // Music) can eat tens of GB while we're transcoding. AFC failing
            // mid-write surfaces as a cryptic write error several minutes
            // into the upload — re-query free space here so we abort with
            // a clear message instead.
            //
            // Headroom: file size + 256 MB. medialibraryd needs scratch for
            // ingestion (artwork DB, search index); 256 MB matches what we
            // observed it briefly hold during a TV-episode batch.
            if let result = queryDeviceDiskSpace(device: device.handle) {
                deviceFreeBytes = result.free
                let needed = Int64(realPrepared.item.fileSize) + 256 * 1024 * 1024
                if result.free < needed {
                    workFailed = "Device filled up during sync (have \(ByteFormat.short(result.free)), need \(ByteFormat.short(needed)) for next file)."
                    registerSession.abandonAsset(assetID: pair.prepared.assetID)
                    break
                }
            }

            job.status = .syncing
            job.progress = 0
            overallStatus = "Uploading \(realItem.title) (\(idx + 1)/\(preparedPairs.count))"

            let capJob = job
            let capPrepared = realPrepared
            let capCancel = cancelFlag
            let uploadStart = Date()
            prevWork = Task.detached { [weak self] in
                // FileBegin BEFORE upload — announces the asset so the bytes
                // arriving at /iTunes_Control/Music/Fxx/<slot>.mp4 get bound
                // to assetID. With FileBegin sent after upload, bytes land
                // anonymously, medialibraryd treats them as orphan content,
                // and the row never binds (location='', file_size=0).
                try registerSession.beginFile(capPrepared.asSyncFileInfo)

                var lastReport = Date.distantPast
                var lastAtcProgress = Date()
                var lastAtcPct: Double = 0
                let capAssetID = capPrepared.assetID
                try uploader.upload(capPrepared, progress: { sent, total in
                    let now = Date()
                    let pct = total > 0 ? Double(sent) / Double(total) : 0
                    if now.timeIntervalSince(lastReport) >= 0.25 {
                        lastReport = now
                        Task { @MainActor in capJob.progress = pct }
                    }
                    // Heartbeat FileProgress: every 5 s OR every 10% (whichever
                    // first). Without these, medialibraryd marks the asset
                    // slot stale on multi-GB uploads and the terminal
                    // FileComplete binds nothing — bytes get swept as orphan.
                    if now.timeIntervalSince(lastAtcProgress) >= 5.0 || pct - lastAtcPct >= 0.1 {
                        lastAtcProgress = now
                        lastAtcPct = pct
                        registerSession.sendProgress(assetID: capAssetID, fraction: pct)
                    }
                }, isCancelled: { capCancel.get() || diskDetector.isFull() })
                let uploadElapsed = Date().timeIntervalSince(uploadStart)

                // Bytes landed — flip the row to .uploaded for the brief
                // moment between AFC EOF and the FileComplete ack.
                await MainActor.run {
                    capJob.progress = 1.0
                    capJob.status = .uploaded
                }

                // Artwork + FileProgress + FileComplete on the live ATC
                // session. Fast (~ms range). Failure here means medialibraryd
                // will be stuck — caller's finishSync() will log the timeout.
                try registerSession.completeFile(capPrepared.asSyncFileInfo)

                await MainActor.run { [weak self] in
                    capJob.status = .synced
                    var t = self?.lastRunStats?.timingsByFile[capJob.fileName]
                        ?? stats.timingsByFile[capJob.fileName]
                        ?? PipelineStats.FileTiming()
                    t.uploadSeconds = uploadElapsed
                    t.uploadBytes = Int64(capPrepared.item.fileSize)
                    stats.timingsByFile[capJob.fileName] = t
                }
            }
            registeredCount = idx + 1
        }

        if let prev = prevWork {
            do { try await prev.value }
            catch { workFailed = error.localizedDescription }
        }
        diskPoller.cancel()
        // Prefer the disk-full message when both fired — the underlying AFC
        // error is just "cancelled" because that's how the upload aborted.
        if let diskMsg = diskDetector.reason() { workFailed = diskMsg }
        uploader.close()

        // Any analyzed job we didn't reach (cancel, prior failure) needs a
        // FileError so the device's SyncFinished isn't blocked on it.
        if registeredCount < preparedPairs.count {
            for i in registeredCount..<preparedPairs.count {
                let (job, prepared) = preparedPairs[i]
                if job.status != .synced && job.status != .syncing && job.status != .uploaded {
                    registerSession.abandonAsset(assetID: prepared.assetID)
                }
            }
        }

        if let err = workFailed {
            let wasCancel = cancelFlag.get()
            overallStatus = wasCancel ? "Cancelled" : "Upload failed: \(err)"
            for (job, _) in preparedPairs
                where job.status == .syncing || job.status == .uploaded
            {
                job.status = .failed
                job.error = wasCancel ? "Cancelled" : err
            }
            registerSession.close()
            isRunning = false
            lastRunStats = stats
            cancelFlag.set(false)
            return
        }

        if cancelFlag.get() {
            overallStatus = "Cancelled"
            for (job, _) in preparedPairs
                where job.status == .syncing || job.status == .uploaded || job.status == .transcoding
            {
                job.status = .failed
                job.error = "Cancelled"
            }
            registerSession.close()
            isRunning = false
            lastRunStats = stats
            cancelFlag.set(false)
            return
        }

        // Close the streaming session — waits for SyncFinished. Most rows
        // are already in MediaLibrary.sqlitedb at this point; the wait is
        // for medialibraryd's bookkeeping (anchor commit) rather than per-
        // file ingestion.
        let finishStart = Date()
        let synced = preparedPairs.filter { $0.job.status == .synced }.count
        overallStatus = "\(synced)/\(preparedPairs.count) synced — finalizing…"
        let elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = Int(Date().timeIntervalSince(finishStart))
                let mm = elapsed / 60, ss = elapsed % 60
                self.overallStatus = String(
                    format: "%d/%d synced — finalizing… %d:%02d",
                    synced, preparedPairs.count, mm, ss
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        await Task.detached { registerSession.finish() }.value
        elapsedTask.cancel()
        overallStatus = "\(synced)/\(preparedPairs.count) synced"

        // Invalidate the device-library snapshot — the rows we just added
        // would otherwise falsely flag the next analyze as duplicates.
        deviceLibrarySnapshot = []

        // Reclaim temp space for every successfully synced job.
        for (job, _) in preparedPairs where job.status == .synced {
            deleteTempOutput(for: job)
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
        // Short-circuit when a previous run already left this job at .ready
        // with a valid output file. Without this, accepting .ready in
        // runPipelined()'s filter would re-transcode the file unnecessarily
        // (and overwrite the previous output, breaking the upload loop's
        // outputURL reference).
        if job.status == .ready,
           let out = job.outputURL,
           FileManager.default.fileExists(atPath: out.path) {
            DebugLog.notice("pipeline.transcode", "skip — \(job.fileName) already at .ready with output on disk")
            return
        }
        guard job.mediaInfo != nil, job.decision != nil else {
            job.status = .failed
            job.error = "Missing analysis data"
            DebugLog.error("pipeline.transcode", "\(job.fileName) missing mediaInfo or decision (status=\(job.status.rawValue))")
            return
        }

        // Pre-mux external dubs/subs into an intermediate MKV — same step as
        // runAll (line ~1078). Without this the pipelined path silently drops
        // every extra cluster track because ffmpeg is fed the source file
        // directly and never sees the sidecar audio/sub.
        var muxIntermediate: URL? = nil
        if !job.externalTracksToMux.isEmpty {
            job.status = .muxing
            let intermediate = FileManager.default.temporaryDirectory
                .appendingPathComponent("mp-mux-\(UUID().uuidString).mkv")
            do {
                try await ExternalMux.mux(
                    sourceVideo: job.inputURL,
                    extras: job.externalTracksToMux,
                    outputPath: intermediate
                )
                var newInfo = try await probeFile(url: intermediate)
                scanExternalSubtitles(mediaInfo: &newInfo)
                let newDecision = evaluateCompatibility(mediaInfo: newInfo)
                job.mediaInfo = newInfo
                job.decision = newDecision
                muxIntermediate = intermediate
                job.selectedAudio = Array(0..<newInfo.audioStreams.count)
                job.selectedSubtitles = newInfo.subtitleStreams.enumerated().compactMap { idx, s in
                    isTextSubtitle(s.codecName) || s.codecName == "mov_text" ? idx : nil
                }
                job.externalTracksToMux = []

                // Resolve a deferred cluster-extras burn-in now that the
                // matching sub is embedded in the intermediate. Match by
                // ISO-639 language; ignore bitmap subs (libass can't burn
                // them and our cluster-extras pipeline only produces SRT).
                if let target = job.pendingBurnInExtraLang {
                    let norm = target.lowercased()
                    if let idx = newInfo.subtitleStreams.firstIndex(where: {
                        let lang = ($0.language ?? "und").lowercased()
                        let isText = isTextSubtitle($0.codecName) || $0.codecName == "mov_text"
                        return isText && lang == norm
                    }) {
                        job.burnInSubtitle = .embedded(idx)
                    } else {
                        // Mux either didn't include this language or the sub
                        // didn't survive the conversion. Drop the burn-in
                        // silently rather than failing the whole file.
                        job.burnInSubtitle = nil
                    }
                    job.pendingBurnInExtraLang = nil
                }
            } catch {
                job.status = .failed
                job.error = "External mux: \(error.localizedDescription)"
                return
            }
        }
        defer {
            if let u = muxIntermediate { try? FileManager.default.removeItem(at: u) }
        }

        guard let info = job.mediaInfo, let decision = job.decision else {
            job.status = .failed
            job.error = "Missing analysis data after mux"
            return
        }

        if job.needsWork {
            job.status = .transcoding
            job.progress = 0
            // Don't write to overallStatus here — transcode/tag run in
            // parallel with upload. The Transcode pill in the bottom
            // timeline already conveys progress; clobbering overallStatus
            // makes the device card flicker between "Uploading" and
            // "Tagging" mid-batch.

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
                    burnIn: job.burnInSubtitle,
                    originalLanguageFallback: job.metadata?.originalLanguage,
                    audioLanguageOverrides: job.audioLanguageOverrides
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
            // See comment above — bottom timeline carries this; don't fight
            // the upload phase for overallStatus.
            try? await Tagger.tag(file: output, metadata: meta, mediaInfo: info)
            job.status = .ready
        }
    }

    /// Build a SyncItem for a ready job.
    private func buildSyncItem(for job: FileJob, fileURL: URL) -> SyncItem {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? job.fileSize
        let info = job.mediaInfo
        let meta = job.metadata

        // For TV the displayed/sorted title in the TV app must be the
        // episode title, not the show name — `ResolvedMetadata.title`
        // returns `showName` for TV so we can't use it here.
        let resolvedTitle: String
        if case .tvEpisode(let e) = meta {
            // Generic fallbacks like "Episode 1" collide with Apple's
            // cloud-catalog matching in medialibraryd — the row goes in
            // unbound (location='', file_size=0) and the file won't play.
            // A show-qualified title sidesteps the match.
            resolvedTitle = e.episodeTitle
                ?? String(format: "%@ — S%02dE%02d", e.showName, e.season, e.episode)
        } else {
            resolvedTitle = meta?.title ?? job.fileName
        }

        var item = SyncItem(
            fileURL: fileURL,
            title: resolvedTitle,
            sortName: resolvedTitle.lowercased(),
            durationMs: Int(info?.duration ?? 0) * 1000,
            fileSize: size
        )
        item.isHD = getHDFlag(
            width: info?.videoStreams.first?.width,
            height: info?.videoStreams.first?.height
        ) > 0
        item.channels = info?.audioStreams.first?.channels ?? 2

        // Predict post-mux/transcode track multiplicity for the insert_track
        // plist. The flags drive whether TV.app shows the audio/subtitle
        // pickers — without them the user gets a forced single track even
        // if extras were merged in.
        let extraDubs = job.externalTracksToMux.filter { $0.kind == .dub }.count
        let extraSubs = job.externalTracksToMux.filter { $0.kind == .sub }.count
        let selAudio = job.selectedAudio.count
        let selSubs = job.selectedSubtitles.count
        let extSubs = job.selectedExternalSubs.count
        item.hasAlternateAudio = (selAudio + extraDubs) > 1
        item.hasSubtitles = (selSubs + extSubs + extraSubs) > 0

        item.posterData = meta?.posterData
        if case .tvEpisode(let e) = meta {
            item.isMovie = false
            item.isTVShow = true
            item.tvShowName = e.showName
            item.sortTVShowName = e.showName.lowercased()
            item.seasonNumber = e.season
            item.episodeNumber = e.episode
            item.episodeSortID = e.episode
            item.artist = e.showName
            item.sortArtist = e.showName.lowercased()
            item.album = "\(e.showName), Season \(e.season)"
            item.sortAlbum = "\(e.showName.lowercased()), season \(e.season)"
            item.albumArtist = e.showName
            item.sortAlbumArtist = e.showName.lowercased()
            // For TV the Library tile renders posterData. The episode still
            // is landscape and looks wrong squished into a portrait slot —
            // prefer the show portrait when we have one.
            item.posterData = e.showPosterData ?? e.posterData
            item.showPosterData = e.showPosterData
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
            DebugLog.write("cleanup",
                "skipping temp cleanup — \(jobs.count) jobs unfinished, "
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

    /// Snapshot of which `/iTunes_Control/Music/Fxx/<name>` paths the device's
    /// medialibraryd considers registered. Used by the cleanup flow to keep
    /// active library content and only delete true orphans. Empty result on
    /// any failure — the caller falls back to showing 'cancel' rather than
    /// risk deleting registered content blindly.
    public func loadRegisteredPaths() async -> RegisteredPaths {
        guard let device = deviceInfo else {
            return RegisteredPaths(paths: [], pendingSlots: [])
        }
        let handle = device
        return (try? await Task.detached {
            try loadDeviceRegisteredPaths(device: handle)
        }.value) ?? RegisteredPaths(paths: [], pendingSlots: [])
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

/// Shared between the upload Task (which polls `isFull()` between 1 MB chunks)
/// and the background disk-poll Task (which calls `trigger()` if the device
/// drops below the safety threshold). First trigger wins so we get the
/// original free-bytes number in the error message rather than whatever it
/// drifted to by the time the upload noticed.
final class DiskFullDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var triggered = false
    private var msg: String?
    func trigger(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        if !triggered { triggered = true; msg = reason }
    }
    func isFull() -> Bool { lock.lock(); defer { lock.unlock() }; return triggered }
    func reason() -> String? { lock.lock(); defer { lock.unlock() }; return msg }
}
