// Per-file TMDb movie picker.
//
// The movie counterpart to ShowPickerSheet, with one deliberate difference in
// posture: the show picker is a *blocking prompt* queued when TMDb found
// nothing, while this one is *opt-in*. TMDb did match here — it just wasn't
// sure, and being wrong is silent (you only notice when the wrong poster shows
// up in TV.app). So the row shows an "N matches" badge and this sheet opens
// only if the user clicks it.
//
// Everything listed comes from the search response the lookup already made, so
// switching films costs one poster download and no search round-trip.

import SwiftUI
import MediaPorterCore

struct MoviePickerSheet: View {
    let theme: Theme
    let accent: AccentKey
    let job: FileJob
    let current: MovieMetadata
    @Environment(PipelineController.self) private var pipeline

    @State private var query: String = ""
    @State private var extraResults: [MovieCandidate] = []
    @State private var isSearching = false
    @State private var selectedID: Int?
    @State private var searchFailed = false

    let onClose: () -> Void

    /// Current pick first, then its runners-up, then anything a manual
    /// re-search turned up — de-duplicated by TMDb id so a re-search that
    /// returns the same films doesn't double the list.
    private var allCandidates: [MovieCandidate] {
        var seen = Set<Int>()
        var out: [MovieCandidate] = []
        if let id = current.tmdbID {
            out.append(MovieCandidate(
                id: id, title: current.title, year: current.year,
                overview: current.overview, posterURL: current.posterURL,
                originalLanguage: current.originalLanguage
            ))
            seen.insert(id)
        }
        for c in current.alternates + extraResults where !seen.contains(c.id) {
            out.append(c)
            seen.insert(c.id)
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(alignment: .leading, spacing: 6) {
                Text("Search TMDb")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Movie title", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await runSearch() } }
                    Button("Search") { Task { await runSearch() } }
                        .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if searchFailed {
                    Text("No further matches for that term.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            candidatesList

            HStack {
                if isSearching {
                    ProgressView().controlSize(.small)
                    Text("Searching TMDb…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                Button("Use This") {
                    guard let id = selectedID,
                          let pick = allCandidates.first(where: { $0.id == id }) else { return }
                    Task {
                        await pipeline.applyMovieCandidate(to: job, candidate: pick)
                        onClose()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil || selectedID == current.tmdbID || isSearching)
            }
        }
        .padding(20)
        .frame(width: 560, height: 540)
        .onAppear {
            query = current.title
            selectedID = current.tmdbID
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Which film is this?")
                .font(.system(size: 15, weight: .semibold))
            Text(job.fileName)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("TMDb returned several plausible matches and none of them matched the filename exactly, so the highlighted one is a best guess.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var candidatesList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(allCandidates) { c in
                    candidateRow(c)
                        .onTapGesture { selectedID = c.id }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func candidateRow(_ c: MovieCandidate) -> some View {
        let isSelected = selectedID == c.id
        let isCurrent = current.tmdbID == c.id
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? accent.solid : theme.textDim)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(c.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.text)
                    if let y = c.year {
                        Text(String(y))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.textDim)
                    }
                    if isCurrent {
                        Text("current")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(accent.soft, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(accent.solid)
                    }
                }
                if let o = c.overview, !o.isEmpty {
                    Text(o)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textDim)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isSelected ? accent.soft.opacity(0.35) : Color.clear)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.divider).frame(height: 1)
        }
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        isSearching = true
        searchFailed = false
        defer { isSearching = false }

        let key = pipeline.tmdbAPIKey
        guard !key.isEmpty else { searchFailed = true; return }
        guard let results = try? await TMDbClient.searchMovieCandidates(
            query: q, apiKey: key
        ) else {
            searchFailed = true
            return
        }
        let known = Set(allCandidates.map(\.id))
        let fresh = results.filter { !known.contains($0.id) }
        extraResults.append(contentsOf: fresh)
        searchFailed = fresh.isEmpty
    }
}
