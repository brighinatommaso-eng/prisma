"""Reading a playlist exported by the Demus app.

This only parses. It downloads nothing, writes nothing and makes no request:
the client shows the result, and what gets queued is the client's decision.

A .playlist file is one xz stream holding one JSON object: `title`,
`createdDate`, `songs`, and a few fields ignored here. A song's `id` is the
YouTube video id, which is Prisma's own track key, so it is passed through
exactly as exported.

`albumId` is deliberately not read. In real exports it is sometimes a channel
id rather than an album browse id, and nothing in the file says which; the
download pipeline resolves the album itself.

The file comes from outside, so every size is bounded before it is paid for:
the compressed bytes while the request is read, the decompressed bytes while
they are produced, and the decoder's own memory, which an xz header is
otherwise free to set to gigabytes.
"""

import json
import lzma
import threading
from datetime import datetime
from typing import Any, AsyncIterator
from urllib.parse import urlsplit

from .artwork import upsized_artwork_url

# The two exports this was written against are 4 KB and 11 KB, lyrics removed.
# Lyrics add a few KB of text per song, so these leave room for a playlist of
# thousands of songs and still bound what a hostile file can cost.
MAX_COMPRESSED_BYTES = 4 * 1024 * 1024
MAX_DECOMPRESSED_BYTES = 16 * 1024 * 1024
# The byte limits do not bound this on their own: a song can be a dozen bytes,
# and a file of nothing but those compresses thousands to one.
MAX_SONGS = 10_000
# Enough for the dictionary of `xz -9`, the largest an ordinary file asks for.
DECODER_MEMORY_LIMIT_BYTES = 128 * 1024 * 1024
DECOMPRESS_CHUNK_BYTES = 64 * 1024

MAX_DURATION_S = 7 * 24 * 3600

_XZ_MAGIC = b"\xfd7zXZ\x00"


# One file at a time. The limits above bound what a single parse can hold;
# this keeps several uploads at once from multiplying it. There is one user.
_parse_lock = threading.Lock()


class DemusError(ValueError):
    """The file is not a Demus playlist this can read. The message says why,
    and is written to be shown to the person who uploaded it."""


async def read_body(chunks: AsyncIterator[bytes], content_length: str | None,
                    limit: int = MAX_COMPRESSED_BYTES) -> bytes:
    """Collect a request body, refusing one longer than `limit`.

    Content-Length is checked first so an honest oversized upload is refused
    before a byte of it is read. It is not trusted beyond that: a chunked
    upload has none and a hostile one can understate it, so the bytes are
    counted as they arrive and reading stops at the limit.
    """
    too_long = DemusError(f"The file is larger than the {limit} byte limit on the "
                          "compressed size.")
    if content_length is not None and content_length.isdecimal():
        # A length too long to be worth converting is over the limit already.
        if len(content_length) > len(str(limit)) or int(content_length) > limit:
            raise too_long
    body = bytearray()
    async for chunk in chunks:
        if len(body) + len(chunk) > limit:
            raise too_long
        body += chunk
    return bytes(body)


def _decompress(data: bytes) -> bytes:
    """Unpack one xz stream, never producing more than the limit plus a byte.

    Decompress-then-measure would be the bomb going off: output is asked for a
    chunk at a time and the count is checked between chunks.
    """
    if not data:
        raise DemusError("The request body is empty; send the .playlist file as the body.")
    if len(data) > MAX_COMPRESSED_BYTES:
        raise DemusError(f"The file is larger than the {MAX_COMPRESSED_BYTES} byte limit "
                         "on the compressed size.")
    if data[:len(_XZ_MAGIC)] != _XZ_MAGIC:
        raise DemusError("This is not an xz file, so not a Demus playlist export.")

    decompressor = lzma.LZMADecompressor(
        format=lzma.FORMAT_XZ, memlimit=DECODER_MEMORY_LIMIT_BYTES)
    output = bytearray()
    pending = data
    try:
        while not decompressor.eof:
            if decompressor.needs_input and not pending:
                raise DemusError("The xz data is truncated: the file ends before the "
                                 "compressed stream does.")
            # One byte past the limit is enough to know it was exceeded.
            room = MAX_DECOMPRESSED_BYTES + 1 - len(output)
            output += decompressor.decompress(pending, min(DECOMPRESS_CHUNK_BYTES, room))
            pending = b""
            if len(output) > MAX_DECOMPRESSED_BYTES:
                raise DemusError(f"The file decompresses to more than the "
                                 f"{MAX_DECOMPRESSED_BYTES} byte limit on the "
                                 "decompressed size.")
    except lzma.LZMAError as exc:
        if "memory" in str(exc).lower():
            raise DemusError("The xz data asks for more decoder memory than the "
                             f"{DECODER_MEMORY_LIMIT_BYTES} byte limit.") from exc
        raise DemusError(f"The xz data is corrupt: {exc}.") from exc
    if decompressor.unused_data:
        raise DemusError("There is data after the end of the xz stream; a Demus export "
                         "is a single stream.")
    return bytes(output)


def _created_at(value: Any) -> int | None:
    """`createdDate` as Unix seconds, like every other timestamp in the API.

    Demus writes ISO 8601 in UTC with milliseconds; the fraction is dropped.
    """
    if value is None:
        return None
    problem = DemusError("'createdDate' is not an ISO 8601 date such as "
                         "2026-06-21T14:38:56.787Z.")
    if not isinstance(value, str):
        raise problem
    try:
        moment = datetime.fromisoformat(value)
    except ValueError:
        raise problem from None
    if moment.tzinfo is None:
        # Without an offset the instant is ambiguous, and guessing the
        # server's zone would be wrong for a file made on a phone.
        raise problem
    try:
        return int(moment.timestamp())
    except (OverflowError, OSError):
        raise problem from None


def _artwork_url(value: str | None) -> str | None:
    """The larger rendition of a googleusercontent thumbnail, by rewrite alone.

    /search verifies its rewritten URL with a HEAD request; this must not make
    one, so the rewrite is applied only where it cannot produce a broken link.
    On googleusercontent the text after the last "=" is the rendition, and a
    larger one than exists is answered with the source size. On any other
    host that text is something else -- on a video thumbnail it is a signature
    -- so the URL is passed through as it is.
    """
    if not value or any(character.isspace() for character in value):
        return None
    try:
        parts = urlsplit(value)
    except ValueError:
        return None
    if parts.scheme not in ("http", "https") or not parts.hostname:
        return None
    # With a query or a fragment, the last "=" is theirs and not a rendition.
    plain = not parts.query and not parts.fragment
    if plain and parts.hostname.endswith(".googleusercontent.com"):
        return upsized_artwork_url(value) or value
    return value


def _text(song: dict[str, Any], field: str, position: int) -> str | None:
    value = song.get(field)
    if value is not None and not isinstance(value, str):
        raise DemusError(f"Song {position}: {field!r} is not a string.")
    return value


def _song(raw: Any, position: int) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise DemusError(f"The entry for song {position} is not a JSON object.")
    video_id = raw.get("id")
    if not isinstance(video_id, str) or not video_id.strip():
        raise DemusError(f"Song {position} has no 'id' (the YouTube video id), so it "
                         "cannot be matched to a track.")
    duration = raw.get("duration")
    # bool is an int in Python, and `true` is not a duration.
    if duration is not None and (type(duration) is not int
                                 or not 0 <= duration <= MAX_DURATION_S):
        raise DemusError(f"Song {position}: 'duration' is not a whole number of seconds "
                         f"between 0 and {MAX_DURATION_S}.")
    return {
        "video_id": video_id,
        "title": _text(raw, "title", position),
        "artist": _text(raw, "artistName", position),
        "album": _text(raw, "albumTitle", position),
        "artwork_url": _artwork_url(_text(raw, "artwork", position)),
        "duration_s": duration,
    }


def parse(data: bytes) -> dict[str, Any]:
    """Parse the bytes of a .playlist file. Raises DemusError on anything else.

    Songs come back in the file's order, and a song listed twice stays twice:
    a playlist may repeat a track.
    """
    with _parse_lock:
        return _parse(data)


def _parse(data: bytes) -> dict[str, Any]:
    try:
        text = _decompress(data).decode("utf-8")
    except UnicodeDecodeError:
        raise DemusError("The decompressed content is not UTF-8 text, so it is "
                         "not JSON.") from None
    try:
        document = json.loads(text)
    except (ValueError, RecursionError):
        # ValueError covers a syntax error and an integer too long to convert.
        raise DemusError("The decompressed content is not JSON.") from None

    if not isinstance(document, dict):
        raise DemusError("The decompressed content is not a JSON object with "
                         "'title' and 'songs'.")
    title = document.get("title")
    if not isinstance(title, str):
        raise DemusError("The playlist has no 'title', or it is not a string.")
    songs = document.get("songs")
    if not isinstance(songs, list):
        raise DemusError("The playlist has no 'songs' list.")
    if len(songs) > MAX_SONGS:
        raise DemusError(f"The playlist has {len(songs)} songs, more than the "
                         f"{MAX_SONGS} songs one import may carry.")

    playlist = {
        "name": title,
        "created_at": _created_at(document.get("createdDate")),
        "songs": [_song(raw, position) for position, raw in enumerate(songs, start=1)],
    }
    try:
        # JSON can spell half of a surrogate pair as an escape. Such a string
        # cannot be written back out, so it is refused here, as bad input,
        # rather than failing later as the response is serialised.
        json.dumps(playlist, ensure_ascii=False).encode("utf-8")
    except UnicodeEncodeError:
        raise DemusError("The playlist contains text that is not valid Unicode "
                         "(an unpaired surrogate).") from None
    return playlist
