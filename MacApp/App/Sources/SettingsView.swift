// Settings window — opens via ⌘ , or the gear button in the titlebar.

import SwiftUI
import MediaPorterCore

struct SettingsView: View {
    @Environment(PipelineController.self) private var pipeline
    @Environment(Tweaks.self) private var tweaks
    @State private var tmdbKey: String = ""
    @State private var keySource: TMDbKeySource = .none
    @State private var savedFlash: Bool = false

    // OpenSubtitles
    @State private var osApiKey: String = ""
    @State private var osUsername: String = ""
    @State private var osPassword: String = ""
    @State private var osLanguages: String = ""
    @State private var osKeySource: TMDbKeySource = .none
    @State private var osSavedFlash: Bool = false

    var body: some View {
        TabView {
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            metadataTab
                .tabItem { Label("Metadata", systemImage: "tag") }

            subtitlesTab
                .tabItem { Label("Subtitles", systemImage: "captions.bubble") }
        }
        .frame(width: 500, height: 420)
        .onAppear {
            tmdbKey = ConfigLoader.tmdbAPIKey() ?? ""
            keySource = ConfigLoader.tmdbSource()
            osApiKey = ConfigLoader.openSubtitlesAPIKey() ?? ""
            osUsername = ConfigLoader.openSubtitlesUsername() ?? ""
            osPassword = ConfigLoader.openSubtitlesPassword() ?? ""
            osLanguages = ConfigLoader.openSubtitlesLanguages()
            osKeySource = ConfigLoader.openSubtitlesSource()
        }
    }

    // MARK: - Appearance tab

    private var appearanceTab: some View {
        @Bindable var tweaks = tweaks
        @Bindable var pipe = pipeline

        return Form {
            Section {
                LabeledContent("Accent") {
                    HStack(spacing: 8) {
                        ForEach(AccentKey.allCases) { k in
                            AccentSwatchButton(key: k, selected: tweaks.accentKey == k) {
                                tweaks.accentKey = k
                            }
                        }
                    }
                }

                LabeledContent("Appearance") {
                    Picker("", selection: $tweaks.dark) {
                        Text("Light").tag(false)
                        Text("Dark").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }

                LabeledContent("Row density") {
                    Picker("", selection: $tweaks.density) {
                        Text("Comfortable").tag(Density.comfortable)
                        Text("Compact").tag(Density.compact)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
            } footer: {
                Text("Comfortable rows show a larger poster and more padding; compact fits more files on screen.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            Section {
                LabeledContent("Encoder") {
                    Picker("", selection: Binding(
                        get: { pipe.hwAccel },
                        set: { newValue in
                            pipe.hwAccel = newValue
                            ConfigLoader.saveHwAccel(newValue)
                        }
                    )) {
                        Text("VideoToolbox (GPU)").tag(true)
                        Text("libx265 (CPU)").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }
            } header: {
                Text("Transcode").font(.system(size: 13, weight: .semibold))
            } footer: {
                Text("VideoToolbox uses Apple's hardware HEVC encoder — 5–10× faster, slightly larger files at the same quality. libx265 is the reference software encoder — slower, smaller files, more consistent quality. VideoToolbox is the right default on Apple Silicon.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Metadata tab

    private var metadataTab: some View {
        Form {
            Section {
                SecureField("TMDb API key", text: $tmdbKey, prompt: Text("v3 API key"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)

                HStack(spacing: 6) {
                    Image(systemName: keySource == .none ? "exclamationmark.triangle" : "info.circle")
                        .foregroundStyle(.secondary)
                    Text(sourceDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if savedFlash {
                        Text("Saved")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }

                HStack {
                    Button("Get a key from themoviedb.org") {
                        NSWorkspace.shared.open(URL(string: "https://www.themoviedb.org/settings/api")!)
                    }
                    .buttonStyle(.link)
                    Spacer()
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!hasChanges)
                }
            } header: {
                Text("Poster & metadata lookup")
                    .font(.system(size: 13, weight: .semibold))
            } footer: {
                Text("Without a key, files still get a generated fallback poster. With a key, Mediaporter fetches real posters and metadata from TMDb during analysis.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Subtitles tab (OpenSubtitles)

    private var subtitlesTab: some View {
        Form {
            Section {
                SecureField("API key", text: $osApiKey,
                            prompt: Text("from opensubtitles.com/consumers"))
                    .textFieldStyle(.roundedBorder)
                TextField("Username", text: $osUsername,
                          prompt: Text("opensubtitles.com account"))
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $osPassword,
                            prompt: Text("opensubtitles.com password"))
                    .textFieldStyle(.roundedBorder)
                TextField("Languages", text: $osLanguages,
                          prompt: Text("en,ru"))
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 6) {
                    Image(systemName: osReady ? "info.circle" : "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text(osSourceDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if osSavedFlash {
                        Text("Saved").font(.system(size: 11)).foregroundStyle(.green)
                    }
                }

                HStack {
                    Button("Get a key from opensubtitles.com") {
                        NSWorkspace.shared.open(URL(string: "https://www.opensubtitles.com/consumers")!)
                    }
                    .buttonStyle(.link)
                    Spacer()
                    Button("Save", action: saveOS)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!osHasChanges)
                }
            } header: {
                Text("OpenSubtitles").font(.system(size: 13, weight: .semibold))
            } footer: {
                Text("Downloaded SRTs are cached in ~/Library/Caches/MediaPorter/opensubtitles and picked up automatically on the next analyze. Languages are comma-separated ISO codes (en, ru, uk, fr, ...).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
    }

    private var osReady: Bool {
        !osApiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !osUsername.trimmingCharacters(in: .whitespaces).isEmpty
            && !osPassword.isEmpty
            && !osLanguages.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var osSourceDescription: String {
        if !osReady { return "Fill all four fields to enable." }
        switch osKeySource {
        case .none, .userDefaults:
            return "Analyze will fetch missing-language SRTs automatically."
        default:
            return "API key \(osKeySource.label) · analyze will fetch missing-language SRTs."
        }
    }

    private var osHasChanges: Bool {
        osApiKey != (ConfigLoader.openSubtitlesAPIKey() ?? "")
            || osUsername != (ConfigLoader.openSubtitlesUsername() ?? "")
            || osPassword != (ConfigLoader.openSubtitlesPassword() ?? "")
            || osLanguages != ConfigLoader.openSubtitlesLanguages()
    }

    private func saveOS() {
        ConfigLoader.saveOpenSubtitlesCreds(
            apiKey: osApiKey, username: osUsername,
            password: osPassword, languages: osLanguages
        )
        pipeline.openSubtitlesAPIKey = ConfigLoader.openSubtitlesAPIKey() ?? ""
        pipeline.openSubtitlesUsername = ConfigLoader.openSubtitlesUsername() ?? ""
        pipeline.openSubtitlesPassword = ConfigLoader.openSubtitlesPassword() ?? ""
        pipeline.openSubtitlesLanguages = ConfigLoader.openSubtitlesLanguages()
        osKeySource = ConfigLoader.openSubtitlesSource()
        withAnimation { osSavedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { osSavedFlash = false }
        }
    }

    private var sourceDescription: String {
        switch keySource {
        case .none: return "No key set — fallback poster will be used."
        default:    return "Currently \(keySource.label)."
        }
    }

    private var hasChanges: Bool {
        tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines) != (ConfigLoader.tmdbAPIKey() ?? "")
    }

    private func save() {
        ConfigLoader.saveTMDbKey(tmdbKey)
        pipeline.tmdbAPIKey = ConfigLoader.tmdbAPIKey() ?? ""
        keySource = ConfigLoader.tmdbSource()
        withAnimation { savedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { savedFlash = false }
        }
    }
}

private struct AccentSwatchButton: View {
    let key: AccentKey
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(key.solid)
                    .frame(width: 22, height: 22)
                Circle()
                    .strokeBorder(selected ? Color.primary.opacity(0.8) : Color.primary.opacity(0.15),
                                  lineWidth: selected ? 2 : 1)
                    .frame(width: 22, height: 22)
                if selected {
                    Circle()
                        .strokeBorder(key.ring, lineWidth: 2)
                        .frame(width: 28, height: 28)
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(key.label)
    }
}
