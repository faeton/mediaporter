// Bottom toolbar — device status, progress, sync/save buttons.

import SwiftUI

struct BottomBarView: View {
    @Environment(PipelineController.self) private var pipeline

    var body: some View {
        HStack(spacing: 12) {
            // Device status
            HStack(spacing: 4) {
                Circle()
                    .fill(pipeline.isDeviceConnected ? .green : .red)
                    .frame(width: 8, height: 8)
                if pipeline.isDeviceConnected, let device = DeviceMonitor.shared.currentDevice {
                    Image(systemName: device.deviceClass == "iPad" ? "ipad" : "iphone")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(pipeline.deviceName ?? "No device")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("(\(device.screenDescription))")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                } else {
                    Text("No device")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Status / progress
            if pipeline.isRunning {
                ProgressView(value: pipeline.overallProgress)
                    .frame(width: 120)
                Text(pipeline.overallStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
            } else if !pipeline.overallStatus.isEmpty {
                Text(pipeline.overallStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Clear completed
            if pipeline.jobs.contains(where: { $0.status == .synced }) {
                Button("Clear Synced") {
                    pipeline.clearCompleted()
                    pipeline.overallStatus = ""
                }
                .font(.caption)
            }

            // Action buttons
            Button("Save Locally") {
                saveLocally()
            }
            .disabled(!pipeline.hasJobsToSync)

            Button("Sync to Device") {
                Task { await pipeline.runFullPipeline() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!pipeline.hasJobsToSync || !pipeline.isDeviceConnected)
        }
        .padding(.horizontal, 8)
    }

    private func saveLocally() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await pipeline.saveLocally(to: url) }
        }
    }
}
