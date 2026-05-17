// Wire-key invariants for ATCSession.buildSyncPlist / buildDeletePlist.
//
// These are the protocol rules from CLAUDE.md #6 that, when broken,
// fail silently on device — TV.app shows blank header, "Season 0",
// "0." prefix on episode rows, or the row never lands at all. The
// fragile thing is which sub-dict each key lives in: snake-case at
// item top-level → dropped, kebab-case in video_info → dropped (that's
// the iTunes Store code path at strings 0x770800, different cluster).
//
// We deserialize the binary plist and assert key placement directly —
// no device required, no fuzzing, just structural pinning.

import XCTest
@testable import MediaPorterCore

final class SyncPlistTests: XCTestCase {

    // Build an ATCSession with a non-functional device pointer.
    // buildSyncPlist / buildDeletePlist never touch device.handle or
    // self.conn, so the dummy pointer is safe.
    private func makeSession() -> ATCSession {
        let device = DeviceInfo(
            udid: "TEST",
            handle: UnsafeRawPointer(bitPattern: 0x1)!
        )
        return ATCSession(device: device, verbose: false)
    }

    private func makeMovieFile(assetID: Int = 12345) -> SyncFileInfo {
        let item = SyncItem(
            fileURL: URL(fileURLWithPath: "/tmp/fake.mp4"),
            title: "Test Movie",
            sortName: "Test Movie",
            durationMs: 7_200_000,
            fileSize: 1_500_000_000,
            isMovie: true,
            isTVShow: false,
            isHD: true,
            channels: 2
        )
        return SyncFileInfo(item: item, assetID: assetID,
                            devicePath: "/iTunes_Control/Music/F00/TEST.mp4",
                            slot: "F00")
    }

    private func makeEpisodeFile(assetID: Int = 67890) -> SyncFileInfo {
        let item = SyncItem(
            fileURL: URL(fileURLWithPath: "/tmp/ep.mp4"),
            title: "Pilot",
            sortName: "Pilot",
            durationMs: 1_800_000,
            fileSize: 800_000_000,
            isMovie: false,
            isTVShow: true,
            tvShowName: "The Mandalorian",
            sortTVShowName: "Mandalorian, The",
            seasonNumber: 1,
            episodeNumber: 1,
            episodeSortID: 10001,
            artist: "The Mandalorian",
            sortArtist: "Mandalorian, The",
            album: "The Mandalorian, Season 1",
            sortAlbum: "Mandalorian, The, Season 1",
            albumArtist: "The Mandalorian",
            sortAlbumArtist: "Mandalorian, The",
            isHD: true,
            channels: 6,
            hasAlternateAudio: true,
            hasSubtitles: true
        )
        return SyncFileInfo(item: item, assetID: assetID,
                            devicePath: "/iTunes_Control/Music/F01/EP.mp4",
                            slot: "F01")
    }

    // Deserialize binary plist data into [String: Any] root.
    private func parsePlist(_ data: Data) -> [String: Any] {
        let raw = try! PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        return raw as! [String: Any]
    }

    private func opsIn(_ root: [String: Any]) -> [[String: Any]] {
        return root["operations"] as! [[String: Any]]
    }

    private func insertTrack(in root: [String: Any]) -> [String: Any] {
        let ops = opsIn(root)
        return ops.first { ($0["operation"] as? String) == "insert_track" }!
    }

    // MARK: - movie path

    func testMoviePlistRootShape() {
        let session = makeSession()
        let data = session.buildSyncPlist(files: [makeMovieFile()], anchor: 42)
        let root = parsePlist(data)

        XCTAssertEqual(root["revision"] as? Int, 42)
        XCTAssertNotNil(root["timestamp"] as? Date)

        let ops = opsIn(root)
        XCTAssertEqual(ops.count, 2, "1 update_db_info + 1 insert_track")
        XCTAssertEqual(ops[0]["operation"] as? String, "update_db_info")
        XCTAssertEqual(ops[1]["operation"] as? String, "insert_track")
    }

    func testMovieInsertTrackHasMovieFlagAndNoTVKeys() {
        let session = makeSession()
        let data = session.buildSyncPlist(files: [makeMovieFile(assetID: 999)], anchor: 1)
        let op = insertTrack(in: parsePlist(data))

        XCTAssertEqual(op["pid"] as? Int, 999)

        let item = op["item"] as! [String: Any]
        XCTAssertEqual(item["is_movie"] as? Bool, true)
        XCTAssertNil(item["is_tv_show"])
        XCTAssertNil(item["artist"])
        XCTAssertNil(item["album"])
        XCTAssertNil(item["album_artist"])
        XCTAssertNil(item["episode_sort_id"])

        let videoInfo = op["video_info"] as! [String: Any]
        XCTAssertNil(videoInfo["series_name"])
        XCTAssertNil(videoInfo["season_number"])
        XCTAssertNil(videoInfo["episode_id"])
        XCTAssertNil(videoInfo["episode_sort_id"])
    }

    func testMovieLocationKindIsMpeg4VideoFile() {
        let session = makeSession()
        let data = session.buildSyncPlist(files: [makeMovieFile()], anchor: 1)
        let op = insertTrack(in: parsePlist(data))

        let location = op["location"] as! [String: Any]
        XCTAssertEqual(location["kind"] as? String, "MPEG-4 video file")
    }

    // MARK: - TV-episode path (CLAUDE.md rule #6 invariants)

    func testEpisodeSeriesKeysLiveInVideoInfo() {
        let session = makeSession()
        let data = session.buildSyncPlist(files: [makeEpisodeFile()], anchor: 1)
        let op = insertTrack(in: parsePlist(data))
        let videoInfo = op["video_info"] as! [String: Any]

        XCTAssertEqual(videoInfo["series_name"] as? String, "The Mandalorian")
        XCTAssertEqual(videoInfo["sort_series_name"] as? String, "Mandalorian, The")
        XCTAssertEqual(videoInfo["season_number"] as? Int, 1)
        XCTAssertEqual(videoInfo["episode_id"] as? String, "S01E01")
        XCTAssertEqual(videoInfo["episode_sort_id"] as? Int, 10001)
    }

    func testEpisodeItemDictHasArtistAlbumSortFields() {
        let session = makeSession()
        let data = session.buildSyncPlist(files: [makeEpisodeFile()], anchor: 1)
        let op = insertTrack(in: parsePlist(data))
        let item = op["item"] as! [String: Any]

        XCTAssertEqual(item["is_tv_show"] as? Bool, true)
        XCTAssertNil(item["is_movie"])

        XCTAssertEqual(item["artist"] as? String, "The Mandalorian")
        XCTAssertEqual(item["sort_artist"] as? String, "Mandalorian, The")
        XCTAssertEqual(item["album"] as? String, "The Mandalorian, Season 1")
        XCTAssertEqual(item["sort_album"] as? String, "Mandalorian, The, Season 1")
        XCTAssertEqual(item["album_artist"] as? String, "The Mandalorian")
        XCTAssertEqual(item["sort_album_artist"] as? String, "Mandalorian, The")
    }

    // episode_sort_id is duplicated: video_info AND item top-level.
    // Per CLAUDE.md #6: current iOS expects the int at item top-level;
    // older schema kept it on video_info. We ship both for safety.
    func testEpisodeSortIDIsAtBothItemTopLevelAndVideoInfo() {
        let session = makeSession()
        let data = session.buildSyncPlist(files: [makeEpisodeFile()], anchor: 1)
        let op = insertTrack(in: parsePlist(data))
        let item = op["item"] as! [String: Any]
        let videoInfo = op["video_info"] as! [String: Any]

        XCTAssertEqual(item["episode_sort_id"] as? Int, 10001,
            "missing item.episode_sort_id → TV.app prefixes '0.' on episode rows")
        XCTAssertEqual(videoInfo["episode_sort_id"] as? Int, 10001)
    }

    // Forbidden by rule #6: snake-case TV keys at item top-level get
    // silently dropped because the canonical cluster routes them
    // through video_info only. If a future refactor moves them, this
    // test fails before it reaches device.
    func testEpisodeSeriesKeysAreNotAtItemTopLevel() {
        let session = makeSession()
        let data = session.buildSyncPlist(files: [makeEpisodeFile()], anchor: 1)
        let op = insertTrack(in: parsePlist(data))
        let item = op["item"] as! [String: Any]

        XCTAssertNil(item["series_name"],
            "series_name at item top-level is dropped — must live in video_info")
        XCTAssertNil(item["season_number"],
            "season_number at item top-level is dropped — must live in video_info")
        XCTAssertNil(item["episode_id"],
            "episode_id at item top-level is dropped — must live in video_info")
    }

    // Forbidden by rule #6: kebab-case keys hit iTunes-Store cluster at
    // strings 0x770800, not the insert_track cluster — different code
    // path, silently ignored by medialibraryd.
    func testNoKebabCaseKeysAnywhere() {
        let session = makeSession()
        let data = session.buildSyncPlist(files: [makeEpisodeFile()], anchor: 1)
        let op = insertTrack(in: parsePlist(data))

        for subKey in ["item", "video_info"] {
            let dict = op[subKey] as! [String: Any]
            for k in dict.keys {
                XCTAssertFalse(k.contains("-"),
                    "kebab key '\(k)' in \(subKey) — wrong code path, gets dropped")
            }
            // Also assert specific forbidden names that have burned us
            // before (per CLAUDE.md #6 history note):
            XCTAssertNil(dict["show-name"])
            XCTAssertNil(dict["season-number"])
            XCTAssertNil(dict["episode-number"])
            XCTAssertNil(dict["tv_show_name"], "key doesn't exist — confused with kebab")
        }
    }

    func testVideoInfoCarriesAudioAndSubtitleFlags() {
        let session = makeSession()
        let data = session.buildSyncPlist(files: [makeEpisodeFile()], anchor: 1)
        let op = insertTrack(in: parsePlist(data))
        let vi = op["video_info"] as! [String: Any]

        XCTAssertEqual(vi["has_alternate_audio"] as? Bool, true,
            "without this TV.app won't expose the audio switcher")
        XCTAssertEqual(vi["has_subtitles"] as? Bool, true,
            "without this TV.app won't expose the subtitle picker")
        XCTAssertEqual(vi["is_hd"] as? Bool, true)
    }

    // MARK: - mixed-batch

    func testMixedBatchEmitsCorrectShapePerFile() {
        let session = makeSession()
        let data = session.buildSyncPlist(
            files: [makeMovieFile(assetID: 100), makeEpisodeFile(assetID: 200)],
            anchor: 7
        )
        let ops = opsIn(parsePlist(data))
        let inserts = ops.filter { ($0["operation"] as? String) == "insert_track" }
        XCTAssertEqual(inserts.count, 2)

        let byPid = Dictionary(uniqueKeysWithValues: inserts.map {
            ($0["pid"] as! Int, $0)
        })

        let movieItem = byPid[100]!["item"] as! [String: Any]
        XCTAssertEqual(movieItem["is_movie"] as? Bool, true)
        XCTAssertNil(movieItem["episode_sort_id"])

        let tvItem = byPid[200]!["item"] as! [String: Any]
        XCTAssertEqual(tvItem["is_tv_show"] as? Bool, true)
        XCTAssertEqual(tvItem["episode_sort_id"] as? Int, 10001)
    }

    // MARK: - buildDeletePlist

    func testDeletePlistHasOnlyDeleteTrackOps() {
        let session = makeSession()
        let data = session.buildDeletePlist(syncIDs: [111, 222, 333], anchor: 99)
        let root = parsePlist(data)

        XCTAssertEqual(root["revision"] as? Int, 99)
        let ops = opsIn(root)
        XCTAssertEqual(ops.count, 3, "no update_db_info — focused delete")
        for op in ops {
            XCTAssertEqual(op["operation"] as? String, "delete_track")
        }

        let pids = ops.compactMap { $0["pid"] as? Int }.sorted()
        XCTAssertEqual(pids, [111, 222, 333])
    }

    func testDeletePlistDoesNotIncludeUpdateDbInfo() {
        let session = makeSession()
        let data = session.buildDeletePlist(syncIDs: [42], anchor: 1)
        let ops = opsIn(parsePlist(data))
        XCTAssertFalse(ops.contains { ($0["operation"] as? String) == "update_db_info" },
            "delete plist must not emit update_db_info — risks library-wide rewrite")
    }
}
