#!/usr/bin/env python3
"""Tests for the guard that keeps the test scripts away from the real library.

Runs with no dependencies and no network:

    python scripts/test_guard.py

The decision is tested as a function, with the path resolution replaced so the
POSIX production paths can be judged on any system, and then end to end: a
child process is started the way a test script starts, with the environment a
production container would hand it, and must exit before it creates anything.
The two children that inherit a literal /music or /opt/prisma/music only mean
something where those are real paths, so on Windows they are reported as
skipped rather than passed.
"""

import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import guard

_SCRATCH = guard.scratch_music_dir("prisma-test-guard-")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

guard.assert_scratch(_SCRATCH)

SCRIPTS = Path(__file__).resolve().parent
POSIX = os.name == "posix"
SKIPPED: list[str] = []

# What every test script does first, and then a trace that it got past it.
_CHILD = "import guard; print('SCRATCH=' + str(guard.scratch_music_dir('prisma-guard-child-')))"


def _identity(path):
    return str(path)


def _reason(music_dir, **extra):
    environ = dict(extra)
    if music_dir is not None:
        environ["PRISMA_MUSIC_DIR"] = music_dir
    return guard.production_reason(environ, realpath=_identity)


def _child(env_changes, code=_CHILD):
    """Run `code` from scripts/ with a private temp directory. Returns
    (exit code, stdout, stderr, what was created in the temp directory)."""
    tmp = Path(tempfile.mkdtemp(dir=_SCRATCH))
    env = {k: v for k, v in os.environ.items() if not k.startswith("PRISMA_")}
    env.update({"TMPDIR": str(tmp), "TEMP": str(tmp), "TMP": str(tmp)})
    for key, value in env_changes.items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = value
    result = subprocess.run([sys.executable, "-c", code], cwd=str(SCRIPTS), env=env,
                            capture_output=True, text=True, timeout=60)
    return result.returncode, result.stdout, result.stderr, sorted(p.name for p in tmp.iterdir())


def _library(with_catalogue=True):
    music = Path(tempfile.mkdtemp(dir=_SCRATCH)) / "library"
    (music / ".prisma").mkdir(parents=True)
    if with_catalogue:
        (music / ".prisma" / "catalog.db").write_bytes(b"not really sqlite")
    return music


# --- the decision ---------------------------------------------------------

def test_default_matches_the_config_default():
    """The guard may not import app.config, so it repeats its default."""
    config = (SCRIPTS.parent / "app" / "config.py").read_text(encoding="utf-8")
    expected = 'os.environ.get("PRISMA_MUSIC_DIR", "%s")' % guard.CONFIG_DEFAULT_MUSIC_DIR
    assert expected in config, expected


def test_inherited_container_mount_is_production():
    assert "/music" in _reason("/music")
    assert _reason("/music/") is not None
    assert _reason("/opt/../music") is not None


def test_inherited_host_directory_is_production():
    assert "/opt/prisma/music" in _reason("/opt/prisma/music")


def test_unset_variable_falls_back_to_the_config_default():
    reason = _reason(None)
    assert reason is not None and "not set" in reason, reason


def test_a_link_to_the_library_is_production():
    resolved = {"/srv/link": "/opt/prisma/music"}
    reason = guard.production_reason(
        {"PRISMA_MUSIC_DIR": "/srv/link"}, realpath=lambda p: resolved.get(str(p), str(p)))
    assert reason is not None and "/opt/prisma/music" in reason, reason


def test_a_catalogue_at_the_inherited_location_is_production():
    music = _library()
    reason = guard.production_reason({"PRISMA_MUSIC_DIR": str(music)})
    assert reason is not None and "catalog.db" in reason, reason


def test_a_catalogue_named_by_another_inherited_variable_is_production():
    music = _library()
    elsewhere = str(_library(with_catalogue=False))
    database = str(music / ".prisma" / "catalog.db")
    assert guard.production_reason(
        {"PRISMA_MUSIC_DIR": elsewhere, "PRISMA_DB_PATH": database}) is not None
    assert guard.production_reason(
        {"PRISMA_MUSIC_DIR": elsewhere, "PRISMA_STATE_DIR": str(music / ".prisma")}) is not None


def test_an_ordinary_directory_is_not_production():
    assert _reason("/scratch-not-the-library") is None
    assert _reason("/music-test") is None
    assert _reason("/opt/prisma/music/sub") is None
    assert guard.production_reason(
        {"PRISMA_MUSIC_DIR": str(_library(with_catalogue=False))}) is None


# --- a test script starting up --------------------------------------------

def test_child_passes_in_an_ordinary_directory():
    code, out, err, created = _child({"PRISMA_MUSIC_DIR": str(_library(with_catalogue=False))})
    assert code == 0, (code, err)
    assert out.startswith("SCRATCH="), out
    assert len(created) == 1 and created[0].startswith("prisma-guard-child-"), created


def test_child_refuses_where_a_catalogue_is_and_creates_nothing():
    music = _library()
    before = sorted(str(p.relative_to(music)) for p in music.rglob("*"))
    code, out, err, created = _child({"PRISMA_MUSIC_DIR": str(music)})
    assert code == guard.EXIT_REFUSED, (code, out, err)
    assert "REFUSING" in err and "catalog.db" in err, err
    assert out == "" and created == [], (out, created)
    assert sorted(str(p.relative_to(music)) for p in music.rglob("*")) == before


def test_child_refuses_before_importing_app():
    """The refusal must come from the first statement, not from a later check."""
    probe = ("import guard, sys\n"
             "try:\n"
             "    guard.scratch_music_dir('prisma-guard-child-')\n"
             "finally:\n"
             "    print('APP_IMPORTED=' + str(any(m == 'app' or m.startswith('app.') "
             "for m in sys.modules)))\n")
    code, out, _, created = _child({"PRISMA_MUSIC_DIR": str(_library())}, probe)
    assert code == guard.EXIT_REFUSED, code
    assert out.strip() == "APP_IMPORTED=False", out
    assert created == [], created


def test_child_refuses_the_container_mount():
    if not POSIX:
        SKIPPED.append("test_child_refuses_the_container_mount")
        return
    for env in ({"PRISMA_MUSIC_DIR": "/music"}, {"PRISMA_MUSIC_DIR": None}):
        code, out, err, created = _child(env)
        assert code == guard.EXIT_REFUSED, (env, code, out, err)
        assert "REFUSING" in err and created == [], (err, created)


def test_child_refuses_the_host_directory():
    if not POSIX:
        SKIPPED.append("test_child_refuses_the_host_directory")
        return
    code, out, err, created = _child({"PRISMA_MUSIC_DIR": "/opt/prisma/music"})
    assert code == guard.EXIT_REFUSED, (code, out, err)
    assert "REFUSING" in err and created == [], (err, created)


def test_every_test_script_starts_with_the_guard():
    """A new script that forgets the guard fails here, not in production."""
    for script in sorted(SCRIPTS.glob("test_*.py")):
        lines = script.read_text(encoding="utf-8").splitlines()
        first_app = next((i for i, line in enumerate(lines)
                          if line.startswith(("from app", "import app"))), len(lines))
        scratch = next((i for i, line in enumerate(lines)
                        if "guard.scratch_music_dir(" in line), None)
        check = next((i for i, line in enumerate(lines)
                      if line.startswith("guard.assert_scratch(")), None)
        assert scratch is not None and scratch < first_app, script.name
        assert check is not None, script.name
        text = "\n".join(lines)
        # Spelled in two halves so this file does not match itself.
        assert "tempfile.mkdtemp(" + "prefix=" not in text, script.name
        assert "docker compose " + "exec" not in text, script.name


def test_smoke_download_refuses_the_real_library_without_the_opt_in():
    music = _library()
    script = str(SCRIPTS / "smoke_download.py")
    run = ("import runpy, sys; sys.argv = %r; runpy.run_path(%r, run_name='__main__')")
    code, out, err, _ = _child({"PRISMA_MUSIC_DIR": str(music)},
                               run % ([script, "dQw4w9WgXcQ"], script))
    assert code == guard.EXIT_REFUSED, (code, out, err)
    assert "REFUSING" in err and guard.SMOKE_OPT_IN in err, err
    assert sorted(p.name for p in music.iterdir()) == [".prisma"]


def test_scratch_assertion_rejects_a_directory_outside_the_scratch():
    elsewhere = Path(tempfile.mkdtemp(dir=_SCRATCH))
    said = io.StringIO()
    try:
        with contextlib.redirect_stderr(said):
            guard.assert_scratch(elsewhere)
    except SystemExit as exc:
        assert exc.code == guard.EXIT_REFUSED, exc.code
        assert "REFUSING" in said.getvalue() and "MUSIC_DIR" in said.getvalue(), said.getvalue()
    else:
        raise AssertionError("a MUSIC_DIR outside the scratch directory was accepted")


def main() -> int:
    tests = [value for name, value in sorted(globals().items())
             if name.startswith("test_") and callable(value)]
    failures = 0
    for test in tests:
        skipped_before = len(SKIPPED)
        try:
            test()
        except AssertionError as exc:
            failures += 1
            print(f"FAIL  {test.__name__}: {exc}")
        except Exception as exc:
            failures += 1
            print(f"ERROR {test.__name__}: {type(exc).__name__}: {exc}")
        else:
            print(("skip  " if len(SKIPPED) > skipped_before else "ok    ") + test.__name__)
    passed = len(tests) - failures - len(SKIPPED)
    print(f"\n{passed}/{len(tests)} passed" + (
        f", {len(SKIPPED)} skipped (need POSIX paths)" if SKIPPED else ""))
    shutil.rmtree(_SCRATCH, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
