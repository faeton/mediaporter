// Native AFC (Apple File Conduit) client for iOS device file operations.

import Foundation

enum AFCError: LocalizedError {
    case connectionFailed(Int32)
    case openFailed(String, Int32)
    case writeFailed(Int, Int32)
    case readFailed(Int, Int32)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let rc): return "AFC connection failed (error \(rc))"
        case .openFailed(let path, let rc): return "AFC open '\(path)' failed (error \(rc))"
        case .writeFailed(let offset, let rc): return "AFC write failed at offset \(offset) (error \(rc))"
        case .readFailed(let offset, let rc): return "AFC read failed at offset \(offset) (error \(rc))"
        case .cancelled: return "Cancelled"
        }
    }
}

class AFCClient {
    private var conn: UnsafeMutableRawPointer?
    private let chunkSize = 1_048_576 // 1MB

    init(device: DeviceInfo) throws {
        var rc = MD.connect(device.handle)
        guard rc == 0 else { throw AFCError.connectionFailed(rc) }

        rc = MD.startSession(device.handle)
        guard rc == 0 else { throw AFCError.connectionFailed(rc) }

        var svcHandle: UnsafeMutableRawPointer?
        rc = MD.startService(device.handle, "com.apple.afc" as CFString, &svcHandle, nil)
        guard rc == 0, let svc = svcHandle else { throw AFCError.connectionFailed(rc) }

        var afcConn: UnsafeMutableRawPointer?
        rc = MD.afcOpen(svc, 0, &afcConn)
        guard rc == 0, let c = afcConn else { throw AFCError.connectionFailed(rc) }
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
        isCancelled: (() -> Bool)? = nil
    ) throws {
        guard let c = conn else { return }
        let fileSize = try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as! Int
        DebugLog.write("afc.upload.begin", "\(localURL.path) (\(fileSize) B) -> \(remotePath)")

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
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        while sent < fileSize {
            if isCancelled?() == true { throw AFCError.cancelled }

            let read = stream.read(&buffer, maxLength: chunkSize)
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

    /// Query st_size for a remote path. Returns nil if the path doesn't exist or
    /// doesn't report a size field. Uses AFCFileInfoOpen which returns a key/value
    /// dict with st_size, st_blocks, st_ifmt, st_nlink, st_mtime, st_birthtime.
    func fileSize(_ path: String) -> Int64? {
        guard let c = conn else { return nil }
        var dictHandle: UnsafeMutableRawPointer?
        let rc = MD.afcFileInfoOpen(c, path, &dictHandle)
        guard rc == 0, let dh = dictHandle else { return nil }
        defer { _ = MD.afcKeyValueClose(dh) }

        var size: Int64?
        while true {
            var keyPtr: UnsafePointer<CChar>?
            var valPtr: UnsafePointer<CChar>?
            let kv = MD.afcKeyValueRead(dh, &keyPtr, &valPtr)
            guard kv == 0, let kp = keyPtr, let vp = valPtr else { break }
            let key = String(cString: kp)
            if key.isEmpty { break }
            if key == "st_size" {
                size = Int64(String(cString: vp))
            }
        }
        return size
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
