"""MediaLibrary.sqlitedb injection for native TV app integration.

Handles reading, writing, and re-indexing the iOS media library database
to make transferred files appear in the native TV app.

Schema based on iOS 18.x/26.x MediaLibrary.sqlitedb analysis.
"""

from __future__ import annotations

import random
import sqlite3
import time
from pathlib import Path

from mediaporter.device import afc_pull_file, afc_push_file
from mediaporter.exceptions import MediaDBError
from mediaporter.metadata import EpisodeMetadata, MovieMetadata

MEDIA_DB_PATH = "iTunes_Control/iTunes/MediaLibrary.sqlitedb"
MEDIA_DB_WAL = "iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal"
MEDIA_DB_SHM = "iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm"

# Media types (item.media_type)
MEDIA_TYPE_VIDEO = 2048

# Media kinds (item_extra.media_kind)
MEDIA_KIND_MOVIE = 2
MEDIA_KIND_TV_SHOW = 32  # may also be 64 on some iOS versions

# Video quality (item_video.video_quality)
VQ_SD = 0
VQ_720P = 1
VQ_1080P = 2
VQ_4K = 3


def _generate_item_pid() -> int:
    """Generate a unique item_pid in the range used by synced content."""
    # Use a random large integer similar to existing pids
    return random.randint(10**18, 2**62)


def _get_or_create_base_location(conn: sqlite3.Connection, fxx_path: str) -> int:
    """Get the base_location_id for a given Fxx path, creating if needed."""
    cursor = conn.execute(
        "SELECT base_location_id FROM base_location WHERE path = ?", (fxx_path,)
    )
    row = cursor.fetchone()
    if row:
        return row[0]

    # Create new — IDs follow a pattern (3840 = F00, 3841 = F01, etc.)
    cursor = conn.execute("SELECT MAX(base_location_id) FROM base_location")
    max_id = cursor.fetchone()[0] or 3839
    new_id = max_id + 1

    conn.execute(
        "INSERT INTO base_location (base_location_id, path) VALUES (?, ?)",
        (new_id, fxx_path),
    )
    return new_id


def _get_or_create_sort_map_entry(conn: sqlite3.Connection, name: str) -> tuple[int, int]:
    """Get or create a sort_map entry for a title. Returns (name_order, name_section)."""
    cursor = conn.execute(
        "SELECT name_order, name_section FROM sort_map WHERE name = ?", (name,)
    )
    row = cursor.fetchone()
    if row:
        return row[0], row[1]

    # Get next name_order (increment by a standard step)
    cursor = conn.execute("SELECT MAX(name_order) FROM sort_map")
    max_order = cursor.fetchone()[0] or 0
    # Sort map orders use large increments (multiples of 2^28 or similar)
    new_order = max_order + (1 << 28)

    # Section is the first letter index (A=0, B=1, ... Z=25, #=27)
    first_char = name[0].upper() if name else "#"
    if first_char.isalpha():
        section = ord(first_char) - ord("A")
    else:
        section = 27

    conn.execute(
        "INSERT INTO sort_map (name, name_order, name_section, sort_key) VALUES (?, ?, ?, ?)",
        (name, new_order, section, b""),
    )
    return new_order, section


def _get_or_create_album(conn: sqlite3.Connection, item_pid: int, title: str, year: int) -> int:
    """Get or create an album entry for a movie/show. Returns album_pid."""
    album_pid = random.randint(10**18, 2**62)
    conn.execute(
        """INSERT INTO album (album_pid, album, representative_item_pid, album_year, keep_local_status)
           VALUES (?, ?, ?, ?, 2)""",
        (album_pid, "", item_pid, year),
    )
    return album_pid


def _get_video_quality(width: int | None, height: int | None) -> int:
    """Map resolution to video_quality value."""
    if not height:
        return VQ_SD
    if height >= 2160:
        return VQ_4K
    if height >= 1080:
        return VQ_1080P
    if height >= 720:
        return VQ_720P
    return VQ_SD


def _build_movie_info_plist(metadata: MovieMetadata) -> str:
    """Build the movie_info plist XML with cast/directors."""
    parts = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
             '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
             '<plist version="1.0">',
             '<dict>']

    if metadata.director:
        parts.append('\t<key>directors</key>')
        parts.append('\t<array>')
        parts.append('\t\t<dict>')
        parts.append(f'\t\t\t<key>name</key>')
        parts.append(f'\t\t\t<string>{metadata.director}</string>')
        parts.append('\t\t</dict>')
        parts.append('\t</array>')

    parts.append('</dict>')
    parts.append('</plist>')
    return '\n'.join(parts)


def inject_movie(
    db_path: Path,
    remote_filename: str,
    fxx_dir: str,
    metadata: MovieMetadata,
    file_size: int,
    duration_ms: float,
    width: int | None = None,
    height: int | None = None,
) -> int:
    """Inject a movie into MediaLibrary.sqlitedb. Returns the new item_pid."""
    conn = sqlite3.connect(str(db_path))
    try:
        item_pid = _generate_item_pid()
        year = int(metadata.year) if metadata.year else 0
        now_timestamp = int(time.time() - 978307200)  # Apple epoch (Jan 1, 2001)

        # base_location
        base_loc_id = _get_or_create_base_location(conn, fxx_dir)

        # sort_map for title
        title_order, title_section = _get_or_create_sort_map_entry(conn, metadata.title)

        # album (each movie gets its own album entry)
        album_pid = _get_or_create_album(conn, item_pid, metadata.title, year)

        # Generate a sync_id
        sync_id = random.randint(10**18, 2**62)

        # 1. item table
        conn.execute("""
            INSERT INTO item (
                item_pid, media_type, title_order, title_order_section,
                album_pid, base_location_id, in_my_library, date_added,
                date_downloaded, keep_local, keep_local_status
            ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, 1, 2)
        """, (item_pid, MEDIA_TYPE_VIDEO, title_order, title_section,
              album_pid, base_loc_id, now_timestamp, now_timestamp))

        # 2. item_extra table
        conn.execute("""
            INSERT INTO item_extra (
                item_pid, title, sort_title, total_time_ms, year,
                location, file_size, media_kind, date_modified,
                description, description_long, location_kind_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 4)
        """, (item_pid, metadata.title, metadata.title, duration_ms, year,
              remote_filename, file_size, MEDIA_KIND_MOVIE, now_timestamp,
              metadata.overview or "", metadata.long_overview or ""))

        # 3. item_video table
        vq = _get_video_quality(width, height)
        movie_info = _build_movie_info_plist(metadata) if metadata.director else ""
        conn.execute("""
            INSERT INTO item_video (
                item_pid, video_quality, has_subtitles, has_alternate_audio,
                movie_info
            ) VALUES (?, ?, 1, 1, ?)
        """, (item_pid, vq, movie_info))

        # 4. item_store table (triggers in_my_library via SQL trigger)
        conn.execute("""
            INSERT INTO item_store (
                item_pid, sync_id, sync_in_my_library, sync_redownload_params
            ) VALUES (?, ?, 1, '')
        """, (item_pid, sync_id))

        # 5. item_playback table
        conn.execute("""
            INSERT INTO item_playback (
                item_pid, has_video, duration
            ) VALUES (?, 1, ?)
        """, (item_pid, int(duration_ms / 1000)))

        # 6. item_stats (empty row needed)
        try:
            conn.execute("INSERT INTO item_stats (item_pid) VALUES (?)", (item_pid,))
        except sqlite3.OperationalError:
            pass

        conn.commit()
        return item_pid

    except sqlite3.Error as e:
        raise MediaDBError(f"Failed to inject movie: {e}")
    finally:
        conn.close()


def inject_tv_episode(
    db_path: Path,
    remote_filename: str,
    fxx_dir: str,
    metadata: EpisodeMetadata,
    file_size: int,
    duration_ms: float,
    width: int | None = None,
    height: int | None = None,
) -> int:
    """Inject a TV episode into MediaLibrary.sqlitedb. Returns the new item_pid."""
    conn = sqlite3.connect(str(db_path))
    try:
        item_pid = _generate_item_pid()
        year = int(metadata.year) if metadata.year else 0
        now_timestamp = int(time.time() - 978307200)

        base_loc_id = _get_or_create_base_location(conn, fxx_dir)

        ep_title = metadata.episode_title or f"Episode {metadata.episode}"
        title_order, title_section = _get_or_create_sort_map_entry(conn, ep_title)

        # For TV shows, series_name_order controls show grouping
        series_order, series_section = _get_or_create_sort_map_entry(conn, metadata.show_name)

        # Album represents the show+season
        album_name = f"{metadata.show_name}, Season {metadata.season}"
        album_order, _ = _get_or_create_sort_map_entry(conn, album_name)
        album_pid = random.randint(10**18, 2**62)
        conn.execute("""
            INSERT OR IGNORE INTO album (
                album_pid, album, representative_item_pid, album_year,
                season_number, keep_local_status
            ) VALUES (?, ?, ?, ?, ?, 2)
        """, (album_pid, album_name, item_pid, year, metadata.season))

        sync_id = random.randint(10**18, 2**62)

        # episode_sort_id encodes season+episode for sort order
        episode_sort_id = metadata.season * 10000 + metadata.episode

        # 1. item
        conn.execute("""
            INSERT INTO item (
                item_pid, media_type, title_order, title_order_section,
                series_name_order, series_name_order_section,
                album_pid, album_order, album_order_section,
                episode_sort_id, base_location_id, in_my_library,
                date_added, date_downloaded, keep_local, keep_local_status
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, 1, 2)
        """, (item_pid, MEDIA_TYPE_VIDEO, title_order, title_section,
              series_order, series_section,
              album_pid, album_order, title_section,
              episode_sort_id, base_loc_id,
              now_timestamp, now_timestamp))

        # 2. item_extra — media_kind for TV show
        conn.execute("""
            INSERT INTO item_extra (
                item_pid, title, sort_title, total_time_ms, year,
                location, file_size, media_kind, date_modified,
                description, description_long, location_kind_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 4)
        """, (item_pid, ep_title, ep_title, duration_ms, year,
              remote_filename, file_size, MEDIA_KIND_TV_SHOW, now_timestamp,
              metadata.overview or "", metadata.long_overview or ""))

        # 3. item_video — includes season/episode info
        vq = _get_video_quality(width, height)
        conn.execute("""
            INSERT INTO item_video (
                item_pid, video_quality, season_number, episode_id,
                network_name, has_subtitles, has_alternate_audio
            ) VALUES (?, ?, ?, ?, ?, 1, 1)
        """, (item_pid, vq, metadata.season,
              metadata.episode_id or f"S{metadata.season:02d}E{metadata.episode:02d}",
              metadata.network or ""))

        # 4. item_store
        conn.execute("""
            INSERT INTO item_store (
                item_pid, sync_id, sync_in_my_library, sync_redownload_params
            ) VALUES (?, ?, 1, '')
        """, (item_pid, sync_id))

        # 5. item_playback
        conn.execute("""
            INSERT INTO item_playback (
                item_pid, has_video, duration
            ) VALUES (?, 1, ?)
        """, (item_pid, int(duration_ms / 1000)))

        # 6. item_stats
        try:
            conn.execute("INSERT INTO item_stats (item_pid) VALUES (?)", (item_pid,))
        except sqlite3.OperationalError:
            pass

        conn.commit()
        return item_pid

    except sqlite3.Error as e:
        raise MediaDBError(f"Failed to inject TV episode: {e}")
    finally:
        conn.close()


def inject_item(
    db_path: Path,
    remote_filename: str,
    fxx_dir: str,
    metadata: MovieMetadata | EpisodeMetadata,
    file_size: int,
    duration_ms: float,
    width: int | None = None,
    height: int | None = None,
) -> int:
    """Inject a media item into MediaLibrary.sqlitedb."""
    if isinstance(metadata, EpisodeMetadata):
        return inject_tv_episode(
            db_path, remote_filename, fxx_dir, metadata,
            file_size, duration_ms, width, height,
        )
    else:
        return inject_movie(
            db_path, remote_filename, fxx_dir, metadata,
            file_size, duration_ms, width, height,
        )


def pull_media_db(lockdown, local_dir: Path) -> Path:
    """Pull MediaLibrary.sqlitedb + WAL + SHM from device."""
    db_path = local_dir / "MediaLibrary.sqlitedb"
    afc_pull_file(lockdown, MEDIA_DB_PATH, db_path)

    # Also pull WAL and SHM for consistency
    for suffix in ("-wal", "-shm"):
        try:
            afc_pull_file(
                lockdown,
                MEDIA_DB_PATH + suffix,
                local_dir / f"MediaLibrary.sqlitedb{suffix}",
            )
        except Exception:
            pass

    return db_path


def push_media_db(lockdown, local_dir: Path) -> None:
    """Push modified MediaLibrary.sqlitedb back to device.

    We checkpoint the WAL into the main db first, then push only the main file
    and empty WAL/SHM to avoid corruption.
    """
    db_path = local_dir / "MediaLibrary.sqlitedb"

    # Checkpoint WAL into main database
    conn = sqlite3.connect(str(db_path))
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()

    # Push main db
    afc_push_file(lockdown, db_path, MEDIA_DB_PATH)

    # Push empty WAL and SHM to reset
    wal_path = local_dir / "MediaLibrary.sqlitedb-wal"
    shm_path = local_dir / "MediaLibrary.sqlitedb-shm"
    wal_path.write_bytes(b"")
    shm_path.write_bytes(b"")
    try:
        afc_push_file(lockdown, wal_path, MEDIA_DB_WAL)
        afc_push_file(lockdown, shm_path, MEDIA_DB_SHM)
    except Exception:
        pass  # Not critical if these fail


def trigger_reindex(lockdown) -> None:
    """Attempt to trigger medialibraryd to re-read the database."""
    try:
        from pymobiledevice3.services.notification_proxy import NotificationProxyService
        import asyncio

        async def _notify():
            async with NotificationProxyService(lockdown=lockdown) as np:
                for notification in [
                    "com.apple.itunes-mobdev.syncWillStart",
                    "com.apple.itunes-mobdev.syncDidFinish",
                    "com.apple.mobile.application_installed",
                ]:
                    try:
                        await np.notify_post(notification)
                    except Exception:
                        pass

        from mediaporter.device import _run
        _run(_notify())
    except Exception:
        pass
