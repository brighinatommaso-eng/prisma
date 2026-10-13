#!/usr/bin/env python3
"""Tests for finding and re-downloading tracks whose file is gone or wrong.

Runs with no network, against a throwaway music directory and database, never
the real library:

    python scripts/test_repair.py

Covers the classifier, POST /repair, the self-repair in POST /downloads and
the missing_files field of /health. The endpoints are called as the functions
they are, with no HTTP client. Where a download has to happen, the real worker
step and the real pipeline run it, with only the network parts replaced -- the
metadata lookup, the audio download, the artwork fetch and the tag writer.
Plain asserts in test_* functions, like the other scripts.
"""

import asyncio
import hashlib
import logging
import os
import shutil
import sys
import time
from pathlib import Path

import guard

# Must happen before anything under app/ is imported: config reads the
# environment once, at import time.
_SCRATCH = guard.scratch_music_dir("prisma-test-repair-")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import stubs  # noqa: E402

stubs.install_missing()

from fastapi import HTTPException, Response  # noqa: E402

from app import db, deletion, diagnostics, downloader, integrity, metadata, tagging, worker  # noqa: E402
from app import main as api  # noqa: E402
from app.config import MUSIC_DIR  # noqa: E402
from app.paths import COVER_FILENAME  # noqa: E402

# Refuse to run against anything but the scratch directory.
guard.assert_scratch(_SCRATCH)

# Failed jobs and failed probes are the point of some tests here, not news.
logging.getLogger("prisma.worker").setLevel(logging.CRITICAL)
logging.getLogger("prisma.diagnostics").setLevel(logging.CRITICAL)
logging.getLogger("prisma.api").setLevel(logging.CRITICAL)

ARTIST, ALBUM = "Kid Yugi", "The Globe"
COVER = b"\xff\xd8\xff cover bytes"

_fail_download: set[str] = set()
_pipeline_runs: list[str] = []
_hashed: list[str] = []
_health_seconds = 0.0


def _fake_metadata(video_id):
    track = db.get_track(video_id)
    return {
        "video_id": video_id, "title": track["title"] if track else video_id,
        "artist": ARTIST, "album": ALBUM, "album_raw": ALBUM,
        "album_release_title": ALBUM, "album_browse_id": None, "year": 2022,
        "track_no": None, "duration_s": 180,
        "artwork_url": "https://example.test/cover.jpg",
    }


def _fake_download(video_id, audio_path, on_progress):
    """Stands in for yt-dlp, which leaves a file already at the target alone."""
    _pipeline_runs.append(video_id)
    if video_id in _fail_download:
        raise RuntimeError("ERROR: [youtube] " + video_id + ": Video unavailable")
    if not audio_path.exists():
        audio_path.write_bytes(b"audio:" + video_id.encode())
    return audio_path


def _fake_write_tags(path, meta, cover_bytes):
    with path.open("ab") as handle:
        handle.write(b"|tags:" + meta["video_id"].encode())


metadata.fetch_track_metadata = _fake_metadata
downloader._download_audio = _fake_download
downloader._fetch_artwork = lambda url: COVER
tagging.write_tags = _fake_write_tags
downloader.palette.extract = lambda data: ["#101010"]

_real_sha256_of = integrity.sha256_of


def _counting_sha256_of(path):
    _hashed.append(Path(path).name)
    return _real_sha256_of(path)


integrity.sha256_of = _counting_sha256_of


def _reset():
    _fail_download.clear()
    _pipeline_runs.clear()
    _hashed.clear()
    integrity.forget_hashes()
    diagnostics._MISSING_CACHE.entry = None
    with db._lock:
        conn = db.connect()
        for table in ("tracks", "albums", "jobs", "worker_state"):
            conn.execute("DELETE FROM " + table)
        conn.commit()
    for entry in MUSIC_DIR.iterdir():
        if entry.name != ".prisma":
            shutil.rmtree(entry)


def _path(title):
    return MUSIC_DIR / ARTIST / ALBUM / (title + ".m4a")


def _add(video_id, state="ok", title=None, path=None):
    """A live track in one of the classifier's four states."""
    path = path or _path(title or video_id)
    content = b"audio:" + video_id.encode() + b"|tags:" + video_id.encode()
    cover = path.parent / COVER_FILENAME
    path.parent.mkdir(parents=True, exist_ok=True)
    album_id = db.upsert_album(ARTIST, ALBUM, ALBUM, None, 2022, str(cover), ["#101010"])
    db.upsert_track({
        "id": video_id, "title": title or video_id, "artist": ARTIST, "album": ALBUM,
        "album_id": album_id, "file_path": str(path), "file_bytes": len(content),
        "sha256": None if state == "unverified" else hashlib.sha256(content).hexdigest(),
    })
    if state != "missing":
        cover.write_bytes(COVER)
        path.write_bytes(b"someone else's audio" if state == "mismatch" else content)
    return path


def _jobs(*states):
    return [j for j in db.list_jobs() if not states or j["state"] in states]


def _run_queued_jobs():
    """What the worker does with each job, minus the waiting: the real claim,
    the real locked pipeline and the real bookkeeping."""
    while True:
        job = db.claim_next_queued()
        if job is None:
            return
        asyncio.run(worker._process(job, worker._run_pipeline_locked, time.time))


def _post_download(video_id):
    response = Response()
    body = asyncio.run(api.create_download(api.DownloadRequest(video_id=video_id), response))
    return response.status_code or 202, body


def _status_of(call):
    try:
        asyncio.run(call)
    except HTTPException as exc:
        return exc.status_code
    return 200


def _health():
    saved = diagnostics.ytm.reachable, diagnostics._probe
    # No YouTube and no yt-dlp: the other two probes are not under test.
    diagnostics.ytm.reachable = lambda: True
    diagnostics._probe = lambda: diagnostics.NOT_DETECTED
    diagnostics._YTDLP_CACHE.entry = None
    diagnostics._REACHABLE_CACHE.entry = None
    async def timed():
        # Timed inside the loop: asyncio.run() itself waits for probe threads.
        global _health_seconds
        started = time.monotonic()
        answer = await api.health()
        _health_seconds = time.monotonic() - started
        return answer

    try:
        return asyncio.run(timed()).model_dump()
    finally:
        diagnostics.ytm.reachable, diagnostics._probe = saved
        diagnostics._YTDLP_CACHE.entry = None
        diagnostics._REACHABLE_CACHE.entry = None


def _expire_missing_cache():
    stamp, value = diagnostics._MISSING_CACHE.entry
    diagnostics._MISSING_CACHE.entry = (
        stamp - diagnostics.MISSING_FILES_CACHE_TTL_S - 1, value)


# --- the classifier -------------------------------------------------------

def test_classifier_tells_missing_mismatch_ok_and_unverified_apart():
    _reset()
    _add("ok-1")
    _add("gone-1", "missing")
    _add("wrong-1", "mismatch")
    _add("nosha-1", "unverified")
    _add("deleted-1", "missing")
    db.set_track_deleted("deleted-1")
    # A row that never got a path has no file either.
    db.upsert_track({"id": "nopath-1", "title": "x", "artist": ARTIST, "album": ALBUM})

    found = integrity.classify()

    assert found == {
        "missing": ["gone-1", "nopath-1"],
        "mismatch": ["wrong-1"],
        "unverified": ["nosha-1"],
        "ok": ["ok-1"],
    }, found


def test_a_file_without_a_stored_hash_is_not_hashed_at_all():
    _reset()
    _add("nosha-1", "unverified")
    integrity.classify()
    assert _hashed == [], _hashed


def test_a_file_is_hashed_once_until_it_changes():
    _reset()
    first = _add("ok-1")
    _add("ok-2")
    integrity.classify()
    assert sorted(_hashed) == ["ok-1.m4a", "ok-2.m4a"], _hashed

    _hashed.clear()
    integrity.classify()
    integrity.classify()
    assert _hashed == [], _hashed

    # Same size, later modification time: still a change.
    stat = first.stat()
    first.write_bytes(first.read_bytes()[::-1])
    os.utime(first, ns=(stat.st_atime_ns, stat.st_mtime_ns + 2_000_000_000))
    found = integrity.classify()
    assert _hashed == ["ok-1.m4a"], _hashed
    assert found["mismatch"] == ["ok-1"] and found["ok"] == ["ok-2"], found


def test_the_memo_forgets_tracks_that_left_the_catalogue():
    _reset()
    _add("ok-1")
    _add("ok-2")
    integrity.classify()
    assert len(integrity._memo) == 2
    db.set_track_deleted("ok-2")
    integrity.classify()
    assert list(integrity._memo) == [str(_path("ok-1"))], list(integrity._memo)


# --- POST /repair ---------------------------------------------------------

def test_dry_run_reports_and_queues_nothing():
    _reset()
    _add("ok-1")
    _add("gone-1", "missing")
    _add("wrong-1", "mismatch")
    _add("nosha-1", "unverified")

    report = asyncio.run(api.repair_library(dry_run=True))

    assert report == {
        "dry_run": True,
        "checked": 4,
        "missing": ["gone-1"],
        "mismatch": ["wrong-1"],
        "unverified": ["nosha-1"],
        "queued": [],
        "skipped": [],
    }, report
    assert _jobs() == []


def test_repair_queues_one_job_for_each_broken_track_and_no_other():
    _reset()
    _add("ok-1")
    _add("gone-1", "missing")
    _add("gone-2", "missing")
    _add("wrong-1", "mismatch")
    _add("nosha-1", "unverified")

    report = asyncio.run(api.repair_library(dry_run=False))

    assert report["dry_run"] is False and report["checked"] == 5
    assert report["missing"] == ["gone-1", "gone-2"] and report["mismatch"] == ["wrong-1"]
    assert report["unverified"] == ["nosha-1"] and report["skipped"] == []
    assert [q["video_id"] for q in report["queued"]] == ["gone-1", "gone-2", "wrong-1"]
    jobs = {j["id"]: j for j in _jobs()}
    assert sorted(jobs) == sorted(q["job_id"] for q in report["queued"])
    assert all(j["state"] == db.QUEUED for j in jobs.values()), jobs
    assert {j["track_id"] for j in jobs.values()} == {"gone-1", "gone-2", "wrong-1"}


def test_repair_twice_queues_nothing_twice():
    _reset()
    _add("gone-1", "missing")
    _add("wrong-1", "mismatch")
    first = asyncio.run(api.repair_library(dry_run=False))

    second = asyncio.run(api.repair_library(dry_run=False))
    dry = asyncio.run(api.repair_library(dry_run=True))

    assert second["queued"] == [] and dry["queued"] == []
    expected = [
        {"video_id": q["video_id"], "reason": "job_active", "job_id": q["job_id"],
         "job_state": db.QUEUED}
        for q in first["queued"]
    ]
    assert second["skipped"] == expected and dry["skipped"] == expected, second
    assert len(_jobs()) == 2


def test_repair_skips_a_track_whose_job_is_already_running():
    _reset()
    _add("gone-1", "missing")
    job_id = db.create_job("gone-1")
    assert db.claim_next_queued()["id"] == job_id

    report = asyncio.run(api.repair_library(dry_run=False))

    assert report["queued"] == []
    assert report["skipped"] == [{"video_id": "gone-1", "reason": "job_active",
                                  "job_id": job_id, "job_state": db.RUNNING}]
    assert len(_jobs()) == 1


def test_a_finished_job_does_not_stop_a_later_repair():
    _reset()
    _add("gone-1", "missing")
    _fail_download.add("gone-1")
    asyncio.run(api.repair_library(dry_run=False))
    _run_queued_jobs()
    assert [j["state"] for j in _jobs()] == [db.FAILED]

    # Asking again is the only way it is ever tried again.
    again = asyncio.run(api.repair_library(dry_run=False))

    assert [q["video_id"] for q in again["queued"]] == ["gone-1"]
    assert sorted(j["state"] for j in _jobs()) == [db.FAILED, db.QUEUED]


def test_repair_ignores_soft_deleted_tracks():
    _reset()
    _add("gone-1", "missing")
    _add("deleted-1", "missing")
    _add("deleted-2", "mismatch")
    db.set_track_deleted("deleted-1")
    db.set_track_deleted("deleted-2")

    report = asyncio.run(api.repair_library(dry_run=False))

    assert report["checked"] == 1 and report["missing"] == ["gone-1"]
    assert [q["video_id"] for q in report["queued"]] == ["gone-1"]
    assert db.get_track("deleted-1")["deleted_at"] is not None


def test_a_track_deleted_after_the_scan_is_not_queued_back_to_life():
    """The pipeline restores a deleted row, so a repair job for one would
    undo the deletion."""
    _reset()
    _add("gone-1", "missing")
    db.set_track_deleted("gone-1")

    assert db.queue_repair_job("gone-1") == ("deleted", None, None)
    assert _jobs() == []

    saved = integrity.classify
    integrity.classify = lambda: {"missing": ["gone-1"], "mismatch": [],
                                  "unverified": [], "ok": []}
    try:
        report = integrity.repair(dry_run=False)
    finally:
        integrity.classify = saved
    assert report["queued"] == []
    assert report["skipped"] == [{"video_id": "gone-1", "reason": "deleted"}], report
    assert _jobs() == []


def test_a_queued_repair_blocks_deleting_the_track():
    _reset()
    _add("gone-1", "missing")
    report = asyncio.run(api.repair_library(dry_run=False))
    try:
        deletion.delete_track("gone-1")
    except deletion.DownloadInProgress as exc:
        assert exc.job_id == report["queued"][0]["job_id"]
    else:
        raise AssertionError("a track with a queued repair was deleted")


def test_repair_still_queues_during_a_cooldown():
    _reset()
    _add("gone-1", "missing")
    db.set_download_cooldown_until(int(time.time()) + 600)

    report = asyncio.run(api.repair_library(dry_run=False))

    assert len(report["queued"]) == 1
    assert [j["state"] for j in _jobs()] == [db.QUEUED]


def test_repair_jobs_restore_the_files_and_the_catalogue_follows():
    _reset()
    kept = _add("ok-1")
    held = kept.read_bytes()
    _add("gone-1", "missing")
    wrong = _add("wrong-1", "mismatch")
    foreign = wrong.read_bytes()
    before = {v: db.get_track(v) for v in ("ok-1", "gone-1", "wrong-1")}
    since = int(time.time()) - 1
    with db._lock:
        conn = db.connect()
        conn.execute("UPDATE tracks SET updated_at = ?", (since - 100,))
        conn.execute("UPDATE albums SET updated_at = ?", (since - 100,))
        conn.commit()

    asyncio.run(api.repair_library(dry_run=False))
    _run_queued_jobs()

    assert sorted(_pipeline_runs) == ["gone-1", "wrong-1"], _pipeline_runs
    assert [j["state"] for j in _jobs()] == [db.DONE, db.DONE]
    assert integrity.classify() == {"missing": [], "mismatch": [], "unverified": [],
                                    "ok": ["gone-1", "ok-1", "wrong-1"]}
    # The good track and the wrong file were both left exactly as they were.
    assert kept.read_bytes() == held and db.get_track("ok-1")["sha256"] == before["ok-1"]["sha256"]
    assert wrong.read_bytes() == foreign
    assert db.get_track("wrong-1")["file_path"] == str(_path("wrong-1 [wrong-1]"))
    assert db.get_track("gone-1")["file_path"] == before["gone-1"]["file_path"]
    for video_id in ("gone-1", "wrong-1"):
        row = db.get_track(video_id)
        assert row["deleted_at"] is None and row["album_id"] == before[video_id]["album_id"]
        assert row["sha256"] == _real_sha256_of(Path(row["file_path"]))
        assert row["file_bytes"] == Path(row["file_path"]).stat().st_size
    with db._lock:
        counts = db.connect().execute(
            "SELECT (SELECT COUNT(*) FROM tracks) t, (SELECT COUNT(*) FROM albums) a"
        ).fetchone()
    assert (counts["t"], counts["a"]) == (3, 1), tuple(counts)
    # The phone's delta carries the album with the repaired tracks' new hashes.
    delta = db.library(since)
    assert len(delta["albums"]) == 1 and delta["deleted_track_ids"] == []
    shas = {t["id"]: t["sha256"] for t in delta["albums"][0]["tracks"]}
    assert shas == {v: db.get_track(v)["sha256"] for v in ("ok-1", "gone-1", "wrong-1")}


def test_a_failed_repair_job_is_not_retried_and_the_track_stays_reported():
    _reset()
    _add("gone-1", "missing")
    wrong = _add("wrong-1", "mismatch")
    foreign = wrong.read_bytes()
    before = db.get_track("wrong-1")
    _fail_download.update({"gone-1", "wrong-1"})

    asyncio.run(api.repair_library(dry_run=False))
    _run_queued_jobs()
    _run_queued_jobs()

    assert sorted(_pipeline_runs) == ["gone-1", "wrong-1"], _pipeline_runs
    assert [j["state"] for j in _jobs()] == [db.FAILED, db.FAILED]
    assert db.get_track("wrong-1") == before
    assert wrong.read_bytes() == foreign
    report = asyncio.run(api.repair_library(dry_run=True))
    assert report["missing"] == ["gone-1"] and report["mismatch"] == ["wrong-1"]


# --- POST /downloads ------------------------------------------------------

def test_download_of_a_track_whose_file_is_there_still_answers_exists():
    _reset()
    _add("ok-1")
    status, body = _post_download("ok-1")
    assert status == 200 and body["status"] == "exists", (status, body)
    assert body["track"]["id"] == "ok-1"
    assert _jobs() == []


def test_download_does_not_hash_so_a_wrong_file_still_answers_exists():
    _reset()
    _add("wrong-1", "mismatch")
    status, body = _post_download("wrong-1")
    assert status == 200 and body["status"] == "exists", (status, body)
    assert _hashed == [] and _jobs() == []


def test_download_of_a_live_track_with_no_file_queues_it():
    _reset()
    _add("gone-1", "missing")

    status, body = _post_download("gone-1")

    assert status == 202, status
    assert body == {"status": db.QUEUED, "job_id": _jobs()[0]["id"], "video_id": "gone-1"}, body
    assert [(j["track_id"], j["state"]) for j in _jobs()] == [("gone-1", db.QUEUED)]


def test_download_of_a_track_already_being_repaired_returns_that_job():
    _reset()
    _add("gone-1", "missing")
    _, first = _post_download("gone-1")

    status, again = _post_download("gone-1")
    assert status == 202 and again == first, (status, again)
    assert len(_jobs()) == 1

    assert db.claim_next_queued()["id"] == first["job_id"]
    status, running = _post_download("gone-1")
    assert status == 202, status
    assert running == {"status": db.RUNNING, "job_id": first["job_id"], "video_id": "gone-1"}
    assert len(_jobs()) == 1


def test_file_and_cover_answer_410_until_the_job_has_run():
    _reset()
    _add("gone-1", "missing")
    album_id = db.get_track("gone-1")["album_id"]
    request = type("Request", (), {"headers": {}})()

    _post_download("gone-1")
    assert _status_of(api.track_file("gone-1")) == 410
    assert _status_of(api.album_cover(album_id, request)) == 410

    _run_queued_jobs()

    assert _status_of(api.track_file("gone-1")) == 200
    assert _status_of(api.album_cover(album_id, request)) == 200
    status, body = _post_download("gone-1")
    assert status == 200 and body["status"] == "exists", (status, body)
    assert len(_jobs()) == 1


def test_download_of_an_unknown_or_deleted_track_queues_as_before():
    _reset()
    _add("deleted-1")
    deletion.delete_track("deleted-1")

    for video_id in ("never-seen-1", "deleted-1"):
        status, body = _post_download(video_id)
        assert status == 202 and body["status"] == db.QUEUED, (video_id, status, body)
        assert body["video_id"] == video_id
    assert sorted(j["track_id"] for j in _jobs()) == ["deleted-1", "never-seen-1"]


# --- /health: missing_files -----------------------------------------------

def test_health_counts_missing_and_mismatched_files():
    _reset()
    _add("ok-1")
    _add("nosha-1", "unverified")
    assert _health()["missing_files"] == 0

    _reset()
    _add("ok-1")
    _add("gone-1", "missing")
    _add("gone-2", "missing")
    _add("wrong-1", "mismatch")
    _add("nosha-1", "unverified")
    payload = _health()
    assert payload["missing_files"] == 3, payload
    assert payload["track_count"] == 5


def test_missing_files_is_cached_for_a_minute():
    _reset()
    _add("ok-1")
    _add("gone-1", "missing")
    scans = []
    saved = integrity.classify

    def counting_classify():
        scans.append(1)
        return saved()

    integrity.classify = counting_classify
    try:
        assert [_health()["missing_files"] for _ in range(5)] == [1] * 5
        assert len(scans) == 1 and _hashed == ["ok-1.m4a"], (scans, _hashed)

        # Within the minute the answer is the cached one, even though it is stale.
        _path("gone-1").write_bytes(b"audio:gone-1|tags:gone-1")
        assert diagnostics.missing_files() == 1
        assert len(scans) == 1

        _expire_missing_cache()
        assert diagnostics.missing_files() == 0
        assert len(scans) == 2
    finally:
        integrity.classify = saved


def test_after_the_cache_expires_only_a_changed_file_is_hashed_again():
    _reset()
    first = _add("ok-1")
    _add("ok-2")
    _add("ok-3")
    assert diagnostics.missing_files() == 0
    assert sorted(_hashed) == ["ok-1.m4a", "ok-2.m4a", "ok-3.m4a"]

    _hashed.clear()
    first.write_bytes(b"no longer the recorded audio")
    _expire_missing_cache()

    assert diagnostics.missing_files() == 1
    assert _hashed == ["ok-1.m4a"], _hashed


def test_missing_files_is_null_not_zero_when_the_scan_fails():
    _reset()
    _add("gone-1", "missing")
    saved = integrity.classify

    def broken():
        raise OSError("the share went away")

    integrity.classify = broken
    try:
        assert diagnostics.missing_files() is None
        payload = _health()
    finally:
        integrity.classify = saved
    assert payload["missing_files"] is None, payload
    assert "missing_files" in payload and payload["track_count"] == 1


def test_missing_files_is_null_when_the_scan_outlasts_the_probe_timeout():
    _reset()
    _add("gone-1", "missing")
    saved_classify, saved_timeout = integrity.classify, api.HEALTH_PROBE_TIMEOUT_S

    def slow():
        time.sleep(0.3)
        return saved_classify()

    integrity.classify = slow
    api.HEALTH_PROBE_TIMEOUT_S = 0.05
    try:
        payload = _health()
    finally:
        integrity.classify = saved_classify
        api.HEALTH_PROBE_TIMEOUT_S = saved_timeout
    assert payload["missing_files"] is None, payload
    assert _health_seconds < 0.25, _health_seconds

    # The scan carried on in its thread and its answer is there for the next poll.
    deadline = time.monotonic() + 5
    while diagnostics._MISSING_CACHE.entry is None and time.monotonic() < deadline:
        time.sleep(0.02)
    assert diagnostics.missing_files() == 1


def test_a_scan_still_running_reports_the_last_count_or_null():
    _reset()
    saved_wait = diagnostics.LOCK_WAIT_S
    diagnostics.LOCK_WAIT_S = 0.05
    # Stands in for a scan that is still hashing while holding the lock.
    diagnostics._MISSING_CACHE.lock.acquire()
    try:
        diagnostics._MISSING_CACHE.entry = None
        assert diagnostics.missing_files() is None
        diagnostics._MISSING_CACHE.entry = (0.0, 7)
        assert diagnostics.missing_files() == 7
    finally:
        diagnostics._MISSING_CACHE.lock.release()
        diagnostics.LOCK_WAIT_S = saved_wait
        diagnostics._MISSING_CACHE.entry = None


def test_health_never_queues_a_repair():
    _reset()
    _add("gone-1", "missing")
    _add("wrong-1", "mismatch")
    for _ in range(3):
        _health()
        _expire_missing_cache()
    assert _jobs() == [] and _pipeline_runs == []


def main() -> int:
    MUSIC_DIR.mkdir(parents=True, exist_ok=True)
    db.connect()
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
