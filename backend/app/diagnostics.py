"""What yt-dlp can use against YouTube's bot checks, for /health.

Spec section 3.6 wants a broken download pipeline to be diagnosable at a
glance. Beyond the yt-dlp version, two things decide whether extraction gets
past YouTube's checks: a JavaScript runtime to solve player challenges, and a
PO token provider plugin. Both are reported as yt-dlp itself sees them --
built from the download pipeline's own options -- rather than by guessing at
PATH or at installed packages, so "configured but not picked up" shows as
absent.

Nothing here touches the network. Building a YoutubeDL, looking up its JS
runtimes and asking the PO token director which providers are available are
all local: yt-dlp's provider contract forbids network requests in
is_available(). The work is still not free -- the first call imports yt-dlp,
about a second, and each probe runs a `deno --version` subprocess when deno is
present -- so the result is cached for CACHE_TTL_S and callers run it off the
event loop.

The probes lean on yt-dlp internals (YoutubeDL._js_runtimes and
initialize_pot_director), which can change in any release, and yt-dlp updates
itself on every container start. A probe that breaks logs a warning and
reports "not detected" rather than failing /health.
"""

import copy
import logging
import threading
import time
from dataclasses import dataclass
from typing import Any

from .downloader import YTDLP_OPTIONS

log = logging.getLogger("prisma.diagnostics")

# A JS runtime or a provider plugin only changes with a rebuild, which restarts
# the process and empties this cache anyway; the TTL only bounds staleness for
# anything changed by hand inside a running container.
CACHE_TTL_S = 300.0
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

_cache: tuple[float, YtdlpEnvironment] | None = None
_cache_lock = threading.Lock()


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
    """The cached probe result. Blocking; call from a thread.

    The lock is held while probing so concurrent callers wait for one probe
    instead of each starting their own. The wait is bounded: if a probe hangs,
    later callers get the last known result (or "not detected") instead of
    each parking a thread on the lock.
    """
    global _cache
    if not _cache_lock.acquire(timeout=LOCK_WAIT_S):
        log.warning("yt-dlp probe still running after %ss; reporting last known result", LOCK_WAIT_S)
        cached = _cache
        return cached[1] if cached is not None else NOT_DETECTED
    try:
        now = time.monotonic()
        if _cache is not None and now - _cache[0] < CACHE_TTL_S:
            return _cache[1]
        environment = _probe()
        _cache = (now, environment)
        return environment
    finally:
        _cache_lock.release()
