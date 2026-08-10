// Metadata lookup orchestrator — parse filename, search TMDb, download/generate poster.

import Foundation

/// Resolved metadata for a file — either movie or TV episode.
public enum ResolvedMetadata {
    case movie(MovieMetadata)
    case tvEpisode(EpisodeMetadata)

    public var title: String {
        switch self {
        case .movie(let m): return m.title
        case .tvEpisode(let e): return e.showName
        }
    }

    public var posterData: Data? {
        switch self {
        case .movie(let m): return m.posterData
        case .tvEpisode(let e): return e.posterData ?? e.showPosterData
        }
    }

    /// Preview thumb for the Mac app UI. For TV episodes prefers the show
    /// portrait — it's the most recognisable image and lets the user verify
    /// the cluster picker resolved to the right show without expanding.
    /// Falls back to the per-episode still or the show backdrop. The thumb
    /// frame is portrait-shaped (2:3) so a landscape backdrop only fits
    /// poorly anyway. Never goes to the device — that path uses `posterData`.
    public var previewThumbData: Data? {
        switch self {
        case .movie(let m): return m.posterData
        case .tvEpisode(let e):
            return e.showPosterData ?? e.posterData ?? e.showBackdropData
        }
    }

    /// Compact episode marker for the row thumb badge ("E01", "S2·E03").
    /// nil for movies. Season is elided when it's the implicit S01.
    public var episodeBadge: String? {
        guard case .tvEpisode(let e) = self else { return nil }
        return MetadataLookup.episodeBadgeFormat(season: e.season, episode: e.episode)
    }

    /// Show-level portrait (2:3) for TV episodes. nil for movies. Used by
    /// the row-preview popover so the user can confirm the cluster picker
    /// resolved to the right show, since the device-side portrait isn't
    /// otherwise visible from the Mac app.
    public var showPortraitData: Data? {
        if case .tvEpisode(let e) = self { return e.showPosterData }
        return nil
    }

    /// Per-episode 16:9 still for TV episodes. nil for movies.
    public var episodeStillData: Data? {
        if case .tvEpisode(let e) = self { return e.posterData }
        return nil
    }

    public var isEpisode: Bool {
        if case .tvEpisode = self { return true }
        return false
    }

    /// TMDb `original_language` (ISO 639-1) for the title. nil when TMDb
    /// didn't resolve or the title was created via the fallback path.
    public var originalLanguage: String? {
        switch self {
        case .movie(let m): return m.originalLanguage
        case .tvEpisode(let e): return e.originalLanguage
        }
    }
}

public enum MetadataLookup {
    /// Full metadata pipeline: parse filename → TMDb → poster.
    public static func lookup(
        path: URL,
        showOverride: String? = nil,
        seasonOverride: Int? = nil,
        episodeOverride: Int? = nil,
        apiKey: String?,
        sourceURL: URL? = nil,
        duration: TimeInterval? = nil
    ) async -> ResolvedMetadata? {
        let parsed = FilenameParser.parse(
            path.lastPathComponent,
            parentDir: path.deletingLastPathComponent().lastPathComponent
        )

        switch parsed.mediaType {
        case .tvShow:
            return await lookupTV(
                parsed: parsed,
                showOverride: showOverride,
                seasonOverride: seasonOverride,
                episodeOverride: episodeOverride,
                apiKey: apiKey,
                sourceURL: sourceURL ?? path,
                duration: duration
            )
        case .movie:
            return await lookupMovie(parsed: parsed, apiKey: apiKey)
        }
    }

    /// Direct movie lookup that skips filename parsing. Use this when the user
    /// has provided explicit title + year via the Edit-title sheet — otherwise
    /// we round-trip through a synthesized alias URL and lose the year hint.
    public static func lookupMovieDirect(
        title: String,
        year: Int?,
        apiKey: String?
    ) async -> ResolvedMetadata? {
        let parsed = ParsedFilename(
            title: title, year: year, season: nil, episode: nil, mediaType: .movie
        )
        return await lookupMovie(parsed: parsed, apiKey: apiKey)
    }

    /// Direct TV lookup that bypasses filename parsing. Use when the user has
    /// explicitly chosen TV in the Edit-title sheet — otherwise `lookup(path:)`
    /// routes by filename shape (e.g. `o04.mkv` parses as movie and ignores TV
    /// overrides entirely, which silently yields a fallback movie result).
    public static func lookupTVDirect(
        showName: String,
        season: Int,
        episode: Int,
        year: Int?,
        apiKey: String?,
        sourceURL: URL? = nil,
        duration: TimeInterval? = nil
    ) async -> ResolvedMetadata? {
        let parsed = ParsedFilename(
            title: showName, year: year, season: season,
            episode: episode, mediaType: .tvShow
        )
        return await lookupTV(
            parsed: parsed, showOverride: showName,
            seasonOverride: season, episodeOverride: episode,
            apiKey: apiKey, sourceURL: sourceURL, duration: duration
        )
    }

    /// Lowercased alphanumeric word set — punctuation and separators dropped,
    /// so "Rambo: First Blood" and "Rambo.First.Blood" tokenize identically.
    static func titleTokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }

    /// Pick the candidate whose title is closest to what we actually searched
    /// for, instead of trusting TMDb's ordering.
    ///
    /// TMDb's `/search/movie` is relevance-ranked and its notion of relevance
    /// isn't ours: "Rambo First Blood" puts *Rambo: First Blood Part II* (1985)
    /// first and the real *First Blood* (1982) fourth, because the sequel's
    /// title contains the query verbatim. Jaccard overlap on word sets prefers
    /// whichever candidate adds the fewest words of its own, so {first, blood}
    /// (2/3 = 0.67) beats {rambo, first, blood, part, ii} (3/5 = 0.60).
    ///
    /// This only ever *re-orders*; it never rejects. When no candidate shares a
    /// single token with the query every score is zero and TMDb's own ordering
    /// stands — which is exactly what keeps cross-language lookups working. A
    /// search for "Крестный отец" legitimately returns "The Godfather" with
    /// zero word overlap (TMDb resolves it through alternative titles, and
    /// `cleanTitle` strips the parenthesized English name on purpose so the
    /// Cyrillic query survives). Any rule that *discarded* low-overlap results
    /// would throw those away. Ties keep TMDb's order via the strict `>`.
    static func bestMatch(for query: String, among results: [MovieMetadata]) -> MovieMetadata? {
        guard let first = results.first else { return nil }
        let q = titleTokens(query)
        guard !q.isEmpty else { return first }

        var best = first
        var bestScore = 0.0
        for candidate in results {
            let c = titleTokens(candidate.title)
            let overlap = q.intersection(c).count
            guard overlap > 0 else { continue }
            let score = Double(overlap) / Double(q.union(c).count)
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    /// Whether the winning match was a judgement call rather than a certainty.
    ///
    /// A single candidate whose title matches the query word-for-word is
    /// decisive — "Signal One" → *Signal One* needs no second-guessing. Every
    /// other shape is a guess: partial overlap ("Rambo First Blood" → four
    /// partial hits), two candidates tied on an exact title, or no overlap at
    /// all (the cross-language case, where we take TMDb's word for it). Those
    /// are exactly the cases worth showing the user alternatives for.
    static func isAmbiguousMatch(query: String, results: [MovieMetadata]) -> Bool {
        guard results.count > 1 else { return false }
        let q = titleTokens(query)
        guard !q.isEmpty else { return true }

        let scores = results.map { r -> Double in
            let c = titleTokens(r.title)
            let overlap = q.intersection(c).count
            guard overlap > 0 else { return 0 }
            return Double(overlap) / Double(q.union(c).count)
        }
        let exact = scores.filter { $0 >= 1.0 }.count
        return exact != 1
    }

    private static func lookupMovie(parsed: ParsedFilename, apiKey: String?) async -> ResolvedMetadata {
        guard let apiKey, !apiKey.isEmpty else {
            return .movie(fallbackMovie(parsed: parsed))
        }

        // "E5 «Historia»" is an episode filename whose show name lives in the
        // folder, not the file. TMDb's /search/movie is relevance-ranked
        // full-text and always hands back *something*, so a fragment like this
        // yields a confidently wrong film — observed live: "E5 «Historia»" →
        // "Pirates of the Caribbean: Dead Men Tell No Tales", complete with
        // poster. Showing "no TMDb match" is strictly better than tagging the
        // file with another movie's artwork.
        //
        // Note this guards the *query*, not the result. We deliberately do not
        // similarity-check the returned title against the query: matching a
        // localized title to its TMDb entry is a supported path (cleanTitle
        // exists precisely so "Крестный отец (The Godfather)" queries as
        // "Крестный отец", which TMDb resolves via alternative titles), and any
        // token-overlap rule would reject exactly those legitimate hits.
        if FilenameParser.looksLikeBareEpisodeMarker(parsed.title) {
            DebugLog.notice(
                "tmdb.skip",
                "\(parsed.title): bare episode marker, no show name — not querying as a movie"
            )
            return .movie(fallbackMovie(parsed: parsed))
        }

        do {
            let results = try await TMDbClient.searchMovie(
                title: parsed.title, year: parsed.year, apiKey: apiKey
            )
            guard var meta = bestMatch(for: parsed.title, among: results) else {
                return .movie(fallbackMovie(parsed: parsed))
            }
            if let first = results.first, first.tmdbID != meta.tmdbID {
                DebugLog.notice(
                    "tmdb.rerank",
                    "\(parsed.title): picked \(meta.title) (\(meta.year.map(String.init) ?? "?")) " +
                    "over TMDb's top hit \(first.title) (\(first.year.map(String.init) ?? "?"))"
                )
            }

            // Offer the runners-up when the pick wasn't clear-cut. Excludes
            // the winner itself so the picker lists genuine alternatives.
            if isAmbiguousMatch(query: parsed.title, results: results) {
                meta.alternates = results
                    .filter { $0.tmdbID != meta.tmdbID }
                    .compactMap { r in
                        r.tmdbID.map {
                            MovieCandidate(
                                id: $0, title: r.title, year: r.year,
                                overview: r.overview, posterURL: r.posterURL,
                                originalLanguage: r.originalLanguage
                            )
                        }
                    }
                DebugLog.notice(
                    "tmdb.ambiguous",
                    "\(parsed.title): chose \(meta.title) with \(meta.alternates.count) alternative(s)"
                )
            }

            // Download poster
            if let url = meta.posterURL {
                meta.posterData = await TMDbClient.downloadPoster(urlString: url)
            }
            // Fallback poster if download failed
            if meta.posterData == nil {
                meta.posterData = PosterGenerator.generate(title: meta.title, year: meta.year)
            }
            return .movie(meta)
        } catch {
            return .movie(fallbackMovie(parsed: parsed))
        }
    }

    private static func lookupTV(
        parsed: ParsedFilename,
        showOverride: String?,
        seasonOverride: Int?,
        episodeOverride: Int?,
        apiKey: String?,
        sourceURL: URL?,
        duration: TimeInterval?
    ) async -> ResolvedMetadata? {
        let showName = showOverride ?? parsed.title
        let season = seasonOverride ?? parsed.season ?? 1
        let episode = episodeOverride ?? parsed.episode ?? 1

        guard let apiKey, !apiKey.isEmpty else {
            return .tvEpisode(await fallbackEpisode(
                showName: showName, season: season, episode: episode, parsed: parsed,
                sourceURL: sourceURL, duration: duration
            ))
        }

        do {
            guard var meta = try await TMDbClient.searchTVEpisode(
                showName: showName, season: season, episode: episode, apiKey: apiKey
            ) else {
                return .tvEpisode(await fallbackEpisode(
                    showName: showName, season: season, episode: episode, parsed: parsed,
                    sourceURL: sourceURL, duration: duration
                ))
            }

            // Download posters
            if let url = meta.showPosterURL {
                meta.showPosterData = await TMDbClient.downloadPoster(urlString: url)
            }
            if let url = meta.posterURL {
                meta.posterData = await TMDbClient.downloadPoster(urlString: url)
            }
            // Episode-still fallback chain: ffmpeg extraction → landscape
            // synthetic. Show portrait stays in `showPosterData` for any
            // future season-level use; we do NOT route it into posterData
            // because it gets squished into TV.app's 16:9 episode tile.
            if meta.posterData == nil {
                meta.posterData = await episodePosterFallback(
                    sourceURL: sourceURL, duration: duration,
                    showName: meta.showName, season: meta.season, episode: meta.episode
                )
            }
            if let still = meta.posterData {
                meta.posterData = EpisodeStillStamper.stamp(
                    still, label: episodeBadgeFormat(season: meta.season, episode: meta.episode)
                )
            }
            return .tvEpisode(meta)
        } catch {
            return .tvEpisode(await fallbackEpisode(
                showName: showName, season: season, episode: episode, parsed: parsed,
                sourceURL: sourceURL, duration: duration
            ))
        }
    }

    /// Episode-still fallback: ffmpeg-extracted frame from source if
    /// available, otherwise a 1280×720 landscape synthetic. Mirrors
    /// `PipelineController.resolveEpisodePoster` for the non-cluster path.
    private static func episodePosterFallback(
        sourceURL: URL?, duration: TimeInterval?,
        showName: String, season: Int, episode: Int
    ) async -> Data? {
        if let sourceURL, let duration,
           let extracted = await StillExtractor.extract(from: sourceURL, duration: duration) {
            return extracted
        }
        let label = String(format: "%@ S%02dE%02d", showName, season, episode)
        return PosterGenerator.generateLandscape(title: label)
    }

    /// Compact episode badge ("E01", "S2·E03") — same format as the row-thumb
    /// badge so the burn-in on the device matches what the user sees in the
    /// Mac app. Season is elided when implicit S01.
    static func episodeBadgeFormat(season: Int, episode: Int) -> String {
        let ep = String(format: "E%02d", episode)
        return season > 1 ? "S\(season)·\(ep)" : ep
    }

    private static func fallbackMovie(parsed: ParsedFilename) -> MovieMetadata {
        MovieMetadata(
            title: parsed.title,
            year: parsed.year,
            genre: nil,
            overview: nil,
            longOverview: nil,
            director: nil,
            posterURL: nil,
            posterData: PosterGenerator.generate(title: parsed.title, year: parsed.year),
            tmdbID: nil
        )
    }

    private static func fallbackEpisode(
        showName: String, season: Int, episode: Int, parsed: ParsedFilename,
        sourceURL: URL?, duration: TimeInterval?
    ) async -> EpisodeMetadata {
        let rawPoster = await episodePosterFallback(
            sourceURL: sourceURL, duration: duration,
            showName: showName, season: season, episode: episode
        )
        let posterData = rawPoster.map {
            EpisodeStillStamper.stamp($0, label: episodeBadgeFormat(season: season, episode: episode))
        }
        return EpisodeMetadata(
            showName: showName,
            season: season,
            episode: episode,
            episodeTitle: nil,
            episodeID: String(format: "S%02dE%02d", season, episode),
            year: parsed.year,
            genre: nil,
            overview: nil,
            longOverview: nil,
            network: nil,
            posterURL: nil,
            posterData: posterData,
            showPosterURL: nil,
            showPosterData: PosterGenerator.generate(title: showName, year: parsed.year),
            tmdbShowID: nil
        )
    }
}
