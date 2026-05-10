// High-level sync API — upload-first architecture.
// Upload files via AFC first, then short ATC session for metadata + registration.
//
// Decomposed so PipelineController can pipeline transcode + upload:
//   prepareSyncFiles(...)         → allocate asset IDs + device paths up front
//   AFCUploader(device)           → hold one AFC connection open across many files
//   registerUploadedFiles(...)    → single short ATC session at end

import Foundation

struct SyncResult {
    let fileURL: URL
    let success: Bool
    let error: String?
    let devicePath: String?
}

/// A sync item with its pre-allocated asset ID + target device path.
struct PreparedSyncFile {
    let item: SyncItem
    let assetID: Int
    let devicePath: String
    let slot: String

    var asSyncFileInfo: SyncFileInfo {
        SyncFileInfo(item: item, assetID: assetID, devicePath: devicePath, slot: slot)
    }
}

/// Pre-allocate asset IDs + device paths for every item. Pure — does not touch the device.
func prepareSyncFiles(_ items: [SyncItem]) -> [PreparedSyncFile] {
    items.map { item in
        let (path, slot) = ATCSession.generateDevicePath()
        let assetID = ATCSession.generateAssetID()
        return PreparedSyncFile(item: item, assetID: assetID, devicePath: path, slot: slot)
    }
}

/// Long-lived AFC connection — upload many files over one handle.
final class AFCUploader {
    private let afc: AFCClient

    init(device: DeviceInfo) throws {
        self.afc = try AFCClient(device: device)
    }

    /// Upload a single prepared file, reporting byte-level progress.
    /// The `isCancelled` closure is polled between 1 MB chunks.
    func upload(
        _ file: PreparedSyncFile,
        progress: ((Int, Int) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws {
        afc.makedirs("/iTunes_Control/Music/\(file.slot)")
        try afc.writeFileStreaming(
            remotePath: file.devicePath,
            localURL: file.item.fileURL,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func close() { afc.close() }
}

/// Run a single short ATC session to register every already-uploaded file with the device.
///
/// After a multi-GB pipelined upload run, the device's medialibraryd /
/// atc-mediasvc daemons can take several seconds to settle before they're
/// ready for a new ATC session. We do a brief settle sleep, and if the
/// handshake fails (typically "No ReadyForSync received" on a still-busy
/// daemon) retry it once with a longer pause.
func registerUploadedFiles(
    device: DeviceInfo,
    files: [PreparedSyncFile],
    verbose: Bool = false
) throws {
    let syncFiles = files.map { $0.asSyncFileInfo }

    var lastError: Error?
    for attempt in 0..<2 {
        // Settle delay before each attempt — short before the first, longer
        // before the retry. Lets the device's media indexer catch up.
        let settle: UInt32 = attempt == 0 ? 3 : 8
        sleep(settle)

        do {
            let session = ATCSession(device: device, verbose: verbose)
            let (grappa, anchorStr) = try session.handshake()
            let newAnchor = String(Int(anchorStr)! + 1)

            let plistData = session.buildSyncPlist(files: syncFiles, anchor: Int(newAnchor)!)
            let cigData = try session.computeCIG(deviceGrappa: grappa, plistData: plistData)

            let registerAFC = try AFCClient(device: device)
            try session.register(
                afc: registerAFC,
                files: syncFiles,
                plistData: plistData,
                cigData: cigData,
                anchor: newAnchor
            )
            registerAFC.close()
            session.close()
            return
        } catch let err as SyncError {
            // Only retry handshake failures — anything past the handshake
            // (CIG, plist write, file complete) is likely a real protocol
            // problem and a second attempt won't help.
            if case .handshakeFailed = err {
                lastError = err
                continue
            }
            throw err
        }
    }
    throw lastError ?? SyncError.handshakeFailed("ATC handshake failed after retry")
}

/// One-shot sync: upload all files, then register. Kept for non-pipelined callers.
func syncFiles(
    items: [SyncItem],
    verbose: Bool = false,
    progress: ((String, Int, Int) -> Void)? = nil
) throws -> [SyncResult] {
    guard !items.isEmpty else { return [] }

    let device = try discoverDevice()
    if verbose { print("Device: \(device.udid)") }

    let prepared = prepareSyncFiles(items)

    if verbose { print("  Pre-uploading files via AFC...") }
    let uploader = try AFCUploader(device: device)
    for f in prepared {
        if verbose {
            print("  AFC: uploading \(f.item.fileURL.lastPathComponent) -> \(f.devicePath) (\(f.item.fileSize / 1_048_576) MB)")
        }
        try uploader.upload(f) { sent, total in
            progress?(f.item.title, sent, total)
        }
    }
    uploader.close()

    try registerUploadedFiles(device: device, files: prepared, verbose: verbose)

    return prepared.map { f in
        SyncResult(fileURL: f.item.fileURL, success: true, error: nil, devicePath: f.devicePath)
    }
}
