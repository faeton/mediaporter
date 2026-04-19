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

    public init(title: String, year: Int?, genre: String?, overview: String?,
                longOverview: String?, director: String?, posterURL: String?,
                posterData: Data?, tmdbID: Int?) {
        self.title = title; self.year = year; self.genre = genre
        self.overview = overview; self.longOverview = longOverview
        self.director = director; self.posterURL = posterURL
        self.posterData = posterData; self.tmdbID = tmdbID
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
    public var tmdbShowID: Int?

    public init(showName: String, season: Int, episode: Int, episodeTitle: String?,
                episodeID: String, year: Int?, genre: String?, overview: String?,
                longOverview: String?, network: String?, posterURL: String?,
                posterData: Data?, showPosterURL: String?, showPosterData: Data?,
                tmdbShowID: Int?) {
        self.showName = showName; self.season = season; self.episode = episode
        self.episodeTitle = episodeTitle; self.episodeID = episodeID; self.year = year
        self.genre = genre; self.overview = overview; self.longOverview = longOverview
        self.network = network; self.posterURL = posterURL; self.posterData = posterData
        self.showPosterURL = showPosterURL; self.showPosterData = showPosterData
        self.tmdbShowID = tmdbShowID
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

enum TMDbClient {
    private static let baseURL = "https://api.themoviedb.org/3"
    private static let posterBaseURL = "https://image.tmdb.org/t/p/w500"

    /// Search for movies by title and optional year.
    static func searchMovie(title: String, year: Int? = nil, apiKey: String) async throws -> [MovieMetadata] {
        var components = URLComponents(string: "\(baseURL)/search/movie")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: title),
        ]
        if let year { components.queryItems?.append(URLQueryItem(name: "year", value: String(year))) }

        let (data, _) = try await URLSession.shared.data(from: components.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
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
                tmdbID: r["id"] as? Int
            )
        }
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

        let (searchData, _) = try await URLSession.shared.data(from: searchComponents.url!)
        guard let searchJSON = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
              let results = searchJSON["results"] as? [[String: Any]],
              let show = results.first,
              let showID = show["id"] as? Int else { return nil }

        let showPosterPath = show["poster_path"] as? String
        let firstAir = show["first_air_date"] as? String ?? ""

        // Step 2: Fetch episode details
        let epURL = URL(string: "\(baseURL)/tv/\(showID)/season/\(season)/episode/\(episode)?api_key=\(apiKey)")!
        let (epData, _) = try await URLSession.shared.data(from: epURL)
        guard let epJSON = try JSONSerialization.jsonObject(with: epData) as? [String: Any] else { return nil }

        let stillPath = epJSON["still_path"] as? String
        let episodeID = String(format: "S%02dE%02d", season, episode)

        // Step 3: Fetch show details for genre/network
        let showURL = URL(string: "\(baseURL)/tv/\(showID)?api_key=\(apiKey)")!
        let (showData, _) = try await URLSession.shared.data(from: showURL)
        let showJSON = (try? JSONSerialization.jsonObject(with: showData) as? [String: Any]) ?? [:]

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
            tmdbShowID: showID
        )
    }

    /// Download an image from a URL and return raw data.
    static func downloadPoster(urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("MediaPorter/1.0", forHTTPHeaderField: "User-Agent")
        return try? await URLSession.shared.data(for: request).0
    }
}
