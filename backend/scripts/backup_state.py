#!/usr/bin/env python3
"""Daily backup of Prisma's state directory. Runs on the Docker host, from cron.

Prisma keeps its catalogue and the favourites and playlists in .prisma, inside
the music folder, because that is the one path guaranteed to persist. It also
means that whatever empties the music folder can take them along. This script
copies the two files that cannot be regenerated -- catalog.db and
collection.json -- to a directory that is somewhere else, once a day, and
keeps the last seven copies.

    python3 backend/scripts/backup_state.py             # back up and rotate
    python3 backend/scripts/backup_state.py --dry-run   # check, write nothing

It runs on the host and not in the container on purpose: the backup directory
is not mounted into the container, so nothing the backend does can reach it.
It needs nothing but the host's python3 (3.7 or later) and no root, only read
access to the state directory and write access to the backup directory.

Two settings, read from the environment or, failing that, from the .env file
next to docker-compose.yml (--env-file names another):

    PRISMA_MUSIC_HOST_DIR   the music folder on the host; the default is the
                            one docker-compose.yml uses
    PRISMA_BACKUP_DIR       where the backups go. No default: the script
                            refuses to run without it, and refuses a directory
                            inside the music folder, which would defeat it.

How the catalogue is copied matters. It is SQLite in WAL mode, and the server
is running: recent writes are in catalog.db-wal, not yet in catalog.db, so
copying the file would produce a database that is missing them or is not
consistent at all. The copy is made with SQLite's own backup API, from a
connection opened read-only, which takes one consistent snapshot while the
server keeps working and never writes to the database. The copy is then
checked with PRAGMA integrity_check and switched out of WAL mode, so that it
is one self-contained file.

A backup is a directory, prisma-state-<UTC timestamp>, holding catalog.db,
collection.json when there is one, and backup.json. It is built under a
.partial name and renamed only after the check passes, so a directory with the
final name is always a complete backup. Rotation happens after that, and only
then: a run that fails removes nothing. It deletes nothing but directories of
its own, recognised by their exact name and their backup.json.

Two verified backups are still not allowed to rotate anything out, and count
as failures so that somebody looks. One is a catalogue with no tracks while an
earlier backup has some: that is what a wiped state directory looks like once
the server has started again on a fresh catalogue, and a week of such nights
would otherwise replace every real backup with an empty one. The other is a
backup whose name does not sort last, which means the clock was wrong then or
is wrong now. In both cases the new copy is kept and nothing is removed.

Exit code 0 and one line starting "prisma-backup OK" on success; non-zero and
one line starting "prisma-backup FAILED" on standard error otherwise.

It imports nothing from the application, so it runs from a bare checkout.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import sqlite3
import sys
from pathlib import Path

KEEP = 7

# The default docker-compose.yml gives PRISMA_MUSIC_HOST_DIR.
DEFAULT_MUSIC_HOST_DIR = "/opt/prisma/music"

STATE_DIRNAME = ".prisma"
CATALOGUE = "catalog.db"
COLLECTION = "collection.json"
MANIFEST = "backup.json"

_STAMP = r"prisma-state-\d{8}T\d{6}Z"
COMPLETED_NAME = re.compile(r"^" + _STAMP + r"$")
PARTIAL_SUFFIX = ".partial"
PARTIAL_NAME = re.compile(r"^" + _STAMP + re.escape(PARTIAL_SUFFIX) + r"$")

# docker-compose.yml sits two levels above this file, and its .env beside it.
DEFAULT_ENV_FILE = Path(__file__).resolve().parent.parent.parent / ".env"


class BackupError(Exception):
    """The backup cannot be made, or was made and cannot be trusted."""


def read_env_file(path):
    """KEY=VALUE lines of a compose .env file. Missing file: no settings."""
    values = {}
    try:
        text = Path(path).read_text(encoding="utf-8")
    except FileNotFoundError:
        return values
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, value = line.split("=", 1)
        value = value.strip()
        if value[:1] in ("\"", "'") and value.find(value[0], 1) > 0:
            # Quoted: everything up to the closing quote, # included.
            value = value[1:value.find(value[0], 1)]
        else:
            # Unquoted: a # after whitespace starts a comment, as in compose.
            value = re.split(r"\s+#", value, maxsplit=1)[0].strip()
        values[key.strip()] = value
    return values


def _setting(name, environ, env_file_values):
    """The environment wins over the .env file, as it does for compose."""
    value = environ.get(name)
    if value is None or not value.strip():
        value = env_file_values.get(name)
    return value.strip() if value and value.strip() else None


def _resolved(path):
    return os.path.normcase(os.path.realpath(str(path)))


def is_inside(inner, outer):
    """True when `inner` is `outer` or anywhere below it, links resolved."""
    inner, outer = _resolved(inner), _resolved(outer)
    try:
        return os.path.commonpath([inner, outer]) == outer
    except ValueError:
        # Different drives on Windows: certainly not inside.
        return False


def _is_own_directory(entry, pattern):
    return bool(pattern.match(entry.name)) and entry.is_dir() and not entry.is_symlink()


def _recorded_tracks(backup):
    """The track count a completed backup wrote in its manifest, or None."""
    try:
        with open(str(backup / MANIFEST), encoding="utf-8") as handle:
            tracks = json.load(handle).get("tracks")
    except (OSError, ValueError, AttributeError):
        return None
    return tracks if isinstance(tracks, int) else None


def completed_backups(backup_dir):
    """This script's finished backups in backup_dir, newest first."""
    if not backup_dir.is_dir():
        return []
    found = [entry for entry in backup_dir.iterdir()
             if _is_own_directory(entry, COMPLETED_NAME) and (entry / MANIFEST).is_file()]
    # The timestamp is fixed-width, so the name orders them.
    return sorted(found, key=lambda entry: entry.name, reverse=True)


def stale_partials(backup_dir, older_than):
    """Half-built backups left by runs that were killed before `older_than`."""
    if not backup_dir.is_dir():
        return []
    return sorted(
        (entry for entry in backup_dir.iterdir()
         if _is_own_directory(entry, PARTIAL_NAME) and entry.name < older_than),
        key=lambda entry: entry.name)


def _open_read_only(catalogue):
    """A connection that cannot write to the database.

    While the server has the catalogue open there is a -wal beside it, and
    mode=ro reads through it without writing to it or to the database. With
    no -wal the server is not running and everything is in the main file; but
    the file still says "WAL mode", and a plain read-only connection would
    create an empty -wal and -shm next to it -- inside the music folder.
    immutable=1 makes SQLite read the file as it is and create nothing.
    """
    uri = Path(catalogue).resolve().as_uri() + "?mode=ro"
    if not os.path.exists(str(catalogue) + "-wal"):
        uri += "&immutable=1"
    return sqlite3.connect(uri, uri=True)


def _count_tracks(conn):
    """Live tracks, for the log line. None when the table is not there yet."""
    try:
        return conn.execute(
            "SELECT COUNT(*) FROM tracks WHERE deleted_at IS NULL").fetchone()[0]
    except sqlite3.Error:
        return None


def _sha256(path):
    digest = hashlib.sha256()
    with open(str(path), "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy_catalogue(source, target):
    """A consistent, checked copy of a live SQLite database. Returns the number
    of live tracks in it (None if it has no tracks table)."""
    src = _open_read_only(source)
    try:
        dst = sqlite3.connect(str(target))
        try:
            # One step: the whole database under a single read snapshot.
            src.backup(dst)
            verdict = dst.execute("PRAGMA integrity_check").fetchall()
            if verdict != [("ok",)]:
                problems = "; ".join(str(row[0]) for row in verdict[:3])
                raise BackupError("the copy of %s failed its integrity check: %s"
                                  % (CATALOGUE, problems))
            # The copy inherits WAL mode from the source. Out of it, the
            # backup is a single file with nothing beside it to lose.
            dst.execute("PRAGMA journal_mode=DELETE")
            tracks = _count_tracks(dst)
        finally:
            dst.close()
    finally:
        src.close()
    return tracks


def _plan(environ, env_file):
    """Read and check the settings. Returns (state_dir, backup_dir)."""
    from_file = read_env_file(env_file)
    backup_setting = _setting("PRISMA_BACKUP_DIR", environ, from_file)
    if backup_setting is None:
        raise BackupError(
            "PRISMA_BACKUP_DIR is not set. Set it in the environment or in %s to a "
            "directory outside the music folder; there is no default." % env_file)
    music_dir = Path(_setting("PRISMA_MUSIC_HOST_DIR", environ, from_file)
                     or DEFAULT_MUSIC_HOST_DIR)
    backup_dir = Path(backup_setting)

    if is_inside(backup_dir, music_dir):
        raise BackupError(
            "PRISMA_BACKUP_DIR (%s) is inside the music directory (%s). Whatever empties "
            "the music folder would take the backups with it; choose a directory "
            "somewhere else." % (backup_dir, music_dir))

    state_dir = music_dir / STATE_DIRNAME
    if not (state_dir / CATALOGUE).is_file():
        raise BackupError("there is no %s in %s; check PRISMA_MUSIC_HOST_DIR."
                          % (CATALOGUE, state_dir))
    return state_dir, backup_dir


def _name_for(now):
    return "prisma-state-" + now.astimezone(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def dry_run(state_dir, backup_dir, now):
    """Everything a real run checks before it writes. Creates nothing."""
    src = _open_read_only(state_dir / CATALOGUE)
    try:
        verdict = src.execute("PRAGMA quick_check").fetchall()
        if verdict != [("ok",)]:
            raise BackupError("%s does not pass a quick check: %s"
                              % (CATALOGUE, "; ".join(str(row[0]) for row in verdict[:3])))
        tracks = _count_tracks(src)
    finally:
        src.close()
    name = _name_for(now)
    surplus = max(len(completed_backups(backup_dir)) + 1 - KEEP, 0)
    return ("prisma-backup DRY-RUN OK would_write=%s tracks=%s %s=%s would_remove=%d dir=%s"
            % (name, "n/a" if tracks is None else tracks, COLLECTION,
               "yes" if (state_dir / COLLECTION).is_file() else "no", surplus, backup_dir))


def backup(state_dir, backup_dir, now):
    """Make one backup, then rotate. Returns the line for the log."""
    name = _name_for(now)
    final = backup_dir / name
    partial = backup_dir / (name + PARTIAL_SUFFIX)
    backup_dir.mkdir(parents=True, exist_ok=True)
    if final.exists() or partial.exists():
        raise BackupError("%s already exists in %s; not replacing it." % (name, backup_dir))

    partial.mkdir()
    try:
        copy = partial / CATALOGUE
        tracks = copy_catalogue(state_dir / CATALOGUE, copy)
        has_collection = (state_dir / COLLECTION).is_file()
        if has_collection:
            # Written by the server with a rename, so it is never half a file.
            shutil.copyfile(str(state_dir / COLLECTION), str(partial / COLLECTION))
        size = copy.stat().st_size
        manifest = {
            "created_at": now.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "catalog_bytes": size,
            "catalog_sha256": _sha256(copy),
            "tracks": tracks,
            "collection_json": has_collection,
        }
        with open(str(partial / MANIFEST), "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, indent=2)
            handle.write("\n")
        os.rename(str(partial), str(final))
    except BaseException:
        # Only the directory this run created a moment ago, in the backup
        # directory. Nothing that was good before is touched.
        shutil.rmtree(str(partial), ignore_errors=True)
        raise

    # Reached only with a complete, checked backup in place.
    ordered = completed_backups(backup_dir)
    if ordered[0].name != name:
        raise BackupError(
            "%s was written, but %s holds backups with newer names (%s): the clock is "
            "or was wrong. Nothing was rotated; sort that out by hand."
            % (name, backup_dir, ordered[0].name))
    if not tracks and any((_recorded_tracks(old) or 0) > 0 for old in ordered[1:]):
        raise BackupError(
            "the catalogue has no tracks, but earlier backups do. The copy was kept as "
            "%s and nothing was rotated, so the earlier backups stay until this is "
            "looked at." % name)
    removed = 0
    for old in ordered[KEEP:]:
        shutil.rmtree(str(old))
        removed += 1
    for leftover in stale_partials(backup_dir, older_than=name):
        shutil.rmtree(str(leftover))
    kept = len(completed_backups(backup_dir))
    return ("prisma-backup OK %s %s=%d bytes tracks=%s %s=%s kept=%d removed=%d dir=%s"
            % (name, CATALOGUE, size, "n/a" if tracks is None else tracks, COLLECTION,
               "yes" if has_collection else "no", kept, removed, backup_dir))


def main(argv=None, environ=None, now=None, env_file=None):
    parser = argparse.ArgumentParser(
        description="Back up Prisma's catalogue and collection, and keep the last %d." % KEEP)
    parser.add_argument("--dry-run", action="store_true",
                        help="check the settings and the catalogue; write and remove nothing")
    parser.add_argument("--env-file", default=None,
                        help="the .env to read settings from (default: the one next to "
                             "docker-compose.yml)")
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)
    environ = os.environ if environ is None else environ
    now = now or datetime.datetime.now(datetime.timezone.utc)
    env_file = Path(args.env_file) if args.env_file else Path(env_file or DEFAULT_ENV_FILE)

    try:
        state_dir, backup_dir = _plan(environ, env_file)
        line = (dry_run if args.dry_run else backup)(state_dir, backup_dir, now)
    except (BackupError, sqlite3.Error, OSError) as exc:
        print("prisma-backup FAILED: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        return 1
    print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
