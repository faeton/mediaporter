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
            Text("Destination")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(theme.textDim)

            HStack {
                Spacer()
                IpadSilhouette(connected: pipeline.isDeviceConnected, theme: theme, accent: accent)
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

    private var sendButton: some View {
        let pendingCount = jobs.filter { $0.status == .analyzed || $0.status == .ready }.count
        return Button(action: onSend) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                Text("Send \(pendingCount) to iPad")
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
                if let res = info.nativeResolution {
                    Text("\(res)  ·  \(info.screenDescription)")
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
            Text("This \(info.deviceClass.isEmpty ? "device" : info.deviceClass)'s display is \(info.screenDescription). " +
                 "\(recommendedLabel(info.suggestedResolution)) is the sweet spot — bigger wastes space with no visible gain.")
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

    private func recommendedLabel(_ r: ResolutionLimit) -> String {
        switch r {
        case .sd: return "480p"
        case .hd: return "720p"
        case .fhd: return "1080p"
        case .uhd4k: return "4K"
        case .original: return "Original"
        }
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

struct IpadSilhouette: View {
    let connected: Bool
    let theme: Theme
    let accent: AccentKey

    private var bodyFill: Color { theme.dark ? Color(hex: 0x28282C) : Color(hex: 0xD5DAE3) }
    private var screenFill: Color { theme.dark ? Color(hex: 0x0F0F12) : Color(hex: 0x1F2024) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Body
                RoundedRectangle(cornerRadius: 12)
                    .fill(bodyFill)
                    .frame(width: 110, height: 148)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(theme.chromeBorder, lineWidth: 0.5)
                    )
                // Screen
                RoundedRectangle(cornerRadius: 4)
                    .fill(screenFill)
                    .frame(width: 98, height: 136)
                    .overlay(
                        Group {
                            if connected {
                                // Mock TV app grid
                                VStack(spacing: 4) {
                                    HStack(spacing: 2) {
                                        RoundedRectangle(cornerRadius: 1)
                                            .fill(accent.solid.opacity(0.9))
                                            .frame(width: 30, height: 3)
                                        RoundedRectangle(cornerRadius: 1)
                                            .fill(Color.white.opacity(0.25))
                                            .frame(width: 16, height: 3)
                                        Spacer()
                                    }
                                    .padding(.top, 6)
                                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 2), count: 3), spacing: 4) {
                                        ForEach(0..<9, id: \.self) { i in
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(Color.white.opacity(0.08 + 0.03 * Double(i % 3)))
                                                .frame(height: 32)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 4)
                                .frame(width: 98, height: 136)
                            }
                        }
                    )
                // Camera dot
                Circle()
                    .fill(theme.dark ? Color(hex: 0x1C1C1F) : Color(hex: 0xA8AFBD))
                    .frame(width: 2, height: 2)
                    .offset(y: -72)
            }
            // Shadow
            Ellipse()
                .fill(Color.black.opacity(0.2))
                .frame(width: 96, height: 10)
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
}
