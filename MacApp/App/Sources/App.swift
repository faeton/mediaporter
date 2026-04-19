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
                    if let key = ConfigLoader.tmdbAPIKey() {
                        pipeline.tmdbAPIKey = key
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 780)

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
