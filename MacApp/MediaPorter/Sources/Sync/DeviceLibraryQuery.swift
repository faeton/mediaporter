// Snapshot of the device's media library for duplicate detection (#10b).
//
// On each analyze run (when the device is connected) we pull
// MediaLibrary.sqlitedb via AFC and read item_extra to learn what's already
// there. analyzeOne then tags each FileJob whose (title, durationMs) matches
// an existing entry so the UI can show "on device" and the pipeline can skip
// it by default.
//
// Match key: title + duration_ms (±2 s tolerance). Title is what SyncItem
// would set in the plist — episode title for TV, movie/file title for
// movies. duration_ms is from ffprobe (incoming) vs total_time_ms (on
// device); they round-trip exactly when we sync, so the only slack is
// floating-point.
//
// Same DB-pull mechanic as gate-test: pull .sqlitedb + -wal + -shm
// (medialibraryd is in WAL mode, recent commits live in -wal). Read-only
// sqlite3 query against the local copy — never touch the device's open
// database.

import Foundation

public struct DeviceLibraryEntry: Sendable, Hashable {
    public let title: String
    public let durationMs: Int
}

public enum DeviceLibraryQueryError: LocalizedError {
    case sqlite3Missing
    case dbPullFailed(String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite3Missing: return "/usr/bin/sqlite3 not found"
        case .dbPullFailed(let m): return "Failed to pull MediaLibrary.sqlitedb: \(m)"
        case .queryFailed(let m): return "sqlite3 query failed: \(m)"
        }
    }
}

private let dbDir = "/iTunes_Control/iTunes"
private let dbFiles = ["MediaLibrary.sqlitedb", "MediaLibrary.sqlitedb-wal", "MediaLibrary.sqlitedb-shm"]

/// Run /usr/bin/sqlite3 and return its stdout. Drains the pipe to EOF
/// BEFORE waiting for exit — a result larger than the ~64 KB pipe buffer
/// would otherwise block sqlite3 on write while we block on wait
/// (CLAUDE.md rule #12). EOF arrives when the child exits, so the
/// subsequent waitUntilExit returns promptly. stderr is expected to stay
/// tiny (error messages only), so a sequential read after stdout is safe.
private func runSQLite3(_ arguments: [String], captureStderr: Bool = false) throws -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    proc.arguments = arguments
    proc.standardInput = FileHandle.nullDevice
    let out = Pipe()
    proc.standardOutput = out
    let err = Pipe()
    proc.standardError = captureStderr ? err : FileHandle.nullDevice
    do { try proc.run() } catch {
        throw DeviceLibraryQueryError.queryFailed(error.localizedDescription)
    }
    let raw = out.fileHandleForReading.readDataToEndOfFile()
    let errData = captureStderr ? err.fileHandleForReading.readDataToEndOfFile() : Data()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
        let errText = String(data: errData, encoding: .utf8) ?? ""
        throw DeviceLibraryQueryError.queryFailed(
            "sqlite3 exit \(proc.terminationStatus)" + (errText.isEmpty ? "" : ": \(errText)"))
    }
    return String(data: raw, encoding: .utf8) ?? ""
}

/// Pull the device's MediaLibrary.sqlitedb and return every (title,
/// total_time_ms) row. Returns an empty array if the device is offline or
/// the DB can't be parsed — callers treat that as "no dedup info" rather
/// than failing the analyze run.
public func loadDeviceLibrary(device: DeviceInfo) throws -> [DeviceLibraryEntry] {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mp-devlib-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let afc: AFCClient
    do {
        afc = try AFCClient(device: device)
    } catch {
        throw DeviceLibraryQueryError.dbPullFailed(error.localizedDescription)
    }
    defer { afc.close() }

    var mainPulled = false
    for f in dbFiles {
        do {
            let data = try afc.readFile("\(dbDir)/\(f)")
            try data.write(to: tmp.appendingPathComponent(f))
            if f == dbFiles[0] { mainPulled = true }
        } catch {
            // -wal / -shm can legitimately be missing right after a
            // checkpoint. The main .sqlitedb missing is fatal.
            if f == dbFiles[0] {
                throw DeviceLibraryQueryError.dbPullFailed(error.localizedDescription)
            }
        }
    }
    guard mainPulled else { return [] }

    let dbPath = tmp.appendingPathComponent(dbFiles[0]).path
    let text = try runSQLite3([
        "-readonly", "-separator", "\t", dbPath,
        // Filter to entries that actually correspond to video files we'd
        // sync — saves parsing musical content / podcasts / etc. on busy
        // devices. media_kind 2 = movie, 32 = TV show (per
        // research/docs/MEDIA_LIBRARY_DB.md).
        "SELECT title, CAST(total_time_ms AS INTEGER) FROM item_extra WHERE media_kind IN (2, 32);"
    ])

    var entries: [DeviceLibraryEntry] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let title = String(parts[0])
        guard let dur = Int(parts[1]) else { continue }
        entries.append(DeviceLibraryEntry(title: title, durationMs: dur))
    }
    return entries
}

/// A row on the device that the user could ask us to delete. `syncID`
/// is the load-bearing field for ATC `delete_track` — it's the original
/// wire pid captured in `item_store.sync_id`, not the renumbered DB
/// `item_pid`. `mediaPath` is what we'll `afc.remove(...)` after the
/// ATC delete commits.
public struct DeleteCandidate: Sendable {
    public let itemPid: Int64       // for display only
    public let syncID: Int64        // wire pid → what we send in delete_track
    public let title: String
    public let mediaPath: String?   // /iTunes_Control/Music/Fxx/yyyy.mp4 (nil if unbound)
    /// `item_extra.media_kind`: 2 = movie, 64 = TV episode. (Earlier notes
    /// here said 32 for TV; measured 2026-08-14 on AkmPad12 — 46 episodes
    /// all carry 64, paired with `item.media_type` 512.)
    public let mediaKind: Int
    public let totalTimeMs: Int
    /// False when the row exists but points at no file — the expired-asset
    /// signature (`base_location_id = 0`, `item_extra.location = ''`). Such a
    /// row shows up in TV.app's Movies tab with no artwork and won't play.
    ///
    /// Do NOT infer this from `mediaPath == nil`. `base_location_id = 0` is a
    /// REAL row in `base_location` whose `path` is the empty string, so the
    /// `bl.path || '/' || e.location` join yields "/" rather than NULL, and
    /// an unbound row would read as bound. We hit that false negative twice
    /// while measuring the asset-expiry window (HISTORY 2026-08-03) — hence
    /// the explicit column check below.
    public let isBound: Bool

    public init(itemPid: Int64, syncID: Int64, title: String,
                mediaPath: String?, mediaKind: Int, totalTimeMs: Int,
                isBound: Bool = true) {
        self.itemPid = itemPid; self.syncID = syncID; self.title = title
        self.mediaPath = mediaPath; self.mediaKind = mediaKind
        self.totalTimeMs = totalTimeMs
        self.isBound = isBound
    }
}

/// Columns every `DeleteCandidate` query selects, in parse order. Kept in
/// one place so the title-LIKE and sync_id lookups can't drift apart.
///
/// `base_location_id` and `location` come back as their own columns rather
/// than being inferred from the joined path — see `DeleteCandidate.isBound`
/// for why the joined path lies about unbound rows.
private let candidateColumns = """
      i.item_pid,
      COALESCE(s.sync_id, 0),
      e.title,
      COALESCE(bl.path || '/' || e.location, ''),
      COALESCE(e.media_kind, 0),
      COALESCE(CAST(e.total_time_ms AS INTEGER), 0),
      COALESCE(i.base_location_id, 0),
      COALESCE(e.location, '')
"""

/// Pull MediaLibrary.sqlitedb + its WAL/SHM sidecars into `dir`, returning
/// the local path of the main DB. The sidecars are mandatory: medialibraryd
/// runs in WAL mode, so a main-file-only copy reads a stale snapshot that
/// misses everything committed in the last few seconds.
private struct LibraryDBPull {
    let path: String
    /// Sidecars the device HAS but we failed to copy. Empty is the healthy
    /// case, and includes the legitimately-checkpointed device that has no
    /// `-wal` at all. Non-empty means the snapshot may be missing rows that
    /// are already committed — read-only callers can live with that, but any
    /// caller about to DELETE something must fail closed on it.
    let staleSidecars: [String]
}

private func pullLibraryDB(device: DeviceInfo, into dir: URL) throws -> LibraryDBPull? {
    let afc: AFCClient
    do { afc = try AFCClient(device: device) }
    catch { throw DeviceLibraryQueryError.dbPullFailed(error.localizedDescription) }
    defer { afc.close() }

    // Which sidecars actually exist right now. Without this we cannot tell a
    // read failure apart from a file that was never there, and "silently
    // ignore both" is what makes a partial snapshot look authoritative.
    let present = Set(afc.listDirectory(dbDir))

    var mainPulled = false
    var stale: [String] = []
    for f in dbFiles {
        do {
            let data = try afc.readFile("\(dbDir)/\(f)")
            try data.write(to: dir.appendingPathComponent(f))
            if f == dbFiles[0] { mainPulled = true }
        } catch {
            if f == dbFiles[0] {
                throw DeviceLibraryQueryError.dbPullFailed(error.localizedDescription)
            }
            if present.contains(f) { stale.append(f) }
        }
    }
    guard mainPulled else { return nil }
    return LibraryDBPull(
        path: dir.appendingPathComponent(dbFiles[0]).path,
        staleSidecars: stale)
}

/// Parse tab-separated rows shaped by `candidateColumns`.
private func parseCandidates(_ text: String) -> [DeleteCandidate] {
    var out: [DeleteCandidate] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let parts = line.split(separator: "\t", maxSplits: 7,
            omittingEmptySubsequences: false)
        guard parts.count == 8,
              let itemPid = Int64(parts[0]),
              let syncID = Int64(parts[1]),
              let kind = Int(parts[4]),
              let dur = Int(parts[5]),
              let baseLocationID = Int64(parts[6]) else { continue }
        let title = String(parts[2])
        let location = String(parts[7])
        let bound = baseLocationID != 0 && !location.isEmpty
        let pathFrag = String(parts[3])
        let mediaPath: String? = (bound && !pathFrag.isEmpty) ? "/\(pathFrag)" : nil
        out.append(DeleteCandidate(
            itemPid: itemPid, syncID: syncID, title: title,
            mediaPath: mediaPath, mediaKind: kind, totalTimeMs: dur,
            isBound: bound
        ))
    }
    return out
}

/// Find delete candidates by title substring (case-insensitive). Pulls
/// the device DB (+ WAL/SHM) and runs the codex-recommended join
/// (item × item_extra × item_store × base_location).
public func findDeleteCandidates(
    titleLike: String, device: DeviceInfo
) throws -> [DeleteCandidate] {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mp-delete-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    guard let pull = try pullLibraryDB(device: device, into: tmp) else { return [] }
    let dbPath = pull.path

    // We pass the pattern as a literal parameter via SQLite's `-cmd .param`
    // dance — but sqlite3 CLI's parameter binding is awkward, so we use the
    // simpler approach: escape single quotes in the pattern and embed it.
    // Risk is purely local to this Mac process; no untrusted input.
    let escaped = titleLike.replacingOccurrences(of: "'", with: "''")
    let sql = """
    SELECT
    \(candidateColumns)
    FROM item i
    JOIN item_extra e ON e.item_pid = i.item_pid
    LEFT JOIN item_store s ON s.item_pid = i.item_pid
    LEFT JOIN base_location bl ON bl.base_location_id = i.base_location_id
    WHERE LOWER(e.title) LIKE LOWER('%\(escaped)%');
    """
    let text = try runSQLite3(["-readonly", "-separator", "\t", dbPath, sql],
                              captureStderr: true)
    return parseCandidates(text)
}

/// Batch variant of `findDeleteCandidate(bySyncID:)` — one DB pull for the
/// whole set instead of one per ID. Used by the post-sync bind verification,
/// which checks every asset the run just shipped; pulling a multi-hundred-MB
/// library once per file would dominate the run's tail latency.
///
/// Returns a map keyed by sync_id; IDs with no row are simply absent.
public func findDeleteCandidates(
    bySyncIDs syncIDs: [Int64], device: DeviceInfo
) throws -> [Int64: DeleteCandidate] {
    guard !syncIDs.isEmpty else { return [:] }
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mp-syncids-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    guard let pull = try pullLibraryDB(device: device, into: tmp) else { return [:] }
    let dbPath = pull.path

    // Int64s we generated ourselves — no injection surface.
    let list = syncIDs.map(String.init).joined(separator: ",")
    let sql = """
    SELECT
    \(candidateColumns)
    FROM item_store s
    JOIN item i ON i.item_pid = s.item_pid
    JOIN item_extra e ON e.item_pid = i.item_pid
    LEFT JOIN base_location bl ON bl.base_location_id = i.base_location_id
    WHERE s.sync_id IN (\(list));
    """
    let text = try runSQLite3(["-readonly", "-separator", "\t", dbPath, sql],
                              captureStderr: true)
    var out: [Int64: DeleteCandidate] = [:]
    for c in parseCandidates(text) { out[c.syncID] = c }
    return out
}

/// Look up the row whose `item_store.sync_id` matches a wire pid we
/// generated and shipped. Returns nil if no row carries that sync_id,
/// throws if the DB pull or query itself fails.
///
/// Preferred over `findDeleteCandidates(titleLike:)` for verification
/// after a sync the caller performed: titles come from metadata and can
/// shape-shift between code paths (TV episode title vs. movie title vs.
/// filename stem), while `sync_id` is the value we locally generated in
/// `ATCSession.generateAssetID()` and iOS stores verbatim. Same DB-pull
/// mechanic as the title-LIKE variant (main + WAL + SHM).
public func findDeleteCandidate(bySyncID syncID: Int64, device: DeviceInfo) throws -> DeleteCandidate? {
    try findDeleteCandidates(bySyncIDs: [syncID], device: device)[syncID]
}

/// Which of `syncIDs` still have a row on the device, as raw integers.
///
/// Deliberately touches NO text columns. `findDeleteCandidates` would answer
/// the same question, but it selects `item_extra.title` into a tab-separated
/// stream, and `parseCandidates` drops any line whose field count is off — so
/// a title containing a tab or newline makes a LIVE row read as absent. That
/// is harmless when the caller is listing delete candidates for a human, and
/// destructive when the caller deletes whatever this says is gone (codex
/// review 2026-08-14). Integers cannot shift the field count.
///
/// Fails closed rather than returning a partial answer:
///   * a `sqlite3` error throws (inherited from `runSQLite3`);
///   * a line that is not an integer throws, instead of being skipped;
///   * an `item_store` with zero rows throws — a real device always has
///     rows, so an empty table means the snapshot is bad, and treating it as
///     truth would report every single asset as orphaned.
///
/// `requireFreshSidecars` additionally throws when the device has a `-wal` or
/// `-shm` we could not copy: that snapshot can be missing recently committed
/// rows, which again reads as false absence. Callers that only display should
/// leave it off; callers that delete must leave it on.
public func liveSyncIDs(
    among syncIDs: [Int64], device: DeviceInfo,
    requireFreshSidecars: Bool = true
) throws -> Set<Int64> {
    guard !syncIDs.isEmpty else { return [] }
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mp-live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    guard let pull = try pullLibraryDB(device: device, into: tmp) else {
        throw DeviceLibraryQueryError.dbPullFailed("no MediaLibrary.sqlitedb on device")
    }
    if requireFreshSidecars, !pull.staleSidecars.isEmpty {
        throw DeviceLibraryQueryError.dbPullFailed(
            "could not read \(pull.staleSidecars.joined(separator: ", "))"
            + " — snapshot may be missing recent commits")
    }

    let sanity = try runSQLite3(
        ["-readonly", pull.path, "SELECT COUNT(*) FROM item_store;"],
        captureStderr: true)
    guard let total = Int(sanity.trimmingCharacters(in: .whitespacesAndNewlines)),
          total > 0 else {
        throw DeviceLibraryQueryError.queryFailed(
            "item_store is empty — refusing to treat this snapshot as authoritative")
    }

    // Int64s we generated ourselves — no injection surface.
    let list = syncIDs.map(String.init).joined(separator: ",")
    let text = try runSQLite3([
        "-readonly", pull.path,
        "SELECT sync_id FROM item_store WHERE sync_id IN (\(list));"
    ], captureStderr: true)

    var live: Set<Int64> = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let id = Int64(line.trimmingCharacters(in: .whitespaces)) else {
            throw DeviceLibraryQueryError.queryFailed(
                "non-integer sync_id in result: \(line)")
        }
        live.insert(id)
    }
    return live
}

/// One TV season whose episodes carry more than one `item.album_order`.
/// `minority` holds the rows on the losing side — the ones a delete-and-resync
/// repairs, because re-inserting into an album that already exists resolved to
/// the season-number key in every case we measured (2026-08-14, one device).
///
/// Keyed by `albumPID`, never by the album name: `PipelineController` sets
/// `item.album = showName` for every season, so two seasons of one show share
/// the string. Grouping on it merged them and could name a perfectly correct
/// season's rows for re-upload (grok review 2026-08-14).
public struct SeasonOrderSplit: Sendable {
    public struct Episode: Sendable {
        public let syncID: Int64
        public let title: String
        public let episodeSortID: Int
    }
    public let albumPID: Int64
    public let album: String
    public let seasonNumber: Int
    /// `album_order` value → the `sort_map` string it resolves to, so the
    /// report can say "these sort under 'the office', those under '3'".
    public let keys: [(order: Int64, name: String, count: Int)]
    /// Rows to delete and re-sync. Only ever rows we shipped (`sync_id != 0`);
    /// can be empty when the losing side is entirely rows we cannot name.
    public let minority: [Episode]
}

/// Two or more seasons of one show sharing a SINGLE `album_order` — the mirror
/// image of `SeasonOrderSplit`, and the other half of the fault CLAUDE.md #6
/// describes.
///
/// `item.album` is the show name for every season, so all seasons of a show
/// live in one album row and separation rests entirely on `album_order`. When
/// medialibraryd stamped that order from the album's sort string — the old
/// `sort_album = showName` behaviour — two seasons synced in the SAME batch
/// both took the show-name key and landed on the same value, so TV.app draws
/// one section holding both seasons, with `episode_sort_id` repeating.
///
/// `findSeasonOrderSplits` cannot see this: it groups by (album, season) and
/// asks for >1 distinct order, and here every season has exactly one. Measured
/// on AkmPad12 2026-08-20 — Attack on Titan seasons 2 and 3, 33 rows, both on
/// order 751619276800 under sort key "attack on titan", reported clean by heal.
public struct SeasonOrderCollapse: Sendable {
    public let albumPID: Int64
    public let album: String
    /// The single `album_order` every listed season sits on.
    public let order: Int64
    /// The `sort_map` string `order` resolves to (e.g. "attack on titan").
    public let keyName: String
    /// Seasons sharing `order`, ascending. Always ≥2.
    public let seasons: [Int]
    /// Every row sitting on `order`, across all of `seasons` — what TV.app
    /// actually draws in the merged section. NOT `minority.count + 1`: the
    /// kept season contributes all of its rows, not one, and rows we did not
    /// ship count toward what the user sees even though we cannot move them.
    public let episodeCount: Int
    /// The season left in place; re-syncing it too would be wasted work, since
    /// one season must keep the order for the album row to survive.
    public let keptSeason: Int
    /// Rows to delete and re-sync — every shipped row of every season except
    /// `keptSeason`. Re-inserting stamps them from their own season number,
    /// which is what separates them.
    public let minority: [SeasonOrderSplit.Episode]
}

/// Both `album_order` faults found in one device pull.
public struct SeasonOrderReport: Sendable {
    public let splits: [SeasonOrderSplit]
    public let collapses: [SeasonOrderCollapse]
    public var isEmpty: Bool { splits.isEmpty && collapses.isEmpty }
}

/// Decode sqlite's `hex(...)` output. We hex every text column we select so
/// that album names, sort-map names and episode titles — arbitrary user text
/// that can contain tabs and newlines — cannot shift the field positions of
/// the numeric columns we make decisions on.
private func decodeHex(_ s: String) -> String {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(s.count / 2)
    var iter = s.makeIterator()
    while let hi = iter.next(), let lo = iter.next() {
        guard let h = hi.hexDigitValue, let l = lo.hexDigitValue else { return "" }
        bytes.append(UInt8(h << 4 | l))
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Find both `album_order` faults in one pass: seasons split across two or
/// more orders, and distinct seasons collapsed onto a single order.
///
/// One DB pull feeds both. The query used to pre-filter to split groups in
/// SQL; that filter is gone because it hid every collapse from the rows the
/// pure parsers see. Both parsers re-derive their own condition, so the
/// wider row set changes no verdict.
///
/// medialibraryd stamps `album_order` from the album's sort string on the
/// batch that creates the album and from `album.season_number` on every
/// later batch, and did not backfill in any case we measured. `album_order`
/// is the second column of TV.app's `ItemSeries` index; a split season
/// rendered as two "Season N" headers on the device we tested. Fixed going
/// forward by shipping `sort_album = String(season)` (PipelineController),
/// but rows already on the device keep whatever they were stamped with.
///
/// Only reports albums holding at least one row we shipped (`item_store.
/// sync_id != 0`) — a split in Apple's own content is not ours to touch.
public func findSeasonOrderIssues(device: DeviceInfo) throws -> SeasonOrderReport {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mp-splits-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    guard let pull = try pullLibraryDB(device: device, into: tmp) else {
        return SeasonOrderReport(splits: [], collapses: [])
    }
    let dbPath = pull.path

    // Numeric columns first, every text column `hex()`-encoded — see
    // `decodeHex`. `media_type = 512` is the TV episode value measured on
    // current iOS; `media_kind = 64` is accepted alongside it so a device
    // whose schema differs still reports rather than silently finding
    // nothing. `in_my_library` matters because `ItemSeries` is a PARTIAL
    // index (`WHERE in_my_library`) — rows outside it are not in the index
    // at all and so cannot produce a section.
    // The season is the ITEM's `item_video.season_number`, never the album
    // row's. `item.album = showName` (no season suffix), so medialibraryd
    // keys one album row per SHOW and every season lands in it — measured
    // 2026-08-14: seasons 1, 2 and 10 of one show all sat in album_pid
    // 73837194 whose own `season_number` was just whichever arrived first.
    // Grouping by album_pid alone therefore reads a correct multi-season
    // show (album_order "1"/"2"/"10") as a three-way split and tells the
    // user to re-upload two good seasons.
    let tvWhere = "(i.media_type = 512 OR ie.media_kind = 64) AND i.in_my_library = 1"
    let sql = """
    SELECT i.album_pid, COALESCE(iv.season_number, 0), i.album_order,
           COALESCE(s.sync_id, 0), COALESCE(i.episode_sort_id, 0),
           hex(a.album),
           hex(COALESCE((SELECT name FROM sort_map WHERE name_order = i.album_order LIMIT 1), '')),
           hex(COALESCE(ie.title, ''))
    FROM item i
    JOIN album a ON a.album_pid = i.album_pid
    JOIN item_extra ie ON ie.item_pid = i.item_pid
    LEFT JOIN item_video iv ON iv.item_pid = i.item_pid
    LEFT JOIN item_store s ON s.item_pid = i.item_pid
    WHERE \(tvWhere);
    """
    let text = try runSQLite3(["-readonly", "-separator", "\t", dbPath, sql],
                              captureStderr: true)
    return SeasonOrderReport(splits: parseSeasonOrderSplits(text),
                             collapses: parseSeasonOrderCollapses(text))
}

/// Pure half of `findSeasonOrderSplits` — everything after the query. Split
/// out so the grouping, tie-breaking and hex decoding are unit-testable
/// without a device (both reviewers flagged the absence of tests here).
func parseSeasonOrderSplits(_ text: String) -> [SeasonOrderSplit] {
    struct Row {
        let order: Int64; let keyName: String
        let syncID: Int64; let title: String; let episode: Int
    }
    // Keyed by (album_pid, the ITEM's season) — not by album name (every
    // season shares one `album` string) and not by album_pid alone (every
    // season shares one album ROW). Either coarser key merges distinct
    // seasons and reports a correct show as split.
    struct GroupKey: Hashable { let albumPID: Int64; let season: Int }
    var groups: [GroupKey: (album: String, rows: [Row])] = [:]
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let f = line.components(separatedBy: "\t")
        guard f.count == 8,
              let albumPID = Int64(f[0]), let season = Int(f[1]),
              let order = Int64(f[2]), let syncID = Int64(f[3]),
              let episode = Int(f[4]) else { continue }
        let key = GroupKey(albumPID: albumPID, season: season)
        var entry = groups[key] ?? (decodeHex(f[5]), [])
        entry.rows.append(Row(order: order, keyName: decodeHex(f[6]),
                              syncID: syncID, title: decodeHex(f[7]),
                              episode: episode))
        groups[key] = entry
    }

    return groups.compactMap { key, entry -> SeasonOrderSplit? in
        // Ours only: an album with no shipped row is Apple's to worry about.
        guard entry.rows.contains(where: { $0.syncID != 0 }) else { return nil }
        var counts: [Int64: (name: String, count: Int)] = [:]
        for r in entry.rows {
            counts[r.order, default: (r.keyName, 0)].count += 1
        }
        guard counts.count > 1 else { return nil }
        // Secondary sort on `order` so the reported ordering is stable when
        // counts tie (Dictionary iteration order is not).
        let keys = counts
            .map { (order: $0.key, name: $0.value.name, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.order < $1.order }
        // The key to KEEP is the season-number one whenever it is present,
        // regardless of how many rows sit on it — that is what medialibraryd
        // stamps on every future batch, so migrating toward it converges.
        // Falling back to raw majority would, on an even split, tell the user
        // to re-sync the half that is already correct.
        let survivor = keys.first { $0.name == String(key.season) }?.order
            ?? keys[0].order
        let minority = entry.rows
            .filter { $0.order != survivor && $0.syncID != 0 }
            .map { SeasonOrderSplit.Episode(syncID: $0.syncID, title: $0.title,
                                            episodeSortID: $0.episode) }
            .sorted { $0.episodeSortID < $1.episodeSortID }
        return SeasonOrderSplit(albumPID: key.albumPID, album: entry.album,
                                seasonNumber: key.season,
                                keys: keys, minority: minority)
    }.sorted { ($0.album, $0.seasonNumber) < ($1.album, $1.seasonNumber) }
}

/// Pure half of the collapse check. Groups by (album_pid, album_order) and
/// reports any order carrying more than one season.
///
/// Kept separate from `parseSeasonOrderSplits` rather than folded in: the two
/// faults group on different keys, pick their survivor by different rules, and
/// a season can legitimately appear in both reports (split across orders, one
/// of which it shares with another season).
func parseSeasonOrderCollapses(_ text: String) -> [SeasonOrderCollapse] {
    struct Row {
        let season: Int; let syncID: Int64; let title: String; let episode: Int
    }
    struct GroupKey: Hashable { let albumPID: Int64; let order: Int64 }
    var groups: [GroupKey: (album: String, keyName: String, rows: [Row])] = [:]
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let f = line.components(separatedBy: "\t")
        guard f.count == 8,
              let albumPID = Int64(f[0]), let season = Int(f[1]),
              let order = Int64(f[2]), let syncID = Int64(f[3]),
              let episode = Int(f[4]) else { continue }
        let key = GroupKey(albumPID: albumPID, order: order)
        var entry = groups[key] ?? (decodeHex(f[5]), decodeHex(f[6]), [])
        entry.rows.append(Row(season: season, syncID: syncID,
                              title: decodeHex(f[7]), episode: episode))
        groups[key] = entry
    }

    return groups.compactMap { key, entry -> SeasonOrderCollapse? in
        // Ours only, exactly as for splits — a collapse in Apple's own content
        // is not ours to repair.
        guard entry.rows.contains(where: { $0.syncID != 0 }) else { return nil }
        let seasons = Set(entry.rows.map(\.season)).sorted()
        guard seasons.count > 1 else { return nil }

        // Keep whichever season is already correctly keyed — its order IS its
        // season-number key, so re-syncing it would only move it back where it
        // is. Otherwise keep the one with the most rows, so the user re-uploads
        // as little as possible; lowest season number breaks a tie so the
        // report is stable across runs.
        let counts = Dictionary(grouping: entry.rows, by: \.season).mapValues(\.count)
        let kept = seasons.first { entry.keyName == String($0) }
            ?? seasons.sorted {
                counts[$0, default: 0] != counts[$1, default: 0]
                    ? counts[$0, default: 0] > counts[$1, default: 0]
                    : $0 < $1
            }[0]

        let minority = entry.rows
            .filter { $0.season != kept && $0.syncID != 0 }
            .map { SeasonOrderSplit.Episode(syncID: $0.syncID, title: $0.title,
                                            episodeSortID: $0.episode) }
            .sorted { $0.episodeSortID < $1.episodeSortID }
        // Every other season was Apple's — nothing of ours to move.
        guard !minority.isEmpty else { return nil }

        return SeasonOrderCollapse(albumPID: key.albumPID, album: entry.album,
                                   order: key.order, keyName: entry.keyName,
                                   seasons: seasons, episodeCount: entry.rows.count,
                                   keptSeason: kept, minority: minority)
    }.sorted { ($0.album, $0.order) < ($1.album, $1.order) }
}

public extension Array where Element == DeviceLibraryEntry {
    /// True if any entry matches the given title (exact) within ±2 s of
    /// the given duration. Used by analyzeOne to flag duplicate jobs.
    func contains(title: String, durationMs: Int) -> Bool {
        let tolerance = 2000
        return contains { e in
            e.title == title && abs(e.durationMs - durationMs) <= tolerance
        }
    }
}

/// Cleanup-side reading of the device library: which `/iTunes_Control/Music/Fxx/<name>`
/// paths the device's medialibraryd considers registered. The path is the
/// concatenation of `base_location.path` (e.g. `iTunes_Control/Music/F39`)
/// and `item_extra.location` (e.g. `FSYH.mp4`), normalized with a leading
/// slash to match what `DeviceMaintenance.scanStagingMedia` returns.
///
/// Used to identify true orphans: scanned files that don't appear in this
/// set are leftovers from abandoned syncs and safe to delete.
public struct RegisteredPaths: Sendable {
    /// Fully-qualified registered paths (e.g. /iTunes_Control/Music/F39/FSYH.mp4).
    public let paths: Set<String>
    /// Slot directories (e.g. F39) that have at least one item row but no
    /// resolvable filename — the row exists with `base_location_id > 0` but
    /// `item_extra.location` is empty (binding still in flight from a fresh
    /// sync). Anything in those slots gets the benefit of the doubt and is
    /// kept regardless of filename match.
    public let pendingSlots: Set<String>
}

public func loadDeviceRegisteredPaths(device: DeviceInfo) throws -> RegisteredPaths {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mp-devpaths-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let afc: AFCClient
    do { afc = try AFCClient(device: device) }
    catch { throw DeviceLibraryQueryError.dbPullFailed(error.localizedDescription) }
    defer { afc.close() }

    var mainPulled = false
    for f in dbFiles {
        do {
            let data = try afc.readFile("\(dbDir)/\(f)")
            try data.write(to: tmp.appendingPathComponent(f))
            if f == dbFiles[0] { mainPulled = true }
        } catch {
            if f == dbFiles[0] {
                throw DeviceLibraryQueryError.dbPullFailed(error.localizedDescription)
            }
        }
    }
    guard mainPulled else { return RegisteredPaths(paths: [], pendingSlots: []) }

    let dbPath = tmp.appendingPathComponent(dbFiles[0]).path
    // Outer left join — we want rows where base_location_id > 0 even if
    // item_extra.location hasn't been populated yet (post-sync binding lag,
    // observed during the re-upload diagnostic). For those we report just
    // the slot dir in pendingSlots and skip the path entry.
    let text = try runSQLite3([
        "-readonly", "-separator", "\t", dbPath,
        """
        SELECT COALESCE(bl.path, ''), COALESCE(e.location, '')
        FROM item i
        LEFT JOIN base_location bl ON bl.base_location_id = i.base_location_id
        LEFT JOIN item_extra e ON e.item_pid = i.item_pid
        WHERE i.base_location_id > 0;
        """
    ])

    var paths = Set<String>()
    var pendingSlots = Set<String>()
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let basePath = String(parts[0])
        let filename = String(parts[1])
        guard basePath.hasPrefix("iTunes_Control/Music/") else { continue }
        let slot = basePath.split(separator: "/").last.map(String.init) ?? ""
        if filename.isEmpty {
            if !slot.isEmpty { pendingSlots.insert(slot) }
        } else {
            paths.insert("/\(basePath)/\(filename)")
        }
    }
    return RegisteredPaths(paths: paths, pendingSlots: pendingSlots)
}
