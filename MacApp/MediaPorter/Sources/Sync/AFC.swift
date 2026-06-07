// Native AFC (Apple File Conduit) client for iOS device file operations.

import Foundation

enum AFCError: LocalizedError {
    case connectionFailed(Int32)
    case openFailed(String, Int32)
    case writeFailed(Int, Int32)
    case readFailed(Int, Int32)
    case sizeMismatch(path: String, expected: Int64, actual: Int64)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let rc): return "AFC connection failed (error \(rc))"
        case .openFailed(let path, let rc): return "AFC open '\(path)' failed (error \(rc))"
        case .writeFailed(let offset, let rc): return "AFC write failed at offset \(offset) (error \(rc))"
        case .readFailed(let offset, let rc): return "AFC read failed at offset \(offset) (error \(rc))"
        case .sizeMismatch(let path, let expected, let actual):
            return "AFC upload size mismatch at \(path): expected \(expected) B, device reports \(actual) B"
        case .cancelled: return "Cancelled"
        }
    }
}

class AFCClient {
    private var conn: UnsafeMutableRawPointer?
    /// The AMDServiceConnectionRef backing `conn` (secure-service path). Held so
    /// its SSL context outlives the AFC connection over Wi-Fi.
    private var serviceConn: UnsafeMutableRawPointer?
    /// Bytes per AFC write call. The size-adaptive default is in
    /// `recommendedChunkSize(forFileBytes:)` below — the constant here
    /// is the lower bound used when the file size isn't known. Read
    /// once at init; configurable so the bench can sweep without
    /// recompiling.
    private let chunkSize: Int
    public static let defaultChunkSize = 4 * 1_048_576

    /// Pick an AFC chunk size based on the local file's byte count.
    /// Bench against akm16pro (research/docs/HISTORY.md 2026-05-18):
    ///   139 MB file: 4 MB and 16 MB tie at ~34.9 MB/s (noise floor 2.7%)
    ///   1.21 GB file: 16 MB wins at 36.2 MB/s vs 35.6 for 4 MB (+1.7%)
    /// USB-3 plateaus around 36 MB/s; 32 MB doesn't help further. The
    /// threshold is conservative: below 300 MB the gain is in noise but
    /// the memory cost of a 16 MB chunk is non-trivial on long-running
    /// processes, above 300 MB the larger chunk amortizes per-write
    /// overhead enough to show.
    public static func recommendedChunkSize(forFileBytes bytes: Int64) -> Int {
        if bytes >= 300 * 1_048_576 { return 16 * 1_048_576 }
        return defaultChunkSize
    }

    init(device: DeviceInfo, chunkSize: Int = AFCClient.defaultChunkSize) throws {
        self.chunkSize = chunkSize
        func hx(_ v: Int32) -> String { "0x\(String(format: "%08x", UInt32(bitPattern: v)))" }
        func fail(_ step: String, _ rc: Int32) -> AFCError {
            DebugLog.error("afc.connect", "\(step) failed rc=\(rc) (\(hx(rc)))")
            return AFCError.connectionFailed(rc)
        }

        var rc = MD.connect(device.handle)
        guard rc == 0 else { throw fail("AMDeviceConnect", rc) }

        rc = MD.startSession(device.handle)
        guard rc == 0 else { throw fail("AMDeviceStartSession", rc) }

        // SSL-aware service start (F1). The legacy AMDeviceStartService returns
        // 0xE8000012 over Wi-Fi: network lockdown sessions are SSL-wrapped and it
        // skips the SSL service handshake. AMDeviceSecureStartService does the
        // handshake and works over both USB and Wi-Fi.
        var svcHandle: UnsafeMutableRawPointer?
        rc = MD.secureStartService(device.handle, "com.apple.afc" as CFString, nil, &svcHandle)
        guard rc == 0, let svc = svcHandle else { throw fail("AMDeviceSecureStartService(afc)", rc) }
        self.serviceConn = svc

        // AFCConnectionOpen takes the service connection's SOCKET fd, NOT the
        // AMDServiceConnectionRef — passing the ref opens a connection whose
        // first file op fails with AFC error 11 (service-not-connected).
        // Matches research/scripts/afc_plus_atc.py:153-162.
        let sock = MD.serviceConnectionGetSocket(svc)
        guard let sockHandle = UnsafeRawPointer(bitPattern: Int(sock)) else {
            throw fail("AMDServiceConnectionGetSocket(fd=\(sock))", -1)
        }

        var afcConn: UnsafeMutableRawPointer?
        rc = MD.afcOpen(sockHandle, 0, &afcConn)
        guard rc == 0, let c = afcConn else { throw fail("AFCConnectionOpen", rc) }

        // Wire the SSL context onto the AFC connection BEFORE any file I/O. Over
        // Wi-Fi the socket is SSL; without this, AFC reads/writes push plaintext
        // into the SSL stream → 60s I/O stalls / hangs. Over USB the context is
        // nil (plaintext) and this is a harmless no-op. `svc` owns the context,
        // so it must outlive the connection — held in self.serviceConn, never
        // invalidated (matches the legacy non-cleanup behaviour).
        let sslCtx = MD.serviceConnectionGetSecureIOContext(svc)
        let setRC = MD.afcSetSecureContext(c, sslCtx)
        DebugLog.notice("afc.connect",
                        "connected via SecureStartService (\(sslCtx != nil ? "ssl/wifi" : "plaintext/usb")) fd=\(sock) setCtx=\(hx(setRC))")

        self.conn = c
    }

    func makedirs(_ path: String) {
        guard let c = conn else { return }
        _ = MD.afcMkdir(c, path)
    }

    func writeFile(_ path: String, data: Data) throws {
        guard let c = conn else { return }
        var handle: Int = 0
        let rc = MD.afcFileOpen(c, path, 2 /* write */, &handle)
        guard rc == 0 else { throw AFCError.openFailed(path, rc) }

        try data.withUnsafeBytes { buffer in
            let base = buffer.baseAddress!
            var offset = 0
            while offset < data.count {
                let remaining = data.count - offset
                let len = min(remaining, chunkSize)
                let wrc = MD.afcFileWrite(c, handle, base + offset, len)
                guard wrc == 0 else {
                    _ = MD.afcFileClose(c, handle)
                    throw AFCError.writeFailed(offset, wrc)
                }
                offset += len
            }
        }
        _ = MD.afcFileClose(c, handle)
    }

    /// Stream a local file to device in chunks. Calls progress(bytesSent, totalBytes).
    /// The `isCancelled` closure is polled between 1 MB chunks; when it returns
    /// true we throw AFCError.cancelled so the caller can abort gracefully.
    func writeFileStreaming(
        remotePath: String,
        localURL: URL,
        progress: ((Int, Int) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil,
        chunkSizeOverride: Int? = nil
    ) throws {
        guard let c = conn else { return }
        let fileSize = try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as! Int
        // Per-call chunk size lets one long-lived AFC connection upload
        // a mix of small files (4 MB chunk — modest memory) and large
        // files (16 MB chunk — better throughput on >300 MB). Without
        // an override we use the instance default captured at init.
        let effectiveChunk = chunkSizeOverride
            ?? AFCClient.recommendedChunkSize(forFileBytes: Int64(fileSize))
        DebugLog.write("afc.upload.begin",
            "\(localURL.path) (\(fileSize) B) -> \(remotePath) chunk=\(effectiveChunk)")

        var handle: Int = 0
        let rc = MD.afcFileOpen(c, remotePath, 2, &handle)
        guard rc == 0 else { throw AFCError.openFailed(remotePath, rc) }

        guard let stream = InputStream(url: localURL) else {
            _ = MD.afcFileClose(c, handle)
            throw AFCError.openFailed(remotePath, -1)
        }
        stream.open()
        defer {
            stream.close()
            _ = MD.afcFileClose(c, handle)
        }

        var sent = 0
        var buffer = [UInt8](repeating: 0, count: effectiveChunk)

        while sent < fileSize {
            if isCancelled?() == true { throw AFCError.cancelled }

            let read = stream.read(&buffer, maxLength: effectiveChunk)
            guard read > 0 else { break }

            let wrc = buffer.withUnsafeBufferPointer { ptr in
                MD.afcFileWrite(c, handle, ptr.baseAddress!, read)
            }
            guard wrc == 0 else { throw AFCError.writeFailed(sent, wrc) }

            sent += read
            progress?(sent, fileSize)
        }
        DebugLog.write("afc.upload.end",
            "\(remotePath) sent=\(sent) expected=\(fileSize) \(sent == fileSize ? "OK" : "TRUNCATED")")
    }

    /// Read a remote file fully into memory. Returns nil if the file doesn't
    /// exist or can't be opened. Use only for small/medium files (sqlitedb,
    /// plists, traces) — the device's MediaLibrary.sqlitedb is ~10 MB which
    /// is fine to hold in memory; don't call this on video.
    func readFile(_ path: String) throws -> Data {
        guard let c = conn else { throw AFCError.connectionFailed(-1) }
        var handle: Int = 0
        let rc = MD.afcFileOpen(c, path, 1 /* read */, &handle)
        guard rc == 0 else { throw AFCError.openFailed(path, rc) }
        defer { _ = MD.afcFileClose(c, handle) }

        var out = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            var len = chunkSize
            let rrc = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
                MD.afcFileRead(c, handle, ptr.baseAddress!, &len)
            }
            guard rrc == 0 else { throw AFCError.readFailed(out.count, rrc) }
            if len == 0 { break } // EOF
            out.append(buffer, count: len)
        }
        return out
    }

    /// List entries in a device directory. Returns entry names only (no path prefix).
    /// "." and ".." are filtered out. Returns empty array if path doesn't exist.
    func listDirectory(_ path: String) -> [String] {
        guard let c = conn else { return [] }
        var dirHandle: UnsafeMutableRawPointer?
        let rc = MD.afcDirOpen(c, path, &dirHandle)
        guard rc == 0, let dh = dirHandle else { return [] }
        defer { _ = MD.afcDirClose(c, dh) }

        var entries: [String] = []
        while true {
            var namePtr: UnsafePointer<CChar>?
            let readRc = MD.afcDirRead(c, dh, &namePtr)
            guard readRc == 0, let ptr = namePtr else { break }
            let name = String(cString: ptr)
            if name.isEmpty { break }
            if name == "." || name == ".." { continue }
            entries.append(name)
        }
        return entries
    }

    /// Remove a file or empty directory.
    @discardableResult
    func removePath(_ path: String) -> Int32 {
        guard let c = conn else { return -1 }
        return MD.afcRemove(c, path)
    }

    /// Result of querying file info via `AFCFileInfoOpen`. Distinguishes the
    /// three causes of a "no size known" outcome so log triage can tell flaky
    /// afcd from missing file from genuine size feedback. The bare
    /// `fileSize(_:)` wrapper collapses everything except .ok back to nil.
    enum StatResult {
        case ok(size: Int64)        // open succeeded, st_size present
        case missingSize            // open succeeded, no st_size key in dict
        case openFailed(rc: Int32)  // afcFileInfoOpen returned non-zero / null handle
    }

    /// Detailed st_size query. The dict returned by AFCFileInfoOpen contains
    /// st_size, st_blocks, st_ifmt, st_nlink, st_mtime, st_birthtime — we
    /// extract st_size and otherwise classify the failure cause.
    func statResult(_ path: String) -> StatResult {
        guard let c = conn else { return .openFailed(rc: -1) }
        var dictHandle: UnsafeMutableRawPointer?
        let rc = MD.afcFileInfoOpen(c, path, &dictHandle)
        guard rc == 0, let dh = dictHandle else { return .openFailed(rc: rc) }
        defer { _ = MD.afcKeyValueClose(dh) }

        while true {
            var keyPtr: UnsafePointer<CChar>?
            var valPtr: UnsafePointer<CChar>?
            let kv = MD.afcKeyValueRead(dh, &keyPtr, &valPtr)
            guard kv == 0, let kp = keyPtr, let vp = valPtr else { break }
            let key = String(cString: kp)
            if key.isEmpty { break }
            if key == "st_size", let size = Int64(String(cString: vp)) {
                return .ok(size: size)
            }
        }
        return .missingSize
    }

    /// Convenience: return st_size if known, nil otherwise. Used by public
    /// helpers and any caller that doesn't need to distinguish missing-file
    /// from missing-key.
    func fileSize(_ path: String) -> Int64? {
        if case .ok(let size) = statResult(path) { return size }
        return nil
    }

    func close() {
        if let c = conn {
            _ = MD.afcClose(c)
            conn = nil
        }
    }

    deinit { close() }
}

/// Pull a remote AFC file to a local URL. Wrapper for use from outside the
/// core module (e.g. CLI debug commands). Connects, reads, writes, closes.
public func pullDeviceFile(remote: String, to local: URL, device: DeviceInfo) throws {
    let client = try AFCClient(device: device)
    defer { client.close() }
    let data = try client.readFile(remote)
    try data.write(to: local)
}

/// List a remote AFC directory. Returns entry names (no path prefix). Empty
/// array if path doesn't exist. Public wrapper for CLI debug.
public func listDeviceDirectory(_ path: String, device: DeviceInfo) throws -> [String] {
    let client = try AFCClient(device: device)
    defer { client.close() }
    return client.listDirectory(path)
}

/// Stat a remote AFC path. Returns st_size or nil if missing/inaccessible.
/// Public wrapper for CLI debug.
public func statDeviceFile(_ path: String, device: DeviceInfo) throws -> Int64? {
    let client = try AFCClient(device: device)
    defer { client.close() }
    return client.fileSize(path)
}
