// Right column — iPad silhouette + storage bar + connection pill.

import SwiftUI
import MediaPorterCore

struct DeviceColumnView: View {
    let theme: Theme
    let accent: AccentKey
    let jobs: [FileJob]
    let canSendNow: Bool
    let onSend: () -> Void
    @Environment(PipelineController.self) private var pipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Destination")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.textDim)
                Spacer()
                if pipeline.availableDevices.count > 1 {
                    DevicePickerMenu(theme: theme, accent: accent)
                }
            }

            HStack {
                Spacer()
                DeviceSilhouette(
                    connected: pipeline.isDeviceConnected,
                    deviceClass: pipeline.deviceInfo?.deviceClass ?? "iPad",
                    theme: theme,
                    accent: accent
                )
                Spacer()
            }
            .padding(.top, 14)
            .padding(.bottom, 6)

            if pipeline.isDeviceConnected, let info = pipeline.deviceInfo {
                deviceBlock(info: info)
                if canSendNow { sendButton }
            } else {
                noDeviceBlock
            }

            Spacer()
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// "iPad" / "iPhone" / "iPod" / "device" — used in user-facing copy so the
    /// button matches what's actually plugged in. Falls back to "device" when
    /// lockdown hasn't returned a class yet (rare, only the first second after
    /// connect) or when something unexpected is attached.
    private var deviceClassLabel: String {
        let cls = pipeline.deviceInfo?.deviceClass ?? ""
        return cls.isEmpty ? "device" : cls
    }

    private var sendButton: some View {
        let pendingCount = jobs.filter { $0.status == .analyzed || $0.status == .ready }.count
        return Button(action: onSend) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                Text("Send \(pendingCount) to \(deviceClassLabel)")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(accent.solid)
            )
            .shadow(color: accent.solid.opacity(0.4), radius: 6, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func deviceBlock(info: DeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Name / model
            VStack(spacing: 2) {
                Text(info.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(modelLine(info))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textDim)
                    .multilineTextAlignment(.center)
                // One value, not two — the point-height (e.g. "852p") already
                // shows up in the RECOMMENDED banner with context, so repeating
                // it here next to the pixel res just looks like a duplicate.
                if let res = info.nativeResolution {
                    Text(res)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.textFaint)
                } else {
                    Text(info.screenDescription)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.textFaint)
                }
            }
            .frame(maxWidth: .infinity)

            StorageBar(
                theme: theme, accent: accent, jobs: jobs,
                deviceFree: pipeline.deviceFreeBytes,
                deviceTotal: pipeline.deviceTotalBytes
            )

            connectionCard

            recommendationCard(info: info)

            if let stats = pipeline.lastRunStats, stats.runEnd != nil {
                RunSummaryCard(theme: theme, accent: accent, stats: stats)
            }
        }
    }

    private func modelLine(_ info: DeviceInfo) -> String {
        var parts: [String] = []
        if !info.modelName.isEmpty { parts.append(info.modelName) }
        if !info.productVersion.isEmpty { parts.append("iOS \(info.productVersion)") }
        return parts.joined(separator: " · ")
    }

    private var noDeviceBlock: some View {
        VStack(spacing: 6) {
            Text("No device")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("Connect an iPhone or iPad via USB.\nTrust the computer if prompted.")
                .font(.system(size: 11))
                .foregroundStyle(theme.textDim)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var connectionCard: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.19, green: 0.82, blue: 0.35).opacity(0.18))
                Image(systemName: "cable.connector")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("USB-C · Apple TV app")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.text)
                Text(pipelineStatusText)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textDim)
            }
            Spacer()
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.panelBorder, lineWidth: 1)
        )
    }

    private var pipelineStatusText: String {
        if pipeline.isRunning { return pipeline.overallStatus.isEmpty ? "Working…" : pipeline.overallStatus }
        let incoming = jobs.filter { ![.synced, .failed].contains($0.status) }
        if incoming.isEmpty { return "Ready." }
        let totalMB = incoming.reduce(0) { $0 + $1.fileSizeMB }
        return "\(incoming.count) incoming · \(fmtSizeMB(totalMB))"
    }

    private func recommendationCard(info: DeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("RECOMMENDED")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(accent.solid)
            Text(recommendationCopy(info: info))
                .font(.system(size: 12))
                .foregroundStyle(theme.text)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(accent.soft, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accent.ring, lineWidth: 1)
        )
    }

    /// Three modes, in order of priority:
    /// - AirPlay/4K: user said the device panel size is irrelevant. Keep originals.
    /// - Tight storage: incoming bytes > 50% of device free. Push downscale harder.
    /// - Plenty of room: standard sweet-spot copy + nudge toward the Settings toggle.
    private func recommendationCopy(info: DeviceInfo) -> String {
        let deviceLabel = info.deviceClass.isEmpty ? "device" : info.deviceClass
        let recLabel = recommendedLabel(info.suggestedResolution)

        if pipeline.airplayTo4K {
            return "Keeping originals — you AirPlay/cast to a 4K display, so the \(deviceLabel)'s panel size doesn't constrain quality. Heavy files just need the disk space."
        }

        let incomingBytes = jobs
            .filter { ![.synced, .failed].contains($0.status) }
            .reduce(0) { $0 + Int64($1.fileSizeMB) * 1024 * 1024 }
        if let free = pipeline.deviceFreeBytes,
           incomingBytes > 0,
           incomingBytes > free / 2 {
            return "Library is tight against free space (\(ByteFormat.short(free)) left). Downscaling to \(recLabel) for this \(deviceLabel)'s screen frees a lot of room with no visible loss."
        }

        return "\(recLabel) is the sweet spot for this \(deviceLabel)'s display. AirPlaying to a 4K TV instead? Flip the toggle in Settings → Appearance to keep originals."
    }

    private func recommendedLabel(_ r: ResolutionLimit) -> String {
        switch r {
        case .tiny: return "360p"
        case .sd: return "480p"
        case .hd: return "720p"
        case .fhd: return "1080p"
        case .uhd4k: return "4K"
        case .original: return "Original"
        }
    }
}

// MARK: - Device picker

/// Compact menu shown only when ≥2 devices are attached. Lets the user override
/// the auto-pick (iPad preferred). Sticky until the chosen device disconnects.
private struct DevicePickerMenu: View {
    let theme: Theme
    let accent: AccentKey
    @Environment(PipelineController.self) private var pipeline

    var body: some View {
        Menu {
            Button {
                pipeline.selectDevice(udid: nil)
            } label: {
                Label("Auto (iPad first)", systemImage: pipeline.selectedDeviceUDID == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(pipeline.availableDevices, id: \.udid) { dev in
                Button {
                    pipeline.selectDevice(udid: dev.udid)
                } label: {
                    let checked = pipeline.selectedDeviceUDID == dev.udid
                    Label(
                        "\(dev.displayName) · \(dev.deviceClass.isEmpty ? "iOS" : dev.deviceClass)",
                        systemImage: checked ? "checkmark" : ""
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.stack.badge.play")
                    .font(.system(size: 10, weight: .medium))
                Text("\(pipeline.availableDevices.count) devices")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(accent.solid)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(accent.soft, in: Capsule())
            .overlay(Capsule().strokeBorder(accent.ring, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Storage bar

private struct StorageBar: View {
    let theme: Theme
    let accent: AccentKey
    let jobs: [FileJob]
    let deviceFree: Int64?
    let deviceTotal: Int64?

    private var incomingBytes: Int64 {
        Int64(jobs.filter { ![.synced, .failed].contains($0.status) }
            .reduce(0) { $0 + $1.fileSize })
    }

    var body: some View {
        if let total = deviceTotal, let free = deviceFree, total > 0 {
            realBar(total: total, free: free)
        } else {
            placeholderBar
        }
    }

    private func realBar(total: Int64, free: Int64) -> some View {
        let used = max(0, total - free)
        let incoming = min(incomingBytes, free) // can't project more than free
        let usedFrac = Double(used) / Double(total)
        let incomingFrac = Double(incoming) / Double(total)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Device storage")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textDim)
                Spacer()
                Text("\(ByteFormat.short(free)) free")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.text)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.divider)
                    // Already used
                    Capsule().fill(theme.textDim.opacity(0.35))
                        .frame(width: geo.size.width * usedFrac)
                    // Incoming (projected)
                    Capsule().fill(accent.solid.opacity(0.65))
                        .frame(width: geo.size.width * incomingFrac)
                        .offset(x: geo.size.width * usedFrac)
                }
            }
            .frame(height: 8)
            HStack {
                Text("\(ByteFormat.short(used)) used · \(ByteFormat.short(total)) total")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.textFaint)
                Spacer()
                if incoming > 0 {
                    Text("+\(ByteFormat.short(incoming)) incoming")
                        .font(.system(size: 9))
                        .foregroundStyle(accent.solid.opacity(0.85))
                }
            }
        }
    }

    private var placeholderBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Incoming")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textDim)
                Spacer()
                Text(ByteFormat.short(incomingBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.text)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(theme.divider).frame(height: 8)
                Capsule().fill(accent.solid.opacity(0.4))
                    .frame(width: min(240, Double(incomingBytes) / 1e9 * 6), height: 8)
            }
            Text("Polling device storage…")
                .font(.system(size: 9))
                .foregroundStyle(theme.textFaint)
        }
    }
}

// MARK: - Run summary

private struct RunSummaryCard: View {
    let theme: Theme
    let accent: AccentKey
    let stats: PipelineStats

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))
                    .font(.system(size: 12))
                Text("Last run")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(theme.text)
                Spacer()
                Text(fmtDuration(stats.totalWallSeconds))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }

            if stats.totalUploadBytes > 0 {
                summaryRow(
                    label: "Uploaded",
                    value: "\(ByteFormat.short(stats.totalUploadBytes)) in \(fmtDuration(stats.totalUploadSeconds))"
                )
                if let avg = stats.avgUploadMBps {
                    let peak = stats.peakUploadMBps ?? avg
                    summaryRow(
                        label: "Throughput",
                        value: String(format: "avg %.0f MB/s · peak %.0f MB/s", avg, peak)
                    )
                }
            }
            if stats.totalTranscodeSeconds > 0 {
                summaryRow(label: "Transcoded", value: fmtDuration(stats.totalTranscodeSeconds))
            }
            if let macDelta = stats.macFreeDelta {
                summaryRow(label: "Mac free", value: ByteFormat.signed(macDelta))
            }
            if let devDelta = stats.deviceFreeDelta {
                summaryRow(label: "Device free", value: ByteFormat.signed(devDelta))
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.panelBorder, lineWidth: 1)
        )
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(theme.textDim)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.text)
        }
    }
}

// MARK: - iPad silhouette

/// Connected-device silhouette. Reshapes itself to roughly match the
/// device class — iPad is wide-ish, iPhone is narrow + tall with a Dynamic
/// Island, iPod has a chunky home-button bezel below the screen. Anything
/// unknown falls back to the iPad shape.
struct DeviceSilhouette: View {
    let connected: Bool
    let deviceClass: String
    let theme: Theme
    let accent: AccentKey

    private var bodyFill: Color { theme.dark ? Color(hex: 0x28282C) : Color(hex: 0xD5DAE3) }
    private var screenFill: Color { theme.dark ? Color(hex: 0x0F0F12) : Color(hex: 0x1F2024) }

    private struct Shape {
        let bodyW: CGFloat, bodyH: CGFloat
        let screenW: CGFloat, screenH: CGFloat
        let cornerRadius: CGFloat
        let screenCorner: CGFloat
        /// Vertical offset of the screen relative to body center. Negative =
        /// up. iPod's home-button bezel pushes the screen up; iPad/iPhone keep
        /// the screen centered.
        let screenOffsetY: CGFloat
        /// Top-bezel feature: dot (iPad camera), notch, or pill (Dynamic Island).
        let topFeature: TopFeature
        /// iPod home-button bezel size; nil for iPhone/iPad.
        let homeButton: CGFloat?
    }
    private enum TopFeature { case cameraDot, dynamicIsland, none }

    private var shape: Shape {
        switch deviceClass.lowercased() {
        case "iphone":
            // ~9:19.5 aspect — modern Pro with Dynamic Island. Body 78×170,
            // screen fills almost the entire face (slim symmetric bezels).
            return Shape(
                bodyW: 78, bodyH: 168,
                screenW: 70, screenH: 156,
                cornerRadius: 18, screenCorner: 14,
                screenOffsetY: 0,
                topFeature: .dynamicIsland,
                homeButton: nil
            )
        case "ipod":
            // Classic iPod touch: ~3:5 ratio, thick bottom bezel for the
            // home button, narrower than an iPhone Pro.
            return Shape(
                bodyW: 76, bodyH: 156,
                screenW: 64, screenH: 116,
                cornerRadius: 10, screenCorner: 4,
                screenOffsetY: -8,
                topFeature: .cameraDot,
                homeButton: 12
            )
        default:
            // iPad — original proportions.
            return Shape(
                bodyW: 110, bodyH: 148,
                screenW: 98, screenH: 136,
                cornerRadius: 12, screenCorner: 4,
                screenOffsetY: 0,
                topFeature: .cameraDot,
                homeButton: nil
            )
        }
    }

    var body: some View {
        let s = shape
        VStack(spacing: 0) {
            ZStack {
                // Body
                RoundedRectangle(cornerRadius: s.cornerRadius)
                    .fill(bodyFill)
                    .frame(width: s.bodyW, height: s.bodyH)
                    .overlay(
                        RoundedRectangle(cornerRadius: s.cornerRadius)
                            .strokeBorder(theme.chromeBorder, lineWidth: 0.5)
                    )

                // Screen
                RoundedRectangle(cornerRadius: s.screenCorner)
                    .fill(screenFill)
                    .frame(width: s.screenW, height: s.screenH)
                    .offset(y: s.screenOffsetY)
                    .overlay(
                        Group {
                            if connected {
                                screenContents(width: s.screenW, height: s.screenH)
                                    .frame(width: s.screenW, height: s.screenH)
                                    .clipShape(RoundedRectangle(cornerRadius: s.screenCorner))
                            }
                        }
                        .offset(y: s.screenOffsetY)
                    )

                // Top bezel feature
                topFeature(s)

                // iPod home button
                if let hb = s.homeButton {
                    Circle()
                        .strokeBorder(
                            theme.dark ? Color(hex: 0x3A3A3F) : Color(hex: 0xB0B6C2),
                            lineWidth: 1
                        )
                        .frame(width: hb, height: hb)
                        .offset(y: s.bodyH / 2 - hb / 2 - 6)
                }
            }
            // Shadow
            Ellipse()
                .fill(Color.black.opacity(0.2))
                .frame(width: s.bodyW * 0.87, height: 10)
                .blur(radius: 3)
                .offset(y: -4)

            if connected {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(red: 0.19, green: 0.82, blue: 0.35))
                        .frame(width: 5, height: 5)
                    Text("CONNECTED")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    Capsule().fill(Color(red: 0.19, green: 0.82, blue: 0.35).opacity(0.15))
                )
                .overlay(
                    Capsule().strokeBorder(Color(red: 0.19, green: 0.82, blue: 0.35).opacity(0.3), lineWidth: 0.5)
                )
                .offset(y: -4)
            }
        }
    }

    /// Mock TV-app grid drawn inside the device screen. Number of columns
    /// scales to whichever device shape we're rendering — 3 cols for iPad,
    /// 2 for iPhone/iPod where 3 looked cramped.
    @ViewBuilder
    private func screenContents(width: CGFloat, height: CGFloat) -> some View {
        let cols = width > 80 ? 3 : 2
        let titleWidth = min(width * 0.45, 36)
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(accent.solid.opacity(0.9))
                    .frame(width: titleWidth, height: 3)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.25))
                    .frame(width: titleWidth * 0.55, height: 3)
                Spacer()
            }
            .padding(.top, 6)
            .padding(.horizontal, 4)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: cols),
                spacing: 4
            ) {
                ForEach(0..<(cols * 3), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.08 + 0.03 * Double(i % 3)))
                        .frame(height: cols == 3 ? 32 : 28)
                }
            }
            .padding(.horizontal, 4)
            Spacer()
        }
    }

    @ViewBuilder
    private func topFeature(_ s: Shape) -> some View {
        switch s.topFeature {
        case .cameraDot:
            Circle()
                .fill(theme.dark ? Color(hex: 0x1C1C1F) : Color(hex: 0xA8AFBD))
                .frame(width: 2, height: 2)
                .offset(y: -(s.bodyH / 2 - 4))
        case .dynamicIsland:
            Capsule()
                .fill(Color.black)
                .frame(width: 28, height: 8)
                .offset(y: -(s.bodyH / 2 - 14))
        case .none:
            EmptyView()
        }
    }
}
