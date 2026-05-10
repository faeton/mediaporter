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

    /// Preview thumb for the Mac app UI. Prefers the show's horizontal
    /// backdrop for TV episodes (one banner shared across the cluster) so
    /// the row preview is consistent and recognisable. Falls back to the
    /// per-episode still, then the vertical poster, then the movie poster.
    /// Never goes to the device — that path uses `posterData`.
    public var previewThumbData: Data? {
        switch self {
        case .movie(let m): return m.posterData
        case .tvEpisode(let e):
            return e.showBackdropData ?? e.posterData ?? e.showPosterData
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
        let parsed = FilenameParser.parse(path.lastPathComponent)

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
        let posterData = await episodePosterFallback(
            sourceURL: sourceURL, duration: duration,
            showName: showName, season: season, episode: episode
        )
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
