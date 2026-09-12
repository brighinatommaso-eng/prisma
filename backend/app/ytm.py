"""YouTube Music search, via ytmusicapi (unauthenticated).

The spec (section 3.5) puts search on ytmusicapi rather than yt-dlp or the
YouTube Data API, so this module is the only place that talks to YouTube Music.

ytmusicapi is synchronous and blocking. Every public helper here is therefore
called from a worker thread by the API layer, never directly on the event loop.
"""

import re
import threading
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from typing import Any

from ytmusicapi import YTMusic

# Search results only ever carry a 120x120 thumbnail, which is unusable both for
# cover display and for the palette extraction in spec section 3.3.
# googleusercontent encodes the rendition in a suffix after the final "=", so the
# larger variant is a URL rewrite rather than a second API call.
#
# Note that googleusercontent will not upscale: for an album whose source art is
# smaller than 544px it serves the source size instead. That is still correct and
# still far better than 120px, so it is accepted rather than rejected.
ARTWORK_SIZE_SUFFIX = "w544-h544-l90-rj"
_ARTWORK_SUFFIX_RE = re.compile(r"=[\w-]+$")
ARTWORK_PROBE_TIMEOUT_S = 5.0
_ARTWORK_PROBE_WORKERS = 8

# ytmusicapi holds a requests session and a visitor id that can go stale, so the
# client is built lazily and rebuilt if it starts failing. One user, one client.
_client: YTMusic | None = None
_client_lock = threading.Lock()


def _get_client() -> YTMusic:
    global _client
    with _client_lock:
        if _client is None:
            _client = YTMusic()
        return _client


def _reset_client() -> None:
    global _client
    with _client_lock:
        _client = None


def _parse_duration(raw: str | None) -> int | None:
    """Turn ytmusicapi's "4:07" / "1:02:33" into seconds."""
    if not raw:
        return None
    total = 0
    try:
        for part in raw.split(":"):
            total = total * 60 + int(part)
    except ValueError:
        return None
    return total


def _largest_thumbnail(item: dict[str, Any]) -> str | None:
    thumbs = item.get("thumbnails") or []
    if not thumbs:
        return None
    # ytmusicapi returns them smallest-first; be explicit rather than trusting it.
    best = max(thumbs, key=lambda t: (t.get("width") or 0) * (t.get("height") or 0))
    return best.get("url")


def _join_artists(item: dict[str, Any]) -> str | None:
    names = [a.get("name") for a in (item.get("artists") or []) if a.get("name")]
    return ", ".join(names) if names else None


def _album_name(item: dict[str, Any]) -> str | None:
    album = item.get("album")
    if isinstance(album, dict):
        return album.get("name") or None
    if isinstance(album, str):
        return album or None
    return None


def _upsized_artwork_url(url: str | None) -> str | None:
    """Rewrite the googleusercontent size suffix to ARTWORK_SIZE_SUFFIX.

    Returns None when there is no size suffix to rewrite, so the caller keeps
    the URL it already has.
    """
    if not url or not _ARTWORK_SUFFIX_RE.search(url):
        return None
    return _ARTWORK_SUFFIX_RE.sub("=" + ARTWORK_SIZE_SUFFIX, url)


def _is_fetchable_image(url: str) -> bool:
    """HEAD the URL and require a 200 carrying an image content type.

    The download phase persists artwork_url to the database, so an unverified
    URL would become a permanently broken link on a stored track. Anything that
    is not provably an image is treated as a miss.
    """
    try:
        request = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(request, timeout=ARTWORK_PROBE_TIMEOUT_S) as response:
            if response.status != 200:
                return False
            return (response.headers.get("Content-Type") or "").startswith("image/")
    except Exception:
        return False


def _resolve_artwork(songs: list[dict[str, Any]]) -> None:
    """Promote artwork_url to the larger rendition where it is actually fetchable.

    Mutates `songs` in place. Probes run concurrently because one sequential
    HEAD per result would otherwise dominate the response time of /search.
    Anything unverified keeps the 120x120 URL, which is known to work.
    """
    candidates: dict[int, str] = {}
    for index, song in enumerate(songs):
        larger = _upsized_artwork_url(song["artwork_url_small"])
        if larger:
            candidates[index] = larger
    if not candidates:
        return

    workers = min(_ARTWORK_PROBE_WORKERS, len(candidates))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        verdicts = list(pool.map(_is_fetchable_image, candidates.values()))

    for (index, larger), fetchable in zip(candidates.items(), verdicts):
        if fetchable:
            songs[index]["artwork_url"] = larger


def normalise_song(item: dict[str, Any]) -> dict[str, Any] | None:
    """Reduce a raw ytmusicapi song result to the API's flat shape.

    Returns None for results without a videoId, which cannot be downloaded and
    so are useless to the client. artwork_url starts out equal to the small
    thumbnail and is promoted later by _resolve_artwork.
    """
    video_id = item.get("videoId")
    if not video_id:
        return None
    thumbnail = _largest_thumbnail(item)
    return {
        "video_id": video_id,
        "title": item.get("title"),
        "artist": _join_artists(item),
        "album": _album_name(item),
        "duration_s": item.get("duration_seconds") or _parse_duration(item.get("duration")),
        "artwork_url": thumbnail,
        "artwork_url_small": thumbnail,
    }


def search_songs(query: str, limit: int) -> list[dict[str, Any]]:
    """Search songs. Blocking; call from a thread.

    Retries once with a fresh client, because a stale visitor id surfaces as a
    parse error rather than a connection error and is invisible otherwise.
    """
    for attempt in (1, 2):
        try:
            raw = _get_client().search(query, filter="songs", limit=limit)
            break
        except Exception:
            _reset_client()
            if attempt == 2:
                raise
    songs = [s for s in (normalise_song(item) for item in raw) if s is not None]
    # ytmusicapi treats `limit` as a floor and pages past it; the caller asked
    # for an exact count. Trim before probing artwork so no discarded result
    # costs a HEAD request.
    songs = songs[:limit]
    _resolve_artwork(songs)
    return songs


def reachable() -> bool:
    """Cheapest possible liveness probe against YouTube Music. Blocking."""
    try:
        _get_client().search("a", filter="songs", limit=1)
        return True
    except Exception:
        _reset_client()
        return False
