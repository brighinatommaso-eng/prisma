"""Cover palette extraction, per spec sections 3.3 and 5.3.

Done once on the server at download time so the phone never analyses an image
on a track change. Four dominant colours become the four sources of the Prisma
aura, so they are quantised, filtered for colours too dark or too washed out to
carry an aura, and -- the part that matters -- clamped in lightness.

The clamp is spec section 5.3's second defence against the projects main
contrast risk: an adaptive aura built from a white or fluorescent cover can
otherwise render white text unreadable. No colour returned from here can exceed
MAX_LIGHTNESS, so no cover can produce a near-white aura.

This module only ever reads the cover. It never rewrites it, so the stored
cover.jpg keeps the source pixels and the source aspect ratio.
"""

import colorsys
import io
from typing import Any

from PIL import Image

PALETTE_SIZE = 4

# Hard ceiling on lightness. Nothing above this is ever emitted.
MAX_LIGHTNESS = 0.70

# Colours below these are discarded as aura sources on the first pass.
MIN_LIGHTNESS = 0.15
MIN_SATURATION = 0.20

QUANTISE_COLORS = 32
ANALYSIS_MAX_EDGE = 240

# Two colours closer than this in RGB space read as the same colour in an aura.
_DUPLICATE_DISTANCE = 40

# Successively looser (min_lightness, min_saturation) gates. A monochrome or very
# dark cover yields nothing on the strict pass, so the filters relax rather than
# return a short palette.
_RELAXATIONS = (
    (MIN_LIGHTNESS, MIN_SATURATION),
    (0.10, 0.10),
    (0.05, 0.03),
    (0.0, 0.0),
)


def _clamp_lightness(rgb: tuple[int, int, int]) -> tuple[int, int, int]:
    r, g, b = (channel / 255 for channel in rgb)
    hue, lightness, saturation = colorsys.rgb_to_hls(r, g, b)
    if lightness <= MAX_LIGHTNESS:
        return rgb
    r, g, b = colorsys.hls_to_rgb(hue, MAX_LIGHTNESS, saturation)
    return (round(r * 255), round(g * 255), round(b * 255))


def _hls(rgb: tuple[int, int, int]) -> tuple[float, float, float]:
    r, g, b = (channel / 255 for channel in rgb)
    return colorsys.rgb_to_hls(r, g, b)


def _to_hex(rgb: tuple[int, int, int]) -> str:
    return "#{:02x}{:02x}{:02x}".format(*rgb)


def _distance(a: tuple[int, int, int], b: tuple[int, int, int]) -> float:
    return sum((x - y) ** 2 for x, y in zip(a, b)) ** 0.5


def _quantised_colours(image: Image.Image) -> list[tuple[int, tuple[int, int, int]]]:
    """(count, rgb) pairs, most frequent first."""
    small = image.convert("RGB").copy()
    # thumbnail preserves aspect ratio; this is analysis only, nothing is written.
    small.thumbnail((ANALYSIS_MAX_EDGE, ANALYSIS_MAX_EDGE))
    quantised = small.quantize(colors=QUANTISE_COLORS, method=Image.Quantize.MEDIANCUT)
    flat_palette = quantised.getpalette() or []
    counted = quantised.getcolors() or []

    colours: list[tuple[int, tuple[int, int, int]]] = []
    for count, index in counted:
        base = index * 3
        if base + 2 < len(flat_palette):
            rgb = (flat_palette[base], flat_palette[base + 1], flat_palette[base + 2])
            colours.append((count, rgb))
    colours.sort(key=lambda pair: pair[0], reverse=True)
    return colours


def _select(colours: list[tuple[int, tuple[int, int, int]]]) -> list[tuple[int, int, int]]:
    for min_lightness, min_saturation in _RELAXATIONS:
        chosen: list[tuple[int, int, int]] = []
        for _, rgb in colours:
            _, lightness, saturation = _hls(rgb)
            if lightness < min_lightness or saturation < min_saturation:
                continue
            clamped = _clamp_lightness(rgb)
            if any(_distance(clamped, taken) < _DUPLICATE_DISTANCE for taken in chosen):
                continue
            chosen.append(clamped)
            if len(chosen) == PALETTE_SIZE:
                return chosen
        if len(chosen) == PALETTE_SIZE:
            return chosen
    return chosen


def _pad(chosen: list[tuple[int, int, int]]) -> list[tuple[int, int, int]]:
    """Guarantee exactly PALETTE_SIZE colours, all inside the clamp.

    Only reachable for a cover with almost no colour variety at all, e.g. a
    solid block. Variants are derived by walking lightness, never by inventing
    a hue the cover does not contain.
    """
    if not chosen:
        chosen = [(64, 64, 64)]
    steps = (0.85, 0.7, 1.15, 0.55)
    index = 0
    while len(chosen) < PALETTE_SIZE:
        hue, lightness, saturation = _hls(chosen[index % len(chosen)])
        factor = steps[index % len(steps)]
        target = max(0.08, min(MAX_LIGHTNESS, lightness * factor))
        r, g, b = colorsys.hls_to_rgb(hue, target, saturation)
        variant = _clamp_lightness((round(r * 255), round(g * 255), round(b * 255)))
        if not any(_distance(variant, taken) < 12 for taken in chosen):
            chosen.append(variant)
        index += 1
        if index > 16:
            break
    while len(chosen) < PALETTE_SIZE:
        chosen.append(chosen[-1])
    return chosen[:PALETTE_SIZE]


def extract(image_bytes: bytes) -> list[str]:
    """Four dominant hex colours for a cover, always exactly four."""
    with Image.open(io.BytesIO(image_bytes)) as image:
        colours = _quantised_colours(image)
    return [_to_hex(rgb) for rgb in _pad(_select(colours))]


def lightness_of(hex_colour: str) -> float:
    """Relative lightness of a stored hex colour. Used to verify the clamp."""
    value = hex_colour.lstrip("#")
    rgb = tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))
    return _hls(rgb)[1]


def describe() -> dict[str, Any]:
    return {
        "palette_size": PALETTE_SIZE,
        "max_lightness": MAX_LIGHTNESS,
        "min_lightness": MIN_LIGHTNESS,
        "min_saturation": MIN_SATURATION,
    }
