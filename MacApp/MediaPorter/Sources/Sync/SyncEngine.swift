// High-level sync API — upload-first architecture.
// Upload files via AFC first, then short ATC session for metadata + registration.

import Foundation

struct SyncResult {
    let fileURL: URL
    let success: Bool
    let error: String?
    let devicePath: String?
}

/// Sync files to connected iOS device. Upload-first: AFC upload, then ATC register.
func syncFiles(
    items: [SyncItem],
    verbose: Bool = false,
    progress: ((String, Int, Int) -> Void)? = nil
) throws -> [SyncResult] {
    guard !items.isEmpty else { return [] }

    // Discover device
    let device = try discoverDevice()
    if verbose { print("Device: \(device.udid)") }

    // Prepare file info
    var syncFiles: [SyncFileInfo] = []
    for item in items {
        let (path, slot) = ATCSession.generateDevicePath()
        let assetID = ATCSession.generateAssetID()
        syncFiles.append(SyncFileInfo(item: item, assetID: assetID, devicePath: path, slot: slot))
    }

    // Step 1: Pre-upload all files via AFC
    if verbose { print("  Pre-uploading files via AFC...") }
    let uploadAFC = try AFCClient(device: device)
    for f in syncFiles {
        uploadAFC.makedirs("/iTunes_Control/Music/\(f.slot)")
        if verbose {
            print("  AFC: uploading \(f.item.fileURL.lastPathComponent) -> \(f.devicePath) (\(f.item.fileSize / 1_048_576) MB)")
        }
        try uploadAFC.writeFileStreaming(
            remotePath: f.devicePath,
            localURL: f.item.fileURL
        ) { sent, total in
            progress?(f.item.title, sent, total)
        }
    }
    uploadAFC.close()

    // Step 2: Short ATC session — metadata + registration
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

    return syncFiles.map { f in
        SyncResult(fileURL: f.item.fileURL, success: true, error: nil, devicePath: f.devicePath)
    }
}
