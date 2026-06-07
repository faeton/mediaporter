// AFC chunk-size benchmark (#3 from research/docs/ATC_PIPELINE_OPTIMIZATION.md).
//
// Question: is the historical 1 MB chunk size used by `AFCClient` near
// optimal, or are we leaving throughput on the table? go-tunes and
// libimobiledevice use different sizes (64 KB through 4 MB depending on
// the implementation). USB-3 latency × chunk size × ack overhead means
// the curve is concave — too-small chunks pay per-syscall overhead,
// too-large chunks waste pipelining headroom.
//
// Method: upload the same local file under several chunk sizes, fresh
// AFC connection each pass, measure wall-clock between FileOpen and the
// EOF write. Remove the upload after each pass via `afcRemove` so the
// device isn't left with stale assets — this is pure AFC (no ATC
// register), so there is no MediaLibrary row to clean up at the daemon
// level, just the file in `/iTunes_Control/Music/<slot>/`.
//
// Caveats baked into the report:
// - First pass usually pays a cache miss; we run a warmup pass and
//   discard it.
// - Tiny local files (<32 MB) finish too fast for the result to be
//   meaningful — caller is warned in `BenchUploadReport.note`.
// - The connection setup itself takes ~50-200 ms, which is in the
//   measured wall clock; for short uploads that noise dominates.

import Foundation

public struct BenchUploadResult: Sendable {
    public let chunkSizeBytes: Int
    public let walls: [Double]          // per-pass wall seconds (after warmup)
    public let bytes: Int64

    public var medianSeconds: Double {
        guard !walls.isEmpty else { return 0 }
        let s = walls.sorted()
        let m = s.count / 2
        if s.count % 2 == 1 { return s[m] }
        return (s[m - 1] + s[m]) / 2
    }
    public var medianMBps: Double {
        let sec = medianSeconds
        guard sec > 0 else { return 0 }
        return Double(bytes) / sec / 1_000_000
    }
}

public struct BenchUploadReport: Sendable {
    public let fileURL: URL
    public let fileBytes: Int64
    public let warmupSeconds: Double
    public let results: [BenchUploadResult]
    public let note: String?
    /// Transport the bench ran over ("USB" / "Wi-Fi" / "unknown"). Makes a
    /// Wi-Fi-vs-USB throughput comparison self-labeling — run the same file on
    /// each link and the reports say which is which. (F1 follow-up.)
    public let transport: String

    public var best: BenchUploadResult? {
        results.max(by: { $0.medianMBps < $1.medianMBps })
    }
}

/// Benchmark several AFC chunk sizes against the same local file.
/// Each chunk size runs `passes` times; one warmup pass is run up front
/// (under the default chunk size) so any cold-path latency on the device
/// doesn't bias the first row's median.
public func benchUploadChunkSizes(
    fileURL: URL,
    chunkSizes: [Int] = [256 * 1024, 1024 * 1024, 4 * 1024 * 1024, 16 * 1024 * 1024],
    passes: Int = 2,
    progress: ((String) -> Void)? = nil
) async throws -> BenchUploadReport {
    let device = try discoverDevice()
    let transport = device.interface.label.isEmpty ? "unknown" : device.interface.label
    let fileSize = (try FileManager.default.attributesOfItem(
        atPath: fileURL.path)[.size] as? Int).map(Int64.init) ?? 0
    progress?("Device: \(device.displayName) [\(transport)]")
    progress?("File: \(fileURL.lastPathComponent) (\(fileSize / 1_048_576) MB)")
    let note: String? = fileSize < 32 * 1024 * 1024
        ? "File <32 MB — connection-setup noise will dominate; numbers are not reliable."
        : nil

    // Warmup pass under the default chunk so the first measured pass
    // doesn't pay any first-AFC-connection setup cost from the device
    // side (medialibraryd / afcd warm caches).
    progress?("Warmup pass…")
    let warmupStart = Date()
    try await runOnePass(
        device: device, fileURL: fileURL,
        chunkSize: AFCClient.defaultChunkSize
    )
    let warmup = Date().timeIntervalSince(warmupStart)
    progress?(String(format: "  warmup %.2fs (%.1f MB/s)", warmup,
        Double(fileSize) / warmup / 1_000_000))

    var results: [BenchUploadResult] = []
    for chunk in chunkSizes {
        let label = formatChunk(chunk)
        var walls: [Double] = []
        for pass in 1...passes {
            progress?("  chunk=\(label) pass \(pass)/\(passes)…")
            let start = Date()
            try await runOnePass(
                device: device, fileURL: fileURL, chunkSize: chunk
            )
            let elapsed = Date().timeIntervalSince(start)
            walls.append(elapsed)
            progress?(String(format: "    %.2fs (%.1f MB/s)", elapsed,
                Double(fileSize) / elapsed / 1_000_000))
        }
        results.append(BenchUploadResult(
            chunkSizeBytes: chunk, walls: walls, bytes: fileSize
        ))
    }
    return BenchUploadReport(
        fileURL: fileURL, fileBytes: fileSize,
        warmupSeconds: warmup, results: results, note: note,
        transport: transport
    )
}

/// One upload + remove pass. Uses a fresh AFC connection so chunk size
/// can change between passes (AFCClient captures chunk size at init).
/// Cleans up the uploaded file via `afcRemove` so the device doesn't
/// accumulate orphan benchmark files. We are NOT going through ATC
/// register, so no MediaLibrary row exists to abandon at the daemon
/// layer — pure file cleanup is enough.
private func runOnePass(device: DeviceInfo, fileURL: URL, chunkSize: Int) async throws {
    let (devicePath, slot) = ATCSession.generateDevicePath()
    let afc = try AFCClient(device: device, chunkSize: chunkSize)
    defer { afc.close() }
    afc.makedirs("/iTunes_Control/Music/\(slot)")
    try afc.writeFileStreaming(remotePath: devicePath, localURL: fileURL)
    _ = afc.removePath(devicePath)
}

private func formatChunk(_ bytes: Int) -> String {
    if bytes >= 1024 * 1024 { return "\(bytes / (1024 * 1024))M" }
    return "\(bytes / 1024)K"
}
