#!/bin/bash
# SessionStart hook for Claude Code on the web: make a Godot binary and Goo2D's
# native kernel available so `python3 tools/check.py` works. Does nothing outside
# the remote environment.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BIN="$(bash "$ROOT/tools/install_godot.sh" | tail -n 1)"
# Goo2D's native kernel (addons/goo2d/bin/ is not committed): build it with cargo.
if ! command -v cargo >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi
if bash "$ROOT/tools/build_native.sh" >/dev/null 2>&1; then
  echo "Goo2D native kernel built"
elif ! command -v cargo >/dev/null 2>&1 && bash "$ROOT/tools/install_native.sh" >/dev/null 2>&1; then
  echo "Goo2D native kernel downloaded (no cargo; tools/install_native.sh)"
else
  echo "build_native.sh failed (no cargo, or a build error); run bash tools/build_native.sh by hand" >&2
fi

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export GODOT=\"$BIN\"" >> "$CLAUDE_ENV_FILE"
  echo "export PATH=\"$(dirname "$BIN"):\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

# Warm the import cache so the first check of the session is fast. Going through
# check.py seeds .godot/extension_list.cfg first, which a fresh import with a
# GDExtension (the goo's kernel) needs to avoid crashing at shutdown.
(cd "$ROOT" && GODOT="$BIN" python3 tools/check.py --only import >/dev/null 2>&1) || true
echo "Godot ready: $BIN"
