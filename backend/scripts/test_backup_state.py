#!/usr/bin/env python3
"""Tests for the daily backup of the state directory.

Runs with no dependencies and no network, on Windows and on Linux, against a
throwaway directory, never the real library:

    python scripts/test_backup_state.py

backup_state.py is a host script: it never imports the application, and these
tests do not either. A stand-in "server" keeps a WAL-mode catalogue open with
its newest rows still only in the write-ahead log, which is exactly the state a
plain file copy gets wrong. The script is run both as a function, with the
clock passed in so nine days fit in one test, and as the command cron runs.
Plain asserts in test_* functions, like the other scripts.
"""

import contextlib
import datetime
import hashlib
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

import guard

# Must happen before anything under app/ is imported: config reads the
# environment once, at import time.
_SCRATCH = guard.scratch_music_dir("prisma-test-backup-")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import backup_state  # noqa: E402

# Refuse to run against anything but the scratch directory.
guard.assert_scratch(_SCRATCH)

SCRIPT = Path(__file__).resolve().parent / "backup_state.py"
DAY = datetime.datetime(2026, 10, 1, 3, 15, 0, tzinfo=datetime.timezone.utc)

_case = 0


class Site:
    """A music directory with a state directory, and a backup directory beside it."""

    def __init__(self, backup_inside_music=False):
        global _case
        _case += 1
        self.root = _SCRATCH / f"case-{_case}"
        self.music = self.root / "music"
        self.state = self.music / ".prisma"
        self.catalogue = self.state / "catalog.db"
        self.backups = (self.music / "backups") if backup_inside_music else self.root / "backups"
        self.state.mkdir(parents=True)
        self.server = None

    def env(self, **changes):
        env = {"PRISMA_MUSIC_HOST_DIR": str(self.music), "PRISMA_BACKUP_DIR": str(self.backups)}
        env.update(changes)
        return {k: v for k, v in env.items() if v is not None}

    def start_server(self, tracks=3):
        """Open the catalogue the way the backend does and leave rows in the WAL."""
        self.server = sqlite3.connect(str(self.catalogue))
        self.server.execute("PRAGMA journal_mode=WAL")
        # Never checkpoint: everything below stays in catalog.db-wal.
        self.server.execute("PRAGMA wal_autocheckpoint=0")
        self.server.execute("CREATE TABLE tracks (id TEXT PRIMARY KEY, deleted_at INTEGER)")
        self.server.executemany("INSERT INTO tracks VALUES (?, NULL)",
                                [(f"track-{n}",) for n in range(tracks)])
        self.server.commit()
        return self.server

    def stop_server(self):
        if self.server is not None:
            self.server.close()
            self.server = None

    def completed(self):
        if not self.backups.exists():
            return []
        return sorted(p.name for p in self.backups.iterdir()
                      if backup_state.COMPLETED_NAME.match(p.name))


def _run(site, now=DAY, argv=(), **env_changes):
    """Call the script's main(). Returns (exit code, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = backup_state.main(list(argv), environ=site.env(**env_changes), now=now,
                                 env_file=site.root / "no-such.env")
    return code, out.getvalue(), err.getvalue()


def _track_ids(database):
    conn = sqlite3.connect(str(database))
    try:
        return [row[0] for row in conn.execute("SELECT id FROM tracks ORDER BY id")]
    finally:
        conn.close()


def _digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest() if Path(path).exists() else None


def _tree(root):
    return sorted(str(p.relative_to(root)) for p in Path(root).rglob("*"))


# --- a consistent copy ----------------------------------------------------

def test_backup_of_a_running_wal_database_carries_what_a_file_copy_loses():
    site = Site()
    server = site.start_server(tracks=3)
    try:
        # What `cp catalog.db` would have produced: the main file alone.
        naive = site.root / "naive-copy.db"
        shutil.copyfile(site.catalogue, naive)
        try:
            naive_rows = _track_ids(naive)
        except sqlite3.Error:
            naive_rows = []
        assert naive_rows == [], "the fixture no longer keeps its rows in the WAL"

        # Written but not committed: must not be in the copy.
        server.execute("INSERT INTO tracks VALUES ('uncommitted', NULL)")
        before = _digest(site.catalogue), _digest(str(site.catalogue) + "-wal")

        code, out, err = _run(site)

        assert code == 0, (out, err)
        assert (_digest(site.catalogue), _digest(str(site.catalogue) + "-wal")) == before
        server.rollback()
    finally:
        site.stop_server()

    name = "prisma-state-20261001T031500Z"
    assert site.completed() == [name]
    copy = site.backups / name / "catalog.db"
    assert _track_ids(copy) == ["track-0", "track-1", "track-2"]
    conn = sqlite3.connect(str(copy))
    try:
        assert conn.execute("PRAGMA integrity_check").fetchall() == [("ok",)]
        # One self-contained file: restoring it needs no -wal beside it.
        assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "delete"
    finally:
        conn.close()
    assert sorted(p.name for p in (site.backups / name).iterdir()) == ["backup.json", "catalog.db"]
    manifest = json.loads((site.backups / name / "backup.json").read_text(encoding="utf-8"))
    assert manifest["tracks"] == 3 and manifest["collection_json"] is False, manifest
    assert manifest["catalog_sha256"] == _digest(copy)


def test_success_is_one_line_for_the_cron_log():
    site = Site()
    site.start_server(tracks=2)
    try:
        code, out, err = _run(site)
    finally:
        site.stop_server()
    assert code == 0 and err == "", (code, err)
    assert out.count("\n") == 1 and out.startswith("prisma-backup OK "), out
    for part in ("prisma-state-20261001T031500Z", "tracks=2", "collection.json=no",
                 "kept=1", "removed=0"):
        assert part in out, (part, out)


def test_collection_json_is_copied_when_present():
    site = Site()
    site.start_server()
    document = '{"version": 3, "favourites": [], "playlists": []}'
    (site.state / "collection.json").write_text(document, encoding="utf-8")
    try:
        code, out, _ = _run(site)
    finally:
        site.stop_server()
    assert code == 0 and "collection.json=yes" in out, out
    copied = site.backups / "prisma-state-20261001T031500Z" / "collection.json"
    assert copied.read_text(encoding="utf-8") == document


def test_the_command_cron_runs_reads_the_env_file():
    site = Site()
    site.start_server()
    env_file = site.root / ".env"
    env_file.write_text(
        "# next to docker-compose.yml\n"
        f"PRISMA_MUSIC_HOST_DIR={site.music}\n"
        f'export PRISMA_BACKUP_DIR="{site.backups}"\n', encoding="utf-8")
    env = {k: v for k, v in os.environ.items() if not k.startswith("PRISMA_")}
    try:
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--env-file", str(env_file)],
            env=env, capture_output=True, text=True, timeout=120)
    finally:
        site.stop_server()
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert result.stdout.startswith("prisma-backup OK "), result.stdout
    assert len(site.completed()) == 1
    assert _track_ids(site.backups / site.completed()[0] / "catalog.db") == [
        "track-0", "track-1", "track-2"]


def test_the_environment_wins_over_the_env_file():
    site, other = Site(), Site()
    site.start_server()
    env_file = site.root / ".env"
    env_file.write_text(f"PRISMA_BACKUP_DIR={other.backups}\n", encoding="utf-8")
    out, err = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = backup_state.main([], environ=site.env(), now=DAY, env_file=env_file)
    finally:
        site.stop_server()
    assert code == 0, err.getvalue()
    assert len(site.completed()) == 1 and not other.backups.exists()


# --- refusals -------------------------------------------------------------

def test_refuses_without_a_backup_directory():
    site = Site()
    site.start_server()
    before = _tree(site.root)
    try:
        for value in (None, "", "   "):
            code, out, err = _run(site, PRISMA_BACKUP_DIR=value)
            assert code != 0 and out == "", (value, code, out)
            assert "prisma-backup FAILED" in err and "PRISMA_BACKUP_DIR" in err, err
            assert _tree(site.root) == before and not site.backups.exists()
    finally:
        site.stop_server()


def test_refuses_a_backup_directory_inside_the_music_directory():
    site = Site()
    site.start_server()
    inside = [
        site.music,
        site.music / "backups",
        site.music / ".prisma" / "backups",
        site.root / "elsewhere" / ".." / "music" / "deep" / "er",
    ]
    try:
        for candidate in inside:
            before = _tree(site.music)
            code, out, err = _run(site, PRISMA_BACKUP_DIR=str(candidate))
            assert code != 0 and out == "", (candidate, code, out)
            assert "inside the music directory" in err, err
            assert _tree(site.music) == before, candidate
    finally:
        site.stop_server()


def test_refuses_a_backup_directory_that_links_into_the_music_directory():
    site = Site()
    site.start_server()
    target = site.music / "hidden"
    target.mkdir()
    link = site.root / "looks-outside"
    try:
        os.symlink(str(target), str(link), target_is_directory=True)
    except (OSError, NotImplementedError):
        site.stop_server()
        print("      (skipped: this account cannot create symlinks)")
        return
    try:
        code, _, err = _run(site, PRISMA_BACKUP_DIR=str(link))
    finally:
        site.stop_server()
    assert code != 0 and "inside the music directory" in err, (code, err)
    assert list(target.iterdir()) == []


def test_a_sibling_whose_name_starts_like_the_music_directory_is_accepted():
    site = Site()
    site.start_server()
    sibling = site.root / "music-backups"
    try:
        code, _, err = _run(site, PRISMA_BACKUP_DIR=str(sibling))
    finally:
        site.stop_server()
    assert code == 0, err
    assert len(list(sibling.iterdir())) == 1


def test_fails_when_there_is_no_catalogue():
    site = Site()
    code, out, err = _run(site)
    assert code != 0 and out == "" and "catalog.db" in err, (code, out, err)
    assert not site.backups.exists()


# --- rotation -------------------------------------------------------------

def test_keeps_the_newest_seven_and_only_removes_its_own_directories():
    site = Site()
    site.start_server()
    site.backups.mkdir()
    (site.backups / "notes.txt").write_text("mine", encoding="utf-8")
    (site.backups / "prisma-state-holiday-photos").mkdir()
    (site.backups / "prisma-state-holiday-photos" / "a.jpg").write_bytes(b"jpg")
    # The right name, but nothing says this script completed it.
    (site.backups / "prisma-state-20200101T000000Z").mkdir()
    (site.backups / "prisma-state-20200101T000000Z" / "keep.me").write_bytes(b"x")
    try:
        for day in range(9):
            code, out, err = _run(site, now=DAY + datetime.timedelta(days=day))
            assert code == 0, err
            assert ("removed=1" if day >= 7 else "removed=0") in out, (day, out)
    finally:
        site.stop_server()

    expected = ["prisma-state-202610%02dT031500Z" % d for d in range(3, 10)]
    assert sorted(p.name for p in site.backups.iterdir()) == sorted(
        expected + ["notes.txt", "prisma-state-holiday-photos",
                    "prisma-state-20200101T000000Z"])
    assert (site.backups / "prisma-state-holiday-photos" / "a.jpg").read_bytes() == b"jpg"
    assert (site.backups / "prisma-state-20200101T000000Z" / "keep.me").read_bytes() == b"x"
    for name in expected:
        assert len(_track_ids(site.backups / name / "catalog.db")) == 3


def test_a_failed_backup_removes_nothing_and_leaves_no_half_backup():
    site = Site()
    site.start_server()
    try:
        for day in range(7):
            assert _run(site, now=DAY + datetime.timedelta(days=day))[0] == 0
    finally:
        site.stop_server()
    good = _tree(site.backups)
    assert len(site.completed()) == 7

    # The catalogue is no longer a database at all.
    for suffix in ("-wal", "-shm"):
        Path(str(site.catalogue) + suffix).unlink(missing_ok=True)
    site.catalogue.write_bytes(b"this is not a database" * 400)

    code, out, err = _run(site, now=DAY + datetime.timedelta(days=30))

    assert code != 0 and out == "", (code, out)
    assert err.startswith("prisma-backup FAILED"), err
    assert _tree(site.backups) == good


def test_a_copy_that_fails_the_integrity_check_is_not_a_backup():
    site = Site()
    conn = sqlite3.connect(str(site.catalogue))
    conn.execute("CREATE TABLE tracks (id TEXT PRIMARY KEY, deleted_at INTEGER)")
    conn.executemany("INSERT INTO tracks VALUES (?, NULL)",
                     [("track-%05d-%s" % (n, "x" * 200),) for n in range(2000)])
    conn.commit()
    page_size = conn.execute("PRAGMA page_size").fetchone()[0]
    conn.close()
    assert _run(site)[0] == 0
    good = _tree(site.backups)

    # Damage pages in the middle; the header stays valid, so it still opens.
    raw = bytearray(site.catalogue.read_bytes())
    assert len(raw) > page_size * 20
    for page in range(5, 15):
        raw[page * page_size:(page + 1) * page_size] = b"\xa5" * page_size
    site.catalogue.write_bytes(bytes(raw))

    code, out, err = _run(site, now=DAY + datetime.timedelta(days=1))

    assert code != 0 and out == "", (code, out)
    assert err.startswith("prisma-backup FAILED"), err
    assert _tree(site.backups) == good


def test_a_second_run_in_the_same_second_does_not_replace_the_first():
    site = Site()
    site.start_server()
    try:
        assert _run(site)[0] == 0
        first = _digest(site.backups / "prisma-state-20261001T031500Z" / "catalog.db")
        code, _, err = _run(site)
    finally:
        site.stop_server()
    assert code != 0 and "already exists" in err, (code, err)
    assert _digest(site.backups / "prisma-state-20261001T031500Z" / "catalog.db") == first


def test_a_half_backup_left_by_a_killed_run_is_cleared_by_the_next_good_one():
    site = Site()
    site.start_server()
    site.backups.mkdir()
    stale = site.backups / "prisma-state-20260901T031500Z.partial"
    stale.mkdir()
    (stale / "catalog.db").write_bytes(b"half")
    try:
        code, out, err = _run(site)
    finally:
        site.stop_server()
    assert code == 0, err
    assert not stale.exists()
    assert site.completed() == ["prisma-state-20261001T031500Z"]


# --- dry run --------------------------------------------------------------

def test_dry_run_checks_everything_and_writes_nothing():
    site = Site()
    site.start_server()
    try:
        before = _tree(site.root)
        code, out, err = _run(site, argv=["--dry-run"])
        assert code == 0 and err == "", (code, err)
        assert out.startswith("prisma-backup DRY-RUN OK ") and out.count("\n") == 1, out
        assert "tracks=3" in out and "would_remove=0" in out, out
        assert _tree(site.root) == before

        code, _, err = _run(site, argv=["--dry-run"], PRISMA_BACKUP_DIR=str(site.music / "b"))
        assert code != 0 and "inside the music directory" in err, (code, err)
        code, _, err = _run(site, argv=["--dry-run"], PRISMA_BACKUP_DIR=None)
        assert code != 0 and "PRISMA_BACKUP_DIR" in err, (code, err)
        assert _tree(site.root) == before
    finally:
        site.stop_server()


def test_dry_run_says_what_a_real_run_would_remove():
    site = Site()
    site.start_server()
    try:
        for day in range(7):
            assert _run(site, now=DAY + datetime.timedelta(days=day))[0] == 0
        before = _tree(site.backups)
        code, out, _ = _run(site, now=DAY + datetime.timedelta(days=8), argv=["--dry-run"])
    finally:
        site.stop_server()
    assert code == 0 and "would_remove=1" in out, out
    assert _tree(site.backups) == before


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
