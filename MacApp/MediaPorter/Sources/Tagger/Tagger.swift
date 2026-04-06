// MP4 metadata tagging via ffmpeg — no re-encode, just copies and adds metadata.

import Foundation

enum TaggerError: LocalizedError {
    case ffmpegNotFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound: return "ffmpeg not found"
        case .failed(let msg): return "Tagging failed: \(msg)"
        }
    }
}

enum Tagger {
    /// Tag an M4V file with metadata. Writes to a temp file then replaces original.
    static func tag(
        file: URL,
        metadata: ResolvedMetadata,
        mediaInfo: MediaInfo
    ) async throws {
        guard let ffmpeg = FFmpegLocator.ffmpeg else { throw TaggerError.ffmpegNotFound }

        let tempFile = file.deletingPathExtension().appendingPathExtension("tagged.m4v")
        var cmd: [String] = ["-hide_banner", "-y"]

        // Input
        cmd += ["-i", file.path]

        // Poster input (if available)
        let posterData = metadata.posterData
        var posterTempURL: URL?
        if let poster = posterData {
            let posterPath = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".jpg")
            try poster.write(to: posterPath)
            posterTempURL = posterPath
            cmd += ["-i", posterPath.path]
        }

        // Map streams
        cmd += ["-map", "0"]
        if posterTempURL != nil {
            cmd += ["-map", "1"]
            cmd += ["-disposition:v:1", "attached_pic"]
        }

        // Copy everything
        cmd += ["-c", "copy"]

        // Metadata atoms
        switch metadata {
        case .movie(let m):
            cmd += ["-metadata", "media_type=9"]  // stik = Movie
            cmd += ["-metadata", "title=\(m.title)"]
            if let year = m.year { cmd += ["-metadata", "date=\(year)"] }
            if let genre = m.genre { cmd += ["-metadata", "genre=\(genre)"] }
            if let overview = m.overview { cmd += ["-metadata", "description=\(overview)"] }
            if let long = m.longOverview { cmd += ["-metadata", "long_description=\(long)"] }
            if let director = m.director { cmd += ["-metadata", "artist=\(director)"] }
            let hd = getHDFlag(
                width: mediaInfo.videoStreams.first?.width,
                height: mediaInfo.videoStreams.first?.height
            )
            cmd += ["-metadata", "hdvd=\(hd)"]

        case .tvEpisode(let e):
            cmd += ["-metadata", "media_type=10"]  // stik = TV Show
            cmd += ["-metadata", "show=\(e.showName)"]
            cmd += ["-metadata", "season_number=\(e.season)"]
            cmd += ["-metadata", "episode_sort=\(e.episode)"]
            cmd += ["-metadata", "episode_id=\(e.episodeID)"]
            cmd += ["-metadata", "title=\(e.episodeTitle ?? "Episode \(e.episode)")"]
            cmd += ["-metadata", "album=\(e.showName), Season \(e.season)"]
            cmd += ["-metadata", "album_artist=\(e.showName)"]
            cmd += ["-metadata", "track=\(e.episode)"]
            if let year = e.year { cmd += ["-metadata", "date=\(year)"] }
            if let genre = e.genre { cmd += ["-metadata", "genre=\(genre)"] }
            if let overview = e.overview { cmd += ["-metadata", "description=\(overview)"] }
            if let network = e.network { cmd += ["-metadata", "network=\(network)"] }
            let hd = getHDFlag(
                width: mediaInfo.videoStreams.first?.width,
                height: mediaInfo.videoStreams.first?.height
            )
            cmd += ["-metadata", "hdvd=\(hd)"]
        }

        // Output
        cmd += ["-f", "mp4", tempFile.path]

        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = cmd
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        try proc.run()
        proc.waitUntilExit()

        // Clean up poster temp file
        if let p = posterTempURL { try? FileManager.default.removeItem(at: p) }

        guard proc.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tempFile)
            throw TaggerError.failed("exit code \(proc.terminationStatus)")
        }

        // Replace original with tagged version
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: tempFile, to: file)
    }
}
