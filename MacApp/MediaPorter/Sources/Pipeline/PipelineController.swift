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

    /// True while a cancel has been requested. Observed from runPipelined's loop
    /// (MainActor) and from the AFC uploader's 1 MB chunk check (Task.detached).
    /// Thread-safe wrapper so the detached upload Task can poll it cheaply.
    private let cancelFlag = AtomicBool()

    // Settings
    public var qualityPreset: QualityPreset = .balanced
    public var hwAccel = true
    public var tmdbAPIKey: String = ""

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

    // MARK: - Pipeline Stages

    public func analyzeAll() async {
        let pending = jobs.filter { $0.status == .pending }
        guard !pending.isEmpty else { return }

        isRunning = true
        overallStatus = "Analyzing..."

        for (i, job) in pending.enumerated() {
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

                if !tmdbAPIKey.isEmpty {
                    job.metadata = await MetadataLookup.lookup(
                        path: job.inputURL, apiKey: tmdbAPIKey
                    )
                } else {
                    let parsed = FilenameParser.parse(job.fileName)
                    let fallbackPoster = PosterGenerator.generate(title: parsed.title, year: parsed.year)
                    job.metadata = .movie(MovieMetadata(
                        title: parsed.title, year: parsed.year,
                        genre: nil, overview: nil, longOverview: nil, director: nil,
                        posterURL: nil, posterData: fallbackPoster, tmdbID: nil
                    ))
                }

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
                    let client = OpenSubtitlesClient(
                        apiKey: openSubtitlesAPIKey,
                        username: openSubtitlesUsername,
                        password: openSubtitlesPassword
                    )
                    let fetched = await fetchOpenSubtitles(
                        for: job.inputURL,
                        tmdbID: tmdbID,
                        languages: langs,
                        existingLanguages: existingLangs,
                        cacheDir: openSubtitlesCacheDir,
                        client: client
                    )
                    if !fetched.isEmpty {
                        info.externalSubtitles.append(contentsOf: fetched)
                        job.mediaInfo = info
                    }
                }

                // Re-derive selected-subs now that (possibly) new externals exist.
                job.selectedExternalSubs = Array(0..<info.externalSubtitles.count)

                job.status = .analyzed
            } catch {
                job.status = .failed
                job.error = error.localizedDescription
            }
            overallProgress = Double(i + 1) / Double(pending.count)
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
                            guard now.timeIntervalSince(lastTranscodeUpdate) >= 0.25 else { return }
                            lastTranscodeUpdate = now
                            DispatchQueue.main.async { job.progress = pct }
                        }
                    )
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
        guard job.status == .analyzed else { return }
        guard let info = job.mediaInfo, let decision = job.decision else { return }

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
                        guard now.timeIntervalSince(lastTranscodeUpdate) >= 0.25 else { return }
                        lastTranscodeUpdate = now
                        DispatchQueue.main.async { job.progress = pct }
                    }
                )
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
            for (job, _) in preparedPairs where job.status == .syncing || job.status == .transcoding {
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
            for (job, _) in preparedPairs {
                job.status = .failed
                job.error = error.localizedDescription
            }
            overallStatus = "Registration failed: \(error.localizedDescription)"
        }

        // Finalize stats
        stats.runEnd = Date()
        stats.macFreeAfter = DiskQuery.macTempFree
        if let result = queryDeviceDiskSpace(device: device.handle) {
            stats.deviceFreeAfter = result.free
            deviceFreeBytes = result.free
            deviceTotalBytes = result.total
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
                    guard now.timeIntervalSince(lastUpdate) >= 0.25 else { return }
                    lastUpdate = now
                    DispatchQueue.main.async { job.progress = pct }
                }
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
    public func cleanupTempOutputs() {
        for job in jobs { deleteTempOutput(for: job) }
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
