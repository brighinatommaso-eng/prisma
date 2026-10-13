"""The download pipeline: fetch, tag, file and record one track.

Audio format is locked by spec section 3.2: take the AAC-in-M4A track YouTube
already serves and do not re-encode it. Only when no m4a exists is Opus pulled
and transcoded to AAC 192k.

yt-dlp writes straight to its final path inside the library rather than to a
staging area. That is deliberate: it means the pipeline never moves or deletes
anything, so a crash leaves a partial file with an obvious name instead of
orphaning a temp file somewhere else.
"""

import subprocess
import urllib.request
from pathlib import Path
from typing import Any, Callable

from . import db, metadata, palette, tagging
from .integrity import sha256_of
from .paths import bracketed_sibling, make_dir_owned, set_owner, track_paths

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


def _send_to_own_paths(shared_path: str, except_id: str | None = None) -> None:
    """Record every live track at shared_path, bar except_id, at its own
    bracketed path instead. Rows only; no file is touched.

    A path belongs to one track. When two live rows name the same one, this
    is what ends it, at the two moments something is known for certain:

    - a track has just been written to the path (except_id). It is that
      track's file now, and no other row may keep pointing at it;
    - a track has just been downloaded away from a file it shared (no
      except_id). That file is one track's audio under another one's tags, and
      the row left behind would otherwise look like its rightful owner -- all
      the more if its hash is the one that matches.

    The rows moved name a path with no file at it yet, so they read as
    missing, which is true, and their own download puts them right.
    """
    for claim in db.path_claims(shared_path):
        if not claim["live"] or claim["id"] == except_id:
            continue
        own_path = str(bracketed_sibling(Path(shared_path), claim["id"]))
        if own_path != shared_path:
            db.repoint_track(claim["id"], shared_path, own_path)


def run_pipeline(video_id: str, job_id: int | None = None) -> dict[str, Any]:
    """Download, tag, file and record one track. Returns the stored row.

    Raises on failure; the worker turns that into state=failed with the message
    preserved.
    """
    def report(fraction: float) -> None:
        if job_id is not None:
            db.set_progress(job_id, fraction)

    meta = metadata.fetch_track_metadata(video_id)
    previous = db.get_track(video_id)

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
    # restore: a track deleted earlier and downloaded again reappears.
    db.upsert_track(track, restore=True)
    _send_to_own_paths(track["file_path"], except_id=video_id)
    if previous is not None and previous.get("deleted_at") is None:
        left = previous.get("file_path")
        if left and left != track["file_path"] and Path(left).exists():
            _send_to_own_paths(left)
        # A live track downloaded again can land in another album than the one
        # its row named, when the album's title is read differently today.
        if previous.get("album_id") not in (None, album_id):
            db.retire_album_if_empty(previous["album_id"])
    report(1.0)
    return track
