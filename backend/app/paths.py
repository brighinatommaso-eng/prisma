"""Filesystem naming and ownership.

The on-disk layout is {MUSIC_DIR}/{Artist}/{Album}/{Title}.m4a with a sibling
cover.jpg per album folder. Because the album name is a path segment, a wrong
album is a wrong path, not just wrong text -- see albums.py. A track whose
natural path belongs to another one is filed beside it as
{Title} [{video_id}].m4a; track_paths has the rule.
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


class PathConflict(Exception):
    """The only path a track may be written to holds a file that is not its own."""


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


def _with_video_id(title_seg: str, video_id: str) -> str:
    """`Title [video_id]`, within the segment limit.

    The title gives way, never the id: cut at the end, a long title would lose
    exactly the part that makes the name this track's own.
    """
    suffix = " [" + sanitise_segment(video_id, "id") + "]"
    room = max(MAX_SEGMENT_CHARS - len(suffix), 1)
    return title_seg[:room].rstrip(" .") + suffix


def bracketed_sibling(audio_path: Path, video_id: str) -> Path:
    """The `Title [video_id]` path beside audio_path, for a track that is
    recorded at audio_path and has to give it up."""
    return audio_path.with_name(_with_video_id(audio_path.stem, video_id) + audio_path.suffix)


def track_paths(artist: str | None, album: str | None, title: str | None,
                video_id: str) -> tuple[Path, Path]:
    """Return (audio_path, cover_path) for a download of video_id.

    Two different video ids never get the same audio path, and an .m4a that
    may be another track's is never the target: yt-dlp does not replace a file
    already at its output path, it reports it as downloaded, and the pipeline
    would then tag and record someone else's audio as this track. That is
    exactly how a path shared by two live ids came to hold one id's audio
    under the other id's tags and hash.

    A track that is live in the catalogue goes back to the path on its row
    when that path is in the folder its metadata names today and is still its
    own. With a file there, that means no other live id is recorded at the
    path and the file has the track's recorded SHA-256; a file two live rows
    point at belongs to neither, whichever hash matches. With no file there,
    it means no lower live id is recorded at the same path, which is what
    separates two ids recorded at one path once the file is gone. Otherwise,
    and for a track that is new or was deleted, the natural path
    Artist/Album/Title.m4a is used when it is free, and `Title [video_id].m4a`
    beside it when it is not. Nothing is ever renamed, moved or removed to
    make room: a file that is nobody's any more simply stays.

    The bracketed path carries the id, so only this track's own downloads ever
    write there, and a file found at it is taken to be what an earlier attempt
    left. The exception raises PathConflict: the row already records that
    path and the file there is not the recorded audio, so there is no further
    name to fall back to.
    """
    from . import db
    from .integrity import sha256_of

    artist_seg = sanitise_segment(artist, UNKNOWN_ARTIST)
    album_seg = sanitise_segment(album, NO_ALBUM)
    title_seg = sanitise_segment(title, video_id)

    album_dir = MUSIC_DIR / artist_seg / album_seg
    cover_path = album_dir / COVER_FILENAME
    natural = album_dir / f"{title_seg}.m4a"
    bracketed = album_dir / f"{_with_video_id(title_seg, video_id)}.m4a"

    own = db.get_track(video_id)
    live = own is not None and own.get("deleted_at") is None and own.get("file_path")
    # A row filed under an older reading of the artist or album is not sent
    # back there: the cover and the album row follow today's metadata, and the
    # audio goes with them.
    if live and Path(own["file_path"]).parent == album_dir:
        recorded = Path(own["file_path"])
        # The string as stored, which is what the other rows were matched on
        # when they were written.
        others = [c["id"] for c in db.path_claims(own["file_path"])
                  if c["live"] and c["id"] != video_id]
        if recorded.exists():
            still_own = (not others and recorded.is_file()
                         and own.get("sha256") is not None
                         and sha256_of(recorded) == own["sha256"])
        else:
            still_own = not any(other < video_id for other in others)
        if still_own:
            return recorded, cover_path
        if recorded == bracketed:
            raise PathConflict(
                f"{recorded} holds a file that is not the audio recorded for "
                f"{video_id}; it was left untouched and nothing was downloaded"
            )
        return bracketed, cover_path

    claims = db.path_claims(str(natural))
    taken = any(c["live"] and c["id"] != video_id for c in claims)
    # A file with no live owner is still not ours to write into, unless it is
    # what a deletion of this same track left behind.
    leftover = natural.exists() and not any(c["id"] == video_id for c in claims)
    if taken or leftover:
        return bracketed, cover_path
    return natural, cover_path


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
