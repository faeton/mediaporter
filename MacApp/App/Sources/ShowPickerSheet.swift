// Cluster-scoped TMDb show picker — one sheet for N episodes.
//
// Surfaces the top-5 ranked candidates from `/search/tv`, lets the user
// re-search with a different query, and applies the chosen show to every
// file that shares the cluster id. Replaces the per-file "Edit title"
// dialog whenever the file is a TV episode.

import SwiftUI
import MediaPorterCore

struct ShowPickerSheet: View {
    let theme: Theme
    let accent: AccentKey
    let clusterID: String
    let initialQuery: String
    let initialCandidates: [TVShowCandidate]
    let affectedCount: Int
    @Environment(PipelineController.self) private var pipeline

    @State private var query: String = ""
    @State private var candidates: [TVShowCandidate] = []
    @State private var isSearching: Bool = false
    @State private var selectedID: Int?
    @State private var hasSearched: Bool = false
    @FocusState private var queryFocused: Bool

    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(alignment: .leading, spacing: 6) {
                Text("Search TMDb")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Show name", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .focused($queryFocused)
                        .onSubmit { Task { await runSearch() } }
                    Button("Search") { Task { await runSearch() } }
                        .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            candidatesList

            Spacer(minLength: 0)

            HStack {
                if isSearching {
                    ProgressView().controlSize(.small)
                    Text("Searching TMDb…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Skip", role: .cancel) {
                    pipeline.dismissClusterPick(clusterID)
                    onClose()
                }
                Button("Apply") {
                    guard let id = selectedID,
                          let pick = candidates.first(where: { $0.id == id }) else { return }
                    Task {
                        await pipeline.applyShowToCluster(clusterID: clusterID, candidate: pick)
                        onClose()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil || isSearching)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .onAppear {
            query = initialQuery
            candidates = initialCandidates
            selectedID = initialCandidates.first?.id
            hasSearched = !initialCandidates.isEmpty
            DispatchQueue.main.async { queryFocused = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(affectedCount > 1 ? "Pick show — applies to \(affectedCount) episodes"
                                   : "Pick show")
                .font(.system(size: 15, weight: .semibold))
            Text("TMDb couldn't auto-match this show, or there are several plausible candidates. Pick one and the choice is reused for every episode in this cluster.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var candidatesList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if candidates.isEmpty {
                    Text(hasSearched ? "No matches — try a different search term."
                                     : "Type a search term and press Search.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ForEach(candidates) { c in
                        candidateRow(c)
                            .onTapGesture { selectedID = c.id }
                    }
                }
            }
        }
        .frame(minHeight: 220, maxHeight: 280)
        .background(theme.canvas)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func candidateRow(_ c: TVShowCandidate) -> some View {
        let isSelected = selectedID == c.id
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? accent.solid : theme.textDim)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.text)
                    if let y = c.year {
                        Text("(\(String(y)))")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textDim)
                    }
                }
                if let orig = c.originalName, !orig.isEmpty, orig != c.name {
                    Text(orig)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textDim)
                }
                if let o = c.overview, !o.isEmpty {
                    Text(o)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textDim)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(String(format: "pop %.0f", c.popularity))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.textDim)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? accent.soft.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !pipeline.tmdbAPIKey.isEmpty else { return }
        isSearching = true
        hasSearched = true
        defer { isSearching = false }
        let results = (try? await TMDbClient.searchTVShows(query: q, apiKey: pipeline.tmdbAPIKey)) ?? []
        candidates = results
        selectedID = results.first?.id
    }
}
