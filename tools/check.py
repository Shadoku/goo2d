#!/usr/bin/env python3
"""Run every automated check for this Godot project and print a compact report.

Stages (in order):
  build     - build the project's native code with tools/build_native.sh, if that
              script exists (e.g. a Rust GDExtension). Without cargo on PATH the stage
              is skipped when `build_native.sh --check` finds the library already built;
              when it does not, tools/install_native.sh (if the project has one) is run
              to download a prebuilt library, and the stage fails if that fails too.
  import    - (re)import assets and rebuild the class_name cache  (godot --import).
              Beforehand, .godot/extension_list.cfg is seeded if GDExtensions exist
              (rewritten when it misses one of the project's *.gdextension files).
  validate  - compile every .gd script and report parse/type errors
  test      - run the unit tests under tests/ with tests/framework/runner.gd
  smoke     - run the main scene headless for a few frames and fail on any error
  render    - run the main scene for a few frames with the real OpenGL renderer under
              Xvfb (xvfb-run) and fail on any error: headless uses a dummy renderer
              that never compiles shaders, so shader errors only show here.
              Skipped (not failed) when xvfb-run is not installed.
  Both also run each example the same way, one process per scene, reported as
  `smoke examples/<name>` / `render examples/<name>`: an example is a scene
  examples/<name>/<name>.tscn (named like its directory; other scenes there are not
  entry points). Without an examples/ directory only the main scene runs.

Usage:
  python3 tools/check.py                # everything
  python3 tools/check.py --only test    # one stage (build and import always run first)
  python3 tools/check.py --only build   # only build the native code
  python3 tools/check.py --only test --no-import   # fastest loop when no files were added
  python3 tools/check.py --filter=player  # pass a test filter to the runner
  python3 tools/check.py --verbose      # show full engine output for every stage
  python3 tools/check.py --only render  # compile shaders / draw a few frames under Xvfb

Exit code is 0 only when every stage passed. The last line is always
"CHECK: PASS" or "CHECK: FAIL (<stages>)" so the result is easy to spot.

Environment:
  GODOT   - path to the Godot 4 binary. If unset, PATH (godot, godot4) and
            ~/.cache/godot/<version>/godot are tried, where <version> comes from
            the .godot-version file next to project.godot.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SMOKE_FRAMES = 30
STAGE_TIMEOUT = {"build": 900, "import": 300, "validate": 120, "test": 1200, "smoke": 120, "render": 180}
# The render stage's virtual screen and the arguments that select the real renderer.
RENDER_SCREEN = "-screen 0 1920x1080x24"
RENDER_ARGS = ["--rendering-driver", "opengl3", "--audio-driver", "Dummy"]

# Error lines matching any of these regexes are ignored (known-benign headless noise).
IGNORE_PATTERNS = [
    r"XDG_RUNTIME_DIR",
    r"ALSA lib",
]

ERROR_PREFIX = re.compile(r"^(SCRIPT ERROR|SHADER ERROR|ERROR|USER ERROR):")
BANNER = re.compile(r"^Godot Engine v\d")


def godot_version() -> str:
    f = ROOT / ".godot-version"
    return f.read_text().strip() if f.exists() else "4.7.2-stable"


def find_godot() -> str:
    candidates = []
    if os.environ.get("GODOT"):
        candidates.append(os.environ["GODOT"])
    for name in ("godot", "godot4", "godot4-stable"):
        p = shutil.which(name)
        if p:
            candidates.append(p)
    candidates.append(str(Path.home() / ".cache" / "godot" / godot_version() / "godot"))
    candidates.append(str(Path.home() / ".cache" / "godot" / "godot"))
    for c in candidates:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    sys.exit(
        "No Godot binary found. Set GODOT=/path/to/godot, put `godot` on PATH, or run "
        ".claude/hooks/session-start.sh to download " + godot_version() + "."
    )


def ensure_extension_list() -> None:
    """Seed .godot/extension_list.cfg so the first --import already knows every GDExtension.

    Without it, the first import on a fresh .godot/ discovers the extensions mid-run
    and can crash at shutdown (exit code 134) even though every import step finished.
    The file is rewritten when it misses an extension (one added to an existing project).
    """
    cfg = ROOT / ".godot" / "extension_list.cfg"
    exts = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        # Godot does not scan hidden folders (.godot/, .git/, .claude/) or ones with a .gdignore.
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and not (Path(dirpath) / d / ".gdignore").exists())
        rel = Path(dirpath).relative_to(ROOT)
        exts += [(rel / f).as_posix() for f in sorted(filenames) if f.endswith(".gdextension")]
    if not exts:
        return
    listed = cfg.read_text().split() if cfg.exists() else []
    if all(f"res://{e}" in listed for e in exts):
        return
    cfg.parent.mkdir(exist_ok=True)
    cfg.write_text("".join(f"res://{e}\n" for e in exts))
    print(f"import: {'updated' if listed else 'seeded'} .godot/extension_list.cfg ({len(exts)} extensions)")


def build_native(timeout: int) -> tuple[str, str]:
    """Run tools/build_native.sh. Returns (status, output): status is PASS, FAIL, SKIP,
    DOWNLOADED or NONE.

    NONE: the project has no build_native.sh. Without cargo on PATH nothing is built:
    SKIP when `build_native.sh --check` finds the library from an earlier build; else
    DOWNLOADED when tools/install_native.sh exists and fetched a prebuilt library, else FAIL.
    """
    script = ROOT / "tools" / "build_native.sh"
    if not script.exists():
        return "NONE", ""
    no_cargo = shutil.which("cargo") is None
    cmd = ["bash", str(script), *(["--check"] if no_cargo else [])]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=ROOT)
    except subprocess.TimeoutExpired:
        return "FAIL", f"tools/build_native.sh timed out after {timeout}s"
    out = (proc.stdout + proc.stderr).strip()
    if not no_cargo:
        return ("PASS" if proc.returncode == 0 else "FAIL"), out
    if proc.returncode == 0:
        return "SKIP", out
    installer = ROOT / "tools" / "install_native.sh"
    if not installer.exists():
        return "FAIL", "cargo is not on PATH and the native library has not been built:\n" + out
    try:
        inst = subprocess.run(["bash", str(installer)], capture_output=True, text=True, timeout=timeout, cwd=ROOT)
    except subprocess.TimeoutExpired:
        return "FAIL", f"cargo is not on PATH and tools/install_native.sh timed out after {timeout}s"
    inst_out = (inst.stdout + inst.stderr).strip()
    if inst.returncode == 0:
        return "DOWNLOADED", inst_out
    return "FAIL", ("cargo is not on PATH, the native library has not been built, and "
                    "tools/install_native.sh could not download a prebuilt one:\n" + out + "\n" + inst_out)


def run(godot: str, args: list[str], timeout: int, prefix: list[str] | None = None) -> tuple[int, str]:
    """Run Godot on the project: headless, or under `prefix` (e.g. xvfb-run) with a real display."""
    if prefix:
        cmd = [*prefix, godot, "--path", str(ROOT), *args]
    else:
        cmd = [godot, "--headless", "--path", str(ROOT), *args]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=ROOT)
        out = proc.stdout + proc.stderr
        return proc.returncode, out
    except subprocess.TimeoutExpired as e:
        # A timeout hands back what was captured as bytes, whatever `text` says.
        out = "".join(part.decode(errors="replace") if isinstance(part, bytes) else (part or "")
                      for part in (e.stdout, e.stderr))
        return 124, out + f"\n[check.py] TIMEOUT after {timeout}s: {' '.join(cmd)}\n"


def find_examples() -> list[str]:
    """Every example, sorted by name, as `examples/<name>`: a directory under examples/
    holding a scene named like itself (examples/<name>/<name>.tscn). Hidden directories and
    ones with a .gdignore are skipped, as Godot does not import them."""
    base = ROOT / "examples"
    if not base.is_dir() or (base / ".gdignore").exists():
        return []
    return [f"examples/{d.name}" for d in sorted(base.iterdir(), key=lambda d: d.name)
            if d.is_dir() and not d.name.startswith(".") and not (d / ".gdignore").exists()
            and (d / f"{d.name}.tscn").is_file()]


def error_blocks(output: str) -> list[str]:
    """Extract ERROR / SCRIPT ERROR blocks (first line + indented continuation lines)."""
    blocks: list[list[str]] = []
    for line in output.splitlines():
        if ERROR_PREFIX.match(line):
            blocks.append([line])
        elif blocks and line[:1] in (" ", "\t") and blocks[-1] is not None:
            blocks[-1].append(line)
        else:
            blocks.append(None)  # break continuation
    result = []
    for b in blocks:
        if b is None:
            continue
        # Backtrace frames inside our own tooling are noise for the reader.
        b = [l for l in b if not ("validate_scripts.gd" in l and l.strip().startswith("["))]
        text = "\n".join(b)
        if any(re.search(p, text) for p in IGNORE_PATTERNS):
            continue
        result.append(text)
    return result


def clean(output: str) -> str:
    return "\n".join(l for l in output.splitlines() if not BANNER.match(l)).strip()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", choices=["build", "import", "validate", "test", "smoke", "render"], help="run a single stage (build and import always run first)")
    ap.add_argument("--no-import", action="store_true", help="skip the import stage (safe only when no scripts, scenes or assets were added or renamed)")
    ap.add_argument("--filter", help="only run tests whose 'file::method' id contains this substring")
    ap.add_argument("--verbose", action="store_true", help="print full engine output for every stage")
    ap.add_argument("--junit", help="write JUnit XML for the test stage to this path")
    ap.add_argument("--smoke-frames", type=int, default=SMOKE_FRAMES)
    ap.add_argument("--skip-smoke", action="store_true")
    ap.add_argument("--skip-render", action="store_true", help="skip the Xvfb render stage")
    ap.add_argument("--include-addons", action="store_true", help="also validate vendored addons (VENDORED.md)")
    args = ap.parse_args()

    godot = find_godot()
    print(f"godot: {godot}")
    failed: list[str] = []

    # Build: the project's native code (tools/build_native.sh), before Godot loads it.
    t0 = time.time()
    status, out = build_native(STAGE_TIMEOUT["build"])
    if status != "NONE":
        dt = time.time() - t0
        if status == "SKIP":
            print("[SKIP] build (no cargo)")
        elif status == "DOWNLOADED":
            print(f"[SKIP] build (no cargo; downloaded a prebuilt library with tools/install_native.sh, {dt:.1f}s)")
        else:
            print(f"[{status}] build ({dt:.1f}s)")
        if args.verbose or status == "FAIL":
            print("    " + out.replace("\n", "\n    "))
        if status == "FAIL":
            failed.append("build")
    if args.only == "build":
        print()
        print(f"CHECK: FAIL ({', '.join(failed)})" if failed else "CHECK: PASS")
        return 1 if failed else 0

    def stage(name: str, godot_args: list[str], judge, prefix: list[str] | None = None, label: str = "") -> None:
        """Run one stage. `name` is the base stage (for --only and STAGE_TIMEOUT); `label`,
        when given, is what the report prints and lists as failed (e.g. "smoke examples/x")."""
        if args.only and args.only != name and (name != "import" or args.only == "build"):
            return
        label = label or name
        t0 = time.time()
        code, out = run(godot, godot_args, STAGE_TIMEOUT[name], prefix)
        ok, details = judge(code, out)
        dt = time.time() - t0
        print(f"[{'PASS' if ok else 'FAIL'}] {label} ({dt:.1f}s)")
        if args.verbose:
            print("    " + clean(out).replace("\n", "\n    "))
        elif not ok:
            print("    " + details.replace("\n", "\n    "))
        else:
            # Always show the one-line summary so a report can quote it.
            for line in out.splitlines():
                if line.startswith(("TESTS:", "SCRIPTS:")):
                    print("    " + line)
        if not ok:
            failed.append(label)

    # 0. GDExtensions: register them before the first import (avoids a shutdown crash).
    ensure_extension_list()

    # 1. import: rebuilds .godot/, imports assets, refreshes class_name cache.
    if not args.no_import:
        stage("import", ["--import"], lambda code, out: (code == 0, clean(out)[-3000:]))

    # 2. validate: every script compiles. Details = the SCRIPT ERROR lines.
    def judge_validate(code, out):
        blocks = error_blocks(out)
        summary = [l for l in out.splitlines() if l.startswith(("[FAIL]", "SCRIPTS:"))]
        return code == 0, "\n".join(blocks + summary) or clean(out)[-3000:]
    validate_args = ["-s", "res://tools/validate_scripts.gd"]
    if args.include_addons:
        validate_args += ["--", "--include-addons"]
    stage("validate", validate_args, judge_validate)

    # 3. test: the runner already prints only failures + summary; show that verbatim.
    test_args = ["-s", "res://tests/framework/runner.gd", "--"]
    if args.verbose:
        test_args.append("--verbose")
    if args.filter:
        test_args.append(f"--filter={args.filter}")
    if args.junit:
        test_args.append(f"--junit={os.path.abspath(args.junit)}")
    stage("test", test_args, lambda code, out: (code == 0, clean(out)))

    # 4. smoke: main scene boots and runs N frames without printing any error; then each
    # example's scene the same way (Godot runs a scene given as a positional argument).
    examples = find_examples()
    def judge_smoke(code, out):
        blocks = error_blocks(out)
        ok = code == 0 and not blocks
        details = "\n".join(blocks) if blocks else clean(out)[-3000:]
        if code != 0:
            details = f"exit code {code}\n" + details
        return ok, details
    if not args.skip_smoke:
        stage("smoke", ["--quit-after", str(args.smoke_frames)], judge_smoke)
        for ex in examples:
            stage("smoke", ["--quit-after", str(args.smoke_frames), f"res://{ex}/{Path(ex).name}.tscn"],
                  judge_smoke, label=f"smoke {ex}")

    # 5. render: the same, drawn by the real OpenGL renderer on a virtual X screen,
    # which compiles every shader the main scene (and each example) uses (headless never does).
    if not args.skip_render and (not args.only or args.only == "render"):
        xvfb = shutil.which("xvfb-run")
        if xvfb:
            stage("render", [*RENDER_ARGS, "--quit-after", str(args.smoke_frames)], judge_smoke,
                  prefix=[xvfb, "-a", "-s", RENDER_SCREEN])
            for ex in examples:
                stage("render", [*RENDER_ARGS, "--quit-after", str(args.smoke_frames), f"res://{ex}/{Path(ex).name}.tscn"],
                      judge_smoke, prefix=[xvfb, "-a", "-s", RENDER_SCREEN], label=f"render {ex}")
        else:
            print("[SKIP] render (no xvfb-run)")

    print()
    if failed:
        print(f"CHECK: FAIL ({', '.join(failed)})")
        return 1
    print("CHECK: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
