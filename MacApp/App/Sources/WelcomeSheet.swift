// First-launch welcome sheet — sets expectations before the user drops files.
//
// Triggered once per install by ContentView, gated on `welcomeShown`
// (@AppStorage Bool). The sheet covers what the app actually does, where
// ffmpeg comes from, what API keys are optional, and Mediaporter's
// telemetry stance ("nothing automatic — Help → Send Diagnostic when you
// want to report something").
//
// The heartbeat opt-in lives at the bottom. Defaults to OFF — opt-in only,
// no dark-pattern pre-checks. The toggle persists via ConfigLoader and is
// also editable in Settings → Privacy.

import SwiftUI
import AppKit
import MediaPorterCore

struct WelcomeSheet: View {
    let onDismiss: () -> Void

    @State private var heartbeatOptIn: Bool = ConfigLoader.heartbeatOptIn()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(
                        icon: "iphone.gen3",
                        title: "What it does",
                        body: "Drag video files in. Mediaporter analyzes them, transcodes only what your iPhone or iPad can't play, and syncs to the TV app over the USB-C cable. The TV app is where the files land — not Files, not Photos."
                    )
                    section(
                        icon: "cable.connector",
                        title: "How it talks to your device",
                        body: "Plug an iPhone or iPad into the Mac with a USB-C cable and tap Trust when iOS asks. No iCloud, no AirDrop, no admin password, no system extensions. Wi-Fi is fine for the device pairing handshake but transfers go over the cable."
                    )
                    section(
                        icon: ffmpegIcon,
                        title: "Where ffmpeg lives",
                        body: ffmpegBody
                    )
                    section(
                        icon: "key",
                        title: "Optional API keys",
                        body: "Posters, episode art, and English-language subtitles come from TMDb and OpenSubtitles — both free, both optional. Add keys in Settings → Metadata to enable them. Without keys the app still works, you just won't get posters or auto-fetched SRTs."
                    )
                    section(
                        icon: "shield",
                        title: "Telemetry — nothing automatic",
                        body: "Mediaporter does not send anything home in the background. When you hit a bug, use Help → Send Diagnostic to ship a report (with optional screenshot + log tail) to the developer's self-hosted server. You choose every time."
                    )
                    heartbeatRow
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            footer
        }
        .frame(width: 560, height: 580)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome to Mediaporter")
                .font(.system(size: 22, weight: .semibold))
            Text("Two minutes on how it works, what it touches, and what it doesn't.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    private func section(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
    }

    private var heartbeatRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $heartbeatOptIn) {
                    Text("Send an anonymous weekly heartbeat")
                        .font(.system(size: 13, weight: .semibold))
                }
                .onChange(of: heartbeatOptIn) { _, new in
                    ConfigLoader.saveHeartbeatOptIn(new)
                }
                Text("Lets the developer see how many active installs there are, on which macOS versions and device classes. No filenames, no UDIDs, no usage events. You can flip this any time in Settings → Privacy.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Link(destination: URL(string: "https://porter.md")!) {
                Text("porter.md ↗").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
            Button("Got it") {
                ConfigLoader.saveHeartbeatOptIn(heartbeatOptIn)
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.gray.opacity(0.06))
    }

    private var ffmpegIcon: String {
        switch Prerequisites.ffmpegSource {
        case .bundled: return "shippingbox.fill"
        case .system:  return "wrench.and.screwdriver"
        case .missing: return "exclamationmark.triangle"
        }
    }

    private var ffmpegBody: String {
        switch Prerequisites.ffmpegSource {
        case .bundled:
            return "This build ships with ffmpeg + ffprobe baked in. Nothing to install. Transcodes use the bundled binaries."
        case .system:
            return "Using ffmpeg + ffprobe from your $PATH (likely Homebrew). If you'd rather not manage them yourself, install the \u{201c}with-ffmpeg\u{201d} DMG from porter.md."
        case .missing:
            return "ffmpeg is not on $PATH and this build doesn't bundle it. Install via Homebrew (brew install ffmpeg) or download the \u{201c}with-ffmpeg\u{201d} DMG from porter.md. Without it, analyze and transcode are disabled."
        }
    }
}
