#!/usr/bin/env python3
"""Manual spike: prove yt-dlp can pull playable AAC audio inside the container.

Deliberately standalone. It is not imported by the API and not wired into any
endpoint; it exists so that a broken yt-dlp can be diagnosed in one command.

    docker compose exec prisma-backend python scripts/smoke_download.py dQw4w9WgXcQ

Format choice is locked by the design spec, section 3.2: take the AAC-in-M4A
track YouTube already serves and do not re-encode it. Only when no m4a exists
does this transcode, at 192 kbps, as the spec prescribes.
"""

import subprocess
import sys
from pathlib import Path

# Importable both as `python scripts/smoke_download.py` from /app and as a
# module, without depending on the package being installed.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.config import MUSIC_DIR  # noqa: E402

FORMAT = "bestaudio[ext=m4a]/bestaudio"
FALLBACK_BITRATE = "192k"


def download(video_id: str) -> Path:
    """Fetch the best audio for `video_id` into MUSIC_DIR. Returns the file."""
    from yt_dlp import YoutubeDL

    opts = {
        "format": FORMAT,
        "outtmpl": str(MUSIC_DIR / "%(id)s.%(ext)s"),
        "noplaylist": True,
        # A spike is for reading, so leave yt-dlp's own progress output on.
        "quiet": False,
        "no_warnings": False,
    }
    with YoutubeDL(opts) as ydl:
        info = ydl.extract_info(f"https://music.youtube.com/watch?v={video_id}", download=True)

    requested = (info or {}).get("requested_downloads") or []
    if requested and requested[0].get("filepath"):
        return Path(requested[0]["filepath"])
    # Older yt-dlp builds omit requested_downloads; reconstruct the name.
    with YoutubeDL(opts) as ydl:
        return Path(ydl.prepare_filename(info))


def transcode_to_m4a(source: Path) -> Path:
    """Spec section 3.2 fallback: no m4a available, so encode AAC at 192 kbps.

    The source is left on disk on purpose. Deleting it is not this script's
    call to make, and keeping it makes a bad transcode diagnosable.
    """
    target = source.with_suffix(".m4a")
    print(f"\n[fallback] {source.name} is not m4a — encoding AAC {FALLBACK_BITRATE}", flush=True)
    subprocess.run(
        ["ffmpeg", "-y", "-i", str(source), "-vn",
         "-c:a", "aac", "-b:a", FALLBACK_BITRATE, str(target)],
        check=True,
    )
    print(f"[fallback] source kept at {source}", flush=True)
    return target


def ffprobe_audio_stream(path: Path) -> str:
    """The codec line the acceptance check reads. Must say aac."""
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a:0",
         "-show_entries", "stream=codec_name,profile,bit_rate,sample_rate,channels",
         "-of", "default=noprint_wrappers=1", str(path)],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {Path(argv[0]).name} <video_id>", file=sys.stderr)
        return 2

    video_id = argv[1]
    MUSIC_DIR.mkdir(parents=True, exist_ok=True)

    path = download(video_id)
    if path.suffix.lower() != ".m4a":
        path = transcode_to_m4a(path)

    probe = ffprobe_audio_stream(path)

    print("\n--- smoke_download result ---")
    print(f"path:  {path}")
    print(f"bytes: {path.stat().st_size}")
    print("ffprobe:")
    for line in probe.splitlines():
        print(f"  {line}")

    codec = next(
        (l.split("=", 1)[1] for l in probe.splitlines() if l.startswith("codec_name=")),
        "",
    )
    if codec != "aac":
        print(f"\nFAIL: expected codec aac, got {codec!r}", file=sys.stderr)
        return 1
    print("\nOK: codec is aac")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
