#!/usr/bin/env python3
"""Scaffold a Godot 4 project with headless testing and AI-assisted development tooling.

Two modes:

  New project (target is empty or missing):
    python3 new_project.py ~/games/my_game --name "My Game" --type 2d

  Adopt an existing project (target already has project.godot):
    python3 new_project.py ~/games/existing --adopt

Adopt mode only adds files that are missing (tests/framework, tools/, CI, hooks,
CLAUDE.md, .godot-version, ...). It never rewrites project.godot, scenes, or
existing scripts. Use --force to overwrite files the template also provides.

Options:
  --name NAME              Project display name (default: target folder name)
  --type {2d,3d}           Main scene root: Node2D or Node3D (default 2d)
  --renderer R             forward_plus | mobile | gl_compatibility
                           (default: gl_compatibility for 2d, forward_plus for 3d)
  --godot-version V        4.6, 4.6.1, 4.7-rc1 ... (default 4.7.2); "-stable" is
                           appended when no suffix is given
  --adopt                  add tooling to an existing project
  --force                  overwrite existing files
  --no-ci --no-hook        skip .github/workflows or .claude hook files
  --no-skill               do not copy this skill into <target>/.claude/skills/
  --no-git                 do not run `git init` when the target is not in a repository
  --no-examples            skip src/health.gd and its tests (adopt mode default)
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
TEMPLATE = SKILL_DIR / "assets" / "template"

RENDERING = {
    "forward_plus": ("Forward Plus", ""),
    "mobile": ("Mobile", '\n[rendering]\n\nrenderer/rendering_method="mobile"\n'),
    "gl_compatibility": (
        "GL Compatibility",
        '\n[rendering]\n\nrenderer/rendering_method="gl_compatibility"\nrenderer/rendering_method.mobile="gl_compatibility"\n',
    ),
}

EXAMPLE_FILES = {"src/health.gd", "tests/unit/test_health.gd"}
CI_FILES = {".github/workflows/ci.yml"}
HOOK_FILES = {".claude/hooks/session-start.sh", ".claude/settings.json"}
# Files that describe the game itself; never touched in adopt mode.
PROJECT_FILES = {"project.godot", "scenes/main.tscn", "src/main.gd", "icon.svg", "README.md"}


def normalize_version(v: str) -> tuple[str, str]:
    """'4.6' -> ('4.6-stable', '4.6'); '4.6.1' -> ('4.6.1-stable', '4.6'); '4.7-rc1' -> ('4.7-rc1', '4.7')."""
    v = v.strip().lstrip("v")
    if "-" not in v:
        v += "-stable"
    m = re.match(r"(\d+)\.(\d+)", v)
    if not m or int(m.group(1)) < 4:
        sys.exit(f"--godot-version must be a Godot 4.x version, got {v!r}")
    return v, f"{m.group(1)}.{m.group(2)}"


def detect_version(project_godot: Path) -> str | None:
    text = project_godot.read_text(errors="replace")
    m = re.search(r'config/features=PackedStringArray\(([^)]*)\)', text)
    if not m:
        return None
    for feat in re.findall(r'"([^"]+)"', m.group(1)):
        if re.match(r"^\d+\.\d+", feat):
            return feat
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target")
    ap.add_argument("--name")
    ap.add_argument("--type", choices=["2d", "3d"], default="2d")
    ap.add_argument("--renderer", choices=list(RENDERING))
    ap.add_argument("--godot-version", default=None)
    ap.add_argument("--adopt", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--no-ci", action="store_true")
    ap.add_argument("--no-hook", action="store_true")
    ap.add_argument("--no-skill", action="store_true")
    ap.add_argument("--no-git", action="store_true")
    ap.add_argument("--no-examples", action="store_true")
    args = ap.parse_args()

    target = Path(args.target).resolve()
    project_godot = target / "project.godot"

    if args.adopt:
        if not project_godot.exists():
            sys.exit(f"--adopt needs an existing project.godot in {target}")
        args.no_examples = True
    else:
        if project_godot.exists() and not args.force:
            sys.exit(f"{target} already contains project.godot. Use --adopt to add tooling, or --force to overwrite.")
        if target.exists() and any(p.name not in {".git", "LICENSE", "README.md", ".claude", ".gitignore"} for p in target.iterdir()) and not args.force:
            sys.exit(f"{target} is not empty. Use --force to write into it anyway.")

    version_in = args.godot_version or (detect_version(project_godot) if args.adopt else None) or "4.7.2"
    full_version, feature = normalize_version(version_in)
    renderer = args.renderer or ("forward_plus" if args.type == "3d" else "gl_compatibility")
    feature_name, rendering_section = RENDERING[renderer]
    name = args.name or target.name
    main_node = "Node3D" if args.type == "3d" else "Node2D"

    subs = {
        "__PROJECT_NAME__": name,
        "__GODOT_VERSION__": full_version,
        "__GODOT_FEATURE__": feature,
        "__FEATURES__": f'"{feature}", "{feature_name}"',
        "__RENDERING_SECTION__": rendering_section,
        "__MAIN_NODE__": main_node,
    }

    written, skipped = [], []
    for src in sorted(TEMPLATE.rglob("*")):
        if not src.is_file():
            continue
        rel = src.relative_to(TEMPLATE).as_posix()
        if args.adopt and rel in PROJECT_FILES:
            continue
        if args.no_examples and rel in EXAMPLE_FILES:
            continue
        if args.no_ci and rel in CI_FILES:
            continue
        if args.no_hook and rel in HOOK_FILES:
            continue
        dest = target / rel
        if dest.exists() and not args.force:
            skipped.append(rel)
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        if src.suffix in {".png", ".jpg", ".zip"}:
            shutil.copy2(src, dest)
        else:
            text = src.read_text()
            for k, v in subs.items():
                text = text.replace(k, v)
            dest.write_text(text)
            if src.stat().st_mode & 0o111:
                dest.chmod(dest.stat().st_mode | 0o755)
        written.append(rel)

    if not args.no_skill:
        skill_dest = target / ".claude" / "skills" / SKILL_DIR.name
        if skill_dest.resolve() == SKILL_DIR.resolve():
            pass  # scaffolding the repo that hosts this skill
        elif skill_dest.exists() and not args.force:
            skipped.append(".claude/skills/" + SKILL_DIR.name)
        else:
            if skill_dest.exists():
                shutil.rmtree(skill_dest)
            shutil.copytree(SKILL_DIR, skill_dest, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
            written.append(".claude/skills/" + SKILL_DIR.name + "/")

    git_initialized = False
    if not args.no_git and shutil.which("git"):
        inside = subprocess.run(["git", "rev-parse", "--is-inside-work-tree"], cwd=target, capture_output=True, text=True)
        if inside.returncode != 0:
            subprocess.run(["git", "init", "-q"], cwd=target, check=False)
            git_initialized = True

    print(f"{'Adopted' if args.adopt else 'Created'} Godot {feature} project '{name}' at {target}")
    if git_initialized:
        print("  + (git init)")
    for rel in written:
        print(f"  + {rel}")
    for rel in skipped:
        print(f"  = {rel} (exists, kept)")
    if args.adopt and "CLAUDE.md" in skipped:
        print("\nCLAUDE.md already exists: merge the 'Commands', 'The development loop' and 'Writing tests'")
        print(f"sections from {TEMPLATE / 'CLAUDE.md'} into it.")
    print("\nNext steps:")
    print(f"  cd {target}")
    print("  bash tools/install_godot.sh      # once, if godot is not on PATH")
    print("  python3 tools/check.py           # must end with CHECK: PASS")
    print("  git add -A && git commit -m 'Scaffold Godot project with headless test tooling'   # includes the *.uid files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
