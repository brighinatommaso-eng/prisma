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
from .paths import COVER_FILENAME, NO_ALBUM, UNKNOWN_ARTIST, make_dir_owned, set_owner

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

# The favourites and playlists, as one JSON document in one row. Replacing the
# whole collection is the only write, so a row is the unit that stays atomic;
# `version` is the counter the stale-write guard compares. Independent of the
# tracks table on purpose: deleting a track's audio must not touch it.
_COLLECTION_SCHEMA = """
CREATE TABLE IF NOT EXISTS collection (
    id         INTEGER PRIMARY KEY CHECK (id = 1),
    version    INTEGER NOT NULL,
    body       TEXT    NOT NULL,
    updated_at INTEGER NOT NULL
)
"""

# What the download worker has to remember across a restart, as integers under
# a key. Today that is one row, the end of a bot-wall cooldown: a redeploy is
# what usually follows a bot wall, and a cooldown held in memory would end
# with the old container and send the queue straight back at YouTube.
_WORKER_STATE_SCHEMA = """
CREATE TABLE IF NOT EXISTS worker_state (
    key   TEXT PRIMARY KEY,
    value INTEGER NOT NULL
)
"""

_COOLDOWN_UNTIL_KEY = "download_cooldown_until"

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
    conn.execute(_COLLECTION_SCHEMA)
    conn.execute(_WORKER_STATE_SCHEMA)
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


def path_claims(file_path: str) -> list[dict[str, Any]]:
    """Every track recorded at file_path, as {"id", "live"}, ordered by id.

    All of them, not the first: a deleted track keeps its old path on its row,
    so a path can be recorded for a deleted id and a live one at once, and
    which row a single-row lookup returned is what let two ids share a file.
    """
    with _lock:
        rows = connect().execute(
            "SELECT id, deleted_at IS NULL AS live FROM tracks "
            "WHERE file_path = ? ORDER BY id", (file_path,)
        ).fetchall()
    return [{"id": row["id"], "live": bool(row["live"])} for row in rows]


def upsert_track(track: dict[str, Any], restore: bool = False) -> None:
    """Insert or update a track row.

    restore=True is for the download pipeline only: a track that was deleted
    and is now downloaded again comes back, and so does its album, in the same
    transaction as the row itself. It is not the default because repair.py
    rewrites rows it read earlier, and must not revive a track deleted since.
    """
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
        with conn:
            conn.execute(statement, values)
            if restore:
                conn.execute(
                    "UPDATE tracks SET deleted_at = NULL WHERE id = ?", (payload["id"],)
                )
                # updated_at moves so the album leaves deleted_album_ids and
                # comes back in the next delta.
                conn.execute(
                    "UPDATE albums SET deleted_at = NULL, updated_at = ? "
                    "WHERE id = ? AND deleted_at IS NOT NULL",
                    (payload["updated_at"], payload.get("album_id")),
                )


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


def mark_track_deleted(video_id: str) -> dict[str, Any] | None:
    """The database half of deleting a track, in one transaction.

    Soft-deletes the track, and its album when no live track is left in it.
    Safe to repeat: an already-deleted track is not re-stamped, but the album
    check runs again, and the facts the file cleanup needs are returned either
    way. Returns None for an id that never existed.

    A queued or running job for the same track blocks the deletion, and nothing
    is written: the job would write the file back behind the delete. Jobs are
    created and claimed under the same lock, so this check cannot race them.
    """
    stamp = _now()
    with _lock:
        conn = connect()
        with conn:
            row = conn.execute(
                "SELECT id, file_path, album_id, deleted_at FROM tracks WHERE id = ?",
                (video_id,),
            ).fetchone()
            if row is None:
                return None
            job = conn.execute(
                "SELECT id FROM jobs WHERE track_id = ? AND state IN (?, ?) "
                "ORDER BY id LIMIT 1",
                (video_id, QUEUED, RUNNING),
            ).fetchone()
            if job is not None:
                return {"track_id": video_id, "active_job_id": int(job["id"])}

            already_deleted = row["deleted_at"] is not None
            if not already_deleted:
                conn.execute(
                    "UPDATE tracks SET deleted_at = ?, updated_at = ? WHERE id = ?",
                    (stamp, stamp, video_id),
                )

            album = None
            if row["album_id"] is not None:
                live = conn.execute(
                    "SELECT COUNT(*) c FROM tracks WHERE album_id = ? AND deleted_at IS NULL",
                    (row["album_id"],),
                ).fetchone()["c"]
                if live == 0:
                    conn.execute(
                        "UPDATE albums SET deleted_at = ?, updated_at = ? "
                        "WHERE id = ? AND deleted_at IS NULL",
                        (stamp, stamp, row["album_id"]),
                    )
                album = conn.execute(
                    "SELECT id, cover_path, deleted_at FROM albums WHERE id = ?",
                    (row["album_id"],),
                ).fetchone()

            file_in_use = False
            if row["file_path"]:
                file_in_use = conn.execute(
                    "SELECT 1 FROM tracks WHERE file_path = ? AND id != ? "
                    "AND deleted_at IS NULL LIMIT 1",
                    (row["file_path"], video_id),
                ).fetchone() is not None

            # Asked about the cover.jpg next to this track's file, which is the
            # one the cleanup would remove. Two album rows can share a folder:
            # the album key is not sanitised, the path segments are.
            cover_in_use = False
            if row["file_path"]:
                folder_cover = str(Path(row["file_path"]).parent / COVER_FILENAME)
                cover_in_use = conn.execute(
                    "SELECT 1 FROM albums WHERE cover_path = ? AND id IS NOT ? "
                    "AND deleted_at IS NULL LIMIT 1",
                    (folder_cover, row["album_id"]),
                ).fetchone() is not None

    return {
        "track_id": video_id,
        "active_job_id": None,
        "already_deleted": already_deleted,
        "file_path": row["file_path"],
        "file_in_use": file_in_use,
        "album_id": row["album_id"],
        "album_deleted": album is not None and album["deleted_at"] is not None,
        "cover_path": album["cover_path"] if album is not None else None,
        "cover_in_use": cover_in_use,
    }


def repoint_track(video_id: str, from_path: str, to_path: str) -> bool:
    """Record a live track at to_path instead of from_path. Row only.

    For a track recorded at a path that turned out to be another track's, or
    nobody's; see downloader._send_to_own_paths. Conditional on the row still being live
    and still at from_path, so it cannot undo a download that got there first.
    updated_at moves so a client mirror hears about it.
    """
    with _lock:
        conn = connect()
        with conn:
            cursor = conn.execute(
                "UPDATE tracks SET file_path = ?, updated_at = ? "
                "WHERE id = ? AND file_path = ? AND deleted_at IS NULL",
                (to_path, _now(), video_id, from_path),
            )
            return cursor.rowcount > 0


def retire_album_if_empty(album_id: int) -> bool:
    """Soft-delete an album that has no live track left. Returns whether it did.

    For a track that a new download filed under a different album: the album
    it left follows the same rule as after a deletion, or it would stay in the
    library with nothing in it. Only the row changes; no file is touched.
    """
    stamp = _now()
    with _lock:
        conn = connect()
        with conn:
            live = conn.execute(
                "SELECT COUNT(*) c FROM tracks WHERE album_id = ? AND deleted_at IS NULL",
                (album_id,),
            ).fetchone()["c"]
            if live:
                return False
            cursor = conn.execute(
                "UPDATE albums SET deleted_at = ?, updated_at = ? "
                "WHERE id = ? AND deleted_at IS NULL",
                (stamp, stamp, album_id),
            )
            return cursor.rowcount > 0


def clear_album_cover(album_id: int, cover_path: str) -> None:
    """Forget a deleted album's cover once its file is gone from disk.

    Conditional on the album still being deleted and still pointing at that
    file: a download that revived the album in the meantime owns the cover now.
    """
    with _lock:
        conn = connect()
        conn.execute(
            "UPDATE albums SET cover_path = NULL "
            "WHERE id = ? AND cover_path = ? AND deleted_at IS NOT NULL",
            (album_id, cover_path),
        )
        conn.commit()


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


def live_track_files() -> list[dict[str, Any]]:
    """Every live track's id, recorded path and stored hash, ordered by id."""
    with _lock:
        rows = connect().execute(
            "SELECT id, file_path, sha256 FROM tracks WHERE deleted_at IS NULL ORDER BY id"
        ).fetchall()
    return [dict(row) for row in rows]


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


def last_successful_download_at() -> int | None:
    """Unix time the most recent successful download finished, or None.

    Spec section 3.6: this date is what tells a yt-dlp breakage apart from a
    quiet week. It is read off the jobs table rather than stored separately:
    finish_job stamps updated_at when a job reaches done, and nothing moves a
    done job afterwards.
    """
    with _lock:
        row = connect().execute(
            "SELECT MAX(COALESCE(updated_at, created_at)) t FROM jobs WHERE state = ?",
            (DONE,),
        ).fetchone()
    return int(row["t"]) if row["t"] is not None else None


# --- download cooldown ----------------------------------------------------

def _store_cooldown_until(conn: sqlite3.Connection, until: int) -> None:
    # MAX: a cooldown is only ever extended, never cut short by a later write.
    conn.execute(
        "INSERT INTO worker_state (key, value) VALUES (?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value = MAX(value, excluded.value)",
        (_COOLDOWN_UNTIL_KEY, int(until)),
    )


def set_download_cooldown_until(until: int) -> None:
    """Pause the download queue until `until` (Unix time)."""
    with _lock:
        conn = connect()
        with conn:
            _store_cooldown_until(conn, until)


def download_cooldown_until(now: int | float | None = None) -> int | None:
    """Unix time the download cooldown in force at `now` ends, or None.

    None both when there has never been a cooldown and when the stored one is
    over: the row is left in place and simply stops applying. The worker asks
    with its own clock; /health asks without one.
    """
    with _lock:
        row = connect().execute(
            "SELECT value FROM worker_state WHERE key = ?", (_COOLDOWN_UNTIL_KEY,)
        ).fetchone()
    if row is None:
        return None
    until = int(row["value"])
    return until if until > (_now() if now is None else now) else None


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


def _active_job(conn: sqlite3.Connection, video_id: str) -> sqlite3.Row | None:
    return conn.execute(
        "SELECT id, state FROM jobs WHERE track_id = ? AND state IN (?, ?) "
        "ORDER BY id LIMIT 1",
        (video_id, QUEUED, RUNNING),
    ).fetchone()


def active_job(video_id: str) -> dict[str, Any] | None:
    """The oldest queued or running job for a track, as {"id", "state"}."""
    with _lock:
        row = _active_job(connect(), video_id)
    return {"id": int(row["id"]), "state": row["state"]} if row else None


def queue_job_once(video_id: str) -> tuple[int, str]:
    """Queue a job unless one is already queued or running for the track.

    Returns (job id, job state): the existing job's when there is one. Checked
    and inserted under one lock, so two callers cannot both queue.
    """
    with _lock:
        conn = connect()
        with conn:
            job = _active_job(conn, video_id)
            if job is not None:
                return int(job["id"]), job["state"]
            cursor = conn.execute(
                "INSERT INTO jobs (track_id, state, progress, created_at, updated_at) "
                "VALUES (?, ?, 0.0, ?, ?)",
                (video_id, QUEUED, _now(), _now()),
            )
            return int(cursor.lastrowid), QUEUED


def queue_repair_job(video_id: str) -> tuple[str, int | None, str | None]:
    """Queue a download for a track that is live right now.

    Returns ("queued", job id, state), ("job_active", job id, state) when a
    job for it is already queued or running, or ("deleted", None, None) when
    the track is no longer live: the pipeline restores a deleted track, so
    queueing one would bring it back. The check and the insert share a lock
    with mark_track_deleted, and a queued job then blocks the deletion, so the
    track cannot be deleted between the two.
    """
    with _lock:
        conn = connect()
        with conn:
            live = conn.execute(
                "SELECT 1 FROM tracks WHERE id = ? AND deleted_at IS NULL", (video_id,)
            ).fetchone()
            if live is None:
                return "deleted", None, None
            job = _active_job(conn, video_id)
            if job is not None:
                return "job_active", int(job["id"]), job["state"]
            cursor = conn.execute(
                "INSERT INTO jobs (track_id, state, progress, created_at, updated_at) "
                "VALUES (?, ?, 0.0, ?, ?)",
                (video_id, QUEUED, _now(), _now()),
            )
            return "queued", int(cursor.lastrowid), QUEUED


def get_job(job_id: int) -> dict[str, Any] | None:
    with _lock:
        row = connect().execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
    return dict(row) if row else None


def list_jobs(finished_within_s: int | None = None) -> list[dict[str, Any]]:
    """Jobs, newest first.

    With finished_within_s, only jobs still queued or running plus those that
    reached any final state within that many seconds; None returns every job.
    """
    with _lock:
        conn = connect()
        if finished_within_s is None:
            rows = conn.execute("SELECT * FROM jobs ORDER BY id DESC").fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM jobs WHERE state IN (?, ?) "
                "OR COALESCE(updated_at, created_at) >= ? ORDER BY id DESC",
                (QUEUED, RUNNING, _now() - finished_within_s),
            ).fetchall()
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
               progress: float | None = None,
               cooldown_until: int | None = None) -> None:
    """Record how a job ended.

    cooldown_until is for a job that ended at YouTube's bot wall: the cooldown
    is stored in the same transaction as the failure, so a crash between the
    two cannot leave the job failed and the queue free to run into the wall.
    """
    with _lock:
        conn = connect()
        with conn:
            conn.execute(
                "UPDATE jobs SET state = ?, error = ?, progress = COALESCE(?, progress), "
                "updated_at = ? WHERE id = ?",
                (state, error, progress, _now(), job_id),
            )
            if cooldown_until is not None:
                _store_cooldown_until(conn, cooldown_until)


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

    Only `running` is touched. The worker never holds a claimed job while it
    waits out a gap or a cooldown, so a queued job stays queued through any
    number of restarts.
    """
    with _lock:
        conn = connect()
        cursor = conn.execute(
            "UPDATE jobs SET state = ?, error = ?, updated_at = ? WHERE state = ?",
            (FAILED, "interrupted by a backend restart", _now(), RUNNING),
        )
        conn.commit()
        return cursor.rowcount
