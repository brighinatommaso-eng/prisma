"""Runtime configuration, read from the environment.

Nothing here is hardcoded to a machine: the deploy target supplies
PRISMA_MUSIC_DIR, PRISMA_HOST and PRISMA_PORT. The defaults describe the
inside of the container, not the server.
"""

import os
from pathlib import Path

# Where downloaded audio lands. Inside the container this is the mount point;
# the host path it maps to is set in docker-compose.yml.
MUSIC_DIR = Path(os.environ.get("PRISMA_MUSIC_DIR", "/music"))

# Bind address for uvicorn.
HOST = os.environ.get("PRISMA_HOST", "0.0.0.0")
PORT = int(os.environ.get("PRISMA_PORT", "8000"))

# Prisma's own state lives in a dotted directory inside the music volume: it is
# the only path guaranteed to be persistent without touching docker-compose.yml,
# and a leading dot keeps it out of the Artist/ namespace and out of the way of
# anything else pointed at the same folder (Navidrome, spec section 3.7).
STATE_DIR = Path(os.environ.get("PRISMA_STATE_DIR", str(MUSIC_DIR / ".prisma")))
DB_PATH = Path(os.environ.get("PRISMA_DB_PATH", str(STATE_DIR / "catalog.db")))
STAGING_DIR = Path(os.environ.get("PRISMA_STAGING_DIR", str(STATE_DIR / "staging")))

# Everything created on the music volume is chowned to this uid:gid. The
# container runs as root, so without this the library would be root-owned and
# unusable from any other account or container.
OWNER_UID = int(os.environ.get("PRISMA_OWNER_UID", "1000"))
OWNER_GID = int(os.environ.get("PRISMA_OWNER_GID", "1000"))
