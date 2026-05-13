// Kill orphan ffmpeg processes left over from a previous crash.
//
// Background: `ActiveProcesses.cancelAll()` (Transcoder.swift) only fires on
// graceful Swift exit. SIGKILL of the app, panic, or a brutal force-quit
// leaves orphan ffmpeg children writing to temp files. Re-launching the app
// would then race with leftovers that still hold partial outputs open and
// burn CPU for hours.
//
// Strategy: at launch, list every ffmpeg process on the system, keep only
// the ones whose command line references our temp dir prefix, and SIGKILL
// them. The temp-dir-prefix filter is what makes this safe — if the user
// happens to have an unrelated ffmpeg encode running (yt-dlp, a manual
// session), it does not match our prefix and is left alone.

import Foundation

public enum ZombieSweep {
    public static func sweep() {
        let tempPrefix = FileManager.default
            .temporaryDirectory
            .resolvingSymlinksInPath()
            .path
        guard !tempPrefix.isEmpty, tempPrefix != "/" else { return }

        let mine = pid_t(ProcessInfo.processInfo.processIdentifier)
        for pid in pgrepFfmpeg() where pid != mine {
            guard let cmd = commandLine(for: pid),
                  cmd.contains(tempPrefix) else { continue }
            kill(pid, SIGKILL)
            DebugLog.write("zombie.killed", "pid=\(pid) cmd=\(cmd.prefix(160))")
        }
    }

    private static func pgrepFfmpeg() -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "ffmpeg"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) }
    }

    private static func commandLine(for pid: pid_t) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", String(pid), "-o", "command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8) ?? ""
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
