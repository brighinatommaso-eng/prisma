#!/usr/bin/env python3
"""Tests for the yt-dlp diagnostics /health reports.

Runs against a throwaway database, never the real library, and makes no
network request -- run it with networking off to prove that:

    docker compose exec -T backend python scripts/test_health_diagnostics.py
    docker run --rm --network none prisma-backend:latest \\
        python scripts/test_health_diagnostics.py

yt-dlp must be importable, so this runs inside the image rather than on a
bare dev machine. Plain asserts in test_* functions, like the other scripts.
"""

import asyncio
import os
import shutil
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

# Must happen before anything under app/ is imported: config reads the
# environment once, at import time.
_SCRATCH = Path(tempfile.mkdtemp(prefix="prisma-test-health-"))
os.environ["PRISMA_MUSIC_DIR"] = str(_SCRATCH / "music")
os.environ["PRISMA_STATE_DIR"] = str(_SCRATCH / "music" / ".prisma")
os.environ["PRISMA_DB_PATH"] = str(_SCRATCH / "music" / ".prisma" / "catalog.db")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import db  # noqa: E402
from app.config import MUSIC_DIR  # noqa: E402

# Refuse to run against anything but the scratch directory.
assert MUSIC_DIR.is_relative_to(_SCRATCH), MUSIC_DIR


def _set_job_time(job_id, when):
    with db._lock:
        conn = db.connect()
        conn.execute("UPDATE jobs SET created_at = ?, updated_at = ? WHERE id = ?",
                     (when, when, job_id))
        conn.commit()


def _clear_jobs():
    with db._lock:
        conn = db.connect()
        conn.execute("DELETE FROM jobs")
        conn.commit()


def _runtime(name, version, supported):
    return SimpleNamespace(info=SimpleNamespace(name=name, version=version, supported=supported))


# --- last successful download --------------------------------------------

def test_last_success_is_none_without_done_jobs():
    _clear_jobs()
    failed = db.create_job("health-failed")
    db.finish_job(failed, db.FAILED, "boom", None)
    db.create_job("health-queued")

    assert db.last_successful_download_at() is None


def test_last_success_is_newest_done_job_only():
    _clear_jobs()
    older = db.create_job("health-done-old")
    db.finish_job(older, db.DONE, None, 1.0)
    _set_job_time(older, 1000)
    newer = db.create_job("health-done-new")
    db.finish_job(newer, db.DONE, None, 1.0)
    _set_job_time(newer, 2000)
    # Later than both, but none of them succeeded.
    for state in (db.FAILED, db.CANCELLED, db.RUNNING, db.QUEUED):
        job = db.create_job("health-" + state)
        db.finish_job(job, state, None, None)
        _set_job_time(job, 9000)

    assert db.last_successful_download_at() == 2000


# --- JS runtime ----------------------------------------------------------

def test_js_runtime_reports_name_and_version():
    from app import diagnostics
    ydl = SimpleNamespace(_js_runtimes={"deno": _runtime("deno", "2.5.1", True)})

    assert diagnostics._js_runtime(ydl) == "deno 2.5.1"


def test_js_runtime_is_none_when_not_found():
    from app import diagnostics
    # yt-dlp's shape when deno is enabled but not on PATH: info is None.
    ydl = SimpleNamespace(_js_runtimes={"deno": SimpleNamespace(info=None)})

    assert diagnostics._js_runtime(ydl) is None


def test_js_runtime_flags_unsupported_version():
    from app import diagnostics
    ydl = SimpleNamespace(_js_runtimes={"deno": _runtime("deno", "2.1.0", False)})

    assert diagnostics._js_runtime(ydl) == "deno 2.1.0 (unsupported)"


# --- PO token provider ---------------------------------------------------

def _with_registered_provider(available, check):
    """Register a real PoTokenProvider in yt-dlp's own registry for one check."""
    from yt_dlp.extractor.youtube.pot._registry import _pot_providers
    from yt_dlp.extractor.youtube.pot.provider import (
        PoTokenProvider, PoTokenProviderRejectedRequest, register_provider,
    )

    class PrismaTestPTP(PoTokenProvider):
        PROVIDER_VERSION = "0.0.1"

        def is_available(self):
            return available

        def _real_request_pot(self, request):
            raise PoTokenProviderRejectedRequest("test provider")

    register_provider(PrismaTestPTP)
    try:
        check()
    finally:
        _pot_providers.value.pop(PrismaTestPTP.PROVIDER_KEY, None)


def test_real_probe_detects_available_provider():
    from app import diagnostics

    def check():
        assert diagnostics._probe().po_token_provider_active is True

    _with_registered_provider(True, check)


def test_real_probe_ignores_unavailable_provider():
    from app import diagnostics

    def check():
        assert diagnostics._probe().po_token_provider_active is False

    _with_registered_provider(False, check)


# --- the probe as a whole ------------------------------------------------

def test_real_probe_returns_typed_result_offline():
    from app import diagnostics
    env = diagnostics._probe()

    assert env.js_runtime is None or isinstance(env.js_runtime, str), env
    assert isinstance(env.po_token_provider_active, bool), env


def test_probe_failure_degrades_instead_of_raising():
    from app import diagnostics

    def broken(_ydl):
        raise AttributeError("yt-dlp internals moved")

    saved = diagnostics._js_runtime, diagnostics._po_token_provider_active
    diagnostics._js_runtime = diagnostics._po_token_provider_active = broken
    try:
        env = diagnostics._probe()
    finally:
        diagnostics._js_runtime, diagnostics._po_token_provider_active = saved

    assert env.js_runtime is None
    assert env.po_token_provider_active is False


def test_environment_is_cached_within_ttl():
    from app import diagnostics
    calls = []

    def fake_probe():
        calls.append(1)
        return diagnostics.YtdlpEnvironment(js_runtime="deno 9", po_token_provider_active=True)

    saved = diagnostics._probe
    diagnostics._probe = fake_probe
    diagnostics._YTDLP_CACHE.entry = None
    try:
        first = diagnostics.ytdlp_environment()
        second = diagnostics.ytdlp_environment()
        assert len(calls) == 1, calls
        assert first == second

        # Age the cache past the TTL: the next call probes again.
        stamp, value = diagnostics._YTDLP_CACHE.entry
        diagnostics._YTDLP_CACHE.entry = (stamp - diagnostics.YTDLP_CACHE_TTL_S - 1, value)
        diagnostics.ytdlp_environment()
        assert len(calls) == 2, calls
    finally:
        diagnostics._probe = saved
        diagnostics._YTDLP_CACHE.entry = None


def test_hung_probe_does_not_block_other_callers():
    from app import diagnostics
    last_known = diagnostics.YtdlpEnvironment(js_runtime="deno 1", po_token_provider_active=True)

    saved_wait = diagnostics.LOCK_WAIT_S
    diagnostics.LOCK_WAIT_S = 0.05
    # Stands in for a probe that is stuck while holding the lock.
    diagnostics._YTDLP_CACHE.lock.acquire()
    try:
        diagnostics._YTDLP_CACHE.entry = None
        assert diagnostics.ytdlp_environment() == diagnostics.NOT_DETECTED
        diagnostics._YTDLP_CACHE.entry = (0.0, last_known)
        assert diagnostics.ytdlp_environment() == last_known
    finally:
        diagnostics._YTDLP_CACHE.lock.release()
        diagnostics.LOCK_WAIT_S = saved_wait
        diagnostics._YTDLP_CACHE.entry = None


# --- YouTube Music reachability ------------------------------------------

def _counting_reachable(verdict=True):
    """Stand in for ytm.reachable, recording every call. Makes no request."""
    calls = []

    def probe():
        calls.append(1)
        return verdict

    return calls, probe


def test_reachability_is_cached_within_ttl():
    from app import diagnostics
    calls, probe = _counting_reachable()

    saved = diagnostics.ytm.reachable
    diagnostics.ytm.reachable = probe
    diagnostics._REACHABLE_CACHE.entry = None
    try:
        assert diagnostics.youtube_music_reachable() is True
        assert diagnostics.youtube_music_reachable() is True
        assert len(calls) == 1, calls

        # Age the cache past the TTL: the next call searches again.
        stamp, value = diagnostics._REACHABLE_CACHE.entry
        diagnostics._REACHABLE_CACHE.entry = (
            stamp - diagnostics.REACHABLE_CACHE_TTL_S - 1, value)
        diagnostics.youtube_music_reachable()
        assert len(calls) == 2, calls
    finally:
        diagnostics.ytm.reachable = saved
        diagnostics._REACHABLE_CACHE.entry = None


def test_reachability_caches_a_failure_too():
    """A YouTube Music that is down must not be re-probed on every poll either."""
    from app import diagnostics
    calls, probe = _counting_reachable(verdict=False)

    saved = diagnostics.ytm.reachable
    diagnostics.ytm.reachable = probe
    diagnostics._REACHABLE_CACHE.entry = None
    try:
        assert diagnostics.youtube_music_reachable() is False
        assert diagnostics.youtube_music_reachable() is False
        assert len(calls) == 1, calls
    finally:
        diagnostics.ytm.reachable = saved
        diagnostics._REACHABLE_CACHE.entry = None


def test_hung_reachability_probe_does_not_block_other_callers():
    from app import diagnostics

    saved_wait = diagnostics.LOCK_WAIT_S
    diagnostics.LOCK_WAIT_S = 0.05
    # Stands in for a search that is stuck while holding the lock.
    diagnostics._REACHABLE_CACHE.lock.acquire()
    try:
        diagnostics._REACHABLE_CACHE.entry = None
        assert diagnostics.youtube_music_reachable() is False
        diagnostics._REACHABLE_CACHE.entry = (0.0, True)
        assert diagnostics.youtube_music_reachable() is True
    finally:
        diagnostics._REACHABLE_CACHE.lock.release()
        diagnostics.LOCK_WAIT_S = saved_wait
        diagnostics._REACHABLE_CACHE.entry = None


def test_the_two_caches_are_independent():
    """Expiring one probe must not force the other to run again."""
    from app import diagnostics
    ytdlp_calls = []
    reachable_calls, reachable_probe = _counting_reachable()

    def fake_probe():
        ytdlp_calls.append(1)
        return diagnostics.NOT_DETECTED

    saved_probe = diagnostics._probe
    saved_reachable = diagnostics.ytm.reachable
    diagnostics._probe = fake_probe
    diagnostics.ytm.reachable = reachable_probe
    diagnostics._YTDLP_CACHE.entry = None
    diagnostics._REACHABLE_CACHE.entry = None
    try:
        diagnostics.ytdlp_environment()
        diagnostics.youtube_music_reachable()
        # Only reachability ages out.
        stamp, value = diagnostics._REACHABLE_CACHE.entry
        diagnostics._REACHABLE_CACHE.entry = (
            stamp - diagnostics.REACHABLE_CACHE_TTL_S - 1, value)
        diagnostics.ytdlp_environment()
        diagnostics.youtube_music_reachable()

        assert len(ytdlp_calls) == 1, ytdlp_calls
        assert len(reachable_calls) == 2, reachable_calls
    finally:
        diagnostics._probe = saved_probe
        diagnostics.ytm.reachable = saved_reachable
        diagnostics._YTDLP_CACHE.entry = None
        diagnostics._REACHABLE_CACHE.entry = None


# --- the endpoint --------------------------------------------------------

def test_health_carries_new_fields_and_keeps_old_ones():
    from app import diagnostics, main

    _clear_jobs()
    job = db.create_job("health-endpoint")
    db.finish_job(job, db.DONE, None, 1.0)
    _set_job_time(job, 4242)

    saved_reachable = diagnostics.ytm.reachable
    saved_probe = diagnostics._probe
    # No YouTube: the only upstream call /health makes is stubbed out.
    diagnostics.ytm.reachable = lambda: True
    diagnostics._probe = lambda: diagnostics.YtdlpEnvironment(
        js_runtime="deno 2.5.1", po_token_provider_active=False)
    diagnostics._YTDLP_CACHE.entry = None
    diagnostics._REACHABLE_CACHE.entry = None
    MUSIC_DIR.mkdir(parents=True, exist_ok=True)
    try:
        payload = asyncio.run(main.health()).model_dump()
    finally:
        diagnostics.ytm.reachable = saved_reachable
        diagnostics._probe = saved_probe
        diagnostics._YTDLP_CACHE.entry = None
        diagnostics._REACHABLE_CACHE.entry = None

    for field in ("ytdlp_version", "ytmusicapi_version", "music_free_bytes",
                  "youtube_music_reachable", "track_count", "album_count",
                  "total_bytes_stored"):
        assert field in payload, field
    assert payload["youtube_music_reachable"] is True
    assert payload["js_runtime"] == "deno 2.5.1"
    assert payload["po_token_provider_active"] is False
    assert payload["last_successful_download_at"] == 4242


def test_health_asks_youtube_music_once_however_often_it_is_polled():
    """The iOS client polls /health; YouTube must not see one search per poll."""
    from app import diagnostics, main

    calls, probe = _counting_reachable()
    saved_reachable = diagnostics.ytm.reachable
    saved_probe = diagnostics._probe
    diagnostics.ytm.reachable = probe
    diagnostics._probe = lambda: diagnostics.NOT_DETECTED
    diagnostics._YTDLP_CACHE.entry = None
    diagnostics._REACHABLE_CACHE.entry = None
    MUSIC_DIR.mkdir(parents=True, exist_ok=True)
    try:
        payloads = [asyncio.run(main.health()).model_dump() for _ in range(5)]
    finally:
        diagnostics.ytm.reachable = saved_reachable
        diagnostics._probe = saved_probe
        diagnostics._YTDLP_CACHE.entry = None
        diagnostics._REACHABLE_CACHE.entry = None

    assert len(calls) == 1, calls
    assert all(p["youtube_music_reachable"] is True for p in payloads), payloads


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
