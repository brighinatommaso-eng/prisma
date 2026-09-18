"""Prisma backend.

Phase 1a proved the external dependencies work: ytmusicapi for search, yt-dlp
for extraction. On top of that sits the download write path, and the read path
the iOS client mirrors locally for offline playback.

The read path is shaped for a client that keeps its own copy of this catalogue:
stable ordering so diffs are quiet, a timestamped delta so a resync is cheap,
explicit deletion ids so a mirror can drop rows, and Range on the audio so an
interrupted transfer resumes instead of restarting.
"""

import asyncio
import contextlib
import logging
import shutil
from contextlib import asynccontextmanager
from importlib.metadata import PackageNotFoundError, version as dist_version
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Query, Request, Response
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from . import db, diagnostics, worker, ytm
from .config import MUSIC_DIR

log = logging.getLogger("prisma.api")

# A hanging upstream must not hang /health, which is the one endpoint used to
# diagnose a broken deploy.
HEALTH_PROBE_TIMEOUT_S = 8.0
SEARCH_TIMEOUT_S = 20.0

# Covers are immutable once written: a new cover means a new album folder. A
# long max-age plus the ETag means the client revalidates rarely and cheaply.
COVER_CACHE_CONTROL = "public, max-age=604800"

# GET /downloads is polled every 2s, so by default it carries only live jobs and
# those that ended within this window -- long enough for a client that was away
# to still see how its job ended.
RECENT_JOBS_WINDOW_S = 3600


@asynccontextmanager
async def lifespan(_: FastAPI):
    # The bind mount exists, but the directory inside it may not on a fresh
    # server. disk_usage() and yt-dlp both need it to be there.
    MUSIC_DIR.mkdir(parents=True, exist_ok=True)
    await asyncio.to_thread(db.connect)
    task = asyncio.create_task(worker.run())
    try:
        yield
    finally:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task


app = FastAPI(
    title="Prisma",
    description="Self-hosted music download backend.",
    version="0.3.0",
    lifespan=lifespan,
)


class Health(BaseModel):
    ytdlp_version: str
    ytmusicapi_version: str
    music_free_bytes: int
    youtube_music_reachable: bool
    track_count: int
    album_count: int
    total_bytes_stored: int
    # How yt-dlp sees its defences against YouTube's bot checks; see
    # diagnostics.py. Local probes only, cached, never a YouTube request.
    js_runtime: str | None
    po_token_provider_active: bool
    # Unix time; None until the first download succeeds.
    last_successful_download_at: int | None


class SongResult(BaseModel):
    video_id: str
    title: str | None
    artist: str | None
    album: str | None
    duration_s: int | None
    artwork_url: str | None
    artwork_url_small: str | None


class DownloadRequest(BaseModel):
    video_id: str = Field(min_length=1, description="YouTube video id to download.")


class Job(BaseModel):
    id: int
    track_id: str | None
    state: str
    progress: float
    error: str | None
    created_at: int
    updated_at: int | None


class LibraryTrack(BaseModel):
    id: str
    title: str | None
    track_no: int | None
    duration_s: int | None
    file_bytes: int | None
    sha256: str | None
    updated_at: int | None


class LibraryAlbum(BaseModel):
    id: int
    artist: str
    title: str
    year: int | None
    palette: list[str] | None
    cover_url: str | None
    updated_at: int | None
    # Ordered by track_no, then title. Unnumbered tracks sort last.
    tracks: list[LibraryTrack]


class Library(BaseModel):
    server_time: int = Field(
        description="Send this back as `since` next time, rather than the device clock."
    )
    since: int | None
    # Ordered by artist, then title.
    albums: list[LibraryAlbum]
    deleted_album_ids: list[int]
    deleted_track_ids: list[str]


def _installed_version(distribution: str) -> str:
    try:
        return dist_version(distribution)
    except PackageNotFoundError:
        return "not installed"


async def _youtube_music_reachable() -> bool:
    try:
        return await asyncio.wait_for(
            asyncio.to_thread(ytm.reachable), timeout=HEALTH_PROBE_TIMEOUT_S
        )
    except Exception:
        # Includes the timeout. /health must answer even when YouTube does not.
        return False


async def _ytdlp_environment() -> diagnostics.YtdlpEnvironment:
    try:
        return await asyncio.wait_for(
            asyncio.to_thread(diagnostics.ytdlp_environment), timeout=HEALTH_PROBE_TIMEOUT_S
        )
    except Exception:
        # The probe itself never raises; this is the timeout. The thread keeps
        # running and fills the cache for the next call.
        log.warning("yt-dlp environment probe exceeded %ss", HEALTH_PROBE_TIMEOUT_S)
        return diagnostics.NOT_DETECTED


@app.get("/health", response_model=Health)
async def health() -> Health:
    # Concurrent: the first call after a start pays for importing yt-dlp, and
    # that should not queue behind the YouTube Music probe.
    reachable, environment = await asyncio.gather(
        _youtube_music_reachable(), _ytdlp_environment()
    )
    counts = await asyncio.to_thread(db.counters)
    last_success = await asyncio.to_thread(db.last_successful_download_at)
    return Health(
        ytdlp_version=_installed_version("yt-dlp"),
        ytmusicapi_version=_installed_version("ytmusicapi"),
        music_free_bytes=shutil.disk_usage(MUSIC_DIR).free,
        youtube_music_reachable=reachable,
        **counts,
        js_runtime=environment.js_runtime,
        po_token_provider_active=environment.po_token_provider_active,
        last_successful_download_at=last_success,
    )


@app.get("/search", response_model=list[SongResult])
async def search(
    q: str = Query(min_length=1, description="Free-text query."),
    limit: int = Query(default=20, ge=1, le=50, description="Maximum results to return."),
) -> list[SongResult]:
    try:
        results = await asyncio.wait_for(
            asyncio.to_thread(ytm.search_songs, q, limit), timeout=SEARCH_TIMEOUT_S
        )
    except asyncio.TimeoutError:
        raise HTTPException(status_code=504, detail="YouTube Music search timed out.")
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"YouTube Music search failed: {exc}")
    return [SongResult(**r) for r in results]


@app.post("/downloads", status_code=202)
async def create_download(payload: DownloadRequest, response: Response) -> dict[str, Any]:
    """Queue a download.

    A video_id already in the catalogue is returned as-is with 200 and nothing
    is downloaded again.
    """
    existing = await asyncio.to_thread(db.get_track, payload.video_id)
    if existing is not None:
        response.status_code = 200
        return {"status": "exists", "track": existing}

    job_id = await asyncio.to_thread(db.create_job, payload.video_id)
    return {"status": db.QUEUED, "job_id": job_id, "video_id": payload.video_id}


@app.get("/downloads", response_model=list[Job])
async def list_downloads(
    all_jobs: bool = Query(
        default=False, alias="all",
        description="Return every job ever created, for debugging. By default only "
                    "queued and running jobs, plus jobs that ended in the last hour.",
    ),
) -> list[Job]:
    window = None if all_jobs else RECENT_JOBS_WINDOW_S
    jobs = await asyncio.to_thread(db.list_jobs, window)
    return [Job(**job) for job in jobs]


@app.delete("/downloads/{job_id}")
async def cancel_download(job_id: int) -> dict[str, Any]:
    """Cancel a queued job.

    A job already running is left to finish rather than killed mid-write, and
    the response says so.
    """
    previous = await asyncio.to_thread(db.cancel_queued_job, job_id)
    if previous is None:
        raise HTTPException(status_code=404, detail=f"No job with id {job_id}.")
    if previous == db.QUEUED:
        return {"job_id": job_id, "status": db.CANCELLED, "detail": "Queued job cancelled."}
    if previous == db.RUNNING:
        return {
            "job_id": job_id,
            "status": db.RUNNING,
            "detail": "Job is already running and was left to finish; it was not cancelled.",
        }
    return {
        "job_id": job_id,
        "status": previous,
        "detail": f"Job already finished with state {previous}; nothing to cancel.",
    }


@app.get("/library", response_model=Library)
async def library(
    since: int | None = Query(
        default=None, ge=0,
        description="Unix timestamp. Omit for the full catalogue; pass the previous "
                    "response's server_time for a delta.",
    ),
) -> Library:
    payload = await asyncio.to_thread(db.library, since)
    return Library(**payload)


@app.get("/tracks/{track_id}/file")
async def track_file(track_id: str) -> FileResponse:
    """The audio file, with Range support.

    Range is handled by Starlette's FileResponse (verified on 1.6.0, which
    implements single and multiple ranges). Without it an interrupted transfer
    would restart from zero, which spec section 3.5 calls out.
    """
    track = await asyncio.to_thread(db.track_file, track_id)
    if track is None:
        raise HTTPException(status_code=404, detail=f"No track with id {track_id}.")
    path = Path(track["file_path"])
    if not path.is_file():
        raise HTTPException(
            status_code=410,
            detail=f"Track {track_id} is in the catalogue but its file is missing.",
        )
    return FileResponse(
        path,
        media_type="audio/mp4",
        filename=path.name,
        # Lets a client verify the transfer without a second request.
        headers={"X-Prisma-SHA256": track["sha256"] or ""},
    )


@app.get("/albums/{album_id}/cover")
async def album_cover(album_id: int, request: Request) -> Response:
    """The album cover, with ETag and Cache-Control.

    The 304 is handled here rather than left to the framework so the behaviour
    is explicit and does not change under us on a Starlette upgrade.
    """
    album = await asyncio.to_thread(db.get_album, album_id)
    if album is None:
        raise HTTPException(status_code=404, detail=f"No album with id {album_id}.")
    cover_path = album.get("cover_path")
    if not cover_path:
        raise HTTPException(status_code=404, detail=f"Album {album_id} has no cover.")
    path = Path(cover_path)
    if not path.is_file():
        raise HTTPException(status_code=410, detail=f"Cover file for album {album_id} is missing.")

    stat = path.stat()
    etag = f'"{stat.st_size:x}-{int(stat.st_mtime):x}"'
    cache_headers = {"ETag": etag, "Cache-Control": COVER_CACHE_CONTROL}

    if_none_match = request.headers.get("if-none-match", "")
    # A client may send a list, and may weaken the tag with a W/ prefix.
    candidates = {value.strip().removeprefix("W/") for value in if_none_match.split(",")}
    if etag in candidates:
        return Response(status_code=304, headers=cache_headers)

    return Response(
        content=await asyncio.to_thread(path.read_bytes),
        media_type="image/jpeg",
        headers=cache_headers,
    )
