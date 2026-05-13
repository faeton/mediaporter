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

    private static func lookupMovie(parsed: ParsedFilename, apiKey: String?) async -> ResolvedMetadata {
        guard let apiKey, !apiKey.isEmpty else {
            return .movie(fallbackMovie(parsed: parsed))
        }

        do {
            let results = try await TMDbClient.searchMovie(
                title: parsed.title, year: parsed.year, apiKey: apiKey
            )
            guard var meta = results.first else {
                return .movie(fallbackMovie(parsed: parsed))
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
