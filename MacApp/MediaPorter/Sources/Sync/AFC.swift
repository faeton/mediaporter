// Native AFC (Apple File Conduit) client for iOS device file operations.

import Foundation

enum AFCError: LocalizedError {
    case connectionFailed(Int32)
    case openFailed(String, Int32)
    case writeFailed(Int, Int32)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let rc): return "AFC connection failed (error \(rc))"
        case .openFailed(let path, let rc): return "AFC open '\(path)' failed (error \(rc))"
        case .writeFailed(let offset, let rc): return "AFC write failed at offset \(offset) (error \(rc))"
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
    func writeFileStreaming(
        remotePath: String,
        localURL: URL,
        progress: ((Int, Int) -> Void)? = nil
    ) throws {
        guard let c = conn else { return }
        let fileSize = try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as! Int

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
            let read = stream.read(&buffer, maxLength: chunkSize)
            guard read > 0 else { break }

            let wrc = buffer.withUnsafeBufferPointer { ptr in
                MD.afcFileWrite(c, handle, ptr.baseAddress!, read)
            }
            guard wrc == 0 else { throw AFCError.writeFailed(sent, wrc) }

            sent += read
            progress?(sent, fileSize)
        }
    }

    func close() {
        if let c = conn {
            _ = MD.afcClose(c)
            conn = nil
        }
    }

    deinit { close() }
}
