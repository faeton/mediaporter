"""Metadata lookup: filename parsing (guessit) + TMDb API search."""

from __future__ import annotations

import urllib.request
from dataclasses import dataclass
from pathlib import Path

from mediaporter.exceptions import MetadataError


@dataclass
class MovieMetadata:
    """Metadata for a movie."""
    title: str
    year: str | None = None
    genre: str | None = None
    overview: str | None = None
    long_overview: str | None = None
    director: str | None = None
    network: str | None = None
    poster_url: str | None = None
    poster_data: bytes | None = None
    tmdb_id: int | None = None


@dataclass
class EpisodeMetadata:
    """Metadata for a TV episode."""
    show_name: str
    season: int
    episode: int
    episode_title: str | None = None
    episode_id: str | None = None
    year: str | None = None
    genre: str | None = None
    overview: str | None = None
    long_overview: str | None = None
    network: str | None = None
    poster_url: str | None = None
    poster_data: bytes | None = None
    show_poster_url: str | None = None
    show_poster_data: bytes | None = None
    tmdb_show_id: int | None = None


def parse_filename(path: Path) -> dict:
    """Parse a video filename to extract title, year, season, episode, etc."""
    try:
        from guessit import guessit
    except ImportError:
        raise MetadataError("guessit not installed. Run: pip install guessit")
    return dict(guessit(path.name))


def search_movie(title: str, year: str | None = None, api_key: str | None = None) -> list[MovieMetadata]:
    """Search TMDb for a movie by title and optional year."""
    if not api_key:
        raise MetadataError("TMDb API key required. Set TMDB_API_KEY or use --tmdb-key.")

    try:
        import tmdbsimple as tmdb
    except ImportError:
        raise MetadataError("tmdbsimple not installed. Run: pip install tmdbsimple")

    tmdb.API_KEY = api_key
    search = tmdb.Search()
    params = {"query": title}
    if year:
        params["year"] = year
    search.movie(**params)

    results = []
    for item in search.results[:5]:
        results.append(MovieMetadata(
            title=item.get("title", title),
            year=item.get("release_date", "")[:4] or None,
            overview=item.get("overview", "")[:255],
            long_overview=item.get("overview"),
            poster_url=f"https://image.tmdb.org/t/p/w500{item['poster_path']}" if item.get("poster_path") else None,
            tmdb_id=item.get("id"),
        ))

    return results


def search_tv_shows(show_name: str, api_key: str | None = None) -> list[dict]:
    """Return ranked TMDb TV-show candidates for a query (top 5).

    Ranking prefers shows that actually have a first_air_date over the bare
    popularity order TMDb returns — that pushes musicals/specials/empty stubs
    below real series with the same name.
    """
    if not api_key:
        raise MetadataError("TMDb API key required. Set TMDB_API_KEY or use --tmdb-key.")
    try:
        import tmdbsimple as tmdb
    except ImportError:
        raise MetadataError("tmdbsimple not installed. Run: pip install tmdbsimple")

    tmdb.API_KEY = api_key
    search = tmdb.Search()
    search.tv(query=show_name)
    results = list(search.results or [])
    results.sort(
        key=lambda r: (
            1 if r.get("first_air_date") else 0,
            float(r.get("popularity") or 0.0),
        ),
        reverse=True,
    )
    return results[:5]


def search_tv_episode(
    show_name: str, season: int, episode: int, api_key: str | None = None,
    show: dict | None = None,
) -> EpisodeMetadata | None:
    """Search TMDb for a TV episode.

    If `show` is provided (a TMDb tv search-result dict), it's used directly
    instead of running a fresh search — lets the caller pick a specific show
    after presenting candidates.
    """
    if not api_key:
        raise MetadataError("TMDb API key required. Set TMDB_API_KEY or use --tmdb-key.")

    try:
        import tmdbsimple as tmdb
    except ImportError:
        raise MetadataError("tmdbsimple not installed. Run: pip install tmdbsimple")

    tmdb.API_KEY = api_key

    if show is None:
        candidates = search_tv_shows(show_name, api_key)
        if not candidates:
            return None
        show = candidates[0]
    show_id = show["id"]

    try:
        ep = tmdb.TV_Episodes(show_id, season, episode)
        ep_info = ep.info()
    except Exception:
        return None

    try:
        show_detail = tmdb.TV(show_id)
        show_info = show_detail.info()
        genre = show_info.get("genres", [{}])[0].get("name") if show_info.get("genres") else None
        network = show_info.get("networks", [{}])[0].get("name") if show_info.get("networks") else None
    except Exception:
        genre = None
        network = None

    show_poster_url = (
        f"https://image.tmdb.org/t/p/w500{show['poster_path']}" if show.get("poster_path") else None
    )
    ep_still_url = (
        f"https://image.tmdb.org/t/p/w500{ep_info['still_path']}" if ep_info.get("still_path") else None
    )

    return EpisodeMetadata(
        show_name=show.get("name", show_name),
        season=season,
        episode=episode,
        episode_title=ep_info.get("name"),
        episode_id=f"S{season:02d}E{episode:02d}",
        year=show.get("first_air_date", "")[:4] or None,
        genre=genre,
        overview=ep_info.get("overview", "")[:255] if ep_info.get("overview") else None,
        long_overview=ep_info.get("overview"),
        network=network,
        poster_url=ep_still_url or show_poster_url,
        show_poster_url=show_poster_url,
        tmdb_show_id=show_id,
    )


def download_poster(url: str) -> bytes | None:
    """Download a poster image from URL."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "mediaporter/0.2"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.read()
    except Exception:
        return None


def generate_fallback_poster(title: str, year: str | None = None) -> bytes | None:
    """Generate a simple poster image with title text when TMDb has no poster.

    Returns JPEG bytes in 2:3 aspect ratio (500x750), or None if Pillow unavailable.
    """
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        return None

    W, H = 500, 750
    img = Image.new("RGB", (W, H), color=(25, 25, 35))
    draw = ImageDraw.Draw(img)

    # Subtle gradient overlay
    for y in range(H):
        alpha = int(30 * (y / H))
        draw.line([(0, y), (W, y)], fill=(25 + alpha, 25 + alpha, 40 + alpha))

    # Load font
    try:
        font_large = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", size=40)
        font_small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", size=24)
    except (OSError, IOError):
        font_large = ImageFont.load_default(size=40)
        font_small = ImageFont.load_default(size=24)

    # Word-wrap title
    max_width = W - 60
    words = title.split()
    lines: list[str] = []
    current_line = ""
    for word in words:
        test = f"{current_line} {word}".strip()
        bbox = draw.textbbox((0, 0), test, font=font_large)
        if bbox[2] - bbox[0] <= max_width:
            current_line = test
        else:
            if current_line:
                lines.append(current_line)
            current_line = word
    if current_line:
        lines.append(current_line)

    # Center vertically
    line_height = 50
    total_text_height = len(lines) * line_height + (30 if year else 0)
    y_start = (H - total_text_height) // 2

    # Draw title lines
    for i, line in enumerate(lines):
        bbox = draw.textbbox((0, 0), line, font=font_large)
        text_w = bbox[2] - bbox[0]
        x = (W - text_w) // 2
        draw.text((x, y_start + i * line_height), line, fill=(240, 240, 240), font=font_large)

    # Draw year
    if year:
        y_year = y_start + len(lines) * line_height + 10
        bbox = draw.textbbox((0, 0), year, font=font_small)
        text_w = bbox[2] - bbox[0]
        x = (W - text_w) // 2
        draw.text((x, y_year), year, fill=(160, 160, 170), font=font_small)

    # Thin border
    draw.rectangle([(2, 2), (W - 3, H - 3)], outline=(60, 60, 80), width=1)

    import io
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=85)
    return buf.getvalue()


def _pick_tv_show_interactive(
    initial_query: str, api_key: str
) -> dict | None:
    """Interactively pick a TMDb TV show.

    Loops: shows top candidates for the current query, lets the user pick by
    number, type a new query to re-search, or skip. Returns the chosen TMDb
    search-result dict or None if skipped.
    """
    import sys
    if not sys.stdin.isatty():
        return None

    query = initial_query
    while True:
        try:
            candidates = search_tv_shows(query, api_key)
        except MetadataError:
            return None

        if candidates:
            print(f"  TMDb candidates for \"{query}\":")
            for i, c in enumerate(candidates, 1):
                year = (c.get("first_air_date") or "")[:4] or "----"
                name = c.get("name") or "?"
                orig = c.get("original_name") or ""
                orig_str = f" / {orig}" if orig and orig != name else ""
                pop = c.get("popularity") or 0.0
                print(f"    {i}. {name}{orig_str} ({year})  [pop {pop:.0f}]")
        else:
            print(f"  No TMDb match for \"{query}\".")

        try:
            prompt = "  Pick number, type new search, or [s]kip: " if candidates \
                else "  Type new search or [s]kip: "
            choice = input(prompt).strip()
        except (EOFError, KeyboardInterrupt):
            return None

        if not choice or choice.lower() in {"s", "skip"}:
            return None
        if candidates and choice.isdigit():
            idx = int(choice)
            if 1 <= idx <= len(candidates):
                return candidates[idx - 1]
            print(f"  Out of range (1-{len(candidates)}).")
            continue
        query = choice


def _pick_movie_interactive(
    initial_title: str, initial_year: str | int | None, api_key: str
) -> "MovieMetadata | None":
    """Interactively pick a TMDb movie. Same loop pattern as the TV picker."""
    import sys
    if not sys.stdin.isatty():
        return None

    title = initial_title
    year = str(initial_year) if initial_year else None
    while True:
        try:
            results = search_movie(title, year, api_key)
        except MetadataError:
            return None

        if results:
            print(f"  TMDb candidates for \"{title}\"" + (f" ({year})" if year else "") + ":")
            for i, m in enumerate(results, 1):
                y = m.year or "----"
                print(f"    {i}. {m.title} ({y})")
        else:
            print(f"  No TMDb match for \"{title}\"" + (f" ({year})" if year else "") + ".")

        try:
            prompt = "  Pick number, type new search (optional 'title|year'), or [s]kip: " \
                if results else "  Type new search (optional 'title|year') or [s]kip: "
            choice = input(prompt).strip()
        except (EOFError, KeyboardInterrupt):
            return None

        if not choice or choice.lower() in {"s", "skip"}:
            return None
        if results and choice.isdigit():
            idx = int(choice)
            if 1 <= idx <= len(results):
                return results[idx - 1]
            print(f"  Out of range (1-{len(results)}).")
            continue
        if "|" in choice:
            t, _, y = choice.partition("|")
            title = t.strip() or title
            year = y.strip() or None
        else:
            title = choice
            year = None


def lookup_metadata(
    path: Path,
    media_type: str | None = None,
    show_override: str | None = None,
    season_override: int | None = None,
    episode_override: int | None = None,
    api_key: str | None = None,
    non_interactive: bool = False,
) -> MovieMetadata | EpisodeMetadata | None:
    """Full metadata lookup pipeline: parse filename -> search TMDb -> download poster."""
    meta = _lookup_metadata_inner(
        path, media_type, show_override, season_override,
        episode_override, api_key, non_interactive,
    )

    # Apply fallback poster if none found
    if meta:
        has_poster = False
        if isinstance(meta, EpisodeMetadata):
            has_poster = bool(meta.poster_data or meta.show_poster_data)
        elif isinstance(meta, MovieMetadata):
            has_poster = bool(meta.poster_data)

        if not has_poster:
            title = meta.show_name if isinstance(meta, EpisodeMetadata) else meta.title
            year = meta.year
            fallback = generate_fallback_poster(title, year)
            if fallback:
                if isinstance(meta, EpisodeMetadata):
                    meta.show_poster_data = fallback
                else:
                    meta.poster_data = fallback

    return meta


def _lookup_metadata_inner(
    path: Path,
    media_type: str | None = None,
    show_override: str | None = None,
    season_override: int | None = None,
    episode_override: int | None = None,
    api_key: str | None = None,
    non_interactive: bool = False,
) -> MovieMetadata | EpisodeMetadata | None:
    """Internal metadata lookup — called by lookup_metadata which adds fallback poster."""
    guess = parse_filename(path)

    guessed_type = guess.get("type", "movie")
    if media_type:
        guessed_type = "episode" if media_type == "tv" else "movie"

    title = show_override or guess.get("title", path.stem)
    year = guess.get("year")

    if guessed_type == "episode" or season_override is not None or episode_override is not None:
        season = season_override or guess.get("season", 1)
        episode = episode_override or guess.get("episode", 1)
        show = show_override or guess.get("title", path.stem)

        if api_key:
            candidates = search_tv_shows(show, api_key)
            picked = candidates[0] if candidates else None

            if not non_interactive and not candidates:
                picked = _pick_tv_show_interactive(show, api_key)

            if picked is not None:
                meta = search_tv_episode(show, season, episode, api_key, show=picked)
                if meta:
                    if meta.poster_url:
                        meta.poster_data = download_poster(meta.poster_url)
                    if meta.show_poster_url and meta.show_poster_url != meta.poster_url:
                        meta.show_poster_data = download_poster(meta.show_poster_url)
                    return meta

        return EpisodeMetadata(
            show_name=show,
            season=season,
            episode=episode,
            episode_id=f"S{season:02d}E{episode:02d}",
        )

    else:
        if api_key:
            results = search_movie(title, str(year) if year else None, api_key)
            picked = results[0] if results else None

            if not non_interactive and not results:
                picked = _pick_movie_interactive(title, year, api_key)

            if picked is not None:
                if picked.poster_url:
                    picked.poster_data = download_poster(picked.poster_url)
                return picked

        return MovieMetadata(title=title, year=str(year) if year else None)
