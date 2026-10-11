"""The artwork URL rewrite, on its own so it can be used without the network.

It lives apart from ytm.py because that module is the one that talks to
YouTube Music, and the Demus import must be able to normalise a URL without
being able to make a request at all.
"""

import re

# Search results only ever carry a 120x120 thumbnail, which is unusable both for
# cover display and for the palette extraction in spec section 3.3.
# googleusercontent encodes the rendition in a suffix after the final "=", so the
# larger variant is a URL rewrite rather than a second API call.
#
# Note that googleusercontent will not upscale: for an album whose source art is
# smaller than 544px it serves the source size instead. That is still correct and
# still far better than 120px, so it is accepted rather than rejected.
ARTWORK_SIZE_SUFFIX = "w544-h544-l90-rj"
_ARTWORK_SUFFIX_RE = re.compile(r"=[\w-]+$")


def upsized_artwork_url(url: str | None) -> str | None:
    """Rewrite the googleusercontent size suffix to ARTWORK_SIZE_SUFFIX.

    Returns None when there is no size suffix to rewrite, so the caller keeps
    the URL it already has.
    """
    if not url or not _ARTWORK_SUFFIX_RE.search(url):
        return None
    return _ARTWORK_SUFFIX_RE.sub("=" + ARTWORK_SIZE_SUFFIX, url)
