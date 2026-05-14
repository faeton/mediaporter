// Help-menu bug reporting and diagnostics.
//
// Three actions wired from the Help menu in App.swift:
//   1. Report a Bug…           — opens Mail with pre-filled diagnostics + log attachment
//   2. Reveal Debug Log in Finder — selects /tmp/mediaporter-debug.log
//   3. Copy Diagnostic Info     — version/OS/device/ffmpeg paths to pasteboard
//
// Everything goes through the user (no auto-upload, no telemetry endpoint).
// If we later want crash capture, Sentry-cocoa goes on top of this without
// replacing it.

import AppKit
import Foundation
import MediaPorterCore

private let debugLogPath = "/tmp/mediaporter-debug.log"
private let reportRecipient = "bugs@porter.md"

/// Build a single human-readable block of "what version / what machine / what
/// device / where's ffmpeg". Used by both the email body and the
/// Copy-to-pasteboard action.
@MainActor
func diagnosticInfoString(pipeline: PipelineController) -> String {
    let info = Bundle.main.infoDictionary ?? [:]
    let shortVersion = info["CFBundleShortVersionString"] as? String ?? "dev"
    let build = info["CFBundleVersion"] as? String ?? "0"
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    let arch: String = {
        var sysinfo = utsname()
        uname(&sysinfo)
        let raw = withUnsafePointer(to: &sysinfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return raw
    }()

    var deviceLine = "(no device connected)"
    if pipeline.isDeviceConnected, let d = pipeline.deviceInfo {
        deviceLine = "\(d.displayName) — \(d.productType) / iOS \(d.productVersion)"
    }

    // Distinguish bundled (from the with-ffmpeg DMG) from system (brew/PATH)
    // so bug reports about codec/filter behavior land with the right context.
    let source = Prerequisites.ffmpegSource
    let ffmpeg = source.ffmpegPath.map { "\($0)  [\(source.label)]" } ?? "(not found)"
    let ffprobe = source.ffprobePath.map { "\($0)  [\(source.label)]" } ?? "(not found)"

    return """
    MediaPorter \(shortVersion) (\(build))
    macOS: \(os) on \(arch)
    Device: \(deviceLine)
    ffmpeg:  \(ffmpeg)
    ffprobe: \(ffprobe)
    """
}

/// Open Mail with a pre-filled bug report. Attaches the debug log file if it
/// exists. Falls back to plain mailto: if NSSharingService can't compose
/// (e.g. user has no default mail client configured).
@MainActor
func reportBug(pipeline: PipelineController) {
    let diagnostics = diagnosticInfoString(pipeline: pipeline)
    let body = """
    Describe what you tried and what went wrong:



    ---
    \(diagnostics)
    """

    let info = Bundle.main.infoDictionary ?? [:]
    let v = info["CFBundleShortVersionString"] as? String ?? "dev"
    let subject = "MediaPorter bug report — \(v)"

    let logURL = URL(fileURLWithPath: debugLogPath)
    let attachLog = FileManager.default.fileExists(atPath: debugLogPath)

    // Try NSSharingService first — gives us a proper file attachment in
    // Mail.app rather than a body-truncated mailto: URL.
    if let service = NSSharingService(named: .composeEmail) {
        service.recipients = [reportRecipient]
        service.subject = subject
        var items: [Any] = [body]
        if attachLog {
            items.append(logURL)
        }
        if service.canPerform(withItems: items) {
            service.perform(withItems: items)
            return
        }
    }

    // Fallback: mailto: URL (body gets URL-encoded, log can't be attached).
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = reportRecipient
    components.queryItems = [
        URLQueryItem(name: "subject", value: subject),
        URLQueryItem(name: "body", value: body),
    ]
    if let url = components.url {
        NSWorkspace.shared.open(url)
    }
}

/// Select the debug log in Finder. If the log doesn't exist yet (no logging
/// has happened this session), show a small alert explaining that.
@MainActor
func revealDebugLog() {
    let url = URL(fileURLWithPath: debugLogPath)
    if FileManager.default.fileExists(atPath: debugLogPath) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
        let alert = NSAlert()
        alert.messageText = "No debug log yet"
        alert.informativeText = """
        MediaPorter logs activity to \(debugLogPath) as you sync. The file \
        will appear here after the first sync or error.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Copy diagnostic info to the system pasteboard. For users who want to
/// paste into Discord / Twitter / a forum without composing an email.
@MainActor
func copyDiagnosticInfo(pipeline: PipelineController) {
    let info = diagnosticInfoString(pipeline: pipeline)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(info, forType: .string)
    // Brief confirmation — modal alert is heavy for "copied to clipboard",
    // but until we add toasts to the UI this is the only signal.
    let alert = NSAlert()
    alert.messageText = "Diagnostic info copied"
    alert.informativeText = info
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
