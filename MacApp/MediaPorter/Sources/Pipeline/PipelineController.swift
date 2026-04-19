// Pipeline orchestrator — manages file jobs through analyze → transcode → tag → sync.

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
    public var overallProgress: Double = 0
    public var overallStatus: String = ""
    public var isRunning = false

    // Settings
    public var qualityPreset: QualityPreset = .balanced
    public var hwAccel = true
    public var tmdbAPIKey: String = ""

    public init() {}

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
            while let self {
                if let device = DeviceMonitor.shared.currentDevice {
                    self.deviceName = device.displayName
                    self.deviceInfo = device
                    self.isDeviceConnected = true
                } else {
                    self.deviceName = nil
                    self.deviceInfo = nil
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

    /// Run the full pipeline: analyze → transcode → sync.
    public func runFullPipeline() async {
        await analyzeAll()
        await transcodeAll()
        await syncToDevice()
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
