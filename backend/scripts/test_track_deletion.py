#!/usr/bin/env python3
"""Tests for track deletion, re-adding a deleted track, and the recent-jobs window.

Runs with no dependencies, against a throwaway music directory and database,
never the real library:

    python scripts/test_track_deletion.py
    docker compose exec -T backend python scripts/test_track_deletion.py

Written as plain asserts in test_* functions, like test_album_normalisation.py.
"""

import os
import shutil
import sys
import tempfile
import threading
from pathlib import Path

# Must happen before anything under app/ is imported: config reads the
# environment once, at import time.
_SCRATCH = Path(tempfile.mkdtemp(prefix="prisma-test-deletion-"))
os.environ["PRISMA_MUSIC_DIR"] = str(_SCRATCH / "music")
os.environ["PRISMA_STATE_DIR"] = str(_SCRATCH / "music" / ".prisma")
os.environ["PRISMA_DB_PATH"] = str(_SCRATCH / "music" / ".prisma" / "catalog.db")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import db, deletion  # noqa: E402
from app.config import MUSIC_DIR  # noqa: E402
from app.paths import library_write_lock, make_dir_owned, track_paths  # noqa: E402

# Refuse to run against anything but the scratch directory.
assert MUSIC_DIR.is_relative_to(_SCRATCH), MUSIC_DIR

AUDIO = b"a" * 1000
COVER = b"c" * 70


def _add_track(video_id, artist, album, title, cover=True):
    audio_path, cover_path = track_paths(artist, album, title, video_id)
    make_dir_owned(audio_path.parent)
    audio_path.write_bytes(AUDIO)
    if cover and not cover_path.exists():
        cover_path.write_bytes(COVER)
    album_id = db.upsert_album(artist, album, None, None, 2001,
                               str(cover_path) if cover else None, ["#000000"])
    db.upsert_track({
        "id": video_id, "title": title, "artist": artist, "album": album,
        "album_id": album_id, "file_path": str(audio_path),
        "file_bytes": len(AUDIO), "sha256": "0" * 64,
    })
    return audio_path, cover_path, album_id


def _live_track_ids():
    return {t["id"] for a in db.library()["albums"] for t in a["tracks"]}


def test_unknown_track_is_none():
    assert deletion.delete_track("never-existed") is None


def test_delete_one_of_two_keeps_album():
    a_path, cover, album_id = _add_track("keep1", "Artist K", "Album K", "One")
    b_path, _, _ = _add_track("keep2", "Artist K", "Album K", "Two")

    result = deletion.delete_track("keep1")

    assert result["status"] == "deleted", result
    assert result["bytes_freed"] == len(AUDIO), result
    assert result["album_removed"] is False, result
    assert not a_path.exists()
    assert b_path.exists() and cover.exists()
    assert "keep1" not in _live_track_ids()
    assert "keep2" in _live_track_ids()
    assert db.get_album(album_id)["deleted_at"] is None


def test_delete_last_track_removes_album_folder_and_cover():
    audio, cover, album_id = _add_track("last1", "Artist L", "Album L", "Only")
    album_dir = audio.parent

    result = deletion.delete_track("last1")

    assert result["status"] == "deleted", result
    assert result["album_id"] == album_id
    assert result["album_removed"] is True, result
    assert result["album_folder_removed"] is True, result
    assert result["unexpected_files"] == [], result
    assert result["bytes_freed"] == len(AUDIO) + len(COVER), result
    assert not album_dir.exists()
    # Only the album's own folder goes; the artist folder is left alone.
    assert album_dir.parent.exists()
    album = db.get_album(album_id)
    assert album["deleted_at"] is not None
    # No dangling reference to the removed cover.
    assert album["cover_path"] is None
    assert album_id not in {a["id"] for a in db.library()["albums"]}


def test_deletion_appears_in_delta():
    since = db._now() - 1
    _, _, album_id = _add_track("delta1", "Artist D", "Album D", "Only")

    deletion.delete_track("delta1")

    delta = db.library(since)
    assert "delta1" in delta["deleted_track_ids"], delta
    assert album_id in delta["deleted_album_ids"], delta


def test_delete_twice_is_idempotent():
    _add_track("twice1", "Artist T", "Album T", "Only")

    first = deletion.delete_track("twice1")
    second = deletion.delete_track("twice1")

    assert first["status"] == "deleted"
    assert second["status"] == "already_deleted", second
    assert second["bytes_freed"] == 0, second
    assert second["album_removed"] is True, second
    assert second["album_folder_removed"] is True, second


def test_retry_after_crash_removes_leftover_files():
    # Simulates a crash after the database step committed but before any file
    # was removed: the retry must finish the job.
    audio, cover, album_id = _add_track("crash1", "Artist C", "Album C", "Only")
    db.mark_track_deleted("crash1")
    assert audio.exists() and cover.exists()

    result = deletion.delete_track("crash1")

    assert result["status"] == "already_deleted", result
    assert result["bytes_freed"] == len(AUDIO) + len(COVER), result
    assert not audio.parent.exists()
    assert db.get_album(album_id)["deleted_at"] is not None


def test_unexpected_file_keeps_album_folder():
    audio, cover, album_id = _add_track("odd1", "Artist O", "Album O", "Only")
    stray = audio.parent / "notes.txt"
    stray.write_text("not Prisma's")

    result = deletion.delete_track("odd1")

    assert result["album_removed"] is True, result
    assert result["album_folder_removed"] is False, result
    assert result["unexpected_files"] == ["notes.txt"], result
    assert not audio.exists()
    assert stray.exists() and cover.exists()
    assert db.get_album(album_id)["cover_path"] == str(cover)


def test_active_job_blocks_deletion():
    audio, _, _ = _add_track("busy1", "Artist B", "Album B", "Only")
    job_id = db.create_job("busy1")

    try:
        deletion.delete_track("busy1")
    except deletion.DownloadInProgress as exc:
        assert exc.job_id == job_id
    else:
        raise AssertionError("deletion went ahead with a queued job for the track")
    assert audio.exists()
    assert "busy1" in _live_track_ids()

    db.cancel_queued_job(job_id)
    assert deletion.delete_track("busy1")["status"] == "deleted"


def test_file_reused_by_live_track_is_not_removed():
    audio, _, _ = _add_track("shared1", "Artist S", "Album S", "Song")
    db.mark_track_deleted("shared1")
    # A later track legitimately took over the same path.
    db.upsert_track({**db.get_track("shared1"), "id": "shared2", "palette": None},
                    restore=True)

    deletion.delete_track("shared1")

    assert audio.exists()
    assert "shared2" in _live_track_ids()


def test_file_outside_music_dir_is_not_touched():
    outside = _SCRATCH / "elsewhere.m4a"
    outside.write_bytes(AUDIO)
    album_id = db.upsert_album("Artist X", "Album X", None, None, None, None, None)
    db.upsert_track({"id": "outside1", "title": "X", "artist": "Artist X",
                     "album": "Album X", "album_id": album_id,
                     "file_path": str(outside), "file_bytes": len(AUDIO)})

    result = deletion.delete_track("outside1")

    assert result["status"] == "deleted"
    assert result["bytes_freed"] == 0, result
    assert outside.exists()


def test_download_in_progress_blocks_deletion():
    # The worker holds this lock for the whole pipeline; a delete must not
    # remove a file or folder a download is writing into at that moment.
    audio, _, _ = _add_track("locked1", "Artist Q", "Album Q", "Only")
    held = threading.Event()
    release = threading.Event()

    def download():
        with library_write_lock:
            held.set()
            release.wait(5)

    worker = threading.Thread(target=download)
    worker.start()
    held.wait(5)
    previous_timeout = deletion.LIBRARY_LOCK_TIMEOUT_S
    deletion.LIBRARY_LOCK_TIMEOUT_S = 0.1
    try:
        try:
            deletion.delete_track("locked1")
        except deletion.LibraryBusy:
            pass
        else:
            raise AssertionError("deletion went ahead while a download held the library")
    finally:
        deletion.LIBRARY_LOCK_TIMEOUT_S = previous_timeout
        release.set()
        worker.join()
    assert audio.exists()
    assert "locked1" in _live_track_ids()
    assert deletion.delete_track("locked1")["status"] == "deleted"


def test_cover_used_by_live_album_in_same_folder_is_kept():
    # Two album rows can map to one folder: _album_key is not sanitised, the
    # path segments are ("AC/DC" and "AC-DC").
    audio, cover, album_id = _add_track("twin1", "AC/DC", "Twin", "Only")
    other_id = db.upsert_album("AC-DC", "Twin", None, None, None, str(cover), None)
    db.upsert_track({"id": "twin2", "title": "Gone", "artist": "AC-DC",
                     "album": "Twin", "album_id": other_id,
                     "file_path": str(audio.parent / "Gone.m4a"), "file_bytes": 1})
    with db._lock:
        conn = db.connect()
        conn.execute("UPDATE albums SET cover_path = NULL WHERE id = ?", (album_id,))
        conn.commit()

    result = deletion.delete_track("twin1")

    assert cover.exists()
    assert result["album_folder_removed"] is False, result
    assert db.get_album(other_id)["cover_path"] == str(cover)


def test_new_track_into_deleted_album_restores_it():
    _, _, album_id = _add_track("first1", "Artist N", "Album N", "First")
    deletion.delete_track("first1")
    assert db.get_album(album_id)["deleted_at"] is not None

    _add_track("second1", "Artist N", "Album N", "Second")
    db.upsert_track(db.get_track("second1"), restore=True)

    assert db.get_album(album_id)["deleted_at"] is None
    assert "second1" in _live_track_ids()
    assert "first1" not in _live_track_ids()


def test_file_under_state_dir_is_not_touched():
    state_file = MUSIC_DIR / ".prisma" / "x" / "y.m4a"
    state_file.parent.mkdir(parents=True, exist_ok=True)
    state_file.write_bytes(AUDIO)
    album_id = db.upsert_album("Artist Z", "Album Z", None, None, None, None, None)
    db.upsert_track({"id": "dotted1", "title": "y", "artist": "Artist Z",
                     "album": "Album Z", "album_id": album_id,
                     "file_path": str(state_file), "file_bytes": len(AUDIO)})

    result = deletion.delete_track("dotted1")

    assert result["bytes_freed"] == 0, result
    assert state_file.exists()
    assert state_file.parent.exists()


def test_readd_restores_track_and_album():
    audio, cover, album_id = _add_track("back1", "Artist R", "Album R", "Only")
    deletion.delete_track("back1")
    since = db._now() - 1

    # What the pipeline does when the track is downloaded again.
    audio, cover, again_id = _add_track("back1", "Artist R", "Album R", "Only")
    db.upsert_track(db.get_track("back1"), restore=True)

    assert again_id == album_id
    assert db.get_track("back1")["deleted_at"] is None
    album = db.get_album(album_id)
    assert album["deleted_at"] is None
    assert album["cover_path"] == str(cover)
    assert "back1" in _live_track_ids()
    delta = db.library(since)
    assert "back1" not in delta["deleted_track_ids"], delta
    assert album_id not in delta["deleted_album_ids"], delta
    assert album_id in {a["id"] for a in delta["albums"]}, delta


def test_plain_upsert_does_not_restore():
    # repair.py rewrites live rows with upsert_track; it must never bring a
    # track deleted in the meantime back to life.
    _add_track("stay1", "Artist Y", "Album Y", "Only")
    deletion.delete_track("stay1")

    db.upsert_track(db.get_track("stay1"))

    assert db.get_track("stay1")["deleted_at"] is not None


def test_recent_jobs_window():
    old_done = db.create_job("jobs-old-done")
    db.finish_job(old_done, db.DONE, None, 1.0)
    old_queued = db.create_job("jobs-old-queued")
    recent_failed = db.create_job("jobs-recent-failed")
    db.finish_job(recent_failed, db.FAILED, "boom", None)
    with db._lock:
        conn = db.connect()
        conn.execute("UPDATE jobs SET created_at = 1000, updated_at = 1000 "
                     "WHERE id IN (?, ?)", (old_done, old_queued))
        conn.commit()

    recent = {job["id"] for job in db.list_jobs(3600)}
    everything = {job["id"] for job in db.list_jobs()}

    assert old_done not in recent
    assert old_queued in recent
    assert recent_failed in recent
    assert {old_done, old_queued, recent_failed} <= everything


def main() -> int:
    tests = [value for name, value in sorted(globals().items())
             if name.startswith("test_") and callable(value)]
    failures = 0
    for test in tests:
        try:
            test()
        except AssertionError as exc:
            failures += 1
            print(f"FAIL  {test.__name__}: {exc}")
        except Exception as exc:
            failures += 1
            print(f"ERROR {test.__name__}: {type(exc).__name__}: {exc}")
        else:
            print(f"ok    {test.__name__}")
    print(f"\n{len(tests) - failures}/{len(tests)} passed")
    shutil.rmtree(_SCRATCH, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
