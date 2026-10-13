"""Lets the download pipeline be imported where its network packages are absent.

app.downloader and app.main import ytmusicapi and mutagen at module level, and
a bare development machine has neither. The tests that drive the pipeline
replace everything those packages would do anyway -- the metadata lookup, the
download, the tagging -- so all that is missing is something to import.

install_missing() registers an empty stand-in for each package that really is
absent and leaves an installed one alone, so the same test runs unchanged
inside the image. The stand-ins raise if anything calls them: a test that
reaches one has forgotten to replace a network call.

Call it after guard.scratch_music_dir() and before importing anything from app.
"""

import importlib
import sys
import types


class _NotInstalled:
    def __init__(self, *args, **kwargs):
        raise RuntimeError(f"{type(self).__name__} is a test stand-in, not the real package")


def _stand_in(name: str, **attributes) -> None:
    module = types.ModuleType(name)
    module.__dict__.update(attributes)
    sys.modules[name] = module


def install_missing() -> list[str]:
    """Register stand-ins for the absent packages. Returns their names."""
    stubbed = []
    try:
        importlib.import_module("ytmusicapi")
    except ImportError:
        _stand_in("ytmusicapi", YTMusic=type("YTMusic", (_NotInstalled,), {}))
        stubbed.append("ytmusicapi")
    try:
        importlib.import_module("mutagen.mp4")
    except ImportError:
        _stand_in("mutagen")
        _stand_in("mutagen.mp4",
                  MP4=type("MP4", (_NotInstalled,), {}),
                  MP4Cover=type("MP4Cover", (_NotInstalled,), {}))
        stubbed.append("mutagen")
    return stubbed
