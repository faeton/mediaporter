// Empty state — animated floating iPad silhouette with pulsing drop-hint ring.

import SwiftUI

struct EmptyStateView: View {
    let theme: Theme
    let accent: AccentKey

    @State private var float: CGFloat = 0
    @State private var ring: CGFloat = 0

    private var bodyFill: Color { theme.dark ? Color(hex: 0x2A2A2E) : Color(hex: 0xD5DAE3) }
    private var screenFill: Color { theme.dark ? Color(hex: 0x0F0F12) : Color(hex: 0x1F2024) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            illustration
                .frame(width: 280, height: 220)
                .padding(.bottom, 28)
            Text("Drop videos to send them to your iPad")
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(theme.text)
                .padding(.bottom, 6)
            Text("Analyze, transcode, tag and upload — done automatically.\n" +
                 "Expand any file to adjust audio tracks, subtitles or resolution.")
                .font(.system(size: 13))
                .foregroundStyle(theme.textDim)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 24)

            HStack(spacing: 6) {
                ForEach(["MKV", "MP4", "AVI", "MOV", "TS", "M4V"], id: \.self) { ext in
                    Text(ext)
                        .font(.system(size: 11, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(theme.pillText)
                    if ext != "M4V" {
                        Text("·").foregroundStyle(theme.pillText.opacity(0.6))
                            .font(.system(size: 11))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(theme.pill))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .onAppear { runAnimations() }
    }

    private var illustration: some View {
        ZStack {
            // Ground shadow
            Ellipse()
                .fill(Color.black.opacity(0.15))
                .frame(width: 140, height: 10)
                .scaleEffect(x: 1 + 0.05 * sin(float), y: 1, anchor: .center)
                .offset(y: 100)

            // Floating iPad
            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .fill(bodyFill)
                    .frame(width: 100, height: 170)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13)
                            .strokeBorder(theme.chromeBorder, lineWidth: 0.6)
                    )
                RoundedRectangle(cornerRadius: 5)
                    .fill(screenFill)
                    .frame(width: 88, height: 158)

                // Screen top bar hint
                VStack {
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(accent.solid.opacity(0.8))
                            .frame(width: 30, height: 2)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 14, height: 2)
                        Spacer()
                    }
                    .padding(.top, 8).padding(.leading, 6)
                    Spacer()
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.04))
                        .frame(width: 76, height: 15)
                        .padding(.bottom, 8)
                }
                .frame(width: 88, height: 158)

                // Pulsing drop ring
                Circle()
                    .strokeBorder(accent.solid, lineWidth: 1)
                    .frame(width: 36 + ring, height: 36 + ring)
                    .opacity(Double(1 - ring / 24))
                Circle()
                    .fill(accent.solid.opacity(0.18))
                    .frame(width: 24, height: 24)
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent.solid)
            }
            .offset(y: -4 * sin(float))
        }
    }

    private func runAnimations() {
        withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: false)) {
            float = .pi * 2
        }
        withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: false)) {
            ring = 24
        }
    }
}
