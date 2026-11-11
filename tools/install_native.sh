#!/usr/bin/env bash
# Download Goo2D's prebuilt native kernel (the libraries .github/workflows/kernel.yml publishes
# as goo2d-kernel.zip) into addons/goo2d/bin/, for a checkout without a Rust toolchain. The
# last line printed is this platform's library path.
#
#   bash tools/install_native.sh            # the build named by .goo2d-kernel-version (below)
#   bash tools/install_native.sh v0.3.0     # a versioned release
#   bash tools/install_native.sh --update   # replace the library already in bin/ with the
#                                           # latest build (a rolling build moves with its branch)
#
# .goo2d-kernel-version holds either a release tag (v0.3.0) or the word `branch`: the rolling
# pre-release the workflow keeps for the current git branch, tagged kernel-<branch> with every
# character outside [A-Za-z0-9._-] replaced by '-' (kernel-claude-feature for claude/feature),
# falling back to kernel-main when the branch has none (its kernel is main's then).
#
# Environment:
#   GOO2D_KERNEL_VERSION  the tag, or `branch` (default: the argument, else .goo2d-kernel-version)
#   GOO2D_KERNEL_REPO     owner/repo the releases live in (default: Shadoku/goo2d)
#   GOO2D_KERNEL_URL      the zip's full URL, overriding the two above (a mirror, or a test)
#   GOO2D_KERNEL_CACHE    cache directory (default: ~/.cache/goo2d-kernel); the zip is kept in
#                         <cache>/<tag>/ and reused while its published SHA-256 is unchanged
#
# Idempotent: if this platform's library is already in addons/goo2d/bin/ nothing is
# downloaded unless --update is given. The library is built from the commit the build names
# (bin/kernel-commit.txt after installing); a checkout whose kernel sources differ from it
# needs a newer build, or cargo (bash tools/build_native.sh). check.py's build stage runs
# this when cargo is missing and no library is in place.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${GOO2D_KERNEL_REPO:-Shadoku/goo2d}"
CACHE="${GOO2D_KERNEL_CACHE:-$HOME/.cache/goo2d-kernel}"
ASSET="goo2d-kernel.zip"
PREFIX="addons/goo2d/bin"

UPDATE=false
WANT=""
for arg in "$@"; do
  case "$arg" in
    --update|-u) UPDATE=true ;;
    -*) echo "install_native.sh: unknown option $arg" >&2; exit 2 ;;
    *) WANT="$arg" ;;
  esac
done
WANT="${GOO2D_KERNEL_VERSION:-${WANT:-$(cat "$ROOT/.goo2d-kernel-version" 2>/dev/null || true)}}"
WANT="$(echo "$WANT" | tr -d '[:space:]')"
if [ -z "$WANT" ]; then
  WANT="branch"
fi

# Which tags to try, in order: a named tag alone; `branch` is the current branch's rolling
# build, then main's.
TAGS=()
if [ "$WANT" = "branch" ]; then
  BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ]; then
    TAGS+=("kernel-$(printf '%s' "$BRANCH" | tr -c 'A-Za-z0-9._-' '-')")
  fi
  TAGS+=("kernel-main")
else
  TAGS+=("$WANT")
fi

# build_native.sh --check knows this platform's library name and whether it is in bin/.
if [ "$UPDATE" = false ] && LIB="$(bash "$ROOT/tools/build_native.sh" --check 2>/dev/null | tail -n 1)"; then
  echo "$LIB"
  exit 0
fi

command -v curl >/dev/null 2>&1 || { echo "install_native.sh: curl is required" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Fetches the zip of one tag into the cache (refreshing it when the published SHA-256 differs
# from the cached zip's) and prints its path; fails when the tag has no zip.
fetch() {
  local tag="$1"
  local url="${GOO2D_KERNEL_URL:-https://github.com/$REPO/releases/download/$tag/$ASSET}"
  local dest="$CACHE/$tag"
  local zip="$dest/$ASSET"
  mkdir -p "$dest"
  local want=""
  if curl -fsSL --retry 2 -o "$zip.sha256.new" "$url.sha256" 2>/dev/null; then
    want="$(awk '{print $1}' "$zip.sha256.new")"
  fi
  rm -f "$zip.sha256.new"
  if [ -s "$zip" ] && { [ -z "$want" ] || [ "$(sha256_of "$zip")" = "$want" ]; }; then
    echo "$zip"
    return 0
  fi
  echo "install_native.sh: downloading $url" >&2
  if ! curl -fsSL --retry 3 --retry-delay 2 -o "$zip.part" "$url"; then
    rm -f "$zip.part"
    return 1
  fi
  if [ -n "$want" ]; then
    local have
    have="$(sha256_of "$zip.part")"
    if [ "$want" != "$have" ]; then
      rm -f "$zip.part"
      echo "install_native.sh: checksum mismatch for $url (expected $want, got $have)" >&2
      exit 1
    fi
  else
    echo "install_native.sh: no $ASSET.sha256 next to the zip; not verified" >&2
  fi
  mv "$zip.part" "$zip"
  echo "$zip"
}

ZIP=""
TAG=""
for candidate in "${TAGS[@]}"; do
  if ZIP="$(fetch "$candidate")"; then
    TAG="$candidate"
    break
  fi
  echo "install_native.sh: no $ASSET published for $candidate" >&2
done
if [ -z "$ZIP" ]; then
  echo "install_native.sh: could not download the kernel (tried: ${TAGS[*]}; is it published, with $ASSET attached? see .github/workflows/kernel.yml)" >&2
  exit 1
fi

TMP="$(mktemp -d "$CACHE/$TAG/unpack.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
if command -v unzip >/dev/null 2>&1; then
  unzip -o -q "$ZIP" "$PREFIX/*" -d "$TMP" || { echo "install_native.sh: $ZIP has no $PREFIX/ (delete it to download again)" >&2; exit 1; }
else
  python3 -I -m zipfile -e "$ZIP" "$TMP" || { echo "install_native.sh: could not unpack $ZIP (delete it to download again)" >&2; exit 1; }
fi
if [ ! -d "$TMP/$PREFIX" ]; then
  echo "install_native.sh: $ZIP has no $PREFIX/ (delete it to download again)" >&2
  exit 1
fi
mkdir -p "$ROOT/$PREFIX"
cp -R "$TMP/$PREFIX/." "$ROOT/$PREFIX/"

if ! LIB="$(bash "$ROOT/tools/build_native.sh" --check 2>/dev/null | tail -n 1)"; then
  echo "install_native.sh: $ASSET of $TAG has no library for $(uname -s)-$(uname -m); build it with cargo (bash tools/build_native.sh)" >&2
  exit 1
fi
COMMIT="$(cat "$ROOT/$PREFIX/kernel-commit.txt" 2>/dev/null || echo "an unknown commit")"
echo "install_native.sh: installed the Goo2D kernel $TAG (built from $COMMIT) into $PREFIX/" >&2
echo "$LIB"
