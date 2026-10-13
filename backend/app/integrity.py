"""Whether the files the catalogue lists are really there, and really those files.

The catalogue and the library are two things that can disagree. A file can be
removed from the share by hand, and the row then promises audio that
GET /tracks/{id}/file can only answer 410 for; and a file can stop being the
audio its row recorded, which is what a second download tagged into the same
path does to the first one's hash.
"""

import hashlib
from pathlib import Path


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
