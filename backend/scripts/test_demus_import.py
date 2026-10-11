#!/usr/bin/env python3
"""Tests for parsing a playlist exported by Demus.

Runs with no dependencies and no network, against the two real exports in
scripts/fixtures (lyrics removed):

    python scripts/test_demus_import.py
    docker compose exec -T backend python scripts/test_demus_import.py

Plain asserts in test_* functions, like the other scripts. The parser touches
neither the database nor the library. The endpoint tests call the FastAPI app
directly as an ASGI application, with no HTTP client; they need the whole app
to import, so on a machine without ytmusicapi they are skipped and the parser
ones still run.
"""

import asyncio
import json
import lzma
import os
import shutil
import sys
import tempfile
from pathlib import Path

# Must happen before anything under app/ is imported: config reads the
# environment once, at import time. Only importing app.main needs it.
_SCRATCH = Path(tempfile.mkdtemp(prefix="prisma-test-demus-"))
os.environ["PRISMA_MUSIC_DIR"] = str(_SCRATCH / "music")
os.environ["PRISMA_STATE_DIR"] = str(_SCRATCH / "music" / ".prisma")
os.environ["PRISMA_DB_PATH"] = str(_SCRATCH / "music" / ".prisma" / "catalog.db")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import demus  # noqa: E402

try:
    from app.main import app
except ImportError:
    app = None

FIXTURES = Path(__file__).resolve().parent / "fixtures"
RAP = FIXTURES / "demus-rap.playlist"
SAD = FIXTURES / "demus-sad.playlist"

SONG = {"id": "abcdefghijk", "title": "T", "artistName": "A", "albumTitle": "Al",
        "artwork": "https://yt3.googleusercontent.com/x=w60-h60-l90-rj", "duration": 61}


def _xz(document) -> bytes:
    return lzma.compress(json.dumps(document).encode("utf-8"))


def _playlist(**changes) -> dict:
    return {"title": "P", "itemCount": 1, "createdDate": "2026-06-21T14:38:56.787Z",
            "thumbnailData": None, "thumbnailUrl": None, "songs": [dict(SONG)], **changes}


def _refused(data: bytes) -> str:
    """The message the parser refuses `data` with."""
    try:
        demus.parse(data)
    except demus.DemusError as exc:
        return str(exc)
    raise AssertionError("the parser accepted it")


def _raw(path: Path) -> dict:
    """The export read independently of the parser."""
    return json.loads(lzma.decompress(path.read_bytes()))


# --- the real exports ----------------------------------------------------

def _check_fixture(path, name, count, minutes):
    raw = _raw(path)
    parsed = demus.parse(path.read_bytes())

    assert parsed["name"] == name == raw["title"]
    assert len(parsed["songs"]) == count == len(raw["songs"])
    # The file's order, and the video id exactly as exported.
    assert [s["video_id"] for s in parsed["songs"]] == [s["id"] for s in raw["songs"]]
    for song, source in zip(parsed["songs"], raw["songs"]):
        assert set(song) == {"video_id", "title", "artist", "album",
                             "artwork_url", "duration_s"}, song
        assert isinstance(song["video_id"], str) and song["video_id"]
        assert type(song["duration_s"]) is int, song
        assert song["title"] == source["title"]
        assert song["artist"] == source["artistName"]
        assert song["album"] == source["albumTitle"]
    total = sum(s["duration_s"] for s in parsed["songs"]) / 60
    assert abs(total - minutes) < 1, total


def test_rap_fixture_parses():
    _check_fixture(RAP, "Rap", 33, 94)


def test_sad_fixture_parses():
    _check_fixture(SAD, "Sad", 53, 200)


def test_fixtures_share_no_tracks():
    rap = {s["video_id"] for s in demus.parse(RAP.read_bytes())["songs"]}
    sad = {s["video_id"] for s in demus.parse(SAD.read_bytes())["songs"]}
    assert not rap & sad


def test_created_at_is_unix_seconds():
    # 2026-06-21T14:38:56.787Z and 2026-06-17T18:58:55.832Z, truncated.
    assert demus.parse(RAP.read_bytes())["created_at"] == 1782052736
    assert demus.parse(SAD.read_bytes())["created_at"] == 1781722735


def test_album_id_and_lyrics_do_not_leak():
    for path in (RAP, SAD):
        raw = _raw(path)
        blob = json.dumps(demus.parse(path.read_bytes()))
        assert "lyrics" not in blob and "albumId" not in blob
        for source in raw["songs"]:
            # Some of these are channel ids rather than album browse ids.
            assert source["albumId"] not in blob, source["albumId"]
            assert source["artistId"] not in blob, source["artistId"]


def test_fixture_artwork_is_normalised():
    for path in (RAP, SAD):
        raw = _raw(path)
        for song, source in zip(demus.parse(path.read_bytes())["songs"], raw["songs"]):
            url = song["artwork_url"]
            if "googleusercontent.com/" in source["artwork"]:
                assert url.endswith("=w544-h544-l90-rj"), url
                assert url.split("=")[0] == source["artwork"].split("=")[0]
            else:
                # A video thumbnail: its last "=" starts a signature, not a size.
                assert url == source["artwork"], url
    # Both kinds are really present, so neither branch above is vacuous.
    hosts = {s["artwork"].split("/")[2] for s in _raw(RAP)["songs"]}
    assert "i.ytimg.com" in hosts and "yt3.googleusercontent.com" in hosts, hosts


def test_artwork_rewrite_rules():
    cases = {
        "https://yt3.googleusercontent.com/abc=w60-h60-l90-rj":
            "https://yt3.googleusercontent.com/abc=w544-h544-l90-rj",
        "https://lh3.googleusercontent.com/abc=w60-h60-s-l90-rj":
            "https://lh3.googleusercontent.com/abc=w544-h544-l90-rj",
        # No size suffix: kept as it is.
        "https://lh3.googleusercontent.com/abc": "https://lh3.googleusercontent.com/abc",
        "https://i.ytimg.com/vi/x/hq720.jpg?sqp=-oaymwE=&rs=AOn4CLA6":
            "https://i.ytimg.com/vi/x/hq720.jpg?sqp=-oaymwE=&rs=AOn4CLA6",
        # Not googleusercontent, whatever it ends with.
        "https://googleusercontent.com.example.test/abc=w60-h60":
            "https://googleusercontent.com.example.test/abc=w60-h60",
        # A query string: its last "=" belongs to a parameter, not a size.
        "https://lh3.googleusercontent.com/a?x=1&sig=abc":
            "https://lh3.googleusercontent.com/a?x=1&sig=abc",
        "https://lh3.googleusercontent.com/abc=w60-h60\n": None,
        "https://lh3.googleusercontent.com/a b=w60-h60": None,
        "javascript:alert(1)": None,
        "file:///etc/passwd": None,
        "": None,
    }
    for artwork, expected in cases.items():
        parsed = demus.parse(_xz(_playlist(songs=[{**SONG, "artwork": artwork}])))
        assert parsed["songs"][0]["artwork_url"] == expected, artwork


# --- shapes the exports do not show but the parser must survive ----------

def test_field_order_and_unknown_fields_do_not_matter():
    document = {"songs": [{"lyrics": "la la", "duration": 5, "genre": "x", "id": "v1",
                           "albumId": "UCchannel", "somethingNew": 1}],
                "futureField": {"a": 1}, "title": "Later"}
    assert demus.parse(_xz(document)) == {
        "name": "Later", "created_at": None,
        "songs": [{"video_id": "v1", "title": None, "artist": None, "album": None,
                   "artwork_url": None, "duration_s": 5}],
    }


def test_empty_playlist_and_repeated_songs():
    assert demus.parse(_xz(_playlist(songs=[])))["songs"] == []
    twice = demus.parse(_xz(_playlist(songs=[dict(SONG), dict(SONG)])))
    assert [s["video_id"] for s in twice["songs"]] == ["abcdefghijk", "abcdefghijk"]


def test_created_date_without_fraction_or_with_offset():
    assert demus.parse(_xz(_playlist(createdDate="2026-06-21T14:38:56Z")))["created_at"] == 1782052736
    assert demus.parse(_xz(_playlist(createdDate="2026-06-21T16:38:56+02:00")))["created_at"] == 1782052736
    assert demus.parse(_xz(_playlist(createdDate=None)))["created_at"] is None


# --- malformed input -----------------------------------------------------

def test_empty_body():
    assert "empty" in _refused(b"")


def test_random_bytes_are_not_xz():
    assert "not an xz file" in _refused(bytes(range(256)) * 4)
    assert "not an xz file" in _refused(b'{"title": "plain json"}')


def test_truncated_xz():
    data = RAP.read_bytes()
    for cut in (len(data) - 1, len(data) // 2, 20, 7):
        assert "truncated" in _refused(data[:cut]), cut


def test_corrupt_xz():
    data = bytearray(RAP.read_bytes())
    data[len(data) // 2] ^= 0xFF
    assert "corrupt" in _refused(bytes(data))


def test_data_after_the_stream():
    assert "after the end" in _refused(RAP.read_bytes() + b"extra")


def test_xz_of_non_json():
    assert "not JSON" in _refused(lzma.compress(b"this is not json"))
    assert "not UTF-8" in _refused(lzma.compress(b"\xff\xfe\x00{"))
    assert "not JSON" in _refused(lzma.compress(b""))
    # Deep enough to exhaust the JSON parser's recursion.
    assert "not JSON" in _refused(lzma.compress(b"[" * 200_000))


def test_json_of_the_wrong_shape():
    assert "not a JSON object" in _refused(_xz([1, 2, 3]))
    assert "not a JSON object" in _refused(_xz("Rap"))
    assert "'songs'" in _refused(_xz({"title": "P"}))
    assert "'songs'" in _refused(_xz(_playlist(songs={"id": "x"})))
    assert "'title'" in _refused(_xz({"songs": []}))
    assert "'title'" in _refused(_xz(_playlist(title=7)))
    assert "'createdDate'" in _refused(_xz(_playlist(createdDate="yesterday")))
    assert "'createdDate'" in _refused(_xz(_playlist(createdDate=1782052736)))


def test_song_without_an_id_names_the_song():
    for bad in ({k: v for k, v in SONG.items() if k != "id"},
                {**SONG, "id": None}, {**SONG, "id": ""}, {**SONG, "id": "  "},
                {**SONG, "id": 42}):
        message = _refused(_xz(_playlist(songs=[dict(SONG), dict(SONG), bad])))
        assert "Song 3" in message and "'id'" in message, message
    assert "song 2 is not a JSON object" in _refused(_xz(_playlist(songs=[dict(SONG), "x"])))


def test_song_with_a_wrong_typed_field():
    for field, value in (("duration", "118"), ("duration", 1.5), ("duration", True),
                         ("duration", -1), ("duration", 10 ** 12),
                         ("title", 5), ("artistName", ["a"]), ("albumTitle", {}),
                         ("artwork", 9)):
        message = _refused(_xz(_playlist(songs=[{**SONG, field: value}])))
        assert "Song 1" in message and repr(field) in message, message


def test_text_that_is_not_valid_unicode():
    # JSON can spell half of a surrogate pair; no response could carry it.
    for document in (_playlist(title="\ud800"),
                     _playlist(songs=[{**SONG, "id": "\udfff"}]),
                     _playlist(songs=[{**SONG, "albumTitle": "a\ud83d"}])):
        assert "not valid Unicode" in _refused(_xz(document))
    # A whole pair, written as escapes, is an ordinary character.
    paired = lzma.compress(json.dumps(_playlist(title="\U0001f3b5")).encode("ascii"))
    assert demus.parse(paired)["name"] == "\U0001f3b5"


# --- size limits ---------------------------------------------------------

def test_too_many_songs():
    # Tiny songs compress thousands to one, so the byte limits alone would
    # still admit millions of them.
    document = _playlist(songs=[{"id": "a"}] * (demus.MAX_SONGS + 1))
    data = _xz(document)
    assert len(data) < 10_000, len(data)
    message = _refused(data)
    assert str(demus.MAX_SONGS) in message and "songs" in message, message
    at_the_limit = demus.parse(_xz(_playlist(songs=[{"id": "a"}] * demus.MAX_SONGS)))
    assert len(at_the_limit["songs"]) == demus.MAX_SONGS



def test_oversized_compressed_input_is_refused_before_decompressing():
    calls = []
    saved = demus.lzma.LZMADecompressor
    demus.lzma.LZMADecompressor = lambda *a, **k: calls.append(1) or saved(*a, **k)
    try:
        # A valid xz header followed by enough to cross the limit.
        message = _refused(RAP.read_bytes() + b"\0" * demus.MAX_COMPRESSED_BYTES)
    finally:
        demus.lzma.LZMADecompressor = saved
    assert "compressed" in message and str(demus.MAX_COMPRESSED_BYTES) in message, message
    assert calls == []


class _CountingDecompressor:
    """Stands in for lzma.LZMADecompressor and records what was asked of it."""
    produced = 0
    limits: list[int] = []

    def __init__(self, *args, **kwargs):
        self._real = _REAL_DECOMPRESSOR(*args, **kwargs)

    def decompress(self, data, max_length=-1):
        out = self._real.decompress(data, max_length)
        type(self).limits.append(max_length)
        type(self).produced += len(out)
        return out

    def __getattr__(self, name):
        return getattr(self._real, name)


_REAL_DECOMPRESSOR = lzma.LZMADecompressor


def test_xz_bomb_is_refused_without_being_inflated():
    size = 8 * demus.MAX_DECOMPRESSED_BYTES
    compressor = lzma.LZMACompressor(preset=0)
    block = b"\0" * (4 * 1024 * 1024)
    bomb = b"".join(compressor.compress(block) for _ in range(size // len(block)))
    bomb += compressor.flush()
    assert len(bomb) < demus.MAX_COMPRESSED_BYTES, len(bomb)

    _CountingDecompressor.produced = 0
    _CountingDecompressor.limits = []
    demus.lzma.LZMADecompressor = _CountingDecompressor
    try:
        message = _refused(bomb)
    finally:
        demus.lzma.LZMADecompressor = _REAL_DECOMPRESSOR

    assert "decompressed" in message and str(demus.MAX_DECOMPRESSED_BYTES) in message, message
    # Every read was bounded, and reading stopped at the limit rather than at
    # the end of the stream.
    assert _CountingDecompressor.limits, "the decompressor was never used"
    assert all(0 < limit <= demus.DECOMPRESS_CHUNK_BYTES
               for limit in _CountingDecompressor.limits), _CountingDecompressor.limits
    assert _CountingDecompressor.produced <= (
        demus.MAX_DECOMPRESSED_BYTES + demus.DECOMPRESS_CHUNK_BYTES
    ), _CountingDecompressor.produced


def test_decoder_memory_is_capped():
    # A hostile header can ask the decoder for a dictionary of gigabytes. The
    # limit is lowered here so an ordinary 8 MiB dictionary trips it.
    saved = demus.DECODER_MEMORY_LIMIT_BYTES
    demus.DECODER_MEMORY_LIMIT_BYTES = 1024 * 1024
    try:
        message = _refused(lzma.compress(b"x" * 100, preset=6))
    finally:
        demus.DECODER_MEMORY_LIMIT_BYTES = saved
    assert "memory" in message, message
    # At the real limit the strongest ordinary preset still opens.
    assert demus.parse(lzma.compress(json.dumps(_playlist()).encode(), preset=9))["name"] == "P"


# --- reading the request body --------------------------------------------

async def _chunks(sizes, served):
    for size in sizes:
        served.append(size)
        yield b"x" * size


def _read(sizes, declared, limit=100):
    served: list[int] = []
    try:
        body = asyncio.run(demus.read_body(_chunks(sizes, served), declared, limit))
    except demus.DemusError as exc:
        return str(exc), served
    return body, served


def test_body_within_the_limit_is_returned_whole():
    assert _read([40, 0, 60], "100") == (b"x" * 100, [40, 0, 60])
    # No Content-Length at all: a chunked upload.
    assert _read([10, 10], None) == (b"x" * 20, [10, 10])


def test_declared_length_over_the_limit_is_refused_unread():
    message, served = _read([50, 51], "101")
    assert "compressed" in message and "100" in message, message
    assert served == []


def test_absurd_declared_length_is_refused_not_an_error():
    message, served = _read([10], "9" * 5000)
    assert "compressed" in message, message
    assert served == []


def test_stream_longer_than_the_limit_stops_being_read():
    # Content-Length absent, or lying: the count while reading is what holds.
    for declared in (None, "10", "not-a-number"):
        message, served = _read([60, 30, 30, 30, 30], declared)
        assert "compressed" in message and "100" in message, message
        assert served == [60, 30, 30], served


# --- the endpoint --------------------------------------------------------

def _post(chunks, headers=()):
    """POST /import/demus with the body delivered in `chunks`. Returns the
    status, the decoded JSON body, and how many chunks the app asked for."""
    pending = list(chunks)
    asked = []
    sent = []

    async def receive():
        asked.append(1)
        if not pending:
            return {"type": "http.disconnect"}
        return {"type": "http.request", "body": pending.pop(0), "more_body": bool(pending)}

    async def send(message):
        sent.append(message)

    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
             "method": "POST", "scheme": "http", "path": "/import/demus",
             "raw_path": b"/import/demus", "query_string": b"", "root_path": "",
             "headers": [(k.lower().encode(), v.encode()) for k, v in headers],
             "client": ("127.0.0.1", 1), "server": ("127.0.0.1", 8000)}
    asyncio.run(app(scope, receive, send))
    status = [m["status"] for m in sent if m["type"] == "http.response.start"][0]
    body = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
    return status, json.loads(body), len(asked)


def test_endpoint_returns_the_playlist():
    if app is None:
        print("      (skipped: the app does not import here)")
        return
    data = RAP.read_bytes()
    status, body, _ = _post([data[:1000], data[1000:]],
                            [("Content-Length", str(len(data)))])
    assert status == 200, body
    assert body == demus.parse(data)
    assert set(body) == {"name", "created_at", "songs"}
    assert (body["name"], body["created_at"], len(body["songs"])) == ("Rap", 1782052736, 33)


def test_endpoint_answers_422_with_the_reason():
    if app is None:
        return
    for chunks, expected in (
        ([b""], "empty"),
        ([b"not a playlist"], "not an xz file"),
        ([RAP.read_bytes()[:500]], "truncated"),
        ([lzma.compress(b"[1]")], "not a JSON object"),
        ([_xz(_playlist(songs=[{"title": "no id"}]))], "Song 1 has no 'id'"),
        ([_xz(_playlist(title="\ud800"))], "not valid Unicode"),
    ):
        status, body, _ = _post(chunks)
        assert status == 422, (status, body)
        assert isinstance(body["detail"], str) and expected in body["detail"], body


def test_endpoint_refuses_an_oversized_upload_without_reading_it_all():
    if app is None:
        return
    megabyte = b"\0" * (1024 * 1024)
    limit_mb = demus.MAX_COMPRESSED_BYTES // len(megabyte)
    # Declared honestly: refused before the body is asked for at all.
    status, body, asked = _post([megabyte] * (limit_mb + 4),
                                [("Content-Length", str(len(megabyte) * (limit_mb + 4)))])
    assert status == 422 and "compressed" in body["detail"], body
    assert asked == 0, asked
    # Not declared: refused on the chunk that crosses the limit, the rest unread.
    status, body, asked = _post([megabyte] * (limit_mb + 4))
    assert status == 422 and "compressed" in body["detail"], body
    assert asked == limit_mb + 1, asked


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
