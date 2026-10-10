"""Favourites and playlists, stored on the server so a reinstall loses nothing.

One document, replaced whole. There is one phone, so there is no merge: the
client sends the collection it wants, carrying the version it was based on.

The version is an integer that starts at 0 on an empty server and goes up by
one on every accepted write. A write based on a version older than the stored
one is refused, and the caller gets the stored collection back to reconcile
against. A version newer than the stored one is accepted: it can only mean the
server lost state the client still has (a restored backup, say), and the
client's copy is the better data. The new version is then base + 1, so it
never goes backwards for that client.

Every accepted write is also written to collection.json beside the database,
so a corrupted SQLite file does not take the playlists with it. The file is
never read back automatically: restoring from it is a deliberate act.
"""

import json
import logging
import os
from typing import Any

from . import db
from .config import DB_PATH
from .paths import set_owner

log = logging.getLogger("prisma.collection")

BACKUP_PATH = DB_PATH.parent / "collection.json"

EMPTY: dict[str, Any] = {"favourites": [], "playlists": []}


class Stale(Exception):
    def __init__(self, current: dict[str, Any]):
        self.current = current


def _read(conn) -> dict[str, Any]:
    row = conn.execute("SELECT version, body FROM collection WHERE id = 1").fetchone()
    if row is None:
        return {"version": 0, **EMPTY}
    return {"version": row["version"], **json.loads(row["body"])}


def get() -> dict[str, Any]:
    with db._lock:
        return _read(db.connect())


def put(base_version: int, document: dict[str, Any]) -> dict[str, Any]:
    """Replace the collection. Raises Stale if base_version is behind the store."""
    body = json.dumps(document, ensure_ascii=False, separators=(",", ":"))
    with db._lock:
        conn = db.connect()
        stored = _read(conn)
        if base_version < stored["version"]:
            raise Stale(stored)
        version = base_version + 1
        result = {"version": version, **document}

        # The backup is staged before the commit and moved into place after
        # it: a failure to write it aborts the write, and the rename that
        # follows a commit has almost nothing left to fail on.
        staged = BACKUP_PATH.with_name(BACKUP_PATH.name + ".tmp")
        with open(staged, "w", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            with conn:
                conn.execute(
                    "INSERT INTO collection (id, version, body, updated_at) "
                    "VALUES (1, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET "
                    "version = excluded.version, body = excluded.body, "
                    "updated_at = excluded.updated_at",
                    (version, body, db._now()),
                )
        except Exception:
            staged.unlink(missing_ok=True)
            raise
        try:
            os.replace(staged, BACKUP_PATH)
            set_owner(BACKUP_PATH)
        except OSError:
            log.exception("collection v%s is stored but %s could not be updated",
                          version, BACKUP_PATH)
        return result
