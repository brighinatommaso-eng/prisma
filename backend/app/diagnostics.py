"""The probes behind /health: what yt-dlp can bring to YouTube's bot checks,
and whether YouTube Music answers at all.

Spec section 3.6 wants a broken download pipeline to be diagnosable at a
glance. Beyond the yt-dlp version, two things decide whether extraction gets
past YouTube's checks: a JavaScript runtime to solve player challenges, and a
PO token provider plugin. Both are reported as yt-dlp itself sees them --
built from the download pipeline's own options -- rather than by guessing at
PATH or at installed packages, so "configured but not picked up" shows as
absent.

Those two touch nothing but the local machine. Building a YoutubeDL, looking
up its JS runtimes and asking the PO token director which providers are
available are all local: yt-dlp's provider contract forbids network requests
in is_available(). They are still not free -- the first call imports yt-dlp,
about a second, and the runtime lookup runs a `deno --version` subprocess --
so the result is cached.

Reachability is the exception: it costs a real YouTube Music search, and the
iOS client polls /health. One upstream request per poll is exactly the
repetition that earns a bot check, so it is cached here too, on the same
mechanism and with a much shorter TTL. The search itself stays in ytm.py.

missing_files is the third thing cached here: how many live tracks have no
file, or a file that is not the one recorded. It never leaves the machine, but
it reads the library, and hashing a library on every poll would be absurd. The
count is cached for a minute like reachability; the hashes behind it are kept
by integrity.py for as long as each file stays unchanged, so a re-count after
the minute costs one stat per file. It only counts. Queueing a repair is never
done from here.

Every probe here is blocking; callers run it off the event loop.

The yt-dlp probes lean on yt-dlp internals (YoutubeDL._js_runtimes and
initialize_pot_director), which can change in any release, and yt-dlp updates
itself on every container start. A probe that breaks logs a warning and
reports "not detected" rather than failing /health.
"""

import copy
import logging
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Callable, TypeVar

from . import integrity, ytm
from .downloader import YTDLP_OPTIONS

log = logging.getLogger("prisma.diagnostics")

T = TypeVar("T")

# A JS runtime or a provider plugin only changes with a rebuild, which restarts
# the process and empties this cache anyway; the TTL only bounds staleness for
# anything changed by hand inside a running container.
YTDLP_CACHE_TTL_S = 300.0
# Reachability does change on its own, so it is re-probed far more often -- but
# still at most once a minute, however hard the client polls.
REACHABLE_CACHE_TTL_S = 60.0
# The library changes by a download, a deletion or a hand on the share; none
# of that needs to show up sooner than a minute later.
MISSING_FILES_CACHE_TTL_S = 60.0
# Longer than a normal probe (about a second cold), shorter than a client's
# patience with /health.
LOCK_WAIT_S = 5.0


@dataclass(frozen=True)
class YtdlpEnvironment:
    # "deno 2.5.1"; None when yt-dlp finds no enabled runtime. A runtime too
    # old for yt-dlp is still named, suffixed " (unsupported)", as yt-dlp's
    # own verbose header does.
    js_runtime: str | None
    # True only when a registered provider reports itself available.
    po_token_provider_active: bool


NOT_DETECTED = YtdlpEnvironment(js_runtime=None, po_token_provider_active=False)


@dataclass
class _ProbeCache:
    """One probe's last result, its TTL and the lock that serialises it."""

    name: str
    ttl_s: float
    # How long a caller waits for a probe already running before it settles
    # for the last known result; None means LOCK_WAIT_S.
    lock_wait_s: float | None = None
    lock: threading.Lock = field(default_factory=threading.Lock)
    # (monotonic time the probe ran, what it returned)
    entry: tuple[float, Any] | None = None


_YTDLP_CACHE = _ProbeCache("yt-dlp environment", YTDLP_CACHE_TTL_S)
_REACHABLE_CACHE = _ProbeCache("YouTube Music reachability", REACHABLE_CACHE_TTL_S)
# No waiting at all: the first scan after a start hashes the whole library and
# can take far longer than a probe, and /health is polled throughout. A poll
# that finds a scan running takes the last count, or "not known", at once.
_MISSING_CACHE = _ProbeCache("missing files", MISSING_FILES_CACHE_TTL_S, lock_wait_s=0.0)


def _cached(cache: _ProbeCache, probe: Callable[[], T], fallback: T) -> T:
    """Run `probe` at most once per TTL. Blocking; call from a thread.

    The lock is held while probing so concurrent callers wait for one probe
    instead of each starting their own. The wait is bounded: if a probe hangs,
    later callers get the last known result -- or `fallback` when there is
    none -- instead of each parking a thread on the lock.
    """
    wait = LOCK_WAIT_S if cache.lock_wait_s is None else cache.lock_wait_s
    if not cache.lock.acquire(timeout=wait):
        log.warning("%s probe still running after %ss; reporting last known result",
                    cache.name, wait)
        entry = cache.entry
        return entry[1] if entry is not None else fallback
    try:
        now = time.monotonic()
        entry = cache.entry
        if entry is not None and now - entry[0] < cache.ttl_s:
            return entry[1]
        value = probe()
        cache.entry = (now, value)
        return value
    finally:
        cache.lock.release()


def _js_runtime(ydl: Any) -> str | None:
    found = []
    for name, runtime in sorted(ydl._js_runtimes.items()):
        info = runtime.info if runtime is not None else None
        if info is None:
            continue
        label = f"{info.name} {info.version}"
        if info.supported is False:
            label += " (unsupported)"
        found.append(label)
    return ", ".join(found) or None


def _po_token_provider_active(ydl: Any) -> bool:
    from yt_dlp.extractor.youtube.pot._director import initialize_pot_director

    director = initialize_pot_director(ydl.get_info_extractor("Youtube"))
    return any(provider.is_available() for provider in director.providers.values())


def _probe() -> YtdlpEnvironment:
    from yt_dlp import YoutubeDL

    js_runtime: str | None = None
    po_token_provider_active = False
    try:
        with YoutubeDL(copy.deepcopy(YTDLP_OPTIONS)) as ydl:
            # Probed separately so one moved internal cannot hide the other.
            try:
                js_runtime = _js_runtime(ydl)
            except Exception as exc:
                log.warning("JS runtime probe failed: %s: %s", type(exc).__name__, exc)
            try:
                po_token_provider_active = _po_token_provider_active(ydl)
            except Exception as exc:
                log.warning("PO token provider probe failed: %s: %s", type(exc).__name__, exc)
    except Exception as exc:
        log.warning("yt-dlp probe failed: %s: %s", type(exc).__name__, exc)
    return YtdlpEnvironment(js_runtime=js_runtime, po_token_provider_active=po_token_provider_active)


def ytdlp_environment() -> YtdlpEnvironment:
    """What yt-dlp would bring to a challenge. Cached; blocking, call from a thread."""
    return _cached(_YTDLP_CACHE, _probe, NOT_DETECTED)


def youtube_music_reachable() -> bool:
    """Whether YouTube Music answered within the last REACHABLE_CACHE_TTL_S.

    Cached; blocking, call from a thread. False is the safe answer both for a
    failed search and for a probe that could not run at all: /health reports
    "not reachable" rather than failing.
    """
    return _cached(_REACHABLE_CACHE, ytm.reachable, False)


def _count_missing_files() -> int | None:
    try:
        found = integrity.classify()
    except Exception as exc:
        # None, not 0: a scan that could not finish has not found the library
        # intact. The failure is cached like any result, so a share that went
        # away is not re-read on every poll either.
        log.warning("missing files scan failed: %s: %s", type(exc).__name__, exc)
        return None
    return len(found[integrity.MISSING]) + len(found[integrity.MISMATCH])


def missing_files() -> int | None:
    """How many live tracks have no file, or a file that is not the recorded one.

    Cached for MISSING_FILES_CACHE_TTL_S; blocking, call from a thread. None
    means "not known": the scan failed, or the first one is still running.
    """
    return _cached(_MISSING_CACHE, _count_missing_files, None)
