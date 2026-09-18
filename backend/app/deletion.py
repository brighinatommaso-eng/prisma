"""Deleting a track: the catalogue row, its audio file, and an emptied album.

Order: database first, files second. The soft delete (and the album's, when
this was its last live track) commits in one transaction before anything on
disk is touched. A failure halfway therefore leaves at worst a file with no
live row -- invisible to clients, who already see the deletion in the delta --
and never a live row pointing at a missing file. The reverse order would leave
exactly that: a track in /library whose audio answers 410.

Recovery is a retry of DELETE. An already-deleted track is not an error: the
database step re-runs as a no-op and the file cleanup runs again, so whatever a
crash left behind is removed by the next call.

The whole deletion runs under paths.library_write_lock, which the worker holds
for an entire download. Without it a delete could remove a file a download had
just written to the same path, or an album folder it had just created.

Nothing is removed with rmtree. The album folder goes only when, after the
track file is gone, it holds nothing but cover.jpg; anything else keeps both the
folder and the cover, and is reported back.
"""

import logging
from pathlib import Path
from typing import Any

from . import db
from .config import MUSIC_DIR
from .paths import COVER_FILENAME, library_write_lock

log = logging.getLogger("prisma.deletion")

# How long a delete waits for a running download to finish before giving up
# with a busy answer. Short: it blocks a request thread.
LIBRARY_LOCK_TIMEOUT_S = 5.0


class DownloadInProgress(Exception):
    """A queued or running job for the same track would write it back."""

    def __init__(self, job_id: int) -> None:
        super().__init__(f"job {job_id} is downloading this track")
        self.job_id = job_id


class LibraryBusy(Exception):
    """A download is writing to the library; nothing was deleted."""


def _music_root() -> Path:
    return MUSIC_DIR.resolve()


def _is_library_path(path: Path, depth: int) -> bool:
    """True when path sits exactly `depth` segments below the music root.

    The on-disk layout is Artist/Album/Title.m4a, so a track file is depth 3 and
    an album folder depth 2. Dotted segments are Prisma's own state (.prisma)
    and are never library content; sanitise_segment cannot produce them.
    """
    try:
        relative = path.resolve().relative_to(_music_root())
    except ValueError:
        return False
    return len(relative.parts) == depth and not any(
        part.startswith(".") for part in relative.parts
    )


def _remove_file(path: Path) -> int:
    """Unlink a regular file. Returns the bytes freed; 0 when already gone."""
    try:
        size = path.stat().st_size
        path.unlink()
    except FileNotFoundError:
        return 0
    return size


def delete_track(video_id: str) -> dict[str, Any] | None:
    """Delete a track. Returns what was removed, or None for an unknown id.

    Raises DownloadInProgress when a job for the track is queued or running,
    LibraryBusy when another download holds the library for longer than
    LIBRARY_LOCK_TIMEOUT_S, and OSError when a file exists but cannot be
    removed -- in every case a later retry is the way forward.
    """
    if db.get_track(video_id) is None:
        return None
    if not library_write_lock.acquire(timeout=LIBRARY_LOCK_TIMEOUT_S):
        raise LibraryBusy()
    try:
        return _delete_locked(video_id)
    finally:
        library_write_lock.release()


def _delete_locked(video_id: str) -> dict[str, Any] | None:
    state = db.mark_track_deleted(video_id)
    if state is None:
        return None
    if state["active_job_id"] is not None:
        raise DownloadInProgress(state["active_job_id"])

    bytes_freed = 0
    audio_path = Path(state["file_path"]) if state["file_path"] else None
    if audio_path is not None and not state["file_in_use"]:
        if _is_library_path(audio_path, 3) and not audio_path.is_dir():
            bytes_freed += _remove_file(audio_path)
        elif audio_path.exists():
            log.warning("track %s: not removing %s, it is outside the library layout",
                        video_id, audio_path)

    folder_removed = False
    unexpected: list[str] = []
    if state["album_deleted"] and audio_path is not None:
        album_dir = audio_path.parent
        cover = album_dir / COVER_FILENAME
        if not _is_library_path(album_dir, 2):
            log.warning("track %s: not removing album folder %s, it is outside the "
                        "library layout", video_id, album_dir)
        elif not album_dir.exists():
            folder_removed = True
        else:
            cover_shared = state["cover_in_use"]
            unexpected = sorted(
                entry.name for entry in album_dir.iterdir()
                if entry.name != COVER_FILENAME or entry.is_dir() or cover_shared
            )
            if unexpected:
                log.warning("track %s: album folder %s kept, it holds unexpected "
                            "entries: %s", video_id, album_dir, unexpected)
            else:
                bytes_freed += _remove_file(cover)
                if state["cover_path"] == str(cover):
                    db.clear_album_cover(state["album_id"], str(cover))
                try:
                    # rmdir, not rmtree: if anything outside Prisma (the share is
                    # also browsed by hand) put a file here since the listing
                    # above, this fails and the file survives.
                    album_dir.rmdir()
                    folder_removed = True
                except FileNotFoundError:
                    folder_removed = True
                except OSError:
                    unexpected = sorted(entry.name for entry in album_dir.iterdir())
                    log.warning("track %s: album folder %s changed during deletion "
                                "and was kept: %s", video_id, album_dir, unexpected)

    log.info("track %s deleted (already_deleted=%s, bytes_freed=%s, album_removed=%s, "
             "album_folder_removed=%s)", video_id, state["already_deleted"], bytes_freed,
             state["album_deleted"], folder_removed)
    return {
        "track_id": video_id,
        "status": "already_deleted" if state["already_deleted"] else "deleted",
        "bytes_freed": bytes_freed,
        "album_id": state["album_id"],
        "album_removed": state["album_deleted"],
        "album_folder_removed": folder_removed,
        "unexpected_files": unexpected,
    }
