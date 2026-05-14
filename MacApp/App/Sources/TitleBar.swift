// Custom titlebar — traffic lights (native, via hidden titlebar passthrough),
// centered app title + device pill, right-side Tweaks / Settings buttons.

import SwiftUI
import AppKit

struct TitleBar: View {
    @Environment(\.openSettings) private var openSettings
    let theme: Theme
    let accent: AccentKey
    let deviceConnected: Bool
    let deviceName: String

    var body: some View {
        ZStack {
            theme.chrome
                .background(.ultraThinMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.chromeBorder).frame(height: 1)
                }

            HStack(spacing: 12) {
                // Left padding reserves space for native traffic lights (~68px)
                Spacer().frame(width: 68)
                Spacer()

                TitleButton(systemImage: "gearshape",
                            theme: theme, action: { openSettings() },
                            help: "Settings")
            }
            .padding(.horizontal, 14)

            // Centered title
            HStack(spacing: 8) {
                AppGlyph(accent: accent)
                Text("Mediaporter")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text)
                if deviceConnected && !deviceName.isEmpty {
                    Text("·").foregroundStyle(theme.textFaint).font(.system(size: 12))
                    HStack(spacing: 4) {
                        Circle().fill(Color(red: 0.19, green: 0.82, blue: 0.35))
                            .frame(width: 6, height: 6)
                        Text(deviceName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textDim)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(height: 44)
    }
}

private struct TitleButton: View {
    let systemImage: String
    let theme: Theme
    let action: () -> Void
    let help: String
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(theme.textDim)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(hovering ? theme.rowHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct AppGlyph: View {
    // Accent kept for API compatibility — the in-app glyph is the brand mark
    // and stays fixed pink/black regardless of theme accent. Identity match
    // with the dock icon (rendered by AppIcon.swift) and the DMG icon.
    let accent: AccentKey

    var body: some View {
        Image(nsImage: Self.cached)
            .resizable()
            .interpolation(.high)
            .frame(width: 20, height: 20)
    }

    // Render once at 4× the target size for crisp retina down-scaling.
    // `AppIcon.render` builds the same artwork used for the dock + DMG icon.
    private static let cached: NSImage = AppIcon.render(size: 80)
}
