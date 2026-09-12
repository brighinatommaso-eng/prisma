"""MP4/M4A tag writing, via mutagen.

Tags are written so the metadata survives independently of the database: if
catalog.db is ever lost, the library on disk is still a tagged library. The M4A
container carries MP4 tags including the cover, so everything travels inside the
file (spec section 3.2).

The cover is embedded at its source pixel dimensions. Artwork from YouTube Music
is not always square -- 544x539 has been observed -- so it is never cropped and
never stretched.
"""

import io
from pathlib import Path
from typing import Any

from mutagen.mp4 import MP4, MP4Cover
from PIL import Image

_JPEG_MAGIC = b"\xff\xd8\xff"
_PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def _cover_atom(data: bytes) -> MP4Cover:
    """Wrap cover bytes in the right MP4Cover format, without resampling.

    JPEG and PNG go in untouched. Anything else (WebP, for instance) is
    re-encoded to JPEG because MP4Cover cannot describe it -- at identical
    pixel dimensions, so the embedded cover still matches the source.
    """
    if data[:3] == _JPEG_MAGIC:
        return MP4Cover(data, imageformat=MP4Cover.FORMAT_JPEG)
    if data[:8] == _PNG_MAGIC:
        return MP4Cover(data, imageformat=MP4Cover.FORMAT_PNG)
    with Image.open(io.BytesIO(data)) as image:
        buffer = io.BytesIO()
        image.convert("RGB").save(buffer, format="JPEG", quality=92)
    return MP4Cover(buffer.getvalue(), imageformat=MP4Cover.FORMAT_JPEG)


def write_tags(audio_path: Path, meta: dict[str, Any], cover_bytes: bytes | None) -> None:
    """Write title, artist, album, year, track number and cover onto the file."""
    audio = MP4(str(audio_path))

    if meta.get("title"):
        audio["\xa9nam"] = [str(meta["title"])]
    if meta.get("artist"):
        audio["\xa9ART"] = [str(meta["artist"])]
    if meta.get("album"):
        audio["\xa9alb"] = [str(meta["album"])]
    if meta.get("year"):
        audio["\xa9day"] = [str(meta["year"])]
    if meta.get("track_no"):
        # Total is unknown here; 0 is the conventional "unspecified" total.
        audio["trkn"] = [(int(meta["track_no"]), 0)]
    if cover_bytes:
        audio["covr"] = [_cover_atom(cover_bytes)]

    audio.save()


def read_tags(audio_path: Path) -> dict[str, Any]:
    """Read back the tags that matter. Used to verify a write."""
    audio = MP4(str(audio_path))
    covers = audio.get("covr") or []
    cover_dimensions = None
    if covers:
        with Image.open(io.BytesIO(bytes(covers[0]))) as image:
            cover_dimensions = image.size
    track = (audio.get("trkn") or [(None, None)])[0]
    return {
        "title": (audio.get("\xa9nam") or [None])[0],
        "artist": (audio.get("\xa9ART") or [None])[0],
        "album": (audio.get("\xa9alb") or [None])[0],
        "year": (audio.get("\xa9day") or [None])[0],
        "track_no": track[0] if track else None,
        "cover_bytes": len(bytes(covers[0])) if covers else 0,
        "cover_dimensions": cover_dimensions,
    }
