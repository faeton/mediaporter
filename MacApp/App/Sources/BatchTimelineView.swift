// Bottom batch timeline — Analyze → Transcode → Upload pipeline with live progress.

import SwiftUI
import MediaPorterCore

struct BatchTimelineView: View {
    let jobs: [FileJob]
    let theme: Theme
    let accent: AccentKey

    var body: some View {
        if jobs.isEmpty {
            EmptyView()
        } else {
            content
                .frame(height: 60)
                .background(theme.chrome)
                .overlay(alignment: .top) {
                    Rectangle().fill(theme.divider).frame(height: 1)
                }
        }
    }

    private var content: some View {
        let total = jobs.count
        let doneSynced = count([.synced])
        let overallActive = jobs.contains { [.analyzing, .transcoding, .tagging, .syncing].contains($0.status) }
        let stages: [Stage] = [
            Stage(key: "analyze", label: "Analyze", systemImage: "eye",
                  done: count([.analyzed, .transcoding, .tagging, .ready, .syncing, .synced]),
                  active: count([.analyzing])),
            Stage(key: "transcode", label: "Transcode", systemImage: "bolt.fill",
                  done: count([.ready, .syncing, .synced]),
                  active: count([.transcoding, .tagging])),
            Stage(key: "upload", label: "Upload", systemImage: "arrow.up",
                  done: doneSynced,
                  active: count([.syncing]))
        ]

        return HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Text(overallActive ? "WORKING" : doneSynced == total ? "COMPLETE" : "IDLE")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(theme.textDim)
                Text("\(doneSynced) of \(total) synced")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.text)
            }
            .frame(minWidth: 130, alignment: .leading)

            HStack(spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.element.key) { idx, stage in
                    StagePill(stage: stage, total: total, theme: theme, accent: accent)
                    if idx < stages.count - 1 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(theme.divider)
                                Capsule().fill(accent.solid)
                                    .frame(width: geo.size.width * min(1, Double(stage.done) / Double(max(1, total))))
                            }
                        }
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            if overallActive {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(speedText)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.text)
                    Text(remainingText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var speedText: String {
        let pct = Int(overallProgress * 100)
        return "\(pct)%"
    }

    private var remainingText: String {
        let active = jobs.filter { [.transcoding, .syncing].contains($0.status) }
        if active.isEmpty { return "waiting…" }
        let stages = active.map { $0.status == .transcoding ? "transcoding" : "uploading" }
        let uniq = Set(stages)
        if uniq.count == 1, let only = uniq.first { return only }
        return "mixed"
    }

    private var overallProgress: Double {
        let active = jobs.filter { [.transcoding, .syncing].contains($0.status) }
        if active.isEmpty { return 0 }
        return active.map(\.progress).reduce(0, +) / Double(active.count)
    }

    private func count(_ statuses: [JobStatus]) -> Int {
        jobs.filter { statuses.contains($0.status) }.count
    }
}

private struct Stage {
    let key: String
    let label: String
    let systemImage: String
    let done: Int
    let active: Int
}

private struct StagePill: View {
    let stage: Stage
    let total: Int
    let theme: Theme
    let accent: AccentKey

    var body: some View {
        let isActive = stage.active > 0
        let isDone = stage.done == total
        let color: Color = isDone
            ? Color(red: 0.19, green: 0.82, blue: 0.35)
            : isActive ? accent.solid : theme.textFaint
        let bg: Color = isDone
            ? Color(red: 0.19, green: 0.82, blue: 0.35).opacity(0.12)
            : isActive ? accent.soft : theme.pill

        HStack(spacing: 8) {
            ZStack {
                Circle().fill(color)
                Image(systemName: isDone ? "checkmark" : stage.systemImage)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(stage.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(detailText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(minWidth: 110, alignment: .leading)
        .background(bg, in: Capsule())
        .overlay(
            Capsule().strokeBorder(isActive ? accent.ring : Color.clear, lineWidth: 1)
        )
    }

    private var detailText: String {
        if stage.active > 0 {
            return "\(stage.active) active · \(stage.done)/\(total)"
        } else if stage.done + stage.active > 0 {
            return "\(stage.done) / \(total)"
        } else {
            return "waiting"
        }
    }
}
