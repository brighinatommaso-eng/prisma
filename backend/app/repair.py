"""One-off maintenance over the existing catalogue. No downloads.

Two corrections:

1. Track numbers. Album membership is matched loosely on purpose -- a single
   and its parent album name the same recording differently -- but that
   looseness leaked into the track number, so "Around the World (Radio Edit)"
   inherited the album version's number 7. A wrong number silently misorders
   the client, so the number is recomputed under the confident-match rule in
   metadata._confident_track_no and set to NULL when it cannot be trusted.

2. Embedded year. Tagging now takes the year from the album row rather than
   from whichever release that track resolved through, but files written before
   that change still carry the old value.

Both passes are idempotent: the file is only rewritten when the tags it holds
actually differ from the tags it should hold, so a second run is a no-op and
leaves every hash untouched. Nothing is moved or deleted.

    docker compose exec -T backend python -m app.repair
    docker compose exec -T backend python -m app.repair --dry-run
"""

import sys
from pathlib import Path
from typing import Any

from mutagen.mp4 import MP4

from . import db, downloader, metadata, ytm
from .paths import set_owner


def _current_tags(path: Path) -> dict[str, Any]:
    audio = MP4(str(path))
    track = (audio.get("trkn") or [(None, None)])[0]
    return {
        "year": (audio.get("\xa9day") or [None])[0],
        "track_no": track[0] if track else None,
    }


def recompute_track_numbers(dry_run: bool = False) -> list[str]:
    """Re-derive track_no for every live track under the confident-match rule."""
    notes: list[str] = []
    client = ytm._get_client()
    with db._lock:
        rows = db.connect().execute(
            "SELECT id, title, duration_s, track_no, album_browse_id FROM tracks "
            "WHERE deleted_at IS NULL ORDER BY id"
        ).fetchall()

    for row in rows:
        browse_id = row["album_browse_id"]
        if not browse_id:
            new_no = None
        else:
            try:
                album = client.get_album(browse_id)
            except Exception as exc:
                # Leave the stored value alone rather than nulling it on a
                # transient upstream failure.
                notes.append(
                    f"  {row['id']}: SKIPPED, get_album failed "
                    f"({type(exc).__name__}); track_no left at {row['track_no']}"
                )
                continue
            matched = metadata._find_track(album, row["id"], row["title"])
            new_no = (
                metadata._confident_track_no(
                    matched, row["id"], row["title"], row["duration_s"]
                )
                if matched else None
            )

        if new_no == row["track_no"]:
            notes.append(f"  {row['id']}: track_no {row['track_no']} unchanged")
            continue

        notes.append(
            f"  {row['id']}: track_no {row['track_no']} -> {new_no}  ({row['title']})"
        )
        if not dry_run:
            track = db.get_track(row["id"])
            if track is not None:
                track["track_no"] = new_no
                db.upsert_track(track)
    return notes


def retag_files(dry_run: bool = False) -> list[str]:
    """Bring embedded year and track number in line with the database."""
    notes: list[str] = []
    with db._lock:
        rows = db.connect().execute(
            "SELECT id FROM tracks WHERE deleted_at IS NULL ORDER BY id"
        ).fetchall()

    for row in rows:
        track = db.get_track(row["id"])
        if track is None:
            continue
        path = Path(track["file_path"] or "")
        if not path.is_file():
            notes.append(f"  {track['id']}: SKIPPED, file missing at {path}")
            continue

        album = db.get_album(track["album_id"]) if track.get("album_id") else None
        desired = {
            # The album row is the authority for the year.
            "year": str(album["year"]) if album and album.get("year") else None,
            "track_no": track.get("track_no"),
        }
        current = _current_tags(path)

        if current == desired:
            notes.append(
                f"  {track['id']}: tags already correct "
                f"(year={current['year']}, track_no={current['track_no']})"
            )
            continue

        notes.append(
            f"  {track['id']}: year {current['year']} -> {desired['year']}, "
            f"track_no {current['track_no']} -> {desired['track_no']}"
        )
        if dry_run:
            continue

        audio = MP4(str(path))
        if desired["year"]:
            audio["\xa9day"] = [desired["year"]]
        elif "\xa9day" in audio:
            del audio["\xa9day"]
        if desired["track_no"]:
            audio["trkn"] = [(int(desired["track_no"]), 0)]
        elif "trkn" in audio:
            del audio["trkn"]
        audio.save()
        set_owner(path)

        # Re-tagging rewrites the container, so the stored hash and size are
        # now stale. They must be recomputed or the client's integrity check
        # would reject a perfectly good file.
        track["sha256"] = downloader.sha256_of(path)
        track["file_bytes"] = path.stat().st_size
        db.upsert_track(track)
        notes.append(f"      rehashed -> {track['sha256'][:16]}... {track['file_bytes']} bytes")

    return notes


def main(argv: list[str] | None = None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    dry_run = "--dry-run" in argv

    print("=== pass 1: track numbers ===")
    for line in recompute_track_numbers(dry_run):
        print(line)
    print("\n=== pass 2: embedded tags ===")
    for line in retag_files(dry_run):
        print(line)
    if dry_run:
        print("\n(dry run: nothing written)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
