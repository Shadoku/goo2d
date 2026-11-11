#!/usr/bin/env bash
# Build Goo2D's native kernel (the Rust crate in addons/goo2d/native/) and copy the library
# into addons/goo2d/bin/ under the name addons/goo2d/goo2d.gdextension expects for this
# platform. Prints what it did; the last line is the library's path.
#
#   bash tools/build_native.sh            # cargo build --release, then copy if changed
#   bash tools/build_native.sh --check    # build nothing: exit 0 if the library is in bin/
#
# Idempotent and fast when nothing changed (cargo's own incremental check, then a byte
# compare before copying). Exits non-zero when the build fails or cargo is missing.
# Used by check.py (its `build` stage), CI and the Claude session hook; bin/ and the
# crate's target/ are not committed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE="$ROOT/addons/goo2d/native"
BIN="$ROOT/addons/goo2d/bin"
NAME="goo2d_kernel"

# Cargo's output name for this platform, and the name the .gdextension gives it in bin/.
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  BUILT="lib$NAME.so";     LIB="lib$NAME.linux.x86_64-unknown-linux-gnu.so" ;;
  Linux-aarch64) BUILT="lib$NAME.so";     LIB="lib$NAME.linux.aarch64-unknown-linux-gnu.so" ;;
  Darwin-*)      BUILT="lib$NAME.dylib";  LIB="lib$NAME.macos.framework/lib$NAME.macos.dylib" ;;
  MINGW*-x86_64|MSYS*-x86_64|CYGWIN*-x86_64)
                 BUILT="$NAME.dll";       LIB="lib$NAME.windows.x86_64-pc-windows-msvc.dll" ;;
  *) echo "build_native.sh: unsupported platform $(uname -s)-$(uname -m); add it here and in addons/goo2d/goo2d.gdextension" >&2; exit 1 ;;
esac
DEST="$BIN/$LIB"

if [ "${1:-}" = "--check" ]; then
  if [ -f "$DEST" ]; then
    echo "$DEST"
    exit 0
  fi
  echo "build_native.sh: $DEST is missing; install Rust (https://rustup.rs) and run bash tools/build_native.sh" >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "build_native.sh: cargo not found; install Rust (https://rustup.rs) to build $CRATE" >&2
  exit 1
fi

echo "build_native.sh: cargo build --release in ${CRATE#"$ROOT"/}" >&2
(cd "$CRATE" && cargo build --release --quiet)

SRC="${CARGO_TARGET_DIR:-$CRATE/target}/release/$BUILT"
if [ ! -f "$SRC" ]; then
  echo "build_native.sh: cargo succeeded but $SRC does not exist" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
if [ -f "$DEST" ] && cmp -s "$SRC" "$DEST"; then
  echo "build_native.sh: ${DEST#"$ROOT"/} is up to date" >&2
else
  # Copy to a temporary name first so a running Godot never sees a half-written library.
  cp "$SRC" "$DEST.part"
  mv -f "$DEST.part" "$DEST"
  echo "build_native.sh: copied ${SRC#"$ROOT"/} to ${DEST#"$ROOT"/}" >&2
fi

# A macOS framework needs an Info.plist naming its binary.
case "$LIB" in
  *.framework/*)
    PLIST="$(dirname "$DEST")/Resources/Info.plist"
    if [ ! -f "$PLIST" ]; then
      mkdir -p "$(dirname "$PLIST")"
      cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>$(basename "$LIB")</string>
	<key>CFBundleIdentifier</key>
	<string>org.goo2d.goo2d-kernel</string>
	<key>CFBundleName</key>
	<string>Goo2D kernel</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>MacOSX</string>
	</array>
</dict>
</plist>
PLIST_EOF
    fi
    ;;
esac

echo "$DEST"
