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
        case .tvEpisode(let e): return e.showPosterData ?? e.posterData
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
        apiKey: String?
    ) async -> ResolvedMetadata? {
        let parsed = FilenameParser.parse(path.lastPathComponent)

        switch parsed.mediaType {
        case .tvShow:
            return await lookupTV(
                parsed: parsed,
                showOverride: showOverride,
                seasonOverride: seasonOverride,
                episodeOverride: episodeOverride,
                apiKey: apiKey
            )
        case .movie:
            return await lookupMovie(parsed: parsed, apiKey: apiKey)
        }
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
        apiKey: String?
    ) async -> ResolvedMetadata? {
        let showName = showOverride ?? parsed.title
        let season = seasonOverride ?? parsed.season ?? 1
        let episode = episodeOverride ?? parsed.episode ?? 1

        guard let apiKey, !apiKey.isEmpty else {
            return .tvEpisode(fallbackEpisode(
                showName: showName, season: season, episode: episode, parsed: parsed
            ))
        }

        do {
            guard var meta = try await TMDbClient.searchTVEpisode(
                showName: showName, season: season, episode: episode, apiKey: apiKey
            ) else {
                return .tvEpisode(fallbackEpisode(
                    showName: showName, season: season, episode: episode, parsed: parsed
                ))
            }

            // Download posters
            if let url = meta.showPosterURL {
                meta.showPosterData = await TMDbClient.downloadPoster(urlString: url)
            }
            if let url = meta.posterURL {
                meta.posterData = await TMDbClient.downloadPoster(urlString: url)
            }
            // Fallback poster
            if meta.showPosterData == nil && meta.posterData == nil {
                meta.showPosterData = PosterGenerator.generate(title: meta.showName, year: meta.year)
            }
            return .tvEpisode(meta)
        } catch {
            return .tvEpisode(fallbackEpisode(
                showName: showName, season: season, episode: episode, parsed: parsed
            ))
        }
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
        showName: String, season: Int, episode: Int, parsed: ParsedFilename
    ) -> EpisodeMetadata {
        EpisodeMetadata(
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
            posterData: nil,
            showPosterURL: nil,
            showPosterData: PosterGenerator.generate(title: showName, year: parsed.year),
            tmdbShowID: nil
        )
    }
}
