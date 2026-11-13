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
  test      - run the tests under tests/ with tests/framework/runner.gd, in simulated
              time (the runner's --fixed-fps: frames run as fast as they compute) and
              split by file over --jobs processes, slowest files first by the times of
              the last run (.godot/check_times.json).
  smoke     - run the main scene headless for a few frames and fail on any error
  render    - run the main scene for a few frames with the real OpenGL renderer under
              Xvfb (xvfb-run) and fail on any error: headless uses a dummy renderer
              that never compiles shaders, so shader errors only show here.
              Skipped (not failed) when xvfb-run is not installed.
  Both also run each example the same way, one process per scene, reported as
  `smoke examples/<name>` / `render examples/<name>`: an example is a scene
  examples/<name>/<name>.tscn (named like its directory; other scenes there are not
  entry points). Without an examples/ directory only the main scene runs.
  Each level, a scene levels/<name>.tscn (directly in levels/), runs the same way
  after the examples, reported as `smoke levels/<name>` / `render levels/<name>`.

validate runs alone; the test processes, the smoke runs and the render runs (those one
after another: one X server at a time) then run side by side. The report keeps its order.

Tiers:
  --tier quick  - validate and the tests under tests/unit/ only: seconds, for the inner
                  loop while implementing. No smoke, no render.
  --tier full   - everything (the default). The only tier that says a change works.

Pass cache: when a run passes, a fingerprint of every file of the project (tracked or
untracked, not ignored) and of the Godot binary is stored under ~/.cache/godot-check/.
A later run on exactly the same files answers from it without running anything, printing
the stored report under a [CACHED] line (a full pass answers for any narrower run too,
except one with a --filter).
So checking again work that was already checked, e.g. a subagent's after it returns,
costs nothing, and still runs for real when a single byte differs. Failures are never
cached. --fresh ignores the cache; --verbose, --junit and --include-addons always run.

Usage:
  python3 tools/check.py                # everything
  python3 tools/check.py --tier quick   # validate + tests/unit only
  python3 tools/check.py --fresh        # run even if these exact files already passed
  python3 tools/check.py --jobs 1       # one process at a time
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
import concurrent.futures
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
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

# The test stage: where each process writes its JUnit report, the per-file times of the
# last run (how the files are spread over the processes), and the least estimated work
# worth another process (starting Godot twice costs about half a second).
SHARD_DIR = ROOT / ".godot" / "check"
TIMES_FILE = ROOT / ".godot" / "check_times.json"
MIN_SHARD_SECONDS = 2.0
TESTS_LINE = re.compile(r"^TESTS: (\d+) passed, (\d+) failed, (\d+) errors, (\d+) skipped \((\d+) total\)$", re.M)
# The pass cache: one file per fingerprint, the oldest pruned beyond PASS_CACHE_KEEP.
PASS_CACHE_KEEP = 200

ERROR_PREFIX = re.compile(r"^(SCRIPT ERROR|SHADER ERROR|ERROR|USER ERROR):")
BANNER = re.compile(r"^(Godot Engine v\d|Initialize godot-rust )")


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


def find_levels() -> list[str]:
    """Every level, sorted by name, as `levels/<name>`: a scene directly in levels/
    (levels/<name>.tscn). Hidden files are skipped, and so is the whole directory when it
    holds a .gdignore."""
    base = ROOT / "levels"
    if not base.is_dir() or (base / ".gdignore").exists():
        return []
    return [f"levels/{f.stem}" for f in sorted(base.glob("*.tscn"), key=lambda f: f.name)
            if f.is_file() and not f.name.startswith(".")]


def extra_scenes() -> list[tuple[str, str]]:
    """The scenes the smoke and render stages run after the main scene, as (label, res://
    path): each example's entry scene, then each level."""
    scenes = [(ex, f"res://{ex}/{Path(ex).name}.tscn") for ex in find_examples()]
    scenes += [(lv, f"res://{lv}.tscn") for lv in find_levels()]
    return scenes


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


def default_jobs() -> int:
    try:
        return max(1, len(os.sched_getaffinity(0)))
    except AttributeError:  # not on Linux
        return max(1, os.cpu_count() or 1)


def find_test_files(tier: str) -> list[str]:
    """Every test script as the runner finds them (tests/**/test_*.gd, hidden directories
    skipped), relative to the project; only those under tests/unit/ for the quick tier."""
    base = ROOT / "tests"
    files = [p.relative_to(ROOT).as_posix() for p in base.rglob("test_*.gd")
             if p.is_file() and not any(part.startswith(".") for part in p.relative_to(ROOT).parts)]
    if tier == "quick":
        files = [f for f in files if f.startswith("tests/unit/")]
    return sorted(files)


def load_times() -> dict[str, float]:
    try:
        data = json.loads(TIMES_FILE.read_text())
        return {str(k): float(v) for k, v in data.items()}
    except (OSError, ValueError, AttributeError):
        return {}


def plan_shards(files: list[str], times: dict[str, float], jobs: int) -> list[list[str]]:
    """Spread the test files over at most `jobs` processes of about equal work: longest
    file first, each to the least loaded process. A file never timed counts as the slowest
    known one. No more processes than there are MIN_SHARD_SECONDS of estimated work."""
    if not files:
        return []
    known = [times[f] for f in files if f in times]
    unknown = max(known) if known else MIN_SHARD_SECONDS
    estimate = {f: times.get(f, unknown) for f in files}
    count = max(1, min(jobs, len(files), math.ceil(sum(estimate.values()) / MIN_SHARD_SECONDS)))
    shards: list[list[str]] = [[] for _ in range(count)]
    load = [0.0] * count
    for f in sorted(files, key=lambda f: (-estimate[f], f)):
        i = load.index(min(load))
        shards[i].append(f)
        load[i] += estimate[f]
    return [sorted(s) for s in shards if s]


def read_junit(paths: list[Path]) -> list[ET.Element]:
    cases: list[ET.Element] = []
    for path in paths:
        try:
            cases += list(ET.parse(path).getroot().iter("testcase"))
        except (OSError, ET.ParseError):
            pass
    return cases


def save_times(cases: list[ET.Element]) -> None:
    """Remember how long each test file took (files not run this time keep their time)."""
    spent: dict[str, float] = {}
    for case in cases:
        name = case.get("classname", "")
        spent[name] = spent.get(name, 0.0) + float(case.get("time", "0") or 0)
    if not spent:
        return
    times = {f: t for f, t in load_times().items() if (ROOT / f).is_file()}
    times.update({f: round(t, 3) for f, t in spent.items()})
    try:
        TIMES_FILE.parent.mkdir(exist_ok=True)
        TIMES_FILE.write_text(json.dumps(times, indent=1, sort_keys=True) + "\n")
    except OSError:
        pass


def write_junit(path: str, cases: list[ET.Element]) -> None:
    cases = sorted(cases, key=lambda c: c.get("classname", ""))  # stable: the runner's order within a file
    suite = ET.Element("testsuite", name="godot", tests=str(len(cases)),
                       failures=str(sum(1 for c in cases if c.find("failure") is not None)),
                       skipped=str(sum(1 for c in cases if c.find("skipped") is not None)))
    suite.extend(cases)
    ET.indent(suite)
    ET.ElementTree(suite).write(path, encoding="UTF-8", xml_declaration=True)


def project_files() -> list[str]:
    """Every file that can change a check's result: tracked or untracked, not ignored
    (so not .godot/). Outside a git checkout: everything outside hidden directories."""
    try:
        proc = subprocess.run(["git", "ls-files", "-co", "--exclude-standard", "-z"],
                              capture_output=True, cwd=ROOT, timeout=60)
        if proc.returncode == 0:
            return sorted(set(n for n in proc.stdout.decode(errors="surrogateescape").split("\0") if n))
    except (OSError, subprocess.TimeoutExpired):
        pass
    names = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        names += [(Path(dirpath).relative_to(ROOT) / f).as_posix() for f in filenames]
    return sorted(names)


def tree_fingerprint(godot: str) -> str:
    """A hash of the project's files (names and contents) and of the Godot binary's
    identity: equal fingerprints mean a check would run on exactly the same thing."""
    h = hashlib.sha256()
    for name in project_files():
        path = ROOT / name
        if not path.is_file():
            continue  # tracked but deleted
        h.update(name.encode(errors="surrogateescape") + b"\0")
        h.update(hashlib.sha256(path.read_bytes()).digest())
    st = os.stat(godot)
    h.update(f"godot\0{os.path.realpath(godot)}\0{st.st_size}\0{st.st_mtime_ns}".encode())
    return h.hexdigest()


def pass_cache_dir() -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "godot-check" / "passes"


def load_pass(fingerprint: str, scope: str, full_answers: bool) -> dict | None:
    """The stored pass that answers for `scope` on these files: its own, or (when
    `full_answers`) a full one."""
    try:
        scopes = json.loads((pass_cache_dir() / f"{fingerprint}.json").read_text())
        return scopes.get(scope) or (scopes.get("full") if full_answers else None)
    except (OSError, ValueError, AttributeError):
        return None


def store_pass(fingerprint: str, scope: str, seconds: float, report: list[str]) -> None:
    directory = pass_cache_dir()
    path = directory / f"{fingerprint}.json"
    try:
        directory.mkdir(parents=True, exist_ok=True)
        try:
            scopes = json.loads(path.read_text())
        except (OSError, ValueError):
            scopes = {}
        scopes[scope] = {"when": time.strftime("%Y-%m-%d %H:%M:%S"), "seconds": round(seconds, 1),
                         "full": scope == "full", "report": report}
        tmp = path.with_suffix(f".{os.getpid()}.tmp")
        tmp.write_text(json.dumps(scopes))
        os.replace(tmp, path)
        stored = sorted(directory.glob("*.json"), key=lambda f: f.stat().st_mtime)
        for old in stored[:-PASS_CACHE_KEEP]:
            old.unlink(missing_ok=True)
    except OSError:
        pass


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", choices=["build", "import", "validate", "test", "smoke", "render"], help="run a single stage (build and import always run first)")
    ap.add_argument("--tier", choices=["quick", "full"], default="full", help="quick: validate and tests/unit only; full (default): everything")
    ap.add_argument("--no-import", action="store_true", help="skip the import stage (safe only when no scripts, scenes or assets were added or renamed)")
    ap.add_argument("--filter", help="only run tests whose 'file::method' id contains this substring")
    ap.add_argument("--jobs", type=int, default=default_jobs(), help="how many Godot processes run side by side (default: the CPUs available)")
    ap.add_argument("--fresh", action="store_true", help="run even when these exact files already passed (ignore the pass cache)")
    ap.add_argument("--real-time", action="store_true", help="run the tests against the wall clock instead of simulated time (slow: a second of game time takes a second)")
    ap.add_argument("--verbose", action="store_true", help="print full engine output for every stage")
    ap.add_argument("--junit", help="write JUnit XML for the test stage to this path")
    ap.add_argument("--smoke-frames", type=int, default=SMOKE_FRAMES)
    ap.add_argument("--skip-smoke", action="store_true")
    ap.add_argument("--skip-render", action="store_true", help="skip the Xvfb render stage")
    ap.add_argument("--include-addons", action="store_true", help="also validate vendored addons (VENDORED.md)")
    args = ap.parse_args()
    jobs = max(1, args.jobs)
    started = time.time()

    godot = find_godot()
    print(f"godot: {godot}")
    failed: list[str] = []
    report: list[str] = []  # what a later run on the same files prints from the pass cache

    def emit(line: str = "") -> None:
        print(line)
        report.append(line)

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

    def wanted(name: str) -> bool:
        """Whether --only and --tier leave this stage in."""
        if args.only and args.only != name:
            return False
        if args.tier == "quick" and name in ("smoke", "render"):
            return False
        return True

    xvfb = shutil.which("xvfb-run")
    do_smoke = wanted("smoke") and not args.skip_smoke
    # --only smoke has never run the render stage; --only render does.
    do_render = wanted("render") and not args.skip_render and args.only != "smoke"

    # Pass cache: these exact files may have passed this check (or the full one) already.
    scope = ""
    fingerprint = ""
    if not (args.verbose or args.junit or args.include_addons or args.only == "import" or failed):
        is_full = (not args.only and args.tier == "full" and not args.filter and do_smoke
                   and do_render and bool(xvfb) and args.smoke_frames == SMOKE_FRAMES and not args.real_time)
        scope = "full" if is_full else json.dumps(
            [args.only, args.tier, args.filter, do_smoke, do_render and bool(xvfb), args.smoke_frames, args.real_time])
        fingerprint = tree_fingerprint(godot)
        # A filtered run is answered only by the same filter's pass: a full pass does not
        # say that the filter matches any test.
        hit = None if args.fresh else load_pass(fingerprint, scope, not args.filter)
        if hit:
            what = "the full check" if hit.get("full") else "this check"
            print(f"[CACHED] these exact files passed {what} on {hit['when']} ({hit['seconds']}s). "
                  "Nothing was run; --fresh runs it again. Its report:")
            for line in hit["report"]:
                print(("    " + line).rstrip())
            print()
            print("CHECK: PASS")
            return 0

    def timed_run(godot_args: list[str], timeout: int, prefix: list[str] | None = None) -> tuple[int, str, float]:
        t0 = time.time()
        code, out = run(godot, godot_args, timeout, prefix)
        return code, out, time.time() - t0

    def show(label: str, ok: bool, dt: float, out: str, details: str, note: str = "") -> None:
        emit(f"[{'PASS' if ok else 'FAIL'}] {label} ({dt:.1f}s{note})")
        if args.verbose:
            emit("    " + clean(out).replace("\n", "\n    "))
        elif not ok:
            emit("    " + details.replace("\n", "\n    "))
        else:
            # Always show the one-line summary so a report can quote it.
            for line in out.splitlines():
                if line.startswith(("TESTS:", "SCRIPTS:")):
                    emit("    " + line)
        if not ok:
            failed.append(label)

    def stage(name: str, godot_args: list[str], judge) -> None:
        """Run one stage on its own, now."""
        if args.only and args.only != name and name != "import":
            return
        code, out, dt = timed_run(godot_args, STAGE_TIMEOUT[name])
        ok, details = judge(code, out)
        show(name, ok, dt, out, details)

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

    # 3-5. test, smoke and render run side by side, `jobs` Godot processes at a time; the
    # report is printed in the usual order once each has finished.
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=jobs)

    # 3. test: the files spread over several runner processes. Each prints only its
    # failures and a summary, and writes a JUnit report (the per-file times, --junit).
    shards = plan_shards(find_test_files(args.tier), load_times(), jobs) if wanted("test") else []
    shard_reports = [SHARD_DIR / f"tests_{i}.xml" for i in range(len(shards))]
    test_futures = []
    if shards:
        SHARD_DIR.mkdir(parents=True, exist_ok=True)
        for old in SHARD_DIR.glob("tests_*.xml"):
            old.unlink()
    for files, junit in zip(shards, shard_reports):
        test_args = ["-s", "res://tests/framework/runner.gd", "--", "--allow-empty",
                     "--files=" + ",".join(files), f"--junit={junit}"]
        if args.verbose:
            test_args.append("--verbose")
        if args.filter:
            test_args.append(f"--filter={args.filter}")
        if args.real_time:
            test_args.append("--real-time")
        test_futures.append(pool.submit(timed_run, test_args, STAGE_TIMEOUT["test"]))

    # 4. smoke: main scene boots and runs N frames without printing any error; then each
    # example's scene the same way (Godot runs a scene given as a positional argument).
    scenes = [("", "")] + extra_scenes()
    def judge_smoke(code, out):
        blocks = error_blocks(out)
        ok = code == 0 and not blocks
        details = "\n".join(blocks) if blocks else clean(out)[-3000:]
        if code != 0:
            details = f"exit code {code}\n" + details
        return ok, details
    def scene_args(scene: str) -> list[str]:
        return ["--quit-after", str(args.smoke_frames), *([scene] if scene else [])]

    # 5. render: the same, drawn by the real OpenGL renderer on a virtual X screen,
    # which compiles every shader the main scene (and each example) uses (headless never does).
    # One after another in a single job: xvfb-run -a is not safe to start side by side.
    def render_all() -> list[tuple[int, str, float]]:
        return [timed_run([*RENDER_ARGS, *scene_args(scene)], STAGE_TIMEOUT["render"],
                          [xvfb, "-a", "-s", RENDER_SCREEN]) for _, scene in scenes]
    render_future = pool.submit(render_all) if do_render and xvfb else None
    smoke_futures = [pool.submit(timed_run, scene_args(scene), STAGE_TIMEOUT["smoke"])
                     for _, scene in scenes] if do_smoke else []

    if wanted("test"):
        results = [f.result() for f in test_futures]
        cases = read_junit(shard_reports)
        save_times(cases)
        if args.junit:
            write_junit(args.junit, cases)
        totals = [0, 0, 0, 0, 0]
        bodies = []
        complete = True
        for code, out, _ in results:
            text = clean(out)
            found = TESTS_LINE.search(text)
            if found:
                totals = [a + int(b) for a, b in zip(totals, found.groups())]
                text = "\n".join(l for l in text.splitlines() if not l.startswith(("TESTS:", "RESULT:"))).strip()
            else:
                complete = False  # the runner itself died or timed out: show all it printed
            if text:
                bodies.append(text)
        summary = "TESTS: %d passed, %d failed, %d errors, %d skipped (%d total)" % tuple(totals)
        if totals[4] == 0 and complete:
            bodies.append("No tests found. Put test_*.gd files extending TestCase under tests/"
                          + (f" (nothing matches --filter={args.filter})" if args.filter else ""))
        ok = complete and totals[4] > 0 and all(code == 0 for code, _, _ in results)
        merged = "\n".join(bodies + ["", summary]).strip()
        note = f", {len(results)} processes" if len(results) > 1 else ""
        show("test", ok, max((dt for _, _, dt in results), default=0.0), merged, merged, note)

    for (label, _), future in zip(scenes, smoke_futures):
        code, out, dt = future.result()
        ok, details = judge_smoke(code, out)
        show(f"smoke {label}".strip(), ok, dt, out, details)

    if render_future:
        for (label, _), (code, out, dt) in zip(scenes, render_future.result()):
            ok, details = judge_smoke(code, out)
            show(f"render {label}".strip(), ok, dt, out, details)
    elif do_render:
        emit("[SKIP] render (no xvfb-run)")
    pool.shutdown()

    seconds = time.time() - started
    print()
    print(f"total: {seconds:.1f}s")
    if failed:
        print(f"CHECK: FAIL ({', '.join(failed)})")
        return 1
    # Remember the pass, unless a file changed while the check ran.
    if fingerprint and tree_fingerprint(godot) == fingerprint:
        store_pass(fingerprint, scope, seconds, report)
    print("CHECK: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
