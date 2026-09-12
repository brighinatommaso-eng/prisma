"""Track and album metadata from YouTube Music.

Three jobs:

1. Turn a bare video_id into title / artist / release / duration / artwork, so
   POST /downloads needs nothing but the id.
2. Resolve the *canonical* album.
3. Normalise the album title so one album is one folder.

Why (2) is load-bearing rather than cosmetic: the album name is a path segment
in {Artist}/{Album}/{Title}.m4a, so a wrong album is a wrong path. And the album
YouTube Music reports for a recording is the release that recording belongs to,
not necessarily the canonical album. Verified empirically for Daft Punk
"Something About Us" (URzOGF_QGls): search, get_watch_playlist and get_album via
its browseId all report the 2003 single "Something About Us (Love Theme from
Interstella)" with type="Single". Nothing reports Discovery.

Why (3) exists: resolution alone still fragments an album, because YouTube Music
carries the same record under several edition titles. "Homework" and "Homework
(25th Anniversary Edition)" are both real albums by the right artist containing
the right track, so two tracks off one record landed in two folders. Candidate
ranking cannot fix that -- whichever release ranks first is luck. Stripping the
edition suffix makes the folder a function of the album, not of search order.
"""

import re
import unicodedata
from typing import Any

from . import ytm

# How many album search hits to consider before giving up. Each costs one
# get_album round trip, so this is the resolution cost ceiling.
MAX_ALBUM_CANDIDATES = 5
CANONICAL_TYPE = "Album"

# A track number is only assigned on a confident match against the album's
# track list. A wrong number is worse than none: it silently misorders the
# client, while NULL is visibly unknown.
TRACK_MATCH_TOLERANCE_S = 3

# A trailing bracketed group whose contents mention one of these is an edition
# marker, not part of the album name. Kept as one named list so the vocabulary
# is editable without touching any regex.
EDITION_KEYWORDS = (
    "remaster",
    "remastered",
    "deluxe",
    "super deluxe",
    "expanded",
    "anniversary",
    "edition",
    "version",
    "reissue",
    "special",
    "bonus",
    "collector",
    "legacy",
)

# Only a group at the very END of the title is a candidate for stripping, which
# is what keeps "(What's the Story) Morning Glory?" intact.
_TRAILING_GROUP_RE = re.compile(r"[\(\[]([^()\[\]]*)[\)\]]\s*$")
_EDITION_KEYWORD_RE = re.compile(
    "|".join(r"\b" + re.escape(keyword) + r"\b" for keyword in EDITION_KEYWORDS),
    re.IGNORECASE,
)
# Punctuation a stripped suffix tends to leave dangling: "Album - (Remastered)".
_TRAILING_JUNK = " \t-,–—"


def normalise_album_title(title: str | None) -> str | None:
    """Strip trailing edition suffixes so one album maps to one folder.

    Repeats, so "Album (Deluxe) (Remastered)" collapses to "Album". Returns the
    original untouched if stripping would leave nothing, which is what happens
    for a release actually named "(Deluxe Edition)".
    """
    if not title:
        return title
    current = title.strip()
    while True:
        match = _TRAILING_GROUP_RE.search(current)
        if match is None:
            break
        if _EDITION_KEYWORD_RE.search(match.group(1)) is None:
            break
        candidate = current[: match.start()].rstrip(_TRAILING_JUNK)
        if not candidate:
            return title
        current = candidate
    return current or title


def _norm(text: str | None) -> str:
    """Loose comparison key: case, accents, punctuation and parentheticals out.

    "Something About Us (Love Theme from Interstella 5555)" and
    "Something About Us" both reduce to "something about us", which is what
    makes a track match across a single and its parent album.
    """
    folded = unicodedata.normalize("NFKD", text or "").lower()
    folded = re.sub(r"\(.*?\)|\[.*?\]", " ", folded)
    folded = re.sub(r"[^a-z0-9 ]", " ", folded)
    return re.sub(r"\s+", " ", folded).strip()


def _exact_key(text: str | None) -> str:
    """Strict comparison key: case, accents and whitespace only.

    Unlike _norm this KEEPS parentheticals, so "Around the World (Radio Edit)"
    and "Around the World" are different titles -- which is the whole point
    when deciding whether a track number really belongs to this recording.
    """
    folded = unicodedata.normalize("NFKD", text or "")
    folded = "".join(ch for ch in folded if not unicodedata.combining(ch))
    return re.sub(r"\s+", " ", folded).strip().casefold()


def _confident_track_no(track: dict[str, Any], video_id: str, title: str | None,
                        duration_s: int | None) -> int | None:
    """The album track number, but only when the match is trustworthy.

    _find_track deliberately matches loosely, because a single and its parent
    album can name the same recording differently -- that looseness is right
    for identifying the album and wrong for numbering the track. So the number
    survives only on an exact id match, an exact title match, or a duration
    within TRACK_MATCH_TOLERANCE_S of the album track. Anything else is NULL.
    """
    number = _as_int(track.get("trackNumber"))
    if number is None:
        return None
    if track.get("videoId") and track.get("videoId") == video_id:
        return number
    ours = _exact_key(title)
    if ours and _exact_key(track.get("title")) == ours:
        return number
    album_duration = _as_int(track.get("duration_seconds"))
    if (album_duration is not None and duration_s is not None
            and abs(album_duration - duration_s) <= TRACK_MATCH_TOLERANCE_S):
        return number
    return None


def _group_key(title: str | None) -> str:
    """Comparison key for "is this the same album wearing another edition name"."""
    return _norm(normalise_album_title(title))


def _artist_names(entry: dict[str, Any]) -> list[str]:
    return [a.get("name") for a in (entry.get("artists") or []) if a.get("name")]


def _thumbnails(entry: dict[str, Any]) -> list[dict[str, Any]]:
    # get_album uses "thumbnails"; get_watch_playlist tracks use "thumbnail".
    raw = entry.get("thumbnails") or entry.get("thumbnail") or []
    return raw if isinstance(raw, list) else []


def _best_artwork_url(entry: dict[str, Any]) -> str | None:
    """Largest available artwork, upsized and verified via the phase 1a helpers."""
    thumbs = _thumbnails(entry)
    if not thumbs:
        return None
    best = max(thumbs, key=lambda t: (t.get("width") or 0) * (t.get("height") or 0))
    url = best.get("url")
    if not url:
        return None
    larger = ytm._upsized_artwork_url(url)
    if larger and ytm._is_fetchable_image(larger):
        return larger
    return url


def _as_int(value: Any) -> int | None:
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def _find_track(album: dict[str, Any], video_id: str, title: str | None) -> dict[str, Any] | None:
    """Locate our recording inside an album payload.

    videoId first, since it is exact. Falling back to a normalised title match
    is necessary because an album track and the search hit for the same
    recording can carry different ids.
    """
    tracks = album.get("tracks") or []
    for track in tracks:
        if track.get("videoId") and track.get("videoId") == video_id:
            return track
    target = _norm(title)
    if not target:
        return None
    for track in tracks:
        if _norm(track.get("title")) == target:
            return track
    return None


def _candidate(album: dict[str, Any], browse_id: str | None, video_id: str,
               title: str | None, duration_s: int | None,
               require_track: bool) -> dict[str, Any] | None:
    """One resolution candidate, or None when the track is not on this release."""
    matched = _find_track(album, video_id, title)
    if matched is None and require_track:
        return None
    raw_title = album.get("title")
    return {
        "raw_title": raw_title,
        "norm_title": normalise_album_title(raw_title),
        "group": _group_key(raw_title),
        "browse_id": browse_id,
        "year": _as_int(album.get("year")),
        "track_no": (
            _confident_track_no(matched, video_id, title, duration_s)
            if matched else None
        ),
        "artwork_url": _best_artwork_url(album),
    }


def resolve_album(video_id: str, title: str | None, artists: list[str],
                  album_raw: str | None, album_browse_id: str | None,
                  duration_s: int | None = None) -> dict[str, Any]:
    """Best-effort canonical album for a recording.

    Never raises. On any failure the caller gets album_raw back, normalised.

    Selection order is deliberate: normalisation decides the folder, the year
    only decides which release inside that folder supplies year and track
    number.
    """
    fallback: dict[str, Any] = {
        "album": normalise_album_title(album_raw),
        "album_release_title": album_raw,
        "album_browse_id": album_browse_id,
        "year": None,
        "track_no": None,
        "album_artwork_url": None,
    }
    client = ytm._get_client()

    candidates: list[dict[str, Any]] = []
    target_group: str | None = None

    # Stage 1: follow the browseId we already have.
    release: dict[str, Any] | None = None
    if album_browse_id:
        try:
            release = client.get_album(album_browse_id)
        except Exception:
            release = None
    if release:
        # Not required to contain the track: this release came from the
        # recording itself, so it is authoritative even if the ids differ.
        entry = _candidate(release, album_browse_id, video_id, title, duration_s,
                           require_track=False)
        if entry is not None:
            if (release.get("type") or "") == CANONICAL_TYPE:
                candidates.append(entry)
                # An album from the recording pins the folder; siblings found
                # below may only refine which edition supplies the year.
                target_group = entry["group"]
            else:
                # A single or EP. Keep its data as the floor, then try to do
                # better with a search.
                fallback = {
                    "album": entry["norm_title"],
                    "album_release_title": entry["raw_title"],
                    "album_browse_id": album_browse_id,
                    "year": entry["year"],
                    "track_no": entry["track_no"],
                    "album_artwork_url": entry["artwork_url"],
                }

    # Stage 2: look for the canonical album, and for other editions of it.
    query = " ".join(part for part in [artists[0] if artists else None, title] if part)
    if query.strip():
        try:
            hits = client.search(query, filter="albums", limit=MAX_ALBUM_CANDIDATES)
        except Exception:
            hits = []
        ours = {_norm(name) for name in artists if name}
        for hit in (hits or [])[:MAX_ALBUM_CANDIDATES]:
            if (hit.get("type") or "") != CANONICAL_TYPE:
                continue
            browse_id = hit.get("browseId")
            if not browse_id or browse_id == album_browse_id:
                continue
            # Reject a same-titled track on somebody else's record, e.g. the
            # "Instrumental Covers of Daft Punk" hit for this very query.
            if ours and not ours & {_norm(name) for name in _artist_names(hit)}:
                continue
            # When the folder is already pinned, skip anything that cannot join
            # that group -- saves a get_album round trip per rejected hit.
            if target_group is not None and _group_key(hit.get("title")) != target_group:
                continue
            try:
                detail = client.get_album(browse_id)
            except Exception:
                continue
            if (detail.get("type") or "") != CANONICAL_TYPE:
                continue
            entry = _candidate(detail, browse_id, video_id, title, duration_s,
                               require_track=True)
            if entry is not None:
                candidates.append(entry)

    if not candidates:
        return fallback

    # Group by normalised title, so editions of one record collapse together.
    if target_group is None:
        target_group = candidates[0]["group"]
    group = [c for c in candidates if c["group"] == target_group] or candidates

    # Earliest release in the group wins the metadata; unknown years sort last.
    group.sort(key=lambda c: (c["year"] is None, c["year"] or 0))
    best = group[0]

    return {
        # The folder name: normalised, and identical for every edition.
        "album": best["norm_title"],
        # What the chosen release is actually called upstream.
        "album_release_title": best["raw_title"],
        "album_browse_id": best["browse_id"],
        "year": best["year"],
        "track_no": next(
            (c["track_no"] for c in group if c["track_no"] is not None), None
        ),
        "album_artwork_url": next(
            (c["artwork_url"] for c in group if c["artwork_url"]), None
        ),
    }


def fetch_track_metadata(video_id: str) -> dict[str, Any]:
    """Everything needed to name, tag and file a track, from its id alone.

    Raises if the recording cannot be identified at all, because there is then
    nothing to download.
    """
    client = ytm._get_client()
    watch = client.get_watch_playlist(videoId=video_id, limit=1)
    tracks = watch.get("tracks") or []
    if not tracks:
        raise RuntimeError("YouTube Music returned no track for video_id " + video_id)
    head = tracks[0]

    artists = _artist_names(head)
    album_entry = head.get("album") if isinstance(head.get("album"), dict) else None
    album_raw = (album_entry or {}).get("name")
    album_browse_id = (album_entry or {}).get("id")

    # Needed before resolution: the duration is one of the signals that decides
    # whether an album track number may be trusted for this recording.
    duration_s = ytm._parse_duration(head.get("length"))

    resolved = resolve_album(
        video_id=video_id,
        title=head.get("title"),
        artists=artists,
        album_raw=album_raw,
        album_browse_id=album_browse_id,
        duration_s=duration_s,
    )

    return {
        "video_id": video_id,
        # Track titles are never normalised: "(Radio Edit)" is part of the song.
        "title": head.get("title"),
        "artist": ", ".join(artists) if artists else None,
        "artists": artists,
        "album_raw": album_raw,
        "album": resolved.get("album") or normalise_album_title(album_raw),
        "album_release_title": resolved.get("album_release_title") or album_raw,
        "album_browse_id": resolved.get("album_browse_id"),
        "year": resolved.get("year") or _as_int(head.get("year")),
        "track_no": resolved.get("track_no"),
        "duration_s": duration_s,
        "artwork_url": resolved.get("album_artwork_url") or _best_artwork_url(head),
    }
