#!/usr/bin/env python3
"""Unit tests for the album title normaliser.

Runs with no dependencies:

    python scripts/test_album_normalisation.py
    docker compose exec -T backend python scripts/test_album_normalisation.py

Written as plain asserts in test_* functions, so pytest collects them unchanged
if pytest is ever added (spec section 8) without adding a dependency now.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.metadata import EDITION_KEYWORDS, normalise_album_title  # noqa: E402


def test_plain_title_unchanged():
    for title in ["Homework", "Discovery", "Californication", "OK Computer",
                  "Random Access Memories", "In Rainbows"]:
        assert normalise_album_title(title) == title, title


def test_single_edition_suffix_stripped():
    cases = {
        "Homework (25th Anniversary Edition)": "Homework",
        "Californication (Deluxe Version)": "Californication",
        "Discovery (Remastered)": "Discovery",
        "Nevermind [Super Deluxe]": "Nevermind",
        "Kid A (Collector's Edition)": "Kid A",
        "Blue Lines (Reissue)": "Blue Lines",
        "Achtung Baby (Expanded)": "Achtung Baby",
        "Legend (Special Edition)": "Legend",
        "Thriller (Bonus Track Version)": "Thriller",
        "Born to Run (Legacy Edition)": "Born to Run",
    }
    for raw, expected in cases.items():
        assert normalise_album_title(raw) == expected, raw


def test_stacked_suffixes_collapsed():
    cases = {
        "Album (Deluxe) (Remastered)": "Album",
        "Album [Deluxe Edition] (2011 Remaster)": "Album",
        "Homework (Remastered) (25th Anniversary Edition)": "Homework",
        "Album - (Remastered)": "Album",
        "Album, (Deluxe Edition)": "Album",
    }
    for raw, expected in cases.items():
        assert normalise_album_title(raw) == expected, raw


def test_leading_parenthesis_title_unchanged():
    # The group is not trailing, so it must survive untouched even though it
    # sits in brackets.
    title = "(What's the Story) Morning Glory?"
    assert normalise_album_title(title) == title


def test_non_edition_trailing_group_unchanged():
    # A trailing group that is not an edition marker is part of the name.
    cases = [
        "Sgt. Pepper's Lonely Hearts Club Band (Mono)",
        "Music from the Motion Picture (Original Score)",
        "Selected Ambient Works 85-92 (Analogue Bubblebath)",
    ]
    for title in cases:
        assert normalise_album_title(title) == title, title


def test_empty_result_falls_back_to_original():
    # Stripping would leave nothing, so the original is kept.
    for title in ["(Deluxe Edition)", "[Remastered]", "(Special Edition)"]:
        assert normalise_album_title(title) == title, title


def test_blank_and_none_pass_through():
    assert normalise_album_title(None) is None
    assert normalise_album_title("") == ""


def test_track_parentheticals_are_not_this_functions_job():
    # Guard against the keyword list ever growing to match "Radio Edit".
    # "edit" must not be treated as "edition".
    assert normalise_album_title("Around the World (Radio Edit)") == \
        "Around the World (Radio Edit)"


def test_keywords_are_a_named_constant():
    assert isinstance(EDITION_KEYWORDS, tuple)
    assert "anniversary" in EDITION_KEYWORDS
    assert "deluxe" in EDITION_KEYWORDS


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
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
