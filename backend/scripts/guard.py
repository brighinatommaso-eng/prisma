"""Keeps the scripts in this directory away from the real library.

The test scripts create tracks, delete tracks and rewrite the catalogue. They
do it in a scratch directory, but only because each one overrides
PRISMA_MUSIC_DIR before importing the application -- and they have been run
inside the production container, where one forgotten override would have
pointed all of that at the library itself. So the first thing every test
script does is ask for its scratch directory here, and this module refuses,
before anything is created and before anything under app/ is imported, when
the process was started where the real library is:

- the music directory the process inherited -- PRISMA_MUSIC_DIR as it was
  before any override, or the application's default when it is not set --
  resolves to the mount point inside the container or to the default host
  directory; or
- a catalogue exists at that inherited location, wherever it is, or at an
  inherited PRISMA_STATE_DIR or PRISMA_DB_PATH.

The default for an unset PRISMA_MUSIC_DIR is the container's mount point, so a
container of the production image is refused unless it is told otherwise. The
way to run a test there is a throwaway container with no volume and an explicit
directory that is not the library; backend/README.md has the command.

This module deliberately imports nothing from app/: importing app.config is
what would freeze the paths.
"""

import os
import posixpath
import sys
import tempfile
from pathlib import Path

# The default in app/config.py, repeated because that module cannot be
# imported here. test_guard.py fails if the two drift apart.
CONFIG_DEFAULT_MUSIC_DIR = "/music"

# The mount point inside the container and the default host directory
# (PRISMA_MUSIC_HOST_DIR in docker-compose.yml).
PRODUCTION_MUSIC_DIRS = ("/music", "/opt/prisma/music")

CATALOGUE_RELATIVE = (".prisma", "catalog.db")

# Not 1, which is what a failing test exits with.
EXIT_REFUSED = 3

# Long and explicit on purpose: nobody types this by accident.
SMOKE_OPT_IN = "--write-into-the-real-library"


def _posix(path: str, realpath) -> str:
    return posixpath.normpath(Path(realpath(path)).as_posix())


def production_reason(environ=None, realpath=os.path.realpath) -> str | None:
    """Why this process must be treated as running against the real library,
    or None when it is not. Reads the environment as it is now, so it has to
    be asked before any override. Creates and changes nothing.
    """
    environ = os.environ if environ is None else environ
    inherited = environ.get("PRISMA_MUSIC_DIR")
    described = (f"PRISMA_MUSIC_DIR={inherited}" if inherited
                 else f"PRISMA_MUSIC_DIR is not set, so it defaults to {CONFIG_DEFAULT_MUSIC_DIR}")
    music_dir = inherited or CONFIG_DEFAULT_MUSIC_DIR

    resolved = _posix(music_dir, realpath)
    if resolved in PRODUCTION_MUSIC_DIRS:
        return f"{described}, which is the production music directory {resolved}"

    catalogues = [("PRISMA_MUSIC_DIR", Path(music_dir).joinpath(*CATALOGUE_RELATIVE))]
    if environ.get("PRISMA_STATE_DIR"):
        catalogues.append(("PRISMA_STATE_DIR",
                           Path(environ["PRISMA_STATE_DIR"]) / CATALOGUE_RELATIVE[-1]))
    if environ.get("PRISMA_DB_PATH"):
        catalogues.append(("PRISMA_DB_PATH", Path(environ["PRISMA_DB_PATH"])))
    for variable, catalogue in catalogues:
        if catalogue.exists():
            return f"a catalogue exists at {catalogue} (from the inherited {variable})"
    return None


def _refuse(message: str) -> None:
    print(f"REFUSING to run {Path(sys.argv[0]).name}: {message}", file=sys.stderr)
    sys.exit(EXIT_REFUSED)


def refuse_in_production(opt_in: str | None = None) -> None:
    """Exit unless this process is somewhere disposable.

    `opt_in` is for the one script that writes into the library by design: a
    command-line flag that, when present, lets it run anyway.
    """
    reason = production_reason()
    if reason is None or (opt_in is not None and opt_in in sys.argv[1:]):
        return
    message = (
        f"{reason}.\n"
        "This looks like the real library, and these scripts are never run against it.\n"
        "Run them on a development machine, or in a throwaway container with no volume\n"
        "and PRISMA_MUSIC_DIR set to a directory that is not the library "
        "(see backend/README.md, Tests)."
    )
    if opt_in is not None:
        message += f"\nTo write into the real library on purpose, pass {opt_in}."
    _refuse(message)


def scratch_music_dir(prefix: str) -> Path:
    """Create a scratch directory and point the application at it.

    The first statement of every test script: nothing has been created and
    nothing under app/ imported when this refuses. Returns the scratch root;
    the music directory is `music` inside it. Every path variable config.py
    reads is set or removed, so an inherited one cannot outlive the override.
    """
    refuse_in_production()
    scratch = Path(tempfile.mkdtemp(prefix=prefix))
    music = scratch / "music"
    os.environ["PRISMA_MUSIC_DIR"] = str(music)
    os.environ["PRISMA_STATE_DIR"] = str(music / ".prisma")
    os.environ["PRISMA_DB_PATH"] = str(music.joinpath(*CATALOGUE_RELATIVE))
    os.environ.pop("PRISMA_STAGING_DIR", None)
    return scratch


def assert_scratch(scratch: Path) -> None:
    """Check what the application actually resolved, after importing it.

    The second line of defence: whatever the environment said, every path the
    application will write to has to be inside the scratch directory and the
    music directory may not be a production one.
    """
    from app import config

    root = Path(os.path.realpath(scratch))
    for name in ("MUSIC_DIR", "STATE_DIR", "DB_PATH", "STAGING_DIR"):
        resolved = Path(os.path.realpath(getattr(config, name)))
        if not resolved.is_relative_to(root):
            _refuse(f"app.config.{name} is {resolved}, outside the scratch directory {root}")
    music = _posix(str(config.MUSIC_DIR), os.path.realpath)
    if music in PRODUCTION_MUSIC_DIRS:
        _refuse(f"app.config.MUSIC_DIR is the production music directory {music}")
