// "Send Diagnostic" sheet — one-click bug report with attachments.
//
// Wired from Help → Send Diagnostic… and ⌥-clicking the "?" in error banners.
// Sends to a self-hosted Bugsink instance via BugsinkClient. If the DSN is
// not configured, this sheet won't open — App.swift routes to the legacy
// reportBug() (mail.app) fallback instead.
//
// What goes in the report:
//   • User-typed "what happened" text (optional but encouraged).
//   • Diagnostic info string — app version, OS, device, ffmpeg source.
//   • Last 200 lines of /tmp/mediaporter-debug.log.
//   • Window screenshot (toggleable, on by default).
//
// Sentry tags carried:
//   release, environment, device_class, ios_version, ffmpeg_source.

import SwiftUI
import AppKit
import MediaPorterCore

struct SendDiagnosticSheet: View {
    let pipeline: PipelineController
    let onDismiss: () -> Void

    @State private var description: String = ""
    @State private var includeScreenshot: Bool = true
    @State private var includeLog: Bool = true
    @State private var sending: Bool = false
    @State private var sendResult: SendResult? = nil

    private enum SendResult {
        case sent(eventID: String)
        case failed(String)
    }

    private let logTailLines = 200
    private let logPath = "/tmp/mediaporter-debug.log"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 6) {
                Text("What happened?")
                    .font(.system(size: 12, weight: .semibold))
                Text("Describe what you were trying to do, what you saw, and what you expected. Optional, but helps us understand the context that won't show up in the log.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ZStack(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("Tried to send 4 episodes to iPhone, button said \u{201c}Send 4\u{201d} but click did nothing.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6).padding(.vertical, 6)
                    }
                    TextEditor(text: $description)
                        .font(.system(size: 12))
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                }
                .background(Color(NSColor.textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.3)))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Attached automatically")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                attachmentRow(
                    icon: "info.circle",
                    title: "Diagnostic info",
                    detail: "version, OS, device, ffmpeg path",
                    enabled: .constant(true), togglable: false
                )
                attachmentRow(
                    icon: "doc.text",
                    title: "Debug log (last \(logTailLines) lines)",
                    detail: logExists ? "from \(logPath)" : "no log yet — nothing to attach",
                    enabled: $includeLog, togglable: logExists
                )
                attachmentRow(
                    icon: "camera",
                    title: "Window screenshot",
                    detail: "current Mediaporter window only",
                    enabled: $includeScreenshot, togglable: true
                )
            }
            .padding(10)
            .background(Color.gray.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8))

            resultStrip

            HStack {
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: send) {
                    HStack(spacing: 6) {
                        if sending {
                            ProgressView().controlSize(.small)
                        }
                        Text(sending ? "Sending…" : "Send Diagnostic")
                    }
                    .frame(minWidth: 110)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sending)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Send Diagnostic")
                .font(.system(size: 16, weight: .semibold))
            Text("Goes directly to the developer's self-hosted Bugsink instance. Nothing is sent automatically — only when you click Send below.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func attachmentRow(
        icon: String, title: String, detail: String,
        enabled: Binding<Bool>, togglable: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if togglable {
                Toggle("", isOn: enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var resultStrip: some View {
        switch sendResult {
        case .sent(let id):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sent — thank you.")
                        .font(.system(size: 12, weight: .medium))
                    Text("Reference: \(id.prefix(8))…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(id, forType: .string)
                }
                .controlSize(.small)
            }
        case .failed(let msg):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(msg).font(.system(size: 11))
                Spacer()
            }
        case .none:
            EmptyView()
        }
    }

    private var logExists: Bool {
        FileManager.default.fileExists(atPath: logPath)
    }

    private func send() {
        sending = true
        sendResult = nil
        let descCopy = description
        let wantsScreenshot = includeScreenshot
        let wantsLog = includeLog
        let diag = diagnosticInfoString(pipeline: pipeline)
        let tags = diagnosticTags(pipeline: pipeline)

        Task { @MainActor in
            let screenshot: BugsinkClient.Attachment? = {
                guard wantsScreenshot else { return nil }
                guard let png = captureMainWindowPNG() else { return nil }
                return BugsinkClient.Attachment(
                    filename: "window.png",
                    contentType: "image/png",
                    data: png
                )
            }()

            let logAttach: BugsinkClient.Attachment? = {
                guard wantsLog, let tail = tailFile(path: logPath, lines: logTailLines) else { return nil }
                return BugsinkClient.Attachment(
                    filename: "debug.log",
                    contentType: "text/plain",
                    data: Data(tail.utf8)
                )
            }()

            let diagAttach = BugsinkClient.Attachment(
                filename: "diagnostic.txt",
                contentType: "text/plain",
                data: Data(diag.utf8)
            )

            var attachments: [BugsinkClient.Attachment] = [diagAttach]
            if let s = screenshot { attachments.append(s) }
            if let l = logAttach { attachments.append(l) }

            let summary = descCopy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "(no description) — \(diag.split(separator: "\n").first ?? "report")"
                : descCopy

            do {
                let id = try await BugsinkClient.send(
                    message: summary,
                    level: .info,
                    tags: tags,
                    contexts: diagnosticContexts(pipeline: pipeline),
                    attachments: attachments
                )
                sending = false
                sendResult = .sent(eventID: id)
            } catch {
                sending = false
                sendResult = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Screenshot capture

/// Grab a PNG of Mediaporter's frontmost window. CGWindowList APIs require
/// no special entitlement on macOS 14 for capturing the calling app's own
/// windows. Returns nil if the main window can't be located (rare).
@MainActor
func captureMainWindowPNG() -> Data? {
    guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
        return nil
    }
    let windowID = CGWindowID(window.windowNumber)
    guard let cg = CGWindowListCreateImage(
        .null,
        .optionIncludingWindow,
        windowID,
        [.bestResolution, .boundsIgnoreFraming]
    ) else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: cg)
    return bitmap.representation(using: .png, properties: [:])
}

// MARK: - Diagnostic tags / contexts

@MainActor
func diagnosticTags(pipeline: PipelineController) -> [String: String] {
    let info = Bundle.main.infoDictionary ?? [:]
    var t: [String: String] = [
        "app_version": info["CFBundleShortVersionString"] as? String ?? "dev",
    ]
    if let d = pipeline.deviceInfo {
        if !d.deviceClass.isEmpty { t["device_class"] = d.deviceClass }
        if !d.productType.isEmpty { t["product_type"] = d.productType }
        if !d.productVersion.isEmpty { t["ios_version"] = d.productVersion }
    } else {
        t["device_class"] = "none"
    }
    t["ffmpeg_source"] = Prerequisites.ffmpegSource.label
    t["device_connected"] = pipeline.isDeviceConnected ? "yes" : "no"
    return t
}

@MainActor
func diagnosticContexts(pipeline: PipelineController) -> [String: [String: Any]] {
    var os = [String: Any]()
    os["name"] = "macOS"
    os["version"] = ProcessInfo.processInfo.operatingSystemVersionString
    var arch = [String: Any]()
    var sysinfo = utsname()
    uname(&sysinfo)
    let archName: String = withUnsafePointer(to: &sysinfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
    }
    arch["arch"] = archName
    return ["os": os, "device": arch]
}

// MARK: - Log tail

/// Read the last N lines of a text file. Cheap for /tmp/mediaporter-debug.log
/// which rarely exceeds a few MB; we just read it whole and slice. Returns
/// nil if the file doesn't exist (caller decides whether to skip the
/// attachment or surface the empty state).
func tailFile(path: String, lines: Int) -> String? {
    guard FileManager.default.fileExists(atPath: path),
          let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        return nil
    }
    let split = text.split(separator: "\n", omittingEmptySubsequences: false)
    let tail = split.suffix(lines)
    return tail.joined(separator: "\n")
}
