// Show-level metadata shared by every episode of one TV show.
//
// When the user drops 25 episodes of the same series, only show-identity
// fields (title, year, network, poster, tmdb id) are common across files —
// season/episode numbers, episode titles, and per-episode stills stay
// per-file. The cluster cache lets us run TMDb's show search ONCE per
// series instead of 25 times, and lets a single user edit propagate to
// the whole cluster.

import Foundation

/// Show-level metadata pinned to a cluster of episodes. Mirrors the subset
/// of `EpisodeMetadata` fields that don't vary across episodes.
public struct ResolvedShow: Equatable, Sendable {
    public var showName: String
    public var year: Int?
    public var genre: String?
    public var network: String?
    public var showPosterURL: String?
    public var showPosterData: Data?
    /// Horizontal show artwork (TMDb backdrop_path). 16:9, separate from the
    /// 2:3 poster. Used as the primary thumb in the Mac app row preview so
    /// every episode of one show shares the same banner — never sent to the
    /// device (TV.app's show-detail hero is hardcoded to use an episode still).
    public var showBackdropURL: String?
    public var showBackdropData: Data?
    public var tmdbShowID: Int?

    public init(
        showName: String,
        year: Int? = nil,
        genre: String? = nil,
        network: String? = nil,
        showPosterURL: String? = nil,
        showPosterData: Data? = nil,
        showBackdropURL: String? = nil,
        showBackdropData: Data? = nil,
        tmdbShowID: Int? = nil
    ) {
        self.showName = showName
        self.year = year
        self.genre = genre
        self.network = network
        self.showPosterURL = showPosterURL
        self.showPosterData = showPosterData
        self.showBackdropURL = showBackdropURL
        self.showBackdropData = showBackdropData
        self.tmdbShowID = tmdbShowID
    }
}

/// One TMDb /search/tv result, surfaced to the picker UI.
public struct TVShowCandidate: Identifiable, Sendable {
    public let id: Int          // TMDb show id
    public let name: String     // localized name (usually English)
    public let originalName: String?
    public let year: Int?
    public let overview: String?
    public let posterURL: String?
    public let popularity: Double

    public init(
        id: Int, name: String, originalName: String?, year: Int?,
        overview: String?, posterURL: String?, popularity: Double
    ) {
        self.id = id; self.name = name; self.originalName = originalName
        self.year = year; self.overview = overview
        self.posterURL = posterURL; self.popularity = popularity
    }
}

/// A cluster waiting on a user pick (TMDb returned no results, or the
/// top result wasn't dominant enough to auto-pick).
public struct PendingShowPick: Identifiable, Sendable {
    public let id: String           // == clusterID
    public let query: String        // last query used (for the search field)
    public let candidates: [TVShowCandidate]
    public let affectedJobIDs: [UUID]

    public init(id: String, query: String, candidates: [TVShowCandidate], affectedJobIDs: [UUID]) {
        self.id = id; self.query = query; self.candidates = candidates
        self.affectedJobIDs = affectedJobIDs
    }
}

public enum TVShowCluster {
    /// Stable cluster key from a parsed filename. Lowercased + alphanumeric-only
    /// so "Shingeki no Kyojin" and "shingeki.no.kyojin" collapse together.
    /// Year is included when present so a 2020 reboot doesn't share a cluster
    /// with the 2003 original.
    public static func key(showName: String, year: Int?) -> String {
        let normalized = showName
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.append(Character($1)) }
        if let year { return "\(normalized)#\(year)" }
        return normalized
    }

    /// Should we auto-pick the top candidate, or surface the picker?
    /// Prompt when: zero results, top has no air date, or the runner-up's
    /// popularity is within 50% of the top (no clear winner).
    public static func shouldAutoPick(_ candidates: [TVShowCandidate]) -> Bool {
        guard let top = candidates.first else { return false }
        guard top.year != nil else { return false }
        guard candidates.count >= 2 else { return true }
        let runnerUp = candidates[1].popularity
        return top.popularity >= runnerUp * 2.0
    }
}
