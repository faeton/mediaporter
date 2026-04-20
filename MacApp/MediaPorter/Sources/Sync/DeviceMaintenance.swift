// Device-side maintenance — scan and remove leftover media files in
// /iTunes_Control/Music/Fxx/ that accumulate from failed/interrupted syncs.
//
// The TV app can keep playing content whose files are gone (it reads from the
// MediaLibrary.sqlitedb cache), but the files still occupy disk. This utility
// lets the user reclaim that space with a clear blast radius: only the media
// staging directory is touched.

import Foundation

public struct DeviceMediaFile: Sendable, Identifiable {
    public let path: String
    public let slot: String     // e.g. "F23"
    public let name: String     // e.g. "ACER.mp4"
    public var id: String { path }
}

public enum DeviceMaintenance {
    /// Walk /iTunes_Control/Music/F00 .. F49 and return every regular-file entry.
    /// Non-existent slots are silently skipped.
    public static func scanStagingMedia(device: DeviceInfo) throws -> [DeviceMediaFile] {
        let afc = try AFCClient(device: device)
        defer { afc.close() }

        var found: [DeviceMediaFile] = []
        for i in 0..<50 {
            let slot = String(format: "F%02d", i)
            let dir = "/iTunes_Control/Music/\(slot)"
            for name in afc.listDirectory(dir) {
                found.append(DeviceMediaFile(
                    path: "\(dir)/\(name)",
                    slot: slot,
                    name: name
                ))
            }
        }
        return found
    }

    /// Remove each path via AFCRemovePath. Returns the number of successful deletes.
    /// Failures are silently skipped (already-deleted paths return non-zero).
    @discardableResult
    public static func removeFiles(device: DeviceInfo, paths: [String]) throws -> Int {
        let afc = try AFCClient(device: device)
        defer { afc.close() }

        var deleted = 0
        for path in paths {
            if afc.removePath(path) == 0 { deleted += 1 }
        }
        return deleted
    }
}
