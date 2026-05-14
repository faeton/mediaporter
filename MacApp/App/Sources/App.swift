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
                    // Hand the delegate a reference so applicationShouldTerminate
                    // can check for in-flight work before honoring Cmd-Q.
                    AppDelegate.sharedPipeline = pipeline
                    pipeline.startDeviceMonitoring()
                    pipeline.startFFmpegMonitoring()
                    pipeline.refreshLeftovers()
                    if let key = ConfigLoader.tmdbAPIKey() {
                        pipeline.tmdbAPIKey = key
                    }
                    pipeline.openSubtitlesAPIKey = ConfigLoader.openSubtitlesAPIKey() ?? ""
                    pipeline.openSubtitlesUsername = ConfigLoader.openSubtitlesUsername() ?? ""
                    pipeline.openSubtitlesPassword = ConfigLoader.openSubtitlesPassword() ?? ""
                    pipeline.openSubtitlesLanguages = ConfigLoader.openSubtitlesLanguages()
                    pipeline.hwAccel = ConfigLoader.hwAccelEnabled()
                    pipeline.airplayTo4K = ConfigLoader.airplayTo4K()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .help) {
                Button("MediaPorter Documentation") {
                    if let url = URL(string: "https://porter.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
                Button("Report a Bug…") {
                    reportBug(pipeline: pipeline)
                }
                Button("Reveal Debug Log in Finder") {
                    revealDebugLog()
                }
                Button("Copy Diagnostic Info") {
                    copyDiagnosticInfo(pipeline: pipeline)
                }
            }
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
    /// Reference to the active pipeline. Set by the App's onAppear so the
    /// terminate handler can inspect in-flight work without owning the
    /// state model itself. Weak so we don't keep the controller alive
    /// during a clean shutdown.
    static weak var sharedPipeline: PipelineController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppIcon.install()
        // Reap any ffmpeg children left running from a previous hard-kill
        // before we start dispatching new transcodes that would compete with
        // them for disk + CPU.
        ZombieSweep.sweep()
        // ffmpeg pre-flight: log the source for debug, but don't surface a
        // modal alert. ContentView shows a persistent banner while ffmpeg
        // is missing — the user sees it the entire time, vs a one-shot
        // dialog they can dismiss and forget.
        let source = Prerequisites.ffmpegSource
        DebugLog.write("prereq.ffmpeg", "source=\(source.label) ffmpeg=\(source.ffmpegPath ?? "-") ffprobe=\(source.ffprobePath ?? "-")")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let pipeline = AppDelegate.sharedPipeline, pipeline.isRunning else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Quit while sync is running?"
        alert.informativeText = """
        MediaPorter is currently \(pipeline.overallStatus.isEmpty ? "syncing files to your device" : pipeline.overallStatus.lowercased()).

        Quitting now will abort the in-flight transcode/upload. Files already on the device stay there but may not be registered with the TV app — you can register them later via Device → Recover Orphaned Uploads.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        let response = alert.runModal()
        return response == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
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
