#!/usr/bin/env bash
# kernel.yml's check of addons/goo2d/bin/ after the build jobs' artifacts were gathered
# into it: every platform's library is there, each matches the SHA-256 its build job
# wrote next to it (<job>.sha256), and each is a sound image
# (tools/check_kernel_image.py). The checksum files are removed afterwards, so neither
# the zip nor the commit carries them. Exits 1 on any failure.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../addons/goo2d/bin"
ls -laR .
for lib in libgoo2d_kernel.linux.x86_64-unknown-linux-gnu.so \
    libgoo2d_kernel.windows.x86_64-pc-windows-msvc.dll \
    libgoo2d_kernel.macos.framework/libgoo2d_kernel.macos.dylib \
    libgoo2d_kernel.macos.framework/Resources/Info.plist; do
  test -f "$lib" || { echo "verify_kernel_bin.sh: $lib is missing" >&2; exit 1; }
done
sums=(*.sha256)
if [ "${#sums[@]}" -ne 3 ]; then
  echo "verify_kernel_bin.sh: expected 3 checksum files, found ${#sums[@]}: ${sums[*]}" >&2
  exit 1
fi
for sum in "${sums[@]}"; do
  sha256sum -c "$sum"
done
rm -f -- *.sha256
python3 ../../../tools/check_kernel_image.py \
  libgoo2d_kernel.linux.x86_64-unknown-linux-gnu.so \
  libgoo2d_kernel.windows.x86_64-pc-windows-msvc.dll \
  libgoo2d_kernel.macos.framework/libgoo2d_kernel.macos.dylib
echo "verify_kernel_bin.sh: every library is the one its build job made"
