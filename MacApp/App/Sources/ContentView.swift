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

    /// Clusters with detected external tracks, ordered by show name for
    /// stable display. Used by ContentView to render one extras section
    /// per cluster above the file list (#11d).
    private var clusterExtrasOrdered: [(String, ReleaseExtras)] {
        pipeline.clusterExtras
            .filter { entry in
                guard !entry.value.isEmpty else { return false }
                return pipeline.jobs.contains { $0.clusterID == entry.key }
            }
            .sorted { a, b in
                let an = pipeline.tvShowResolutions[a.key]?.showName ?? a.key
                let bn = pipeline.tvShowResolutions[b.key]?.showName ?? b.key
                return an.localizedCaseInsensitiveCompare(bn) == .orderedAscending
            }
            .map { ($0.key, $0.value) }
    }

    /// "iPad" / "iPhone" / "iPod" / "device" — keeps drop-zone copy honest
    /// when an iPhone is plugged in instead of an iPad.
    private var deviceClassLabel: String {
        let cls = pipeline.deviceInfo?.deviceClass ?? ""
        return cls.isEmpty ? "device" : cls
    }

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
                        if !pipeline.leftoverTranscodes.isEmpty {
                            LeftoverBanner(
                                theme: theme,
                                accent: tweaks.accent,
                                count: pipeline.leftoverTranscodes.count,
                                bytes: pipeline.leftoverBytesTotal,
                                deviceConnected: pipeline.isDeviceConnected,
                                onRecover: {
                                    Task {
                                        let r = await pipeline.recoverOrphans()
                                        await MainActor.run { showRecoveryResult(r) }
                                    }
                                },
                                onDiscard: {
                                    if confirmDiscardLeftovers(
                                        count: pipeline.leftoverTranscodes.count,
                                        bytes: pipeline.leftoverBytesTotal
                                    ) {
                                        pipeline.discardLeftovers()
                                    }
                                }
                            )
                        }

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
                                    ForEach(clusterExtrasOrdered, id: \.0) { cid, extras in
                                        ClusterExtrasSection(
                                            clusterID: cid, extras: extras,
                                            theme: theme, accent: tweaks.accent
                                        )
                                    }
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
                    .overlay(dropHighlight(active: isDroppingDevice,
                                           label: "Drop to send to \(deviceClassLabel)",
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
        .sheet(item: Binding(
            get: { pipeline.pendingShowPicks.first },
            set: { _ in /* dismissal handled inside the sheet */ }
        )) { pick in
            ShowPickerSheet(
                theme: theme,
                accent: tweaks.accent,
                clusterID: pick.id,
                initialQuery: pick.query,
                initialCandidates: pick.candidates,
                affectedCount: pick.affectedJobIDs.count,
                onClose: { /* binding above re-evaluates against pendingShowPicks */ }
            )
        }
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

// MARK: - Leftover transcodes banner

/// Shown above the file list when /tmp has tagged .m4v files from a previous
/// session. Click-to-recover (requires device); Discard nukes the local
/// files. Compact strip — doesn't steal much vertical space.
private struct LeftoverBanner: View {
    let theme: Theme
    let accent: AccentKey
    let count: Int
    let bytes: Int64
    let deviceConnected: Bool
    let onRecover: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accent.solid)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count) leftover transcode\(count == 1 ? "" : "s") from a previous run")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(deviceConnected
                     ? "\(formatBytes(bytes)) ready to register without re-uploading."
                     : "\(formatBytes(bytes)). Connect a device to recover.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textDim)
            }
            Spacer()
            Button("Discard", action: onDiscard)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.divider, lineWidth: 1))
            Button("Recover…", action: onRecover)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(accent.solid))
                .opacity(deviceConnected ? 1.0 : 0.45)
                .disabled(!deviceConnected)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(accent.soft.opacity(0.35))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.divider).frame(height: 1)
        }
    }

    private func formatBytes(_ b: Int64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1.0 { return String(format: "%.2f GB", gb) }
        let mb = Double(b) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

@MainActor
private func confirmDiscardLeftovers(count: Int, bytes: Int64) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Discard \(count) leftover transcode\(count == 1 ? "" : "s")?"
    let gb = Double(bytes) / 1_073_741_824
    alert.informativeText = "This deletes the .m4v files in /tmp \(String(format: "(%.2f GB)", gb)). They won't be recoverable; any orphaned bytes already on the device will need Clean Up Staged Media to free."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Discard")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
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
