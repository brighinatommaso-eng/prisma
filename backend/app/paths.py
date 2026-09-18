"""Filesystem naming and ownership.

The on-disk layout is {MUSIC_DIR}/{Artist}/{Album}/{Title}.m4a with a sibling
cover.jpg per album folder. Because the album name is a path segment, a wrong
album is a wrong path, not just wrong text -- see albums.py.
"""

import os
import re
import threading
from pathlib import Path

from .config import MUSIC_DIR, OWNER_GID, OWNER_UID

UNKNOWN_ARTIST = "Unknown Artist"
NO_ALBUM = "Singles"
MAX_SEGMENT_CHARS = 120
COVER_FILENAME = "cover.jpg"

# Held by the worker for a whole download and by a track deletion, so a delete
# never removes a file or album folder a download is writing into right then.
library_write_lock = threading.Lock()

# Illegal on Linux (/) and additionally on SMB/Windows. Slashes become a dash so
# "AC/DC" stays readable; the rest are dropped because they carry no meaning in
# a name ("What?" -> "What").
_TO_DASH = str.maketrans({"/": "-", "\\": "-"})
_TO_DROP = re.compile(r'[:*?"<>|]')
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")
_WHITESPACE = re.compile(r"\s+")


def sanitise_segment(raw: str | None, fallback: str) -> str:
    """Make `raw` safe to use as a single path segment on Linux and SMB.

    Falls back to `fallback` when the input is missing, blank, or sanitises away
    to nothing.
    """
    if not raw:
        return fallback
    text = raw.translate(_TO_DASH)
    text = _TO_DROP.sub("", text)
    text = _CONTROL.sub("", text)
    text = _WHITESPACE.sub(" ", text)
    # Leading dots hide the entry; trailing dots and spaces are silently
    # stripped by SMB, which would make the path Prisma stored differ from the
    # path that actually exists.
    text = text.strip(" .")
    if len(text) > MAX_SEGMENT_CHARS:
        # Truncation can re-expose a trailing space or dot, so strip again.
        text = text[:MAX_SEGMENT_CHARS].strip(" .")
    return text or fallback


def track_paths(artist: str | None, album: str | None, title: str | None,
                video_id: str) -> tuple[Path, Path]:
    """Return (audio_path, cover_path) for a track, avoiding collisions.

    If an audio file already exists at the natural path, " [video_id]" is
    appended to the title segment rather than overwriting it. A file that is
    already this video_id's own is reused as-is, so a re-run is idempotent.
    """
    artist_seg = sanitise_segment(artist, UNKNOWN_ARTIST)
    album_seg = sanitise_segment(album, NO_ALBUM)
    title_seg = sanitise_segment(title, video_id)

    album_dir = MUSIC_DIR / artist_seg / album_seg
    audio_path = album_dir / f"{title_seg}.m4a"

    if audio_path.exists() and not _belongs_to(audio_path, video_id):
        disambiguated = sanitise_segment(f"{title_seg} [{video_id}]", video_id)
        audio_path = album_dir / f"{disambiguated}.m4a"

    return audio_path, album_dir / COVER_FILENAME


def _belongs_to(audio_path: Path, video_id: str) -> bool:
    """True when `audio_path` is already the file Prisma stored for `video_id`."""
    from . import db

    existing = db.track_for_path(str(audio_path))
    return existing is not None and existing == video_id


def set_owner(path: Path) -> None:
    """chown `path` to the configured uid:gid, best effort.

    The container runs as root so this normally succeeds. It is a no-op on
    Windows, where os.chown does not exist, so the same code runs in local
    tests.
    """
    if not hasattr(os, "chown"):
        return
    try:
        os.chown(path, OWNER_UID, OWNER_GID)
    except (PermissionError, FileNotFoundError, OSError):
        pass


def make_dir_owned(path: Path) -> None:
    """mkdir -p, chowning every level this call actually creates."""
    missing = []
    probe = path
    while not probe.exists():
        missing.append(probe)
        if probe.parent == probe:
            break
        probe = probe.parent
    path.mkdir(parents=True, exist_ok=True)
    for created in reversed(missing):
        set_owner(created)
