// MediaPorter — macOS app for transferring video to iPad/iPhone TV app.
//
// Layout (Mediaporter design, 2026-04-19):
//   • Titlebar (custom, hidden native) — app glyph · Mediaporter · device pill | Tweaks · Settings
//   • Left column: file list with inline per-row expansion
//   • Right column: device "destination" (iPad silhouette + storage)
//   • Bottom: batch timeline (Analyze → Transcode → Upload)

import SwiftUI
import AppKit
import MediaPorterCore

@main
struct MediaPorterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var pipeline = PipelineController()
    @State private var tweaks = Tweaks()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(pipeline)
                .environment(tweaks)
                .preferredColorScheme(tweaks.dark ? .dark : .light)
                .onAppear {
                    pipeline.startDeviceMonitoring()
                    pipeline.refreshLeftovers()
                    if let key = ConfigLoader.tmdbAPIKey() {
                        pipeline.tmdbAPIKey = key
                    }
                    pipeline.openSubtitlesAPIKey = ConfigLoader.openSubtitlesAPIKey() ?? ""
                    pipeline.openSubtitlesUsername = ConfigLoader.openSubtitlesUsername() ?? ""
                    pipeline.openSubtitlesPassword = ConfigLoader.openSubtitlesPassword() ?? ""
                    pipeline.openSubtitlesLanguages = ConfigLoader.openSubtitlesLanguages()
                    pipeline.hwAccel = ConfigLoader.hwAccelEnabled()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandMenu("Device") {
                Button(pipeline.hasPendingRegistration
                       ? "Retry Registration (\(pipeline.pendingRegistrationCount) files)"
                       : "Retry Registration") {
                    Task { await pipeline.retryRegistration() }
                }
                .disabled(!pipeline.hasPendingRegistration
                          || !pipeline.isDeviceConnected
                          || pipeline.isRunning)
                .keyboardShortcut("R", modifiers: [.command, .shift])

                Button("Discard Pending Registration") {
                    pipeline.discardPendingRegistration()
                }
                .disabled(!pipeline.hasPendingRegistration || pipeline.isRunning)

                Divider()

                // Use this when in-memory pending state is gone (app was
                // closed, or the failure happened before the retry feature
                // existed). Walks AFC, matches device files by exact byte
                // size to FileJobs whose transcoded outputs are still on
                // disk, and registers without re-upload.
                Button("Recover Orphaned Uploads…") {
                    Task {
                        let result = await pipeline.recoverOrphans()
                        await MainActor.run { showRecoveryResult(result) }
                    }
                }
                .disabled(!pipeline.isDeviceConnected || pipeline.isRunning)

                Divider()

                Button("Clean Up Staged Media Files…") {
                    Task { await promptAndCleanupStagedMedia(pipeline: pipeline) }
                }
                .disabled(!pipeline.isDeviceConnected || pipeline.isRunning)
                .keyboardShortcut("K", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(pipeline)
                .environment(tweaks)
                .preferredColorScheme(tweaks.dark ? .dark : .light)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
func showRecoveryResult(_ r: PipelineController.RecoveryResult) {
    let alert = NSAlert()
    if let err = r.error {
        alert.messageText = "Recovery failed"
        alert.informativeText = """
        \(err)

        Local /tmp m4v files: \(r.localFound)
        Device orphan files: \(r.deviceFound)
        """
        alert.alertStyle = .critical
    } else if r.registered == 0 {
        alert.messageText = "Nothing to recover"
        alert.informativeText = """
        Local /tmp m4v files found: \(r.localFound)
        Device orphan files found: \(r.deviceFound)
        Matched by exact byte size: 0

        If both numbers are 0, there's nothing to do — the device is clean and \
        the local tempdir has no leftovers. If the device has files but local \
        is 0, the temp /tmp transcodes were already cleared (likely by an app \
        quit) — re-run the sync from scratch.
        """
        alert.alertStyle = .informational
    } else {
        alert.messageText = "Recovered \(r.registered) file(s)"
        alert.informativeText = """
        Registered: \(r.registered)
        Device orphans without a local match: \(r.deviceUnmatched)
        Local m4v files without a device match: \(r.candidatesUnmatched)

        \(r.deviceUnmatched > 0 ? "Run Clean Up Staged Media to free the unmatched device files." : "")
        """
        alert.alertStyle = .informational
    }
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
