// Help-menu bug reporting and diagnostics.
//
// Five actions wired from the Help menu in App.swift:
//   1. Send Diagnostic…         — opens a sheet that posts to the self-hosted
//                                 Bugsink instance (with optional screenshot +
//                                 log tail). Falls back to mail.app if no DSN.
//   2. Report a Bug via Mail…   — opens Mail with pre-filled diagnostics +
//                                 log attachment. Kept for users who don't
//                                 want their reports going to the dev's
//                                 server, or as a fallback when offline.
//   3. Reveal Debug Log in Finder — selects /tmp/mediaporter-debug.log
//   4. Stream Log in Terminal… — opens Terminal running `log stream` filtered to
//                                 the md.porter.MediaPorter OSLog subsystem
//   5. Copy Diagnostic Info     — version/OS/device/ffmpeg paths to pasteboard
//
// Nothing auto-uploads. Send Diagnostic only fires when the user clicks Send
// inside the sheet.

import AppKit
import Foundation
import SwiftUI
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

/// Help → Send Diagnostic… — primary entry point. If Bugsink is configured,
/// present the SwiftUI sheet so the user can attach a screenshot + log tail.
/// If not configured (DSN missing), fall through to the mail.app reporter so
/// the menu item never silently no-ops.
@MainActor
func sendDiagnostic(pipeline: PipelineController) {
    MetricsCollector.bump("send_diag_opened")
    guard BugsinkClient.isConfigured else {
        reportBug(pipeline: pipeline)
        return
    }
    presentDiagnosticSheet(pipeline: pipeline)
}

/// Strong references to in-flight sheet windows. NSApp's `beginSheet`
/// retains the window for its lifetime, but we also keep a reference until
/// the user closes the sheet so the SwiftUI state stays alive.
@MainActor
private var liveDiagnosticWindows: [NSWindow] = []

@MainActor
private func presentDiagnosticSheet(pipeline: PipelineController) {
    let host = NSHostingController(rootView: AnyView(EmptyView())) // replaced below
    let window = NSWindow(contentViewController: host)
    window.styleMask = [.titled, .closable]
    window.title = "Send Diagnostic"
    window.isMovableByWindowBackground = false

    let sheet = SendDiagnosticSheet(pipeline: pipeline) {
        liveDiagnosticWindows.removeAll { $0 === window }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }
    host.rootView = AnyView(sheet)
    host.view.setFrameSize(host.view.fittingSize)
    window.setContentSize(host.view.fittingSize)

    liveDiagnosticWindows.append(window)
    if let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
        main.beginSheet(window) { _ in }
    } else {
        window.makeKeyAndOrderFront(nil)
    }
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

/// Open Terminal with a live `log stream` filtered to our OSLog subsystem.
/// Faster + lower-friction than the alternatives (`log collect` snapshot →
/// Console.app needs the user to type the filter manually; Console.app has
/// no documented URL scheme for pre-filtering). `--style compact` is the
/// readable variant; users who want JSON can edit the command in Terminal.
@MainActor
func streamLogInTerminal() {
    let predicate = "subsystem == \"\(DebugLog.subsystem)\""
    // Escape backslashes + double quotes so the command survives being
    // embedded inside the AppleScript string literal below.
    let escaped = "log stream --predicate '\(predicate)' --info --style compact"
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
    tell application "Terminal"
        activate
        do script "\(escaped)"
    end tell
    """
    var error: NSDictionary?
    if let s = NSAppleScript(source: script) {
        s.executeAndReturnError(&error)
    }
    if let error {
        let alert = NSAlert()
        alert.messageText = "Couldn't open Terminal"
        alert.informativeText = "AppleScript error: \(error[NSAppleScript.errorMessage] ?? "unknown")"
        alert.alertStyle = .warning
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
