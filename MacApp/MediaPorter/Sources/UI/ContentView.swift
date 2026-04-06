// Main window — NavigationSplitView with full-window drop target.

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var pipeline = PipelineController()
    @State private var isDragOver = false

    var body: some View {
        VStack(spacing: 0) {
            // Main content area
            ZStack {
                NavigationSplitView {
                    sidebarContent
                } detail: {
                    if let job = pipeline.selectedJob {
                        FileDetailView(job: job)
                    } else if pipeline.jobs.isEmpty {
                        emptyState
                    } else {
                        Text("Select a file")
                            .foregroundColor(.secondary)
                    }
                }

                // Full-window drag overlay
                if isDragOver {
                    RoundedRectangle(cornerRadius: 0)
                        .fill(Color.accentColor.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                                .padding(20)
                        )
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.down.doc.fill")
                                    .font(.system(size: 40))
                                    .foregroundColor(.accentColor)
                                Text("Drop to add videos")
                                    .font(.title3.bold())
                                    .foregroundColor(.accentColor)
                            }
                        )
                        .allowsHitTesting(false)
                }
            }

            Divider()

            // Bottom bar — always visible, in the view hierarchy (not toolbar)
            BottomBarView()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
        }
        .frame(minWidth: 800, minHeight: 500)
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers)
        }
        .environment(pipeline)
        .onAppear {
            pipeline.startDeviceMonitoring()
        }
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            // Add button at top
            HStack {
                Spacer()
                Button {
                    openFilePicker()
                } label: {
                    Label("Add Files", systemImage: "plus")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .padding(8)
            }

            Divider()

            // File list
            List(selection: Bindable(pipeline).selectedJobID) {
                ForEach(pipeline.jobs) { job in
                    FileRowView(job: job)
                        .tag(job.id)
                        .contextMenu {
                            Button("Remove", role: .destructive) {
                                pipeline.removeJob(job)
                            }
                        }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if pipeline.jobs.isEmpty {
                    Text("No files")
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 56))
                .foregroundColor(.secondary.opacity(0.4))
            Text("Drop video files anywhere")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("or click Add Files to browse")
                .font(.callout)
                .foregroundColor(.secondary.opacity(0.6))
            Text("MKV  MP4  AVI  MOV  TS  M4V")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.4))
                .tracking(2)
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]
        if panel.runModal() == .OK {
            pipeline.addFiles(urls: panel.urls)
            Task { await pipeline.analyzeAll() }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            pipeline.addFiles(urls: urls)
            Task { await pipeline.analyzeAll() }
        }
        return true
    }
}

#Preview {
    ContentView()
}
