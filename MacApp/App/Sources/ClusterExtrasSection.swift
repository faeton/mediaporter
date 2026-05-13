// Cluster-level external-tracks UI (#11d).
//
// For every cluster with non-empty `clusterExtras`, render a collapsible
// section above the file list listing the available dub studios and sub
// labels. User checkboxes flip flags on `ClusterSelection`; the "default"
// radio picks the one audio track that gets the `default` disposition at
// mux time. Changes propagate to every episode in the cluster — there is
// no per-episode override for externals (one user, one season, by design).

import SwiftUI
import MediaPorterCore

struct ClusterExtrasSection: View {
    let clusterID: String
    let extras: ReleaseExtras
    let theme: Theme
    let accent: AccentKey
    @Environment(PipelineController.self) private var pipeline
    @State private var expanded = false

    var body: some View {
        let sel = pipeline.clusterSelections[clusterID] ?? ClusterSelection()
        let dubCount = sel.includedDubStudios.count
        let subCount = sel.includedSubLabels.count

        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textFaint)
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.system(size: 11))
                        .foregroundStyle(accent.solid)
                    Text(showLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text("· extras")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textDim)
                    Spacer()
                    Text(summaryLabel(dubs: dubCount, subs: subCount,
                                      availDubs: extras.dubs.count,
                                      availSubs: extras.subs.count))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if !extras.dubs.isEmpty {
                        dubsBlock(extras.dubs, current: sel)
                    }
                    if !extras.subs.isEmpty {
                        subsBlock(extras.subs, current: sel)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.rowSelected.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.divider, lineWidth: 0.5)
        )
    }

    private var showLabel: String {
        if let r = pipeline.tvShowResolutions[clusterID] { return r.showName }
        return clusterID
    }

    private func summaryLabel(dubs: Int, subs: Int, availDubs: Int, availSubs: Int) -> String {
        var parts: [String] = []
        if availDubs > 0 { parts.append("audio \(dubs)/\(availDubs)") }
        if availSubs > 0 { parts.append("subs \(subs)/\(availSubs)") }
        return parts.joined(separator: " · ")
    }

    private func dubsBlock(_ dubs: [DubStudio], current: ClusterSelection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Extra audio")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(theme.textDim)
            ForEach(dubs) { d in
                let on = current.includedDubStudios.contains(d.label)
                let isDefault = current.defaultAudioStudio == d.label
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { on },
                        set: { _ in toggleDub(d) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                    Text(d.label)
                        .font(.system(size: 12, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? theme.text : theme.textDim)
                    Text(d.lang.uppercased())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.textFaint)
                    Text("\(d.episodes.count) ep")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textFaint)
                    Spacer(minLength: 6)
                    if on {
                        Button {
                            setDefault(d)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: isDefault ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 10))
                                Text("Default")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(isDefault ? accent.solid : theme.textFaint)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func subsBlock(_ subs: [SubTrack], current: ClusterSelection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Extra subtitles")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(theme.textDim)
            ForEach(subs) { s in
                let on = current.includedSubLabels.contains(s.label)
                let isBurning = current.burnInSubLang?.lowercased() == s.lang.lowercased()
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { on },
                        set: { _ in toggleSub(s) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                    Text(s.label)
                        .font(.system(size: 12, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? theme.text : theme.textDim)
                    Text(s.lang.uppercased())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.textFaint)
                    if s.forced {
                        Text("forced")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(theme.pill, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(theme.textDim)
                    }
                    Text("\(s.episodes.count) ep")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textFaint)
                    Spacer(minLength: 6)
                    Button {
                        toggleBurn(s)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: isBurning ? "flame.fill" : "flame")
                                .font(.system(size: 10))
                            Text("Burn in")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(isBurning ? accent.solid : theme.textFaint)
                    }
                    .buttonStyle(.plain)
                    .help(isBurning
                        ? "Burning this subtitle into the video for every episode that has it"
                        : "Burn this subtitle into the video. Auto-includes the track in the mux and forces a transcode pass.")
                }
            }
        }
    }

    private func toggleDub(_ d: DubStudio) {
        var sel = pipeline.clusterSelections[clusterID] ?? ClusterSelection()
        if sel.includedDubStudios.contains(d.label) {
            sel.includedDubStudios.remove(d.label)
            if sel.defaultAudioStudio == d.label { sel.defaultAudioStudio = nil }
        } else {
            sel.includedDubStudios.insert(d.label)
            if sel.defaultAudioStudio == nil { sel.defaultAudioStudio = d.label }
        }
        commit(sel)
    }

    private func setDefault(_ d: DubStudio) {
        var sel = pipeline.clusterSelections[clusterID] ?? ClusterSelection()
        guard sel.includedDubStudios.contains(d.label) else { return }
        sel.defaultAudioStudio = (sel.defaultAudioStudio == d.label) ? nil : d.label
        commit(sel)
    }

    private func toggleSub(_ s: SubTrack) {
        var sel = pipeline.clusterSelections[clusterID] ?? ClusterSelection()
        if sel.includedSubLabels.contains(s.label) {
            sel.includedSubLabels.remove(s.label)
            // Removing the only matching-language sub also clears the burn-in
            // pointing at that language — otherwise apply() would re-add the
            // sub via the auto-include rule and the user's "untick" would be
            // effectively ignored.
            if sel.burnInSubLang?.lowercased() == s.lang.lowercased() {
                sel.burnInSubLang = nil
            }
        } else {
            sel.includedSubLabels.insert(s.label)
        }
        commit(sel)
    }

    /// Toggle burn-in for this sub's language at cluster level. Auto-includes
    /// the sub in the mux when turning on — otherwise the sub wouldn't be
    /// embedded post-mux and the burn-in lookup would find nothing. Clicking
    /// the same language again clears burn-in but keeps the include checkbox
    /// (so the user doesn't lose their explicit include via an off click).
    private func toggleBurn(_ s: SubTrack) {
        var sel = pipeline.clusterSelections[clusterID] ?? ClusterSelection()
        let key = s.lang.lowercased()
        if sel.burnInSubLang?.lowercased() == key {
            sel.burnInSubLang = nil
        } else {
            sel.burnInSubLang = s.lang.lowercased()
            sel.includedSubLabels.insert(s.label)
        }
        commit(sel)
    }

    /// Persist updated cluster selection and re-apply to every clustered
    /// job so each episode's `externalTracksToMux` reflects the new pick.
    private func commit(_ sel: ClusterSelection) {
        pipeline.clusterSelections[clusterID] = sel
        let extrasNow = pipeline.clusterExtras[clusterID]
        for j in pipeline.jobs where j.clusterID == clusterID && j.mediaInfo != nil {
            sel.apply(to: j, extras: extrasNow)
        }
    }
}
