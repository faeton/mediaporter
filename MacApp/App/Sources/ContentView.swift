// Root layout — titlebar, main split (file list | device column), bottom timeline.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MediaPorterCore

struct ContentView: View {
    @Environment(PipelineController.self) private var pipeline
    @Environment(Tweaks.self) private var tweaks
    @State private var expanded: Set<UUID> = []
    @State private var isDroppingList = false
    @State private var isDroppingDevice = false

    private var theme: Theme { Theme(dark: tweaks.dark) }
    private var showEmpty: Bool { pipeline.jobs.isEmpty }

    /// Kick off analyze only — user will click Send to proceed.
    private func analyzeOnly() {
        guard !pipeline.isRunning else { return }
        Task { await pipeline.analyzeAll() }
    }

    /// Kick off analyze → transcode → sync. Only makes sense when a device is connected.
    private func runFullPipeline() {
        guard !pipeline.isRunning else { return }
        Task { await pipeline.runFullPipeline() }
    }

    /// Continue from analyzed → transcode → sync (for jobs already analyzed).
    /// Uses the pipelined runner so upload of file N overlaps transcode of file N+1.
    private func continueToSync() {
        guard !pipeline.isRunning else { return }
        Task { await pipeline.runPipelined() }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Desktop wallpaper glow behind the window (visible via hidden titlebar)
            theme.windowBg
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TitleBar(
                    theme: theme,
                    accent: tweaks.accent,
                    deviceConnected: pipeline.isDeviceConnected,
                    deviceName: pipeline.deviceName ?? ""
                )

                HStack(spacing: 0) {
                    // LEFT: File list — drop here = analyze + wait for Send
                    VStack(spacing: 0) {
                        if !showEmpty {
                            ColumnHeader(
                                theme: theme, accent: tweaks.accent,
                                jobs: pipeline.jobs,
                                allExpanded: !pipeline.jobs.isEmpty
                                    && expanded.count == pipeline.jobs.count,
                                toggleAll: {
                                    if expanded.count == pipeline.jobs.count {
                                        expanded.removeAll()
                                    } else {
                                        expanded = Set(pipeline.jobs.map(\.id))
                                    }
                                },
                                addFiles: { pickFiles(autoSync: false) }
                            )
                        }

                        if showEmpty {
                            EmptyStateView(theme: theme, accent: tweaks.accent)
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 4) {
                                    ForEach(pipeline.jobs) { job in
                                        FileRowView(
                                            job: job,
                                            isExpanded: expanded.contains(job.id),
                                            theme: theme,
                                            accent: tweaks.accent,
                                            density: tweaks.density,
                                            onToggle: { toggle(job.id) },
                                            onRemove: { pipeline.removeJob(job) }
                                        )
                                    }
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.canvas)
                    .onDrop(of: [.fileURL], isTargeted: $isDroppingList) { providers in
                        handleDrop(providers, autoSync: false)
                    }
                    .overlay(dropHighlight(active: isDroppingList, label: "Drop to analyze",
                                           symbol: "tray.and.arrow.down"))

                    // Vertical divider
                    Rectangle().fill(theme.divider).frame(width: 1)

                    // RIGHT: Device column — drop here = full pipeline (analyze + send)
                    DeviceColumnView(
                        theme: theme,
                        accent: tweaks.accent,
                        jobs: pipeline.jobs,
                        canSendNow: pipeline.isDeviceConnected
                            && !pipeline.isRunning
                            && pipeline.jobs.contains { $0.status == .analyzed || $0.status == .ready },
                        onSend: continueToSync
                    )
                    .frame(width: 260)
                    .background(theme.chrome)
                    .onDrop(of: [.fileURL], isTargeted: $isDroppingDevice) { providers in
                        handleDrop(providers, autoSync: true)
                    }
                    .overlay(dropHighlight(active: isDroppingDevice, label: "Drop to send to iPad",
                                           symbol: "arrow.up"))
                }
                .frame(maxHeight: .infinity)

                BatchTimelineView(jobs: pipeline.jobs, theme: theme, accent: tweaks.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(theme.chromeBorder, lineWidth: 0.5)
            )
            .padding(0)

        }
        .animation(.easeInOut(duration: 0.15), value: isDroppingList)
        .animation(.easeInOut(duration: 0.15), value: isDroppingDevice)
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func pickFiles(autoSync: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie,
                                     UTType(filenameExtension: "mkv") ?? .movie]
        if panel.runModal() == .OK {
            pipeline.addFiles(urls: panel.urls)
            kickOff(autoSync: autoSync)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], autoSync: Bool) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            pipeline.addFiles(urls: urls)
            kickOff(autoSync: autoSync)
        }
        return !providers.isEmpty
    }

    private func kickOff(autoSync: Bool) {
        guard !pipeline.isRunning else { return }
        if autoSync {
            runFullPipeline()        // Drop on device column
        } else {
            analyzeOnly()            // Drop on file list
        }
    }

    @ViewBuilder
    private func dropHighlight(active: Bool, label: String, symbol: String) -> some View {
        if active {
            ZStack {
                tweaks.accent.soft
                VStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(tweaks.accent.solid)
                    Text(label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.text)
                }
                .padding(EdgeInsets(top: 20, leading: 28, bottom: 20, trailing: 28))
                .background(theme.canvas.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(tweaks.accent.solid,
                                      style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

// MARK: - Column header

private struct ColumnHeader: View {
    let theme: Theme
    let accent: AccentKey
    let jobs: [FileJob]
    let allExpanded: Bool
    let toggleAll: () -> Void
    let addFiles: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("\(jobs.count) files")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text("· \(fmtSizeMB(jobs.reduce(0) { $0 + $1.fileSizeMB }))")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textDim)
            }
            Spacer()
            BulkButton(
                label: allExpanded ? "Collapse all" : "Expand all",
                systemImage: allExpanded ? "chevron.up" : "chevron.down",
                theme: theme, accent: accent, primary: false, action: toggleAll
            )
            Rectangle().fill(theme.divider).frame(width: 1, height: 16)
            BulkButton(label: "Add files…", systemImage: "plus",
                       theme: theme, accent: accent, primary: true, action: addFiles)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.divider).frame(height: 1)
        }
    }
}

private struct BulkButton: View {
    let label: String
    let systemImage: String
    let theme: Theme
    let accent: AccentKey
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(primary ? .white : theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(primary ? accent.solid : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(primary ? Color.clear : theme.divider, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
