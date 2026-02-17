#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
  echo "error: aarch64-linux-gnu-gcc not found in PATH" >&2
  echo "hint: brew install aarch64-elf-gcc or gcc-aarch64-linux-gnu" >&2
  exit 1
fi

BUILD_DIR="$ROOT_DIR/build/rootfs-utils/aarch64"
ASSETS_DIR="$ROOT_DIR/app/src/main/assets/rootfs-utils/aarch64"

mkdir -p "$BUILD_DIR" "$ASSETS_DIR/usr/bin" "$ASSETS_DIR/bin"

echo "[rootfs-utils] building static aarch64 utilities"
aarch64-linux-gnu-gcc -static -O2 -s tools/rootfs-utils/env.c -o "$BUILD_DIR/env"
aarch64-linux-gnu-gcc -static -O2 -s tools/rootfs-utils/cat.c -o "$BUILD_DIR/cat"
aarch64-linux-gnu-gcc -static -O2 -s tools/rootfs-utils/lscpu.c -o "$BUILD_DIR/lscpu"

echo "[rootfs-utils] updating assets"
cp "$BUILD_DIR/env" "$ASSETS_DIR/usr/bin/env"
cp "$BUILD_DIR/cat" "$ASSETS_DIR/usr/bin/cat"
cp "$BUILD_DIR/cat" "$ASSETS_DIR/bin/cat"
cp "$BUILD_DIR/lscpu" "$ASSETS_DIR/usr/bin/lscpu"

chmod +x "$ASSETS_DIR/usr/bin/env" "$ASSETS_DIR/usr/bin/cat" "$ASSETS_DIR/bin/cat" "$ASSETS_DIR/usr/bin/lscpu"

echo "[rootfs-utils] done"
