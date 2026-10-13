"""Whether the files the catalogue lists are really there, and really those files.

The catalogue and the library are two things that can disagree. A file can be
removed from the share by hand, and the row then promises audio that
GET /tracks/{id}/file can only answer 410 for; and a file can stop being the
audio its row recorded, which is what a second download tagged into the same
path does to the first one's hash.

classify() sorts every live track into one of four states, and it is the one
place that decides them: /health counts with it and the repair queues with it,
so the two cannot disagree about what is broken.

Repairing is downloading again, and it is only ever asked for: POST /repair,
or POST /downloads for one track. Nothing here runs at start, on a timer or
from /health. A repair is an ordinary job in the jobs table, so the single
worker, the gap between downloads, the bot-wall cooldown and the absence of
any retry apply to it exactly as to any other download, with no special case.
The pipeline restores a deleted track, so a job is only created for a track
that is still live at that moment.

Nothing in this module deletes, moves or overwrites a file. A file that is not
the audio its row recorded is left where it is; paths.track_paths gives the
track another path to be downloaded to.

Hashing is the expensive part, and the library only grows, so a file is hashed
once and then again only when its size or modification time changes. The memo
is in memory: a restart pays for one full pass.

Everything here blocks on disk or on the database; callers run it in a thread.
"""

import hashlib
import threading
from pathlib import Path
from typing import Any

from . import db

MISSING = "missing"
MISMATCH = "mismatch"
UNVERIFIED = "unverified"
OK = "ok"

# path -> (size, mtime_ns, sha256). One entry per file, replaced when the file
# changes and dropped when its track leaves the catalogue.
_memo: dict[str, tuple[int, int, str]] = {}
_memo_lock = threading.Lock()


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def forget_hashes() -> None:
    with _memo_lock:
        _memo.clear()


def _memoised_sha256(path: Path) -> str:
    """The file's SHA-256, hashed only if it changed since it was last hashed.

    Raises FileNotFoundError if the file goes away meanwhile.
    """
    key = str(path)
    before = path.stat()
    with _memo_lock:
        known = _memo.get(key)
    if known is not None and known[:2] == (before.st_size, before.st_mtime_ns):
        return known[2]
    digest = sha256_of(path)
    after = path.stat()
    # A download may be tagging this very file. A hash taken across a write is
    # reported, but not remembered as the hash of what is there now.
    if (after.st_size, after.st_mtime_ns) == (before.st_size, before.st_mtime_ns):
        with _memo_lock:
            _memo[key] = (after.st_size, after.st_mtime_ns, digest)
    return digest


def _state_of(file_path: str | None, stored_sha256: str | None) -> str:
    if not file_path:
        return MISSING
    path = Path(file_path)
    if not path.is_file():
        return MISSING
    if not stored_sha256:
        # A row from before hashes were stored. There is nothing to compare
        # the file with, so it is neither confirmed nor condemned: reported,
        # never counted as broken and never downloaded again on that ground.
        return UNVERIFIED
    try:
        actual = _memoised_sha256(path)
    except FileNotFoundError:
        return MISSING
    return OK if actual == stored_sha256 else MISMATCH


def classify() -> dict[str, list[str]]:
    """Every live track's id under "missing", "mismatch", "unverified" or "ok".

    missing: the row has no path, or no file is at it. mismatch: a file is
    there and its SHA-256 is not the stored one. unverified: a file is there
    and the row has no stored SHA-256. Deleted tracks are not looked at. Each
    list is sorted by id.

    Raises OSError if a file that is there cannot be read: an unreadable
    library is not a count of anything.
    """
    rows = db.live_track_files()
    found: dict[str, list[str]] = {MISSING: [], MISMATCH: [], UNVERIFIED: [], OK: []}
    for row in rows:
        found[_state_of(row["file_path"], row["sha256"])].append(row["id"])
    live_paths = {row["file_path"] for row in rows}
    with _memo_lock:
        for stale in [key for key in _memo if key not in live_paths]:
            del _memo[stale]
    return found


def repair(dry_run: bool = False) -> dict[str, Any]:
    """Queue a download for every live track that is missing or mismatched.

    With dry_run nothing is queued; the report is otherwise the same, down to
    which tracks would be skipped. A track that already has a queued or
    running job is skipped rather than queued a second time.
    """
    found = classify()
    queued: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []
    for video_id in sorted(found[MISSING] + found[MISMATCH]):
        if dry_run:
            job = db.active_job(video_id)
            outcome = "job_active" if job else "queued"
            job_id, job_state = (job["id"], job["state"]) if job else (None, None)
        else:
            outcome, job_id, job_state = db.queue_repair_job(video_id)
        if outcome == "job_active":
            skipped.append({"video_id": video_id, "reason": outcome,
                            "job_id": job_id, "job_state": job_state})
        elif outcome == "deleted":
            skipped.append({"video_id": video_id, "reason": outcome})
        elif not dry_run:
            queued.append({"video_id": video_id, "job_id": job_id})
    return {
        "dry_run": dry_run,
        "checked": sum(len(ids) for ids in found.values()),
        MISSING: found[MISSING],
        MISMATCH: found[MISMATCH],
        UNVERIFIED: found[UNVERIFIED],
        "queued": queued,
        "skipped": skipped,
    }


def request_download(video_id: str) -> tuple[int, dict[str, Any]]:
    """What POST /downloads answers, as (status code, body).

    A live track whose file is there is answered as-is and nothing is queued.
    A live track whose file is gone counts as absent and is queued -- unless a
    job for it is already queued or running, in which case that job is the
    answer. Only the cheap question is asked here, whether the file exists;
    whether it is the right file is POST /repair's.
    """
    existing = db.get_track(video_id)
    if existing is not None and existing.get("deleted_at") is None:
        file_path = existing.get("file_path")
        if file_path and Path(file_path).is_file():
            return 200, {"status": "exists", "track": existing}
        job_id, job_state = db.queue_job_once(video_id)
        return 202, {"status": job_state, "job_id": job_id, "video_id": video_id}

    job_id = db.create_job(video_id)
    return 202, {"status": db.QUEUED, "job_id": job_id, "video_id": video_id}
