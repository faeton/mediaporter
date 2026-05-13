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
    let registered = await pipeline.loadRegisteredPaths()
    pipeline.overallStatus = ""

    guard !found.isEmpty else {
        showAlert(style: .informational, title: "Nothing to clean up",
                  message: "No files found in /iTunes_Control/Music/F00…F49.")
        return
    }

    // Cross-reference scanned files against the device's registered paths.
    // True orphans: not in the registered set AND not sitting in a slot whose
    // DB row exists but hasn't bound a filename yet (those rows resolve to a
    // pendingSlot — anything in there gets kept to dodge the post-sync
    // binding-lag race that drops `item_extra.location='' temporarily).
    let registeredCount = found.filter { registered.paths.contains($0.path) }.count
    let pendingProtected = found.filter {
        !registered.paths.contains($0.path) && registered.pendingSlots.contains($0.slot)
    }
    let orphans = found.filter {
        !registered.paths.contains($0.path) && !registered.pendingSlots.contains($0.slot)
    }

    guard !orphans.isEmpty else {
        showAlert(
            style: .informational,
            title: "No orphans found",
            message: "\(registeredCount) staged file(s) are registered with the device's library — nothing to free."
        )
        return
    }

    let orphanPaths = orphans.map(\.path)
    let totalBytes = orphans.reduce(Int64(0)) { $0 + $1.size }
    let sizeSuffix = totalBytes > 0 ? " (\(ByteFormat.short(totalBytes)))" : ""
    let confirm = NSAlert()
    confirm.alertStyle = .warning
    confirm.messageText = "Delete \(orphans.count) orphan file\(orphans.count == 1 ? "" : "s")\(sizeSuffix)?"
    var info = """
        Keeping \(registeredCount) file(s) that the TV app's library references. \
        The \(orphans.count) orphan(s) are leftovers from failed or abandoned \
        syncs — nothing on the device points to them. This cannot be undone.
        """
    if !pendingProtected.isEmpty {
        info += "\n\nAlso skipping \(pendingProtected.count) file(s) in slots with in-flight library bindings (recent sync hasn't fully linked them yet)."
    }
    confirm.informativeText = info
    confirm.addButton(withTitle: "Delete Orphans")
    confirm.addButton(withTitle: "Cancel")
    guard confirm.runModal() == .alertFirstButtonReturn else { return }

    pipeline.overallStatus = "Deleting \(orphanPaths.count) orphan(s)…"
    let deleted = await pipeline.purgeStagedMedia(paths: orphanPaths)
    pipeline.overallStatus = "Deleted \(deleted) of \(orphanPaths.count)."

    showAlert(
        style: .informational,
        title: "Cleanup complete",
        message: "Removed \(deleted) of \(orphanPaths.count) orphan(s); kept \(registeredCount) registered file(s) on \(device.displayName)."
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
