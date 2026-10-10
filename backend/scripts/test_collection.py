#!/usr/bin/env python3
"""Tests for the favourites and playlists collection.

Runs against a throwaway music directory and database, never the real library:

    python scripts/test_collection.py
    docker compose exec -T backend python scripts/test_collection.py

Plain asserts in test_* functions, like test_track_deletion.py. The HTTP layer
is exercised through Starlette's TestClient, which needs httpx; without it the
HTTP tests are skipped and the storage ones still run.
"""

import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

_SCRATCH = Path(tempfile.mkdtemp(prefix="prisma-test-collection-"))
os.environ["PRISMA_MUSIC_DIR"] = str(_SCRATCH / "music")
os.environ["PRISMA_STATE_DIR"] = str(_SCRATCH / "music" / ".prisma")
os.environ["PRISMA_DB_PATH"] = str(_SCRATCH / "music" / ".prisma" / "catalog.db")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import collection, db, deletion  # noqa: E402
from app.config import MUSIC_DIR  # noqa: E402
from app.paths import make_dir_owned, track_paths  # noqa: E402

assert MUSIC_DIR.is_relative_to(_SCRATCH), MUSIC_DIR

try:
    from fastapi.testclient import TestClient
    from app.main import app
except (ImportError, RuntimeError):
    TestClient = None

SENT = {
    "favourites": [
        {"video_id": "zzz", "title": "Zeta", "artist": "A", "album": "Alb",
         "artwork_url": "https://example.test/z.jpg", "added_at": 1700000100},
        {"video_id": "aaa", "title": None, "artist": None, "album": None,
         "artwork_url": None, "added_at": 1700000000.5},
    ],
    "playlists": [
        {"id": "p-2", "name": "Sera ✨", "created_at": 1700000000,
         "updated_at": 1700000050, "entries": ["zzz", "aaa", "zzz", "never-downloaded"]},
        {"id": "p-1", "name": "Empty", "created_at": 1700000001,
         "updated_at": 1700000001, "entries": []},
    ],
}


def _client():
    # The context manager runs the lifespan, which connects the database. It
    # also starts the download worker, which idles on an empty queue.
    return TestClient(app)


def _backup():
    return json.loads(collection.BACKUP_PATH.read_text(encoding="utf-8"))


def _reset():
    with db._lock:
        conn = db.connect()
        conn.execute("DELETE FROM collection")
        conn.commit()
    collection.BACKUP_PATH.unlink(missing_ok=True)


def test_empty_server_returns_empty_collection():
    _reset()
    assert collection.get() == {"version": 0, "favourites": [], "playlists": []}


def test_put_then_get_round_trips_exactly():
    _reset()
    stored = collection.put(0, SENT)
    assert stored["version"] == 1
    got = collection.get()
    assert got == {"version": 1, **SENT}
    # Order is the client's order, not the server's.
    assert [f["video_id"] for f in got["favourites"]] == ["zzz", "aaa"]
    assert got["playlists"][0]["entries"] == ["zzz", "aaa", "zzz", "never-downloaded"]


def test_stale_version_is_rejected_with_current_collection():
    _reset()
    collection.put(0, SENT)                      # -> v1
    newer = {"favourites": [], "playlists": SENT["playlists"]}
    collection.put(1, newer)                     # -> v2
    try:
        collection.put(1, SENT)
    except collection.Stale as stale:
        assert stale.current == {"version": 2, **newer}
    else:
        raise AssertionError("a write based on v1 was accepted over v2")
    assert collection.get() == {"version": 2, **newer}


def test_version_ahead_of_server_is_accepted():
    _reset()
    assert collection.put(7, SENT)["version"] == 8


def test_backup_matches_stored_collection_after_each_change():
    _reset()
    collection.put(0, SENT)
    assert _backup() == collection.get()
    changed = {"favourites": SENT["favourites"][:1], "playlists": []}
    collection.put(1, changed)
    assert _backup() == collection.get() == {"version": 2, **changed}
    # A refused write leaves the backup alone.
    try:
        collection.put(1, SENT)
    except collection.Stale:
        pass
    assert _backup() == {"version": 2, **changed}
    assert not collection.BACKUP_PATH.with_name("collection.json.tmp").exists()


def test_deleting_a_track_leaves_the_favourite():
    _reset()
    audio, cover = track_paths("Artist D", "Album D", "Song", "del1")
    make_dir_owned(audio.parent)
    audio.write_bytes(b"a" * 100)
    cover.write_bytes(b"c" * 10)
    album_id = db.upsert_album("Artist D", "Album D", None, None, 2001, str(cover), ["#000000"])
    db.upsert_track({"id": "del1", "title": "Song", "artist": "Artist D", "album": "Album D",
                     "album_id": album_id, "file_path": str(audio),
                     "file_bytes": 100, "sha256": "0" * 64})
    doc = {
        "favourites": [{"video_id": "del1", "title": "Song", "artist": "Artist D",
                        "album": "Album D", "artwork_url": None, "added_at": 1}],
        "playlists": [{"id": "p", "name": "P", "created_at": 1, "updated_at": 1,
                       "entries": ["del1"]}],
    }
    collection.put(0, doc)

    result = deletion.delete_track("del1")

    assert result["status"] == "deleted", result
    assert not audio.exists()
    assert collection.get() == {"version": 1, **doc}
    assert _backup() == collection.get()


# --- HTTP ----------------------------------------------------------------

def test_http_round_trip_and_409():
    if TestClient is None:
        print("      (skipped: httpx not installed)")
        return
    _reset()
    with _client() as client:
        empty = client.get("/collection")
        assert empty.status_code == 200, empty.text
        assert empty.json() == {"version": 0, "favourites": [], "playlists": []}

        put = client.put("/collection", json={"version": 0, **SENT})
        assert put.status_code == 200, put.text
        assert put.json() == {"version": 1, **SENT}
        assert client.get("/collection").json() == {"version": 1, **SENT}

        client.put("/collection", json={"version": 1, "favourites": [], "playlists": []})
        stale = client.put("/collection", json={"version": 1, **SENT})
        assert stale.status_code == 409, stale.text
        assert stale.json() == {"version": 2, "favourites": [], "playlists": []}


def test_http_rejects_duplicate_ids_and_bad_shape():
    if TestClient is None:
        return
    _reset()
    with _client() as client:
        dup = {"version": 0, "playlists": [],
               "favourites": [SENT["favourites"][0], SENT["favourites"][0]]}
        assert client.put("/collection", json=dup).status_code == 422
        assert client.put("/collection", json={"favourites": [], "playlists": []}).status_code == 422
        assert client.get("/collection").json()["version"] == 0


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
