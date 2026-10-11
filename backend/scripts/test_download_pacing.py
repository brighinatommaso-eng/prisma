#!/usr/bin/env python3
"""Tests for the download worker's pacing and its bot-wall cooldown.

Runs with no dependencies, no network and no real waiting, against a throwaway
database, never the real library:

    python scripts/test_download_pacing.py
    docker compose exec -T backend python scripts/test_download_pacing.py

The worker loop itself is run, with its clock, its sleep and its pipeline
replaced: time only moves when the worker sleeps or a fake download "runs", so
thirty minutes of cooldown take milliseconds and every timing is exact. Plain
asserts in test_* functions, like the other scripts.
"""

import asyncio
import logging
import os
import shutil
import sys
import tempfile
from pathlib import Path

# Must happen before anything under app/ is imported: config reads the
# environment once, at import time.
_SCRATCH = Path(tempfile.mkdtemp(prefix="prisma-test-pacing-"))
os.environ["PRISMA_MUSIC_DIR"] = str(_SCRATCH / "music")
os.environ["PRISMA_STATE_DIR"] = str(_SCRATCH / "music" / ".prisma")
os.environ["PRISMA_DB_PATH"] = str(_SCRATCH / "music" / ".prisma" / "catalog.db")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import db, worker  # noqa: E402
from app.config import MUSIC_DIR  # noqa: E402

# Refuse to run against anything but the scratch directory.
assert MUSIC_DIR.is_relative_to(_SCRATCH), MUSIC_DIR

# The worker narrates every failure and cooldown; here those are the point of
# the tests, not news.
logging.getLogger("prisma.worker").setLevel(logging.CRITICAL)

T0 = 1_800_000_000.0
DOWNLOAD_SECONDS = 7.0

# Verbatim from the server log, curly apostrophe (U+2019) included.
REAL_BOT_WALL = ("ERROR: [youtube] dQw4w9WgXcQ: Sign in to confirm you’re not a bot. "
                 "Use --cookies-from-browser or --cookies for the authentication.")
UNAVAILABLE = "ERROR: [youtube] xxxxxxxxxxx: Video unavailable"


class _Stop(BaseException):
    """Ends a worker run from inside its sleep. Not an Exception, so the
    worker's own error handling cannot swallow it."""


class Harness:
    """A clock, a sleep and a pipeline for worker.run()."""

    def __init__(self, failures=None, until=None, deadline=T0 + 6 * 3600):
        self.now = T0
        self.failures = failures or {}
        self.until = until or (lambda: False)
        self.deadline = deadline
        self.starts: list[tuple[str, float]] = []
        self.ends: list[float] = []
        self.sleeps: list[float] = []
        self.events: list[tuple[float, object]] = []
        self.states_while_waiting: set[str] = set()

    def clock(self) -> float:
        return self.now

    def at(self, when: float, action) -> None:
        self.events.append((when, action))

    async def sleep(self, seconds: float) -> None:
        assert seconds > 0, seconds
        self.sleeps.append(seconds)
        self.states_while_waiting |= {job["state"] for job in db.list_jobs()}
        self.now += seconds
        for event in [e for e in self.events if e[0] <= self.now]:
            self.events.remove(event)
            event[1]()
        if self.until() or self.now >= self.deadline:
            raise _Stop

    def pipeline(self, video_id: str, job_id: int) -> dict:
        assert db.get_job(job_id)["state"] == db.RUNNING
        self.starts.append((video_id, self.now))
        self.now += DOWNLOAD_SECONDS
        self.ends.append(self.now)
        if video_id in self.failures:
            raise RuntimeError(self.failures[video_id])
        return {"file_path": "/nowhere/" + video_id + ".m4a"}

    def run(self, **overrides) -> None:
        options = {"pipeline": self.pipeline, "clock": self.clock, "sleep": self.sleep}
        try:
            asyncio.run(worker.run(**{**options, **overrides}))
        except _Stop:
            return
        raise AssertionError("the worker returned on its own")

    def started(self) -> list[str]:
        return [video_id for video_id, _ in self.starts]


def _reset():
    with db._lock:
        conn = db.connect()
        conn.execute("DELETE FROM jobs")
        conn.execute("DELETE FROM worker_state")
        conn.commit()


def _states() -> dict[str, str]:
    return {job["track_id"]: job["state"] for job in db.list_jobs()}


def _none_live() -> bool:
    return not {db.QUEUED, db.RUNNING} & set(_states().values())


# --- recognising the bot wall --------------------------------------------

def test_bot_wall_real_message_with_curly_apostrophe():
    assert "’" in REAL_BOT_WALL
    assert worker.is_bot_wall(REAL_BOT_WALL)
    # As the worker stores it: the exception type in front.
    assert worker.is_bot_wall("DownloadError: " + REAL_BOT_WALL)


def test_bot_wall_whatever_the_apostrophe_or_the_casing():
    assert worker.is_bot_wall("Sign in to confirm you're not a bot")
    assert worker.is_bot_wall("Sign in to confirm you are not a bot.")
    assert worker.is_bot_wall("SIGN IN TO CONFIRM YOU’RE NOT A BOT")
    assert worker.is_bot_wall("sign in to confirm you`re Not A Bot")
    assert worker.is_bot_wall("confirm you’re not a  bot")


def test_bot_wall_http_429():
    assert worker.is_bot_wall("ERROR: [youtube] dQw4w9WgXcQ: Unable to download webpage: "
                              "HTTP Error 429: Too Many Requests (caused by <HTTPError 429>)")
    assert worker.is_bot_wall("DownloadError: ERROR: unable to download video data: "
                              "HTTP Error 429: Too Many Requests")
    assert worker.is_bot_wall("http error 429")
    assert worker.is_bot_wall("Exception: Server returned HTTP 429: Too Many Requests.")


def test_ordinary_failures_are_not_the_bot_wall():
    for text in (
        UNAVAILABLE,
        "DownloadError: ERROR: [youtube] abc: Private video. Sign in if you've been "
        "granted access to this video",
        "ERROR: unable to download video data: HTTP Error 403: Forbidden",
        "HTTP Error 404: Not Found",
        "ERROR: Did not get any data blocks; 4290000 bytes expected",
        "OSError: [Errno 28] No space left on device: '/music/Artist/1429 - Song.m4a'",
        "ERROR: [youtube] 429429429ab: Video unavailable",
        "HTTP Error 4290: nonsense",
        "interrupted by a backend restart",
        "robot rock is not about a bottle",
        "",
        None,
    ):
        assert not worker.is_bot_wall(text), text


# --- the decision, on its own --------------------------------------------

def test_wait_is_zero_with_nothing_holding_it_back():
    assert worker.seconds_until_claim(T0, None, None) == 0
    assert worker.seconds_until_claim(T0, T0 - 1, T0 - 1) == 0
    assert worker.seconds_until_claim(T0, T0, T0) == 0


def test_wait_is_the_longer_of_gap_and_cooldown():
    assert worker.seconds_until_claim(T0, T0 + 9, None) == 9
    assert worker.seconds_until_claim(T0, None, T0 + 1000) == 1000
    assert worker.seconds_until_claim(T0, T0 + 9, T0 + 1000) == 1000
    assert worker.seconds_until_claim(T0, T0 + 9, T0 + 3) == 9


def test_a_clock_set_back_cannot_stretch_the_gap():
    # The gap's end was computed before the clock moved back a day.
    wait = worker.seconds_until_claim(T0 - 86400, T0 + 9, None)
    assert wait == worker.DOWNLOAD_GAP_MAX_SECONDS, wait


def test_constants_are_what_the_readme_says():
    assert 12 <= worker.DOWNLOAD_GAP_MIN_SECONDS < worker.DOWNLOAD_GAP_MAX_SECONDS <= 20
    assert worker.BOT_WALL_COOLDOWN_SECONDS == 30 * 60
    for _ in range(200):
        assert (worker.DOWNLOAD_GAP_MIN_SECONDS <= worker._next_gap()
                <= worker.DOWNLOAD_GAP_MAX_SECONDS)


# --- pacing --------------------------------------------------------------

def test_first_job_starts_at_once_and_the_second_waits_the_gap():
    _reset()
    db.create_job("a")
    db.create_job("b")
    harness = Harness(until=_none_live)
    harness.run()

    assert harness.started() == ["a", "b"]
    assert harness.starts[0][1] == T0
    waited = harness.starts[1][1] - harness.ends[0]
    # The real, random gap: measured from the end of a to the start of b.
    assert worker.DOWNLOAD_GAP_MIN_SECONDS <= waited <= worker.DOWNLOAD_GAP_MAX_SECONDS, waited
    assert _states() == {"a": db.DONE, "b": db.DONE}
    assert db.RUNNING not in harness.states_while_waiting


def test_job_after_a_long_idle_does_not_wait():
    _reset()
    db.create_job("a")
    harness = Harness(until=lambda: len(harness.ends) == 2)
    idle = 10 * worker.DOWNLOAD_GAP_MAX_SECONDS
    harness.at(T0 + DOWNLOAD_SECONDS + idle, lambda: db.create_job("late"))
    harness.run()

    created = T0 + DOWNLOAD_SECONDS + idle
    late_start = dict(harness.starts)["late"]
    # Found on the next look at the queue, not a gap later.
    assert created <= late_start <= created + worker.IDLE_POLL_SECONDS, late_start - created


def test_job_arriving_inside_the_gap_waits_only_the_rest_of_it():
    _reset()
    db.create_job("a")
    harness = Harness(until=lambda: len(harness.ends) == 2)
    harness.at(T0 + DOWNLOAD_SECONDS + 5, lambda: db.create_job("soon"))
    harness.run(gap=lambda: 15.0)

    assert dict(harness.starts)["soon"] == harness.ends[0] + 15.0


def test_gap_follows_a_failed_attempt_too():
    _reset()
    db.create_job("broken")
    db.create_job("b")
    harness = Harness(failures={"broken": UNAVAILABLE}, until=_none_live)
    harness.run(gap=lambda: 13.0)

    assert harness.starts[1] == ("b", harness.ends[0] + 13.0)


# --- failures ------------------------------------------------------------

def test_ordinary_failure_starts_no_cooldown_and_is_not_retried():
    _reset()
    for video_id in ("a", "broken", "c"):
        db.create_job(video_id)
    harness = Harness(failures={"broken": UNAVAILABLE}, until=_none_live)
    harness.run()
    # Keep going well past the end: nothing may come back for a second try.
    harness.until = lambda: harness.now > T0 + 2 * 3600
    harness.run()

    assert harness.started() == ["a", "broken", "c"]
    assert _states() == {"a": db.DONE, "broken": db.FAILED, "c": db.DONE}
    failed = [job for job in db.list_jobs() if job["track_id"] == "broken"][0]
    assert failed["error"] == "RuntimeError: " + UNAVAILABLE
    assert db.download_cooldown_until(int(harness.ends[1])) is None
    assert max(harness.sleeps) <= worker.DOWNLOAD_GAP_MAX_SECONDS


def test_bot_wall_fails_that_job_only_and_parks_the_queue():
    _reset()
    for video_id in ("a", "walled", "c", "d"):
        db.create_job(video_id)
    seen_during_cooldown = []
    harness = Harness(failures={"walled": REAL_BOT_WALL}, until=_none_live)

    def look():
        seen_during_cooldown.append((_states(), harness.started(),
                                     db.download_cooldown_until(int(harness.now))))
    for minutes in (1, 15, 25):
        harness.at(T0 + minutes * 60 + 60, look)
    harness.run()

    wall_hit = harness.ends[1]
    cooldown_end = int(wall_hit) + worker.BOT_WALL_COOLDOWN_SECONDS
    # While it lasted: the walled job failed, the rest untouched, nothing run.
    assert len(seen_during_cooldown) == 3
    for states, started, until in seen_during_cooldown:
        assert states == {"a": db.DONE, "walled": db.FAILED,
                          "c": db.QUEUED, "d": db.QUEUED}, states
        assert started == ["a", "walled"], started
        assert until == cooldown_end, until
    # Afterwards: the queue resumed in order, at the cooldown's end, and the
    # walled job was never tried again.
    assert harness.started() == ["a", "walled", "c", "d"]
    assert harness.starts[2] == ("c", float(cooldown_end))
    assert _states() == {"a": db.DONE, "walled": db.FAILED, "c": db.DONE, "d": db.DONE}
    failed = [job for job in db.list_jobs() if job["track_id"] == "walled"][0]
    assert failed["error"] == "RuntimeError: " + REAL_BOT_WALL
    # Nothing sat in `running` while the worker waited.
    assert db.RUNNING not in harness.states_while_waiting
    assert db.download_cooldown_until(cooldown_end) is None


def test_http_429_starts_the_cooldown_as_well():
    _reset()
    db.create_job("limited")
    db.create_job("b")
    harness = Harness(failures={"limited": "HTTP Error 429: Too Many Requests"},
                      until=_none_live)
    harness.run()

    assert harness.starts[1][1] == int(harness.ends[0]) + worker.BOT_WALL_COOLDOWN_SECONDS


def test_queue_stays_usable_during_a_cooldown():
    _reset()
    db.create_job("walled")
    keep = db.create_job("keep")
    drop = db.create_job("drop")
    harness = Harness(failures={"walled": REAL_BOT_WALL}, until=_none_live)
    outcome = {}

    def use_the_queue():
        outcome["cancel"] = db.cancel_queued_job(drop)
        outcome["new"] = db.create_job("added-later")
    harness.at(T0 + 600, use_the_queue)
    harness.run()

    assert outcome["cancel"] == db.QUEUED
    assert harness.started() == ["walled", "keep", "added-later"]
    assert db.get_job(drop)["state"] == db.CANCELLED
    assert db.get_job(keep)["state"] == db.DONE
    assert db.get_job(outcome["new"])["state"] == db.DONE


def test_a_second_wall_after_the_cooldown_starts_another():
    _reset()
    for video_id in ("w1", "w2", "c"):
        db.create_job(video_id)
    harness = Harness(failures={"w1": REAL_BOT_WALL, "w2": REAL_BOT_WALL}, until=_none_live)
    harness.run()

    assert harness.started() == ["w1", "w2", "c"]
    first_end = int(harness.ends[0]) + worker.BOT_WALL_COOLDOWN_SECONDS
    assert harness.starts[1][1] == first_end
    assert harness.starts[2][1] == int(harness.ends[1]) + worker.BOT_WALL_COOLDOWN_SECONDS


# --- restarts ------------------------------------------------------------

def test_persisted_cooldown_is_honoured_by_a_fresh_worker():
    _reset()
    walled = db.create_job("walled")
    db.claim_next_queued()
    until = int(T0) + 1200
    db.finish_job(walled, db.FAILED, "DownloadError: " + REAL_BOT_WALL, None,
                  cooldown_until=until)
    db.create_job("b")
    db.create_job("c")

    # A redeploy: the process is gone, and only the database is left.
    with db._lock:
        db.connect().close()
        db._conn = None

    harness = Harness(until=_none_live)
    looks = []
    harness.at(T0 + 600, lambda: looks.append((_states(), harness.started())))
    harness.run()

    assert looks == [({"walled": db.FAILED, "b": db.QUEUED, "c": db.QUEUED}, [])]
    assert harness.starts[0] == ("b", float(until))
    assert harness.started() == ["b", "c"]
    assert _states() == {"walled": db.FAILED, "b": db.DONE, "c": db.DONE}
    assert db.RUNNING not in harness.states_while_waiting


def test_restart_fails_the_running_job_and_leaves_the_queued_ones():
    _reset()
    db.create_job("was-running")
    db.create_job("waiting-1")
    db.create_job("waiting-2")
    db.claim_next_queued()
    db.set_download_cooldown_until(int(T0) + 900)

    harness = Harness(until=lambda: harness.now >= T0 + 899)
    harness.run()

    assert harness.starts == []
    assert _states() == {"was-running": db.FAILED, "waiting-1": db.QUEUED,
                         "waiting-2": db.QUEUED}
    interrupted = [j for j in db.list_jobs() if j["track_id"] == "was-running"][0]
    assert interrupted["error"] == "interrupted by a backend restart"


def test_worker_waiting_out_a_cooldown_can_be_cancelled():
    _reset()
    db.create_job("waiting")
    db.set_download_cooldown_until(int(T0) + 1800)
    ran = []

    async def scenario():
        asleep = asyncio.Event()

        async def sleep(seconds):
            asleep.set()
            await asyncio.Event().wait()

        task = asyncio.create_task(worker.run(
            pipeline=lambda video_id, job_id: ran.append(video_id),
            clock=lambda: T0, sleep=sleep))
        await asyncio.wait_for(asleep.wait(), timeout=10)
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            return True
        return False

    assert asyncio.run(scenario()) is True
    assert ran == []
    assert _states() == {"waiting": db.QUEUED}


# --- what /health reads --------------------------------------------------

def test_cooldown_accessor_before_during_and_after():
    _reset()
    now = int(T0)
    assert db.download_cooldown_until(now) is None

    job = db.create_job("walled")
    db.finish_job(job, db.FAILED, "x", None, cooldown_until=now + 1800)
    assert db.download_cooldown_until(now) == now + 1800
    assert db.download_cooldown_until(now + 1799) == now + 1800
    assert db.download_cooldown_until(now + 1800) is None
    assert db.download_cooldown_until(now + 99999) is None
    # Without an argument it reads the real clock, for which T0 is long past
    # or far ahead depending on the day; either way it answers.
    assert db.download_cooldown_until() in (None, now + 1800)


def test_cooldown_is_never_shortened():
    _reset()
    now = int(T0)
    db.set_download_cooldown_until(now + 1800)
    db.set_download_cooldown_until(now + 60)
    assert db.download_cooldown_until(now) == now + 1800
    db.set_download_cooldown_until(now + 3600)
    assert db.download_cooldown_until(now) == now + 3600


def test_older_catalogue_gains_the_table_and_keeps_its_rows():
    _reset()
    job = db.create_job("kept")
    with db._lock:
        conn = db.connect()
        conn.execute("DROP TABLE worker_state")
        conn.commit()
        conn.close()
        db._conn = None

    assert db.download_cooldown_until(int(T0)) is None
    assert db.get_job(job)["track_id"] == "kept"
    db.set_download_cooldown_until(int(T0) + 5)
    assert db.download_cooldown_until(int(T0)) == int(T0) + 5


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
    with db._lock:
        if db._conn is not None:
            db._conn.close()
    shutil.rmtree(_SCRATCH, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
