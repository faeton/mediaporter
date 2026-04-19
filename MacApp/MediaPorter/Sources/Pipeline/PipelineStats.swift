// Per-run pipeline statistics — wall clocks, bytes, disk deltas.
// Ported from src/mediaporter/pipeline.py PipelineStats.

import Foundation

public struct PipelineStats: Sendable {
    public struct FileTiming: Sendable {
        public var transcodeSeconds: Double = 0
        public var uploadSeconds: Double = 0
        public var uploadBytes: Int64 = 0
        public init() {}
    }

    public var runStart: Date = Date()
    public var runEnd: Date?
    public var timingsByFile: [String: FileTiming] = [:]
    public var macFreeBefore: Int64?
    public var macFreeAfter: Int64?
    public var deviceFreeBefore: Int64?
    public var deviceFreeAfter: Int64?
    public var deviceTotalBytes: Int64?
    public var deviceName: String?

    public init() {}

    public var totalWallSeconds: Double {
        (runEnd ?? Date()).timeIntervalSince(runStart)
    }

    public var totalTranscodeSeconds: Double {
        timingsByFile.values.reduce(0) { $0 + $1.transcodeSeconds }
    }

    public var totalUploadSeconds: Double {
        timingsByFile.values.reduce(0) { $0 + $1.uploadSeconds }
    }

    public var totalUploadBytes: Int64 {
        timingsByFile.values.reduce(0) { $0 + $1.uploadBytes }
    }

    /// Average sustained upload speed across all files, in MB/s. Nil if nothing uploaded.
    public var avgUploadMBps: Double? {
        let seconds = totalUploadSeconds
        guard seconds > 0 else { return nil }
        return Double(totalUploadBytes) / seconds / 1_000_000
    }

    /// Peak single-file upload speed (MB/s) — max over per-file (bytes / seconds).
    public var peakUploadMBps: Double? {
        let perFile: [Double] = timingsByFile.values.compactMap { t in
            guard t.uploadSeconds > 0 else { return nil }
            return Double(t.uploadBytes) / t.uploadSeconds / 1_000_000
        }
        return perFile.max()
    }

    public var macFreeDelta: Int64? {
        guard let before = macFreeBefore, let after = macFreeAfter else { return nil }
        return after - before
    }

    public var deviceFreeDelta: Int64? {
        guard let before = deviceFreeBefore, let after = deviceFreeAfter else { return nil }
        return after - before
    }
}

// MARK: - Byte Formatting

public enum ByteFormat {
    public static func short(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    public static func signed(_ bytes: Int64) -> String {
        let sign = bytes >= 0 ? "+" : "−"
        return "\(sign)\(short(abs(bytes)))"
    }
}

// MARK: - Disk Queries

public enum DiskQuery {
    /// Free bytes on the volume that contains the given URL (typically temp dir).
    public static func freeBytes(at url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let cap = values.volumeAvailableCapacityForImportantUsage { return cap }
        } catch { }
        // Fallback to plain availableCapacity
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let cap = values.volumeAvailableCapacity {
            return Int64(cap)
        }
        return nil
    }

    public static var macTempFree: Int64? {
        freeBytes(at: FileManager.default.temporaryDirectory)
    }
}

// MARK: - Preflight

public enum PreflightError: LocalizedError {
    case notEnoughMacSpace(required: Int64, available: Int64)
    case notEnoughDeviceSpace(required: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .notEnoughMacSpace(let r, let a):
            return "Not enough free space on Mac: need ~\(ByteFormat.short(r)), have \(ByteFormat.short(a))."
        case .notEnoughDeviceSpace(let r, let a):
            return "Not enough free space on device: need ~\(ByteFormat.short(r)), have \(ByteFormat.short(a))."
        }
    }
}

/// Fail fast if the Mac temp volume or the device doesn't have ~1.1× the total source
/// size free. Mirrors _check_disk_space in src/mediaporter/pipeline.py.
public func checkDiskSpace(
    sourceBytesTotal: Int64,
    deviceHandle: UnsafeRawPointer?
) throws -> (macFree: Int64?, deviceFree: Int64?, deviceTotal: Int64?) {
    let required = Int64(Double(sourceBytesTotal) * 1.1)

    let macFree = DiskQuery.macTempFree
    if let macFree, macFree < required {
        throw PreflightError.notEnoughMacSpace(required: required, available: macFree)
    }

    var deviceFree: Int64?
    var deviceTotal: Int64?
    if let handle = deviceHandle, let result = queryDeviceDiskSpace(device: handle) {
        deviceFree = result.free
        deviceTotal = result.total
        if result.free < required {
            throw PreflightError.notEnoughDeviceSpace(required: required, available: result.free)
        }
    }

    return (macFree, deviceFree, deviceTotal)
}
