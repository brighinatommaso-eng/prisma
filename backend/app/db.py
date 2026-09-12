"""SQLite catalogue and job queue.

One connection, guarded by a lock. sqlite3 is blocking, so every call here is
made either from the API's threadpool or from the worker thread, never on the
event loop directly.

The schema is spec section 3.4 plus what the download and read paths need.
Migrations are additive only: columns and tables are added, never altered or
dropped.

Why albums is its own table: year, cover and palette are properties of a
release, not of a recording. Two tracks can reach the same folder by different
routes -- one via its own browseId, one via an album search -- and each route
can report a different year for the same record. Storing the year on the track
let that disagreement reach the client. The album row is now the single
authority, and tracks reference it by id.
"""

import json
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any

from .config import DB_PATH
from .paths import NO_ALBUM, UNKNOWN_ARTIST, make_dir_owned, set_owner

QUEUED = "queued"
RUNNING = "running"
DONE = "done"
FAILED = "failed"
CANCELLED = "cancelled"

_conn: sqlite3.Connection | None = None
_lock = threading.RLock()

_TRACKS_SCHEMA = """
CREATE TABLE IF NOT EXISTS tracks (
    id                  TEXT PRIMARY KEY,
    title               TEXT,
    artist              TEXT,
    album_raw           TEXT,
    album               TEXT,
    album_release_title TEXT,
    album_browse_id     TEXT,
    year                INTEGER,
    track_no            INTEGER,
    duration_s          INTEGER,
    file_path           TEXT,
    file_bytes          INTEGER,
    sha256              TEXT,
    artwork_path        TEXT,
    palette             TEXT,
    added_at            INTEGER,
    album_id            INTEGER,
    updated_at          INTEGER,
    deleted_at          INTEGER
)
"""

_ALBUMS_SCHEMA = """
CREATE TABLE IF NOT EXISTS albums (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    artist        TEXT NOT NULL,
    title         TEXT NOT NULL,
    release_title TEXT,
    browse_id     TEXT,
    year          INTEGER,
    cover_path    TEXT,
    palette       TEXT,
    updated_at    INTEGER,
    deleted_at    INTEGER,
    UNIQUE(artist, title)
)
"""

_JOBS_SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    track_id   TEXT,
    state      TEXT    NOT NULL,
    progress   REAL    NOT NULL DEFAULT 0.0,
    error      TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER
)
"""

# Columns added after an earlier release. Additive only.
_EXPECTED_TRACK_COLUMNS = {
    "album_raw": "TEXT",
    "album": "TEXT",
    "album_release_title": "TEXT",
    "album_browse_id": "TEXT",
    "year": "INTEGER",
    "track_no": "INTEGER",
    "sha256": "TEXT",
    "artwork_path": "TEXT",
    "palette": "TEXT",
    "album_id": "INTEGER",
    "updated_at": "INTEGER",
    "deleted_at": "INTEGER",
}

# tracks.year, tracks.palette and tracks.artwork_path are still WRITTEN, as
# per-release provenance, but nothing reads them any more: the read path takes
# year, palette and cover from the album. They are not dropped because dropping
# a column needs explicit approval.
_TRACK_COLUMNS = [
    "id", "title", "artist", "album_raw", "album", "album_release_title",
    "album_browse_id", "year", "track_no", "duration_s", "file_path",
    "file_bytes", "sha256", "artwork_path", "palette", "added_at",
    "album_id", "updated_at",
]


def connect() -> sqlite3.Connection:
    global _conn
    with _lock:
        if _conn is None:
            make_dir_owned(DB_PATH.parent)
            _conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
            _conn.row_factory = sqlite3.Row
            # WAL keeps the worker's writes from blocking the API's reads.
            _conn.execute("PRAGMA journal_mode=WAL")
            _conn.execute("PRAGMA synchronous=NORMAL")
            _init_schema(_conn)
            for suffix in ("", "-wal", "-shm"):
                candidate = Path(str(DB_PATH) + suffix)
                if candidate.exists():
                    set_owner(candidate)
        return _conn


def _init_schema(conn: sqlite3.Connection) -> None:
    conn.execute(_TRACKS_SCHEMA)
    conn.execute(_ALBUMS_SCHEMA)
    conn.execute(_JOBS_SCHEMA)
    present = {row["name"] for row in conn.execute("PRAGMA table_info(tracks)")}
    for column, sql_type in _EXPECTED_TRACK_COLUMNS.items():
        if column not in present:
            conn.execute("ALTER TABLE tracks ADD COLUMN " + column + " " + sql_type)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_jobs_state ON jobs(state, id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_tracks_path ON tracks(file_path)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_tracks_updated ON tracks(updated_at)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_albums_updated ON albums(updated_at)")
    conn.commit()
    _backfill(conn)


def _backfill(conn: sqlite3.Connection) -> None:
    """One-shot migration of pre-albums rows. Idempotent, so it can just run.

    The library is small, so this is done in Python for legibility rather than
    as a clever single statement.
    """
    now = _now()
    conn.execute(
        "UPDATE tracks SET updated_at = COALESCE(added_at, ?) WHERE updated_at IS NULL",
        (now,),
    )
    conn.commit()

    orphans = conn.execute(
        "SELECT * FROM tracks WHERE album_id IS NULL AND deleted_at IS NULL"
    ).fetchall()
    if not orphans:
        return

    # Group by the same key the on-disk layout uses, so one album row
    # corresponds to exactly one folder.
    groups: dict[tuple[str, str], list[sqlite3.Row]] = {}
    for row in orphans:
        groups.setdefault(_album_key(row["artist"], row["album"]), []).append(row)

    for (artist, title), rows in groups.items():
        years = [r["year"] for r in rows if r["year"] is not None]
        covers = [r["artwork_path"] for r in rows if r["artwork_path"]]
        palettes = [r["palette"] for r in rows if r["palette"]]
        releases = [r["album_release_title"] for r in rows if r["album_release_title"]]
        browses = [r["album_browse_id"] for r in rows if r["album_browse_id"]]
        album_id = _upsert_album_row(
            conn,
            artist=artist,
            title=title,
            release_title=releases[0] if releases else None,
            browse_id=browses[0] if browses else None,
            # Disagreement between releases resolves to the earliest year.
            year=min(years) if years else None,
            cover_path=covers[0] if covers else None,
            palette_json=palettes[0] if palettes else None,
        )
        for row in rows:
            conn.execute(
                "UPDATE tracks SET album_id = ?, updated_at = ? WHERE id = ?",
                (album_id, now, row["id"]),
            )
    conn.commit()


def _now() -> int:
    return int(time.time())


def _album_key(artist: str | None, album: str | None) -> tuple[str, str]:
    """The grouping key for an album row: one row per on-disk folder.

    The fallbacks match the path segments exactly, so a track with no album
    groups under Singles just as it is filed under Singles on disk. The track's
    own album column stays NULL -- no metadata is invented, this is a grouping.
    """
    artist_key = (artist or "").strip() or UNKNOWN_ARTIST
    album_key = (album or "").strip() or NO_ALBUM
    return artist_key, album_key


# --- albums ---------------------------------------------------------------

def _upsert_album_row(conn: sqlite3.Connection, artist: str, title: str,
                      release_title: str | None, browse_id: str | None,
                      year: int | None, cover_path: str | None,
                      palette_json: str | None) -> int:
    """Create or adopt an album row. Returns its id.

    A track joining an existing album adopts that album's year. The only thing
    that can change an established year is an earlier one, so disagreement
    between releases always resolves to the earliest.
    """
    row = conn.execute(
        "SELECT * FROM albums WHERE artist = ? AND title = ?", (artist, title)
    ).fetchone()
    if row is None:
        cursor = conn.execute(
            "INSERT INTO albums (artist, title, release_title, browse_id, year, "
            "cover_path, palette, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (artist, title, release_title, browse_id, year, cover_path,
             palette_json, _now()),
        )
        return int(cursor.lastrowid)

    updates: dict[str, Any] = {}
    if row["year"] is None:
        if year is not None:
            updates["year"] = year
    elif year is not None and year < row["year"]:
        updates["year"] = year
    # First writer wins for the rest: an album already carrying a cover does not
    # get it swapped out by the next track.
    for column, incoming in (
        ("release_title", release_title),
        ("browse_id", browse_id),
        ("cover_path", cover_path),
        ("palette", palette_json),
    ):
        if not row[column] and incoming:
            updates[column] = incoming

    if updates:
        # Only touch updated_at when something really changed, or every
        # download would make every album show up in the next delta.
        assignments = ", ".join(name + " = ?" for name in updates)
        conn.execute(
            "UPDATE albums SET " + assignments + ", updated_at = ? WHERE id = ?",
            [*updates.values(), _now(), row["id"]],
        )
    return int(row["id"])


def upsert_album(artist: str | None, album: str | None, release_title: str | None,
                 browse_id: str | None, year: int | None, cover_path: str | None,
                 palette: list[str] | None) -> int:
    artist_key, title_key = _album_key(artist, album)
    palette_json = json.dumps(list(palette)) if palette else None
    with _lock:
        conn = connect()
        album_id = _upsert_album_row(
            conn, artist_key, title_key, release_title, browse_id, year,
            cover_path, palette_json,
        )
        conn.commit()
        return album_id


def get_album(album_id: int) -> dict[str, Any] | None:
    with _lock:
        row = connect().execute("SELECT * FROM albums WHERE id = ?", (album_id,)).fetchone()
    if row is None:
        return None
    album = dict(row)
    album["palette"] = json.loads(album["palette"]) if album.get("palette") else None
    return album


# --- tracks ---------------------------------------------------------------

def get_track(video_id: str) -> dict[str, Any] | None:
    with _lock:
        row = connect().execute("SELECT * FROM tracks WHERE id = ?", (video_id,)).fetchone()
    if row is None:
        return None
    track = dict(row)
    track["palette"] = json.loads(track["palette"]) if track.get("palette") else None
    return track


def track_for_path(file_path: str) -> str | None:
    """The video_id Prisma has stored at file_path, if any."""
    with _lock:
        row = connect().execute(
            "SELECT id FROM tracks WHERE file_path = ?", (file_path,)
        ).fetchone()
    return row["id"] if row else None


def upsert_track(track: dict[str, Any]) -> None:
    payload = dict(track)
    palette = payload.get("palette")
    if isinstance(palette, (list, tuple)):
        payload["palette"] = json.dumps(list(palette))
    payload.setdefault("added_at", _now())
    payload["updated_at"] = _now()

    placeholders = ", ".join(["?"] * len(_TRACK_COLUMNS))
    assignments = ", ".join(
        column + "=excluded." + column for column in _TRACK_COLUMNS if column != "id"
    )
    statement = (
        "INSERT INTO tracks (" + ", ".join(_TRACK_COLUMNS) + ") "
        "VALUES (" + placeholders + ") "
        "ON CONFLICT(id) DO UPDATE SET " + assignments
    )
    values = [payload.get(column) for column in _TRACK_COLUMNS]
    with _lock:
        conn = connect()
        conn.execute(statement, values)
        conn.commit()


def set_track_deleted(video_id: str, deleted: bool = True) -> bool:
    """Soft-delete or restore a track so a client mirror can drop it.

    Soft deletion rather than a tombstone table: the delta is already driven by
    updated_at on these rows, so one timestamp serves both "changed" and
    "removed" and there is no second table to keep in step.
    """
    stamp = _now()
    with _lock:
        conn = connect()
        cursor = conn.execute(
            "UPDATE tracks SET deleted_at = ?, updated_at = ? WHERE id = ?",
            (stamp if deleted else None, stamp, video_id),
        )
        conn.commit()
        return cursor.rowcount > 0


# --- read path ------------------------------------------------------------

_TRACK_FIELDS = ("id", "title", "track_no", "duration_s", "file_bytes",
                 "sha256", "updated_at")


def _track_payload(row: sqlite3.Row) -> dict[str, Any]:
    return {field: row[field] for field in _TRACK_FIELDS}


def _album_payload(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "artist": row["artist"],
        "title": row["title"],
        "year": row["year"],
        "palette": json.loads(row["palette"]) if row["palette"] else None,
        # Relative, so the same payload is valid whether the client reached the
        # server over the LAN address or over Tailscale MagicDNS.
        "cover_url": "/albums/" + str(row["id"]) + "/cover" if row["cover_path"] else None,
        "updated_at": row["updated_at"],
        "tracks": [],
    }


def library(since: int | None = None) -> dict[str, Any]:
    """Full catalogue, or only what changed since `since`.

    A delta returns each affected album with its complete live track list, not
    just the changed tracks: a partial list is indistinguishable from "the album
    now contains only these", so the client would have to guess. Upserting a
    whole album is unambiguous and idempotent.
    """
    with _lock:
        conn = connect()
        if since is None:
            album_rows = conn.execute(
                "SELECT * FROM albums WHERE deleted_at IS NULL "
                "ORDER BY artist COLLATE NOCASE, title COLLATE NOCASE"
            ).fetchall()
        else:
            album_rows = conn.execute(
                "SELECT * FROM albums WHERE deleted_at IS NULL AND ("
                "  updated_at > ? OR id IN ("
                "    SELECT DISTINCT album_id FROM tracks"
                "    WHERE album_id IS NOT NULL AND updated_at > ?"
                "  )"
                ") ORDER BY artist COLLATE NOCASE, title COLLATE NOCASE",
                (since, since),
            ).fetchall()

        albums = [_album_payload(row) for row in album_rows]
        by_id = {album["id"]: album for album in albums}
        if by_id:
            marks = ", ".join(["?"] * len(by_id))
            track_rows = conn.execute(
                "SELECT * FROM tracks WHERE deleted_at IS NULL AND album_id IN ("
                + marks + ") ORDER BY album_id, track_no IS NULL, track_no, "
                "title COLLATE NOCASE",
                list(by_id),
            ).fetchall()
            for row in track_rows:
                by_id[row["album_id"]]["tracks"].append(_track_payload(row))

        if since is None:
            deleted_tracks: list[str] = []
            deleted_albums: list[int] = []
        else:
            deleted_tracks = [
                r["id"] for r in conn.execute(
                    "SELECT id FROM tracks WHERE deleted_at IS NOT NULL "
                    "AND updated_at > ? ORDER BY id", (since,)
                ).fetchall()
            ]
            deleted_albums = [
                r["id"] for r in conn.execute(
                    "SELECT id FROM albums WHERE deleted_at IS NOT NULL "
                    "AND updated_at > ? ORDER BY id", (since,)
                ).fetchall()
            ]

    return {
        # The client should send this back as `since` next time, rather than its
        # own clock, so a skewed device cannot silently skip rows.
        "server_time": _now(),
        "since": since,
        "albums": albums,
        "deleted_album_ids": deleted_albums,
        "deleted_track_ids": deleted_tracks,
    }


def track_file(video_id: str) -> dict[str, Any] | None:
    with _lock:
        row = connect().execute(
            "SELECT id, title, file_path, file_bytes, sha256 FROM tracks "
            "WHERE id = ? AND deleted_at IS NULL", (video_id,)
        ).fetchone()
    return dict(row) if row else None


def counters() -> dict[str, int]:
    with _lock:
        conn = connect()
        tracks = conn.execute(
            "SELECT COUNT(*) c, COALESCE(SUM(file_bytes), 0) b FROM tracks "
            "WHERE deleted_at IS NULL"
        ).fetchone()
        albums = conn.execute(
            "SELECT COUNT(*) c FROM albums WHERE deleted_at IS NULL"
        ).fetchone()
    return {
        "track_count": int(tracks["c"]),
        "album_count": int(albums["c"]),
        "total_bytes_stored": int(tracks["b"]),
    }


# --- jobs -----------------------------------------------------------------

def create_job(video_id: str) -> int:
    with _lock:
        conn = connect()
        cursor = conn.execute(
            "INSERT INTO jobs (track_id, state, progress, created_at, updated_at) "
            "VALUES (?, ?, 0.0, ?, ?)",
            (video_id, QUEUED, _now(), _now()),
        )
        conn.commit()
        return int(cursor.lastrowid)


def get_job(job_id: int) -> dict[str, Any] | None:
    with _lock:
        row = connect().execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
    return dict(row) if row else None


def list_jobs() -> list[dict[str, Any]]:
    with _lock:
        rows = connect().execute("SELECT * FROM jobs ORDER BY id DESC").fetchall()
    return [dict(row) for row in rows]


def claim_next_queued() -> dict[str, Any] | None:
    """Atomically take the oldest queued job and mark it running.

    Concurrency is 1 by design (spec section 3.5), but the claim is still made
    in one transaction so a second consumer could never be handed the same job.
    """
    with _lock:
        conn = connect()
        row = conn.execute(
            "SELECT * FROM jobs WHERE state = ? ORDER BY id ASC LIMIT 1", (QUEUED,)
        ).fetchone()
        if row is None:
            return None
        conn.execute(
            "UPDATE jobs SET state = ?, updated_at = ? WHERE id = ?",
            (RUNNING, _now(), row["id"]),
        )
        conn.commit()
        claimed = dict(row)
        claimed["state"] = RUNNING
        return claimed


def set_progress(job_id: int, progress: float) -> None:
    with _lock:
        conn = connect()
        conn.execute(
            "UPDATE jobs SET progress = ?, updated_at = ? WHERE id = ?",
            (max(0.0, min(1.0, progress)), _now(), job_id),
        )
        conn.commit()


def finish_job(job_id: int, state: str, error: str | None = None,
               progress: float | None = None) -> None:
    with _lock:
        conn = connect()
        conn.execute(
            "UPDATE jobs SET state = ?, error = ?, progress = COALESCE(?, progress), "
            "updated_at = ? WHERE id = ?",
            (state, error, progress, _now(), job_id),
        )
        conn.commit()


def cancel_queued_job(job_id: int) -> str | None:
    """Cancel a queued job. Returns the state the job was in, or None if absent.

    A running job is deliberately left alone: killing a download mid-write would
    leave a partial file behind, so it is allowed to finish.
    """
    with _lock:
        conn = connect()
        row = conn.execute("SELECT state FROM jobs WHERE id = ?", (job_id,)).fetchone()
        if row is None:
            return None
        previous = row["state"]
        if previous == QUEUED:
            conn.execute(
                "UPDATE jobs SET state = ?, updated_at = ? WHERE id = ?",
                (CANCELLED, _now(), job_id),
            )
            conn.commit()
        return previous


def fail_interrupted_jobs() -> int:
    """Mark jobs left running by a crash or restart as failed.

    No automatic retry: a silent retry loop would hide a broken yt-dlp, which
    spec section 3.6 calls the most predictable failure in the project.
    """
    with _lock:
        conn = connect()
        cursor = conn.execute(
            "UPDATE jobs SET state = ?, error = ?, updated_at = ? WHERE state = ?",
            (FAILED, "interrupted by a backend restart", _now(), RUNNING),
        )
        conn.commit()
        return cursor.rowcount
