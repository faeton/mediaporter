// Video stream info — codec, resolution, copy/transcode badge, resolution limit picker.

import SwiftUI

struct VideoInfoSection: View {
    @Bindable var job: FileJob

    var body: some View {
        guard let info = job.mediaInfo, let video = info.videoStreams.first else {
            return AnyView(Text("No video stream").foregroundColor(.secondary))
        }
        let w = video.width ?? 0
        let h = video.height ?? 0
        let downscaling = job.maxResolution.wouldDownscale(from: video.height)
        let baseAction = job.decision?.streamActions[video.index] ?? "copy"
        let effectiveAction = downscaling ? "transcode" : baseAction

        // Available options filtered to source resolution
        let options = ResolutionLimit.availableOptions(sourceHeight: h)
        let deviceSuggestion = DeviceMonitor.shared.currentDevice?.suggestedResolution

        return AnyView(
            GroupBox("Video") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Codec", value: video.codecName.uppercased())
                    LabeledContent("Resolution", value: "\(w) x \(h)")
                    if let profile = video.profile {
                        LabeledContent("Profile", value: profile)
                    }

                    // Action badge
                    HStack {
                        Text("Action")
                        Spacer()
                        Text(effectiveAction.uppercased())
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(effectiveAction == "copy" ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                            .foregroundColor(effectiveAction == "copy" ? .green : .orange)
                            .clipShape(Capsule())
                    }

                    Divider()

                    // Resolution limit picker
                    HStack {
                        Text("Max Resolution")
                        Spacer()
                        Picker("", selection: $job.maxResolution) {
                            ForEach(options) { limit in
                                HStack {
                                    Text(limit.label(sourceHeight: h))
                                    if limit == deviceSuggestion {
                                        Image(systemName: "checkmark.seal.fill")
                                            .foregroundColor(.green)
                                    }
                                }
                                .tag(limit)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }

                    // Info messages
                    if downscaling, let maxH = job.maxResolution.maxHeight {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.caption)
                                .foregroundColor(.orange)
                            Text("\(h)p → \(maxH)p — saves space, no visible quality loss on device")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    } else if h > 1080 && job.maxResolution == .original {
                        if let device = DeviceMonitor.shared.currentDevice {
                            HStack(spacing: 4) {
                                Image(systemName: "info.circle")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                                Text("\(device.displayName) screen is \(device.screenDescription) — \(device.suggestedResolution.rawValue) recommended")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "info.circle")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                                Text("1080p recommended for iPad — 4K wastes space")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        )
    }
}
