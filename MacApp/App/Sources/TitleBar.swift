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
    let accent: AccentKey

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(
                LinearGradient(
                    colors: [accent.solid, accent.solid.opacity(0.78)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .frame(width: 20, height: 20)
            .overlay(
                ZStack {
                    // Play triangle
                    Path { p in
                        p.move(to: CGPoint(x: 4.3, y: 5))
                        p.addLine(to: CGPoint(x: 4.3, y: 15))
                        p.addLine(to: CGPoint(x: 11, y: 10))
                        p.closeSubpath()
                    }
                    .fill(Color.white)
                    // Dot (the "port")
                    Circle()
                        .fill(Color.white)
                        .frame(width: 3, height: 3)
                        .position(x: 15, y: 15)
                }
            )
            .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
    }
}
