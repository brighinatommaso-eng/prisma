"""The download pipeline: fetch, tag, file and record one track.

Audio format is locked by spec section 3.2: take the AAC-in-M4A track YouTube
already serves and do not re-encode it. Only when no m4a exists is Opus pulled
and transcoded to AAC 192k.

yt-dlp writes straight to its final path inside the library rather than to a
staging area. That is deliberate: it means the pipeline never moves or deletes
anything, so a crash leaves a partial file with an obvious name instead of
orphaning a temp file somewhere else.
"""

import hashlib
import subprocess
import urllib.request
from pathlib import Path
from typing import Any, Callable

from . import db, metadata, palette, tagging
from .paths import make_dir_owned, set_owner, track_paths

AUDIO_FORMAT = "bestaudio[ext=m4a]/bestaudio"
FALLBACK_BITRATE = "192k"
ARTWORK_TIMEOUT_S = 15.0

# Download occupies the first slice of the job's progress; tagging, palette and
# hashing take the rest. Reporting 1.0 before the file is tagged would be a lie.
_DOWNLOAD_PROGRESS_CEILING = 0.90
_PROGRESS_MIN_DELTA = 0.02

ProgressCallback = Callable[[float], None]

# The options that shape how yt-dlp talks to YouTube, as opposed to what it
# downloads and where. /health builds its yt-dlp probe from these same options,
# so any JS runtime or extractor argument added here is what it reports.
YTDLP_OPTIONS: dict[str, Any] = {
    "noplaylist": True,
    "quiet": True,
    "no_warnings": True,
}


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _fetch_artwork(url: str | None) -> bytes | None:
    if not url:
        return None
    try:
        with urllib.request.urlopen(urllib.request.Request(url), timeout=ARTWORK_TIMEOUT_S) as response:
            if response.status != 200:
                return None
            return response.read()
    except Exception:
        # Artwork is not worth failing a download over.
        return None


def _transcode_to_m4a(source: Path) -> Path:
    """Spec section 3.2 fallback: no m4a upstream, so encode AAC at 192 kbps.

    The source is kept rather than deleted, so a bad transcode stays
    diagnosable.
    """
    target = source.with_suffix(".m4a")
    subprocess.run(
        ["ffmpeg", "-y", "-i", str(source), "-vn",
         "-c:a", "aac", "-b:a", FALLBACK_BITRATE, str(target)],
        check=True, capture_output=True,
    )
    set_owner(source)
    return target


def _download_audio(video_id: str, audio_path: Path, on_progress: ProgressCallback) -> Path:
    """Fetch audio to audio_path (extension decided by yt-dlp). Returns the file."""
    from yt_dlp import YoutubeDL

    last_reported = [0.0]

    def hook(status: dict[str, Any]) -> None:
        if status.get("status") != "downloading":
            return
        total = status.get("total_bytes") or status.get("total_bytes_estimate")
        done = status.get("downloaded_bytes") or 0
        if not total:
            return
        fraction = (done / total) * _DOWNLOAD_PROGRESS_CEILING
        if fraction - last_reported[0] >= _PROGRESS_MIN_DELTA:
            last_reported[0] = fraction
            on_progress(fraction)

    # A literal % in a title would otherwise be read as an output template field.
    stem = audio_path.stem.replace("%", "%%")
    options = {
        **YTDLP_OPTIONS,
        "format": AUDIO_FORMAT,
        "outtmpl": str(audio_path.parent / (stem + ".%(ext)s")),
        "progress_hooks": [hook],
    }
    with YoutubeDL(options) as ydl:
        info = ydl.extract_info("https://music.youtube.com/watch?v=" + video_id, download=True)

    requested = (info or {}).get("requested_downloads") or []
    if requested and requested[0].get("filepath"):
        return Path(requested[0]["filepath"])
    with YoutubeDL(options) as ydl:
        return Path(ydl.prepare_filename(info))


def run_pipeline(video_id: str, job_id: int | None = None) -> dict[str, Any]:
    """Download, tag, file and record one track. Returns the stored row.

    Raises on failure; the worker turns that into state=failed with the message
    preserved.
    """
    def report(fraction: float) -> None:
        if job_id is not None:
            db.set_progress(job_id, fraction)

    meta = metadata.fetch_track_metadata(video_id)

    audio_path, cover_path = track_paths(
        artist=meta.get("artist"),
        album=meta.get("album"),
        title=meta.get("title"),
        video_id=video_id,
    )
    make_dir_owned(audio_path.parent)

    downloaded = _download_audio(video_id, audio_path, report)
    if downloaded.suffix.lower() != ".m4a":
        downloaded = _transcode_to_m4a(downloaded)
    set_owner(downloaded)
    report(_DOWNLOAD_PROGRESS_CEILING)

    cover_bytes = _fetch_artwork(meta.get("artwork_url"))
    artwork_path: str | None = None
    colours: list[str] | None = None
    if cover_bytes:
        # One cover.jpg per album folder, shared by every track in it.
        if not cover_path.exists():
            cover_path.write_bytes(cover_bytes)
            set_owner(cover_path)
        artwork_path = str(cover_path)
        try:
            colours = palette.extract(cover_bytes)
        except Exception:
            colours = None

    # The album row is the authority for year, cover and palette. Created here
    # so the tags can carry the album's year rather than this release's, which
    # is what stops two tracks in one folder disagreeing.
    album_id = db.upsert_album(
        artist=meta.get("artist"),
        album=meta.get("album"),
        release_title=meta.get("album_release_title"),
        browse_id=meta.get("album_browse_id"),
        year=meta.get("year"),
        cover_path=artwork_path,
        palette=colours,
    )
    album = db.get_album(album_id) or {}

    tag_meta = dict(meta)
    tag_meta["year"] = album.get("year") or meta.get("year")
    tagging.write_tags(downloaded, tag_meta, cover_bytes)
    set_owner(downloaded)
    report(0.97)

    track = {
        "id": video_id,
        "title": meta.get("title"),
        "artist": meta.get("artist"),
        "album_raw": meta.get("album_raw"),
        "album": meta.get("album"),
        "album_release_title": meta.get("album_release_title"),
        "album_browse_id": meta.get("album_browse_id"),
        "album_id": album_id,
        "year": meta.get("year"),
        "track_no": meta.get("track_no"),
        "duration_s": meta.get("duration_s"),
        "file_path": str(downloaded),
        "file_bytes": downloaded.stat().st_size,
        "sha256": sha256_of(downloaded),
        "artwork_path": artwork_path,
        "palette": colours,
    }
    db.upsert_track(track)
    report(1.0)
    return track
