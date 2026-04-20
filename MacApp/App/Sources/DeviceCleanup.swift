// Device → Clean Up Staged Media Files flow.
// Destructive action: confirms via NSAlert with the scanned count + total size
// before deleting anything. Refreshes device free-space when done.

import AppKit
import Foundation
import MediaPorterCore

@MainActor
func promptAndCleanupStagedMedia(pipeline: PipelineController) async {
    guard pipeline.isDeviceConnected, let device = pipeline.deviceInfo else {
        showAlert(style: .warning, title: "No device connected",
                  message: "Connect an iPhone or iPad first.")
        return
    }

    pipeline.overallStatus = "Scanning staged media on \(device.displayName)…"
    let found = await pipeline.scanStagedMedia()
    pipeline.overallStatus = ""

    guard !found.isEmpty else {
        showAlert(style: .informational, title: "Nothing to clean up",
                  message: "No files found in /iTunes_Control/Music/F00…F49.")
        return
    }

    let paths = found.map(\.path)
    let totalBytes = found.reduce(Int64(0)) { $0 + $1.size }
    let sizeSuffix = totalBytes > 0 ? " (\(ByteFormat.short(totalBytes)))" : ""
    let confirm = NSAlert()
    confirm.alertStyle = .warning
    confirm.messageText = "Delete \(found.count) staged media file\(found.count == 1 ? "" : "s")\(sizeSuffix)?"
    confirm.informativeText = """
        This removes every file under /iTunes_Control/Music/F00…F49 on \
        \(device.displayName). Titles the TV app has already cached will keep \
        playing from local metadata until the device reboots; files that were \
        mid-sync will disappear. This cannot be undone.
        """
    confirm.addButton(withTitle: "Delete")
    confirm.addButton(withTitle: "Cancel")
    guard confirm.runModal() == .alertFirstButtonReturn else { return }

    pipeline.overallStatus = "Deleting \(paths.count) file\(paths.count == 1 ? "" : "s")…"
    let deleted = await pipeline.purgeStagedMedia(paths: paths)
    pipeline.overallStatus = "Deleted \(deleted) of \(paths.count)."

    showAlert(
        style: .informational,
        title: "Cleanup complete",
        message: "Removed \(deleted) of \(paths.count) file\(paths.count == 1 ? "" : "s") from \(device.displayName)."
    )
}

private func showAlert(style: NSAlert.Style, title: String, message: String) {
    let a = NSAlert()
    a.alertStyle = style
    a.messageText = title
    a.informativeText = message
    a.addButton(withTitle: "OK")
    a.runModal()
}
