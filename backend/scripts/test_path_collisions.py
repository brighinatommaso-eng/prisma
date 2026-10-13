#!/usr/bin/env python3
"""Tests that two different video ids never end up sharing one file.

Runs with no network, against a throwaway music directory and database, never
the real library:

    python scripts/test_path_collisions.py

The cases are the four pairs found on the server: two recordings with the same
artist, album and title and different video ids, both recorded at one path, so
the second download was tagged into the first one's file. One stored hash of
each pair stopped matching, and the one that still matches belongs to the id
whose audio is not in the file.

downloader.run_pipeline itself is run -- it is what chooses the path and writes
the row -- with only its network parts replaced: the metadata lookup, the
audio download, the artwork fetch and the tag writer. The stand-in download
behaves like yt-dlp in the one way that matters here: it does not write over a
file that is already at the target path. Plain asserts in test_* functions,
like the other scripts.
"""

import hashlib
import shutil
import sys
from pathlib import Path

import guard

# Must happen before anything under app/ is imported: config reads the
# environment once, at import time.
_SCRATCH = guard.scratch_music_dir("prisma-test-collisions-")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import stubs  # noqa: E402

stubs.install_missing()

from app import db, deletion, downloader, metadata, tagging  # noqa: E402
from app.config import MUSIC_DIR  # noqa: E402
from app.paths import COVER_FILENAME, MAX_SEGMENT_CHARS, PathConflict  # noqa: E402

# Refuse to run against anything but the scratch directory.
guard.assert_scratch(_SCRATCH)

# (video id, video id, artist, album, title), as recorded on the server.
PAIRS = [
    ("_3sBwmP9n_g", "zVeVSydiT2c", "Kid Yugi, ANNA", "Anche gli Eroi Muoiono", "Push It"),
    ("9F1bJ8wDZFU", "yfCP6v00Nw8", "Kid Yugi, Ill Santo, FT Kings",
     "Anche gli Eroi Muoiono", "Berserker"),
    ("QConnicOrTQ", "qMc0eVNaTlA", "Kid Yugi", "The Globe", "Kabuki"),
    ("H3cZH9TYQmQ", "bfe3p7StXBM", "Kid Yugi", "Tutti i Nomi del Diavolo",
     "64 BARRE DA CENSURA (Red Bull 64 Bars)"),
]

COVER = b"\xff\xd8\xff cover bytes"

_meta: dict[str, dict] = {}
_downloads: list[tuple[str, Path, bool]] = []
_fail_download: set[str] = set()
_artwork_available = True


def _fake_metadata(video_id):
    return dict(_meta[video_id])


def _fake_download(video_id, audio_path, on_progress):
    """Stands in for yt-dlp, which leaves a file already at the target alone
    and reports it as downloaded."""
    if video_id in _fail_download:
        raise RuntimeError("ERROR: [youtube] " + video_id + ": Video unavailable")
    wrote = not audio_path.exists()
    if wrote:
        audio_path.write_bytes(_audio(video_id))
    _downloads.append((video_id, audio_path, wrote))
    return audio_path


def _fake_write_tags(path, meta, cover_bytes):
    """Tagging rewrites the container, so the file changes on every run."""
    with path.open("ab") as handle:
        handle.write(b"|tags:" + meta["video_id"].encode())


def _fake_artwork(url):
    return COVER if _artwork_available else None


metadata.fetch_track_metadata = _fake_metadata
downloader._download_audio = _fake_download
downloader._fetch_artwork = _fake_artwork
tagging.write_tags = _fake_write_tags
downloader.palette.extract = lambda data: ["#101010"]


def _audio(video_id):
    return b"audio:" + video_id.encode()


def _sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _reset():
    global _artwork_available
    _meta.clear()
    _downloads.clear()
    _fail_download.clear()
    _artwork_available = True
    with db._lock:
        conn = db.connect()
        for table in ("tracks", "albums", "jobs"):
            conn.execute("DELETE FROM " + table)
        conn.commit()
    for entry in MUSIC_DIR.iterdir():
        if entry.name != ".prisma":
            shutil.rmtree(entry)


def _describe(video_id, artist, album, title):
    _meta[video_id] = {
        "video_id": video_id, "title": title, "artist": artist, "album": album,
        "album_raw": album, "album_release_title": album, "album_browse_id": None,
        "year": 2024, "track_no": None, "duration_s": 200,
        "artwork_url": "https://example.test/cover.jpg",
    }


def _natural(artist, album, title):
    return MUSIC_DIR / artist / album / (title + ".m4a")


def _bracketed(artist, album, title, video_id):
    return MUSIC_DIR / artist / album / f"{title} [{video_id}].m4a"


def _record_collided(written_by, tagged_by, artist, album, title, with_file):
    """The state found on the server: both rows live at one path.

    written_by downloaded the file. tagged_by came second: yt-dlp left the
    file in place and the pipeline wrote tagged_by's tags into it and recorded
    its hash. So the file is written_by's audio, and the only stored hash that
    matches it is tagged_by's.
    """
    shared = _natural(artist, album, title)
    cover = shared.parent / COVER_FILENAME
    album_id = db.upsert_album(artist, album, album, None, 2024, str(cover), ["#101010"])
    original = _audio(written_by) + b"|tags:" + written_by.encode()
    retagged = original + b"|tags:" + tagged_by.encode()
    for video_id, recorded in ((written_by, original), (tagged_by, retagged)):
        _describe(video_id, artist, album, title)
        db.upsert_track({
            "id": video_id, "title": title, "artist": artist, "album": album,
            "album_id": album_id, "file_path": str(shared), "file_bytes": len(recorded),
            "sha256": hashlib.sha256(recorded).hexdigest(),
        })
    if with_file:
        shared.parent.mkdir(parents=True, exist_ok=True)
        shared.write_bytes(retagged)
        cover.write_bytes(COVER)
    return shared


def _assert_separate_and_intact(first, second):
    """Both ids live, at two paths, each file holding its own audio and
    matching its own stored hash."""
    rows = [db.get_track(first), db.get_track(second)]
    assert all(r is not None and r["deleted_at"] is None for r in rows), rows
    paths = [Path(r["file_path"]) for r in rows]
    assert paths[0] != paths[1], paths
    for video_id, row, path in zip((first, second), rows, paths):
        assert path.is_file(), path
        assert path.read_bytes().startswith(_audio(video_id) + b"|tags:" + video_id.encode()), (
            video_id, path.read_bytes())
        assert b"tags:" + (second if video_id == first else first).encode() not in path.read_bytes()
        assert row["sha256"] == _sha(path), video_id
        assert row["file_bytes"] == path.stat().st_size, video_id
    with db._lock:
        count = db.connect().execute("SELECT COUNT(*) c FROM tracks").fetchone()["c"]
    assert count == 2, count
    return paths


# --- the rule -------------------------------------------------------------

def test_the_second_id_gets_its_own_path_and_both_are_recorded():
    for first, second, artist, album, title in PAIRS:
        _reset()
        _describe(first, artist, album, title)
        _describe(second, artist, album, title)

        downloader.run_pipeline(first)
        downloader.run_pipeline(second)

        paths = _assert_separate_and_intact(first, second)
        assert paths[0] == _natural(artist, album, title), paths[0]
        assert paths[1] == _bracketed(artist, album, title, second), paths[1]
        # One cover.jpg per album folder, shared, written once.
        assert (paths[0].parent / COVER_FILENAME).read_bytes() == COVER
        assert sorted(p.name for p in paths[0].parent.iterdir()) == sorted(
            [paths[0].name, paths[1].name, COVER_FILENAME])


def test_downloading_either_again_does_not_move_it():
    for first, second, artist, album, title in PAIRS:
        _reset()
        _describe(first, artist, album, title)
        _describe(second, artist, album, title)
        downloader.run_pipeline(first)
        downloader.run_pipeline(second)
        before = [db.get_track(first)["file_path"], db.get_track(second)["file_path"]]

        downloader.run_pipeline(second)
        downloader.run_pipeline(first)

        after = [db.get_track(first)["file_path"], db.get_track(second)["file_path"]]
        assert after == before, (before, after)
        _assert_separate_and_intact(first, second)
        assert len(list(Path(before[0]).parent.glob("*.m4a"))) == 2


def test_a_deleted_track_coming_back_does_not_take_a_path_now_in_use():
    """How two live ids came to share a path: the first was deleted, the second
    took the free path, and the first, downloaded again, was told the file at
    its old path was its own."""
    for first, second, artist, album, title in PAIRS:
        _reset()
        _describe(first, artist, album, title)
        _describe(second, artist, album, title)
        downloader.run_pipeline(first)
        deletion.delete_track(first)
        downloader.run_pipeline(second)
        shared = _natural(artist, album, title)
        assert db.get_track(second)["file_path"] == str(shared)
        held = shared.read_bytes()

        downloader.run_pipeline(first)

        paths = _assert_separate_and_intact(first, second)
        assert paths == [_bracketed(artist, album, title, first), shared], paths
        assert shared.read_bytes() == held


# --- undoing a collision already in the catalogue ---------------------------

def test_collided_pair_with_the_file_present_leaves_it_to_neither():
    """The file is one id's audio under the other id's tags and hash, so it is
    neither track's: both are downloaded to their own paths and the file stays
    exactly as it was, with no row pointing at it."""
    for first, second, artist, album, title in PAIRS:
        for written_by, tagged_by in ((first, second), (second, first)):
            for order in ((first, second), (second, first)):
                _reset()
                shared = _record_collided(written_by, tagged_by, artist, album, title,
                                          with_file=True)
                held = shared.read_bytes()
                waiting = db.get_track(order[1])

                downloader.run_pipeline(order[0])

                assert shared.read_bytes() == held
                assert db.get_track(order[0])["file_path"] == str(
                    _bracketed(artist, album, title, order[0]))
                # The one left behind is no longer recorded at the file either:
                # alone there, with a hash that may match, it would pass for
                # its owner. Its row now names a path with nothing at it yet.
                left = db.get_track(order[1])
                assert left["file_path"] == str(_bracketed(artist, album, title, order[1]))
                assert not Path(left["file_path"]).exists()
                assert (left["sha256"], left["album_id"], left["deleted_at"]) == (
                    waiting["sha256"], waiting["album_id"], None)
                assert db.path_claims(str(shared)) == []

                downloader.run_pipeline(order[1])

                paths = _assert_separate_and_intact(first, second)
                assert paths == [_bracketed(artist, album, title, first),
                                 _bracketed(artist, album, title, second)], paths
                assert shared.read_bytes() == held
                assert db.path_claims(str(shared)) == []


def test_collided_pair_with_the_files_gone_is_separated_in_either_order():
    for first, second, artist, album, title in PAIRS:
        for order in ((first, second), (second, first)):
            _reset()
            shared = _record_collided(first, second, artist, album, title, with_file=False)
            assert not shared.parent.exists()

            for video_id in order:
                downloader.run_pipeline(video_id)

            # With no file to decide it, the lower id keeps the shared path.
            keeper, mover = min(first, second), max(first, second)
            paths = _assert_separate_and_intact(first, second)
            assert db.get_track(keeper)["file_path"] == str(shared), order
            assert db.get_track(mover)["file_path"] == str(
                _bracketed(artist, album, title, mover)), order
            assert len(paths) == 2
            # The cover went with the files and comes back with the first of them.
            cover = shared.parent / COVER_FILENAME
            assert cover.read_bytes() == COVER
            album_row = db.get_album(db.get_track(keeper)["album_id"])
            assert album_row["cover_path"] == str(cover) and Path(album_row["cover_path"]).is_file()
            with db._lock:
                albums = db.connect().execute("SELECT COUNT(*) c FROM albums").fetchone()["c"]
            assert albums == 1, albums


def test_a_failed_download_leaves_the_row_and_the_files_as_they_were():
    first, second, artist, album, title = PAIRS[0]
    _reset()
    shared = _record_collided(first, second, artist, album, title, with_file=True)
    held = shared.read_bytes()
    row = db.get_track(first)
    listing = sorted(p.name for p in shared.parent.iterdir())
    _fail_download.add(first)

    try:
        downloader.run_pipeline(first)
    except RuntimeError as exc:
        assert "Video unavailable" in str(exc)
    else:
        raise AssertionError("the pipeline swallowed a failed download")

    assert db.get_track(first) == row
    assert db.get_track(second)["file_path"] == str(shared)
    assert shared.read_bytes() == held
    assert sorted(p.name for p in shared.parent.iterdir()) == listing


def test_a_missing_cover_stays_missing_when_the_artwork_cannot_be_fetched():
    """Not fatal, and not papered over: the album still names a cover that is
    not there, so the cover endpoint keeps answering 410."""
    global _artwork_available
    first, second, artist, album, title = PAIRS[2]
    _reset()
    shared = _record_collided(first, second, artist, album, title, with_file=False)
    _artwork_available = False

    downloader.run_pipeline(first)

    cover = shared.parent / COVER_FILENAME
    assert not cover.exists()
    assert db.get_album(db.get_track(first)["album_id"])["cover_path"] == str(cover)
    assert db.get_track(first)["sha256"] == _sha(shared)


# --- edges of the rule ------------------------------------------------------

def test_a_live_track_alone_at_its_path_is_downloaded_back_to_it():
    first, _, artist, album, title = PAIRS[1]
    _reset()
    _describe(first, artist, album, title)
    downloader.run_pipeline(first)
    row = db.get_track(first)
    Path(row["file_path"]).unlink()
    (Path(row["file_path"]).parent / COVER_FILENAME).unlink()

    downloader.run_pipeline(first)

    again = db.get_track(first)
    assert again["file_path"] == row["file_path"] == str(_natural(artist, album, title))
    assert again["sha256"] == _sha(again["file_path"])
    assert again["album_id"] == row["album_id"]
    assert _downloads[-1] == (first, Path(row["file_path"]), True)
    assert (Path(row["file_path"]).parent / COVER_FILENAME).read_bytes() == COVER


def test_a_file_that_is_not_the_recorded_audio_is_never_written_over():
    """yt-dlp would leave such a file in place and the pipeline would tag and
    record it as this track. The track goes to its own path instead."""
    first, _, artist, album, title = PAIRS[3]
    _reset()
    _describe(first, artist, album, title)
    downloader.run_pipeline(first)
    natural = Path(db.get_track(first)["file_path"])
    natural.write_bytes(b"something else entirely")

    downloader.run_pipeline(first)

    moved = Path(db.get_track(first)["file_path"])
    assert moved == _bracketed(artist, album, title, first), moved
    assert natural.read_bytes() == b"something else entirely"
    assert moved.read_bytes().startswith(_audio(first))
    assert db.get_track(first)["sha256"] == _sha(moved)


def test_a_wrong_file_at_the_tracks_own_bracketed_path_fails_the_download():
    """There is no further name to fall back to, and writing over the file is
    not an option, so the job fails and says why."""
    first, second, artist, album, title = PAIRS[0]
    _reset()
    _describe(first, artist, album, title)
    _describe(second, artist, album, title)
    downloader.run_pipeline(first)
    downloader.run_pipeline(second)
    own = Path(db.get_track(second)["file_path"])
    assert own == _bracketed(artist, album, title, second)
    own.write_bytes(b"something else entirely")
    row = db.get_track(second)
    calls = len(_downloads)

    try:
        downloader.run_pipeline(second)
    except PathConflict as exc:
        assert str(own) in str(exc), exc
    else:
        raise AssertionError("a file that is not the recorded audio was accepted")

    assert len(_downloads) == calls
    assert own.read_bytes() == b"something else entirely"
    assert db.get_track(second) == row


def test_the_video_id_survives_a_title_at_the_length_limit():
    long_title = "L" * (MAX_SEGMENT_CHARS + 40)
    _reset()
    for video_id in ("aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc"):
        _describe(video_id, "Artist", "Album", long_title)
        downloader.run_pipeline(video_id)

    names = [Path(db.get_track(v)["file_path"]).name
             for v in ("aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc")]
    assert len(set(names)) == 3, names
    assert names[0] == "L" * MAX_SEGMENT_CHARS + ".m4a"
    assert names[1].endswith(" [bbbbbbbbbbb].m4a") and names[2].endswith(" [ccccccccccc].m4a")
    assert all(len(name) <= MAX_SEGMENT_CHARS + len(".m4a") for name in names), names


def test_the_bracketed_name_is_safe_on_linux_and_smb():
    _reset()
    for video_id in ("first-id_01", "other-id_02"):
        _describe(video_id, "AC/DC", "Who Made Who?", 'What: "Now" <or> never*|')
        downloader.run_pipeline(video_id)

    name = Path(db.get_track("other-id_02")["file_path"]).name
    assert name == "What Now or never [other-id_02].m4a", name
    assert not set(name) & set('/\\:*?"<>|'), name


def main() -> int:
    MUSIC_DIR.mkdir(parents=True, exist_ok=True)
    db.connect()
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
