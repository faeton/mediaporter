// Settings window — TMDb API key, quality preset, HW acceleration.

import SwiftUI

struct SettingsView: View {
    @AppStorage("tmdbAPIKey") private var tmdbAPIKey = ""
    @AppStorage("qualityPreset") private var qualityPreset = "balanced"
    @AppStorage("hwAccel") private var hwAccel = true

    var body: some View {
        Form {
            Section("TMDb") {
                SecureField("API Key", text: $tmdbAPIKey)
                    .textFieldStyle(.roundedBorder)
                Text("Get a free key at themoviedb.org")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Transcoding") {
                Picker("Quality", selection: $qualityPreset) {
                    Text("Fast (smaller, lower quality)").tag("fast")
                    Text("Balanced").tag("balanced")
                    Text("Quality (larger, higher quality)").tag("quality")
                }
                .pickerStyle(.radioGroup)

                Toggle("Hardware acceleration (VideoToolbox)", isOn: $hwAccel)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding()
    }
}
