"""The single asyncio download worker.

Concurrency is 1, consuming the jobs table, per spec section 3.5: the load is
one user downloading one track at a time, so a broker would be complexity with
no benefit.

A failed job stops at state=failed with its error text intact. There is no
automatic retry, deliberately: spec section 3.6 expects yt-dlp to break
periodically, and a silent retry loop would turn an obvious breakage into a
mysterious one.

Importing a playlist queues dozens of jobs at once, which is the volume that
has earned "Sign in to confirm you're not a bot" before. So the worker paces
itself in two ways:

- a gap of a few seconds, with jitter, between the end of one download attempt
  and the start of the next;
- a cooldown once YouTube does answer with the bot wall. The job that hit it
  fails like any other and is not tried again; every job behind it stays
  queued until the cooldown ends, instead of being run into the same wall.

The worker waits *before* claiming. A claimed job is `running`, and a restart
marks running jobs failed, so claiming and then sleeping would fail a job that
never ran. The end of a cooldown is stored in the database for the same
reason restarts matter: a redeploy is what usually follows a bot wall.

Every job that reaches the pipeline contacts YouTube: a track already in the
catalogue is answered by POST /downloads and never becomes a job. The worker
therefore paces all of them alike, without asking which ones "really" went
out.
"""

import asyncio
import logging
import random
import re
import time
from typing import Any, Awaitable, Callable

from . import db
from .paths import library_write_lock

log = logging.getLogger("prisma.worker")

# How long to wait before looking for work again when the queue is empty.
IDLE_POLL_SECONDS = 1.0

# The gap after a download attempt, drawn afresh each time so the requests do
# not arrive on a beat.
DOWNLOAD_GAP_MIN_SECONDS = 12.0
DOWNLOAD_GAP_MAX_SECONDS = 20.0

# How long the queue rests after the bot wall.
BOT_WALL_COOLDOWN_SECONDS = 30 * 60

# A wait is slept in slices and re-decided after each: the cooldown ends at a
# wall-clock time, and one long sleep would not notice the clock being set.
MAX_WAIT_SLICE_SECONDS = 30.0

# "not a bot" rather than the full sentence: YouTube writes "you’re" with a
# typographic apostrophe, so anything matching "you're" never fires. A 429 is
# the same signal by another route, as yt-dlp ("HTTP Error 429") and
# ytmusicapi ("HTTP 429") word it. The word boundaries keep a byte count or a
# video id that merely contains 429 from matching.
_BOT_WALL_RE = re.compile(
    r"not\s+a\s+bot\b|\bHTTP(?:\s+Error)?\s+429\b|\bToo\s+Many\s+Requests\b",
    re.IGNORECASE,
)

Pipeline = Callable[[str, int], dict[str, Any]]


def is_bot_wall(error_text: str | None) -> bool:
    """Whether a failure is YouTube refusing the server, not the track."""
    return bool(error_text) and _BOT_WALL_RE.search(error_text) is not None


def seconds_until_claim(now: float, not_before: float | None,
                        cooldown_until: float | None) -> float:
    """How long the worker must still wait before claiming a job; 0 means now.

    not_before is where the gap after the last attempt ends; cooldown_until is
    where a bot-wall cooldown ends. Either may be None or already past.
    """
    wait = 0.0
    if not_before is not None:
        # Capped, because a gap is never longer than this: a clock set back
        # must not turn seconds into hours.
        wait = min(not_before - now, DOWNLOAD_GAP_MAX_SECONDS)
    if cooldown_until is not None:
        wait = max(wait, cooldown_until - now)
    return max(wait, 0.0)


def _next_gap() -> float:
    return random.uniform(DOWNLOAD_GAP_MIN_SECONDS, DOWNLOAD_GAP_MAX_SECONDS)


def _run_pipeline_locked(video_id: str, job_id: int) -> dict:
    # Imported here so the pacing above can be loaded, and tested, on a machine
    # without yt-dlp and ytmusicapi.
    from . import downloader

    # Held for the whole pipeline so a track deletion cannot remove a file or
    # album folder this download is writing into.
    with library_write_lock:
        return downloader.run_pipeline(video_id, job_id)


async def _process(job: dict, pipeline: Pipeline, clock: Callable[[], float]) -> None:
    job_id = int(job["id"])
    video_id = job.get("track_id")
    try:
        track = await asyncio.to_thread(pipeline, video_id, job_id)
    except Exception as exc:
        message = type(exc).__name__ + ": " + str(exc)
        log.warning("job %s failed for %s: %s", job_id, video_id, message)
        cooldown_until = None
        if is_bot_wall(message):
            cooldown_until = int(clock()) + BOT_WALL_COOLDOWN_SECONDS
            log.warning(
                "job %s hit YouTube's bot wall: queued downloads wait until %s "
                "(%s s); the failed job is not retried",
                job_id, cooldown_until, BOT_WALL_COOLDOWN_SECONDS,
            )
        await asyncio.to_thread(
            db.finish_job, job_id, db.FAILED, message, None, cooldown_until)
        return
    log.info("job %s stored %s at %s", job_id, video_id, track.get("file_path"))
    await asyncio.to_thread(db.finish_job, job_id, db.DONE, None, 1.0)


async def run(
    *,
    pipeline: Pipeline = _run_pipeline_locked,
    clock: Callable[[], float] = time.time,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    gap: Callable[[], float] = _next_gap,
) -> None:
    """Consume the queue until cancelled.

    The clock, the sleep, the gap and the pipeline are parameters so the tests
    can run this loop itself, with no waiting and no YouTube.
    """
    interrupted = await asyncio.to_thread(db.fail_interrupted_jobs)
    if interrupted:
        log.warning("marked %s job(s) failed after a restart", interrupted)

    not_before: float | None = None
    announced_until: int | None = None
    while True:
        try:
            cooldown_until = await asyncio.to_thread(db.download_cooldown_until, clock())
            if cooldown_until is not None and cooldown_until != announced_until:
                # Once per cooldown, and again by a worker that starts inside one.
                log.warning("download cooldown in force until %s; queued jobs wait",
                            cooldown_until)
                announced_until = cooldown_until
            wait = seconds_until_claim(clock(), not_before, cooldown_until)
            if wait > 0:
                await sleep(min(wait, MAX_WAIT_SLICE_SECONDS))
                continue
            job = await asyncio.to_thread(db.claim_next_queued)
            if job is None:
                await sleep(IDLE_POLL_SECONDS)
                continue
            try:
                await _process(job, pipeline, clock)
            finally:
                # Whatever happened to the attempt, the next one keeps its
                # distance from it.
                not_before = clock() + gap()
        except asyncio.CancelledError:
            raise
        except Exception:
            # The worker itself must survive anything a single job can throw,
            # or one bad track would stop every later download.
            log.exception("worker loop error")
            await sleep(IDLE_POLL_SECONDS)
