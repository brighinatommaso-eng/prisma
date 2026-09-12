"""The single asyncio download worker.

Concurrency is 1, consuming the jobs table, per spec section 3.5: the load is
one user downloading one track at a time, so a broker would be complexity with
no benefit.

A failed job stops at state=failed with its error text intact. There is no
automatic retry, deliberately: spec section 3.6 expects yt-dlp to break
periodically, and a silent retry loop would turn an obvious breakage into a
mysterious one.
"""

import asyncio
import logging

from . import db, downloader

log = logging.getLogger("prisma.worker")

# How long to wait before looking for work again when the queue is empty.
IDLE_POLL_SECONDS = 1.0


async def _process(job: dict) -> None:
    job_id = int(job["id"])
    video_id = job.get("track_id")
    try:
        track = await asyncio.to_thread(downloader.run_pipeline, video_id, job_id)
    except Exception as exc:
        message = type(exc).__name__ + ": " + str(exc)
        log.warning("job %s failed for %s: %s", job_id, video_id, message)
        await asyncio.to_thread(db.finish_job, job_id, db.FAILED, message, None)
        return
    log.info("job %s stored %s at %s", job_id, video_id, track.get("file_path"))
    await asyncio.to_thread(db.finish_job, job_id, db.DONE, None, 1.0)


async def run() -> None:
    """Consume the queue until cancelled."""
    interrupted = await asyncio.to_thread(db.fail_interrupted_jobs)
    if interrupted:
        log.warning("marked %s job(s) failed after a restart", interrupted)

    while True:
        try:
            job = await asyncio.to_thread(db.claim_next_queued)
            if job is None:
                await asyncio.sleep(IDLE_POLL_SECONDS)
                continue
            await _process(job)
        except asyncio.CancelledError:
            raise
        except Exception:
            # The worker itself must survive anything a single job can throw,
            # or one bad track would stop every later download.
            log.exception("worker loop error")
            await asyncio.sleep(IDLE_POLL_SECONDS)
