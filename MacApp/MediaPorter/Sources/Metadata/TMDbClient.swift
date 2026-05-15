// TMDb API client — async movie/TV search and poster download.

import Foundation

// MARK: - Data Models

public struct MovieMetadata {
    public var title: String
    public var year: Int?
    public var genre: String?
    public var overview: String?
    public var longOverview: String?
    public var director: String?
    public var posterURL: String?
    public var posterData: Data?
    public var tmdbID: Int?
    /// TMDb `original_language` (ISO 639-1, 2-letter, e.g. "ja"). Used as a
    /// fallback when an audio stream has no language tag — anime EAC3 mux
    /// often ships without one and TV.app surfaces it as "Unknown".
    public var originalLanguage: String?

    public init(title: String, year: Int?, genre: String?, overview: String?,
                longOverview: String?, director: String?, posterURL: String?,
                posterData: Data?, tmdbID: Int?, originalLanguage: String? = nil) {
        self.title = title; self.year = year; self.genre = genre
        self.overview = overview; self.longOverview = longOverview
        self.director = director; self.posterURL = posterURL
        self.posterData = posterData; self.tmdbID = tmdbID
        self.originalLanguage = originalLanguage
    }
}

public struct EpisodeMetadata {
    public var showName: String
    public var season: Int
    public var episode: Int
    public var episodeTitle: String?
    public var episodeID: String       // "S01E02"
    public var year: Int?
    public var genre: String?
    public var overview: String?
    public var longOverview: String?
    public var network: String?
    public var posterURL: String?
    public var posterData: Data?
    public var showPosterURL: String?
    public var showPosterData: Data?
    public var showBackdropURL: String?
    public var showBackdropData: Data?
    public var tmdbShowID: Int?
    /// TMDb `original_language` for the show (ISO 639-1, 2-letter, e.g. "ja").
    /// Fallback for untagged audio streams (see `MovieMetadata.originalLanguage`).
    public var originalLanguage: String?

    public init(showName: String, season: Int, episode: Int, episodeTitle: String?,
                episodeID: String, year: Int?, genre: String?, overview: String?,
                longOverview: String?, network: String?, posterURL: String?,
                posterData: Data?, showPosterURL: String?, showPosterData: Data?,
                showBackdropURL: String? = nil, showBackdropData: Data? = nil,
                tmdbShowID: Int?, originalLanguage: String? = nil) {
        self.showName = showName; self.season = season; self.episode = episode
        self.episodeTitle = episodeTitle; self.episodeID = episodeID; self.year = year
        self.genre = genre; self.overview = overview; self.longOverview = longOverview
        self.network = network; self.posterURL = posterURL; self.posterData = posterData
        self.showPosterURL = showPosterURL; self.showPosterData = showPosterData
        self.showBackdropURL = showBackdropURL; self.showBackdropData = showBackdropData
        self.tmdbShowID = tmdbShowID
        self.originalLanguage = originalLanguage
    }
}

enum TMDbError: LocalizedError {
    case noAPIKey
    case requestFailed(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "TMDb API key not set"
        case .requestFailed(let msg): return "TMDb request failed: \(msg)"
        case .notFound: return "No TMDb results found"
        }
    }
}

// MARK: - Client

public enum TMDbClient {
    private static let baseURL = "https://api.themoviedb.org/3"
    private static let posterBaseURL = "https://image.tmdb.org/t/p/w500"
    private static let backdropBaseURL = "https://image.tmdb.org/t/p/w780"
    private static let requestTimeout: TimeInterval = 10

    /// URLSession that honors `HTTPS_PROXY`/`HTTP_PROXY` env vars.
    ///
    /// `URLSession.shared` reads macOS System Settings → Network → Proxies but
    /// ignores the env-var convention every CLI tool uses (curl, wget, git).
    /// On networks where TMDb is reachable only through a tunneled proxy
    /// (e.g. mainland China — api.themoviedb.org is on Facebook CloudFront
    /// edge IPs that GFW blocks), the user typically already has a working
    /// proxy exported in their shell. Picking that up here saves a separate
    /// macOS Network-Settings setup step.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = requestTimeout
        cfg.timeoutIntervalForResource = requestTimeout * 2
        if let dict = proxyFromEnv() {
            cfg.connectionProxyDictionary = dict
        }
        return URLSession(configuration: cfg)
    }()

    private static func proxyFromEnv() -> [AnyHashable: Any]? {
        let env = ProcessInfo.processInfo.environment
        let httpsRaw = env["HTTPS_PROXY"] ?? env["https_proxy"]
        let httpRaw = env["HTTP_PROXY"] ?? env["http_proxy"]
        let raw = httpsRaw ?? httpRaw
        guard let raw, let url = URL(string: raw), let host = url.host else { return nil }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        return [
            "HTTPSEnable": 1,
            "HTTPSProxy": host,
            "HTTPSPort": port,
            "HTTPEnable": 1,
            "HTTPProxy": host,
            "HTTPPort": port,
        ]
    }

    /// Fetch JSON from a URL with an explicit timeout.
    private static func getJSON(_ url: URL) async throws -> Any {
        var req = URLRequest(url: url, timeoutInterval: requestTimeout)
        req.setValue("MediaPorter/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Search for movies by title and optional year.
    static func searchMovie(title: String, year: Int? = nil, apiKey: String) async throws -> [MovieMetadata] {
        var components = URLComponents(string: "\(baseURL)/search/movie")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: title),
        ]
        if let year { components.queryItems?.append(URLQueryItem(name: "year", value: String(year))) }

        guard let json = try await getJSON(components.url!) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }

        return results.prefix(5).map { r in
            let releaseDate = r["release_date"] as? String ?? ""
            let posterPath = r["poster_path"] as? String
            return MovieMetadata(
                title: r["title"] as? String ?? "",
                year: Int(releaseDate.prefix(4)),
                genre: nil,
                overview: r["overview"] as? String,
                longOverview: r["overview"] as? String,
                director: nil,
                posterURL: posterPath.map { "\(posterBaseURL)\($0)" },
                posterData: nil,
                tmdbID: r["id"] as? Int,
                originalLanguage: r["original_language"] as? String
            )
        }
    }

    /// Search TMDb for TV-show candidates and rank them. Used by the cluster
    /// picker — prefers shows that actually have episodes (have a `first_air_date`)
    /// over musicals/parodies/empty stubs that share the title.
    public static func searchTVShows(
        query: String, apiKey: String
    ) async throws -> [TVShowCandidate] {
        var components = URLComponents(string: "\(baseURL)/search/tv")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: query),
        ]

        guard let json = try await getJSON(components.url!) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }

        let candidates: [TVShowCandidate] = results.compactMap { r in
            guard let id = r["id"] as? Int else { return nil }
            let firstAir = r["first_air_date"] as? String ?? ""
            let posterPath = r["poster_path"] as? String
            return TVShowCandidate(
                id: id,
                name: r["name"] as? String ?? "",
                originalName: r["original_name"] as? String,
                year: Int(firstAir.prefix(4)),
                overview: r["overview"] as? String,
                posterURL: posterPath.map { "\(posterBaseURL)\($0)" },
                popularity: (r["popularity"] as? Double) ?? 0,
                originalLanguage: r["original_language"] as? String
            )
        }

        // Rank: shows with an air date first (real series beat musicals/empty
        // stubs), then by popularity. This is the rule that lets us auto-pick.
        return candidates.sorted { a, b in
            let aHas = a.year != nil ? 1 : 0
            let bHas = b.year != nil ? 1 : 0
            if aHas != bHas { return aHas > bHas }
            return a.popularity > b.popularity
        }.prefix(5).map { $0 }
    }

    /// Fetch the show-level fields for a known TMDb show id (genre, network,
    /// poster). Used after the user picks a candidate from the cluster picker.
    public static func fetchTVShow(
        id: Int, apiKey: String
    ) async throws -> ResolvedShow {
        let url = URL(string: "\(baseURL)/tv/\(id)?api_key=\(apiKey)")!
        let json = ((try? await getJSON(url)) as? [String: Any]) ?? [:]
        let firstAir = json["first_air_date"] as? String ?? ""
        let posterPath = json["poster_path"] as? String
        let backdropPath = json["backdrop_path"] as? String
        let genre = (json["genres"] as? [[String: Any]])?.first?["name"] as? String
        let network = (json["networks"] as? [[String: Any]])?.first?["name"] as? String
        return ResolvedShow(
            showName: json["name"] as? String ?? "",
            year: Int(firstAir.prefix(4)),
            genre: genre,
            network: network,
            showPosterURL: posterPath.map { "\(posterBaseURL)\($0)" },
            showPosterData: nil,
            showBackdropURL: backdropPath.map { "\(backdropBaseURL)\($0)" },
            showBackdropData: nil,
            tmdbShowID: id,
            originalLanguage: json["original_language"] as? String
        )
    }

    /// Fetch only the per-episode fields (title, still, overview) for a show
    /// that's already been resolved at the cluster level.
    public static func fetchEpisodeOnly(
        showID: Int, season: Int, episode: Int, apiKey: String
    ) async throws -> (title: String?, stillURL: String?, overview: String?) {
        let url = URL(
            string: "\(baseURL)/tv/\(showID)/season/\(season)/episode/\(episode)?api_key=\(apiKey)"
        )!
        guard let json = try await getJSON(url) as? [String: Any] else {
            return (nil, nil, nil)
        }
        let stillPath = json["still_path"] as? String
        return (
            title: json["name"] as? String,
            stillURL: stillPath.map { "\(posterBaseURL)\($0)" },
            overview: json["overview"] as? String
        )
    }

    /// Search for a TV episode.
    static func searchTVEpisode(
        showName: String, season: Int, episode: Int, apiKey: String
    ) async throws -> EpisodeMetadata? {
        // Step 1: Search for the show
        var searchComponents = URLComponents(string: "\(baseURL)/search/tv")!
        searchComponents.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: showName),
        ]

        guard let searchJSON = try await getJSON(searchComponents.url!) as? [String: Any],
              let results = searchJSON["results"] as? [[String: Any]],
              let show = results.first,
              let showID = show["id"] as? Int else { return nil }

        let showPosterPath = show["poster_path"] as? String
        let showBackdropPath = show["backdrop_path"] as? String
        let firstAir = show["first_air_date"] as? String ?? ""

        // Step 2: Fetch episode details
        let epURL = URL(string: "\(baseURL)/tv/\(showID)/season/\(season)/episode/\(episode)?api_key=\(apiKey)")!
        guard let epJSON = try await getJSON(epURL) as? [String: Any] else { return nil }

        let stillPath = epJSON["still_path"] as? String
        let episodeID = String(format: "S%02dE%02d", season, episode)

        // Step 3: Fetch show details for genre/network
        let showURL = URL(string: "\(baseURL)/tv/\(showID)?api_key=\(apiKey)")!
        let showJSON = ((try? await getJSON(showURL)) as? [String: Any]) ?? [:]

        let genres = (showJSON["genres"] as? [[String: Any]])?.first?["name"] as? String
        let networks = (showJSON["networks"] as? [[String: Any]])?.first?["name"] as? String

        return EpisodeMetadata(
            showName: show["name"] as? String ?? showName,
            season: season,
            episode: episode,
            episodeTitle: epJSON["name"] as? String,
            episodeID: episodeID,
            year: Int(firstAir.prefix(4)),
            genre: genres,
            overview: epJSON["overview"] as? String,
            longOverview: epJSON["overview"] as? String,
            network: networks,
            posterURL: stillPath.map { "\(posterBaseURL)\($0)" },
            posterData: nil,
            showPosterURL: showPosterPath.map { "\(posterBaseURL)\($0)" },
            showPosterData: nil,
            showBackdropURL: showBackdropPath.map { "\(backdropBaseURL)\($0)" },
            showBackdropData: nil,
            tmdbShowID: showID,
            originalLanguage: show["original_language"] as? String
                ?? (showJSON["original_language"] as? String)
        )
    }

    /// Download an image from a URL and return raw data.
    static func downloadPoster(urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("MediaPorter/1.0", forHTTPHeaderField: "User-Agent")
        return try? await session.data(for: request).0
    }
}
