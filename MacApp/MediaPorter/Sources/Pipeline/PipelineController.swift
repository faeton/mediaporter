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
    public var deviceFreeBytes: Int64?
    public var deviceTotalBytes: Int64?
    public var overallProgress: Double = 0
    public var overallStatus: String = ""
    public var isRunning = false
    public var lastRunStats: PipelineStats?

    // Settings
    public var qualityPreset: QualityPreset = .balanced
    public var hwAccel = true
    public var tmdbAPIKey: String = ""

    public init() {
        // Reclaim /tmp on quit — transcoded outputs would otherwise linger for days.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cleanupTempOutputs() }
        }
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
            while let self {
                if let device = DeviceMonitor.shared.currentDevice {
                    self.deviceName = device.displayName
                    self.deviceInfo = device
                    self.isDeviceConnected = true

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
                }
                try? await Task.sleep(for: .seconds(2))
            }
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
    public func transcodeOne(_ job: FileJob) async {
        guard job.status == .analyzed else { return }
        guard let info = job.mediaInfo, let decision = job.decision else { return }

        isRunning = true
        defer { isRunning = false }

        if job.needsWork {
            job.status = .transcoding
            job.progress = 0

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4v")

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
            let transcodeStart = Date()
            await runTranscodeStep(for: job)

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
            let uploadStart = Date()
            prevUpload = Task.detached { [weak self] in
                var lastReport = Date.distantPast
                try uploader.upload(capPrepared) { sent, total in
                    let now = Date()
                    guard now.timeIntervalSince(lastReport) >= 0.25 else { return }
                    lastReport = now
                    let pct = total > 0 ? Double(sent) / Double(total) : 0
                    Task { @MainActor in
                        capJob.progress = pct
                    }
                }
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
            overallStatus = "Upload failed: \(err)"
            for (job, _) in preparedPairs where job.status == .syncing {
                job.status = .failed
                job.error = err
            }
            isRunning = false
            lastRunStats = stats
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
            overallStatus = "Transcoding \(job.fileName)..."

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
                    externalSubs: externalSubs
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

    /// Cancel any running ffmpeg processes. Safe to call from UI.
    public func cancel() {
        Transcoder.cancelAll()
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
