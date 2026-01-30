#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
TMP_DIR="${TMP_DIR:-/tmp/winlator-imagefs}"
ROOTFS_TZST_URL="${ROOTFS_TZST_URL:-https://github.com/Waim908/rootfs-custom-winlator/releases/download/ori-b11.0/rootfs.tzst}"

mkdir -p "$OUT_DIR" "$TMP_DIR"

ROOTFS_TZST_PATH="$TMP_DIR/rootfs.tzst"
ROOTFS_DIR="$TMP_DIR/rootfs"

if [[ ! -f "$ROOTFS_TZST_PATH" ]]; then
  echo "[build-imagefs] Downloading rootfs.tzst..."
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 3 -o "$ROOTFS_TZST_PATH" "$ROOTFS_TZST_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$ROOTFS_TZST_PATH" "$ROOTFS_TZST_URL"
  else
    echo "[build-imagefs] Neither curl nor wget found" >&2
    exit 1
  fi
fi

rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

echo "[build-imagefs] Extracting rootfs.tzst..."
# Requires GNU tar with zstd support
if tar --zstd -tf "$ROOTFS_TZST_PATH" >/dev/null 2>&1; then
  tar --zstd -xf "$ROOTFS_TZST_PATH" -C "$ROOTFS_DIR"
else
  if command -v zstd >/dev/null 2>&1; then
    zstd -dc "$ROOTFS_TZST_PATH" | tar -xf - -C "$ROOTFS_DIR"
  else
    echo "[build-imagefs] zstd not available to extract rootfs.tzst" >&2
    exit 1
  fi
fi

OVERLAY_DIR="$ROOT_DIR/rootfs/overlays/imagefs"
if [[ -d "$OVERLAY_DIR" ]]; then
  echo "[build-imagefs] Applying overlay: $OVERLAY_DIR"
  rsync -a "$OVERLAY_DIR/" "$ROOTFS_DIR/"
fi

IMAGEFS_PATH="$OUT_DIR/imagefs.txz"

echo "[build-imagefs] Packing imagefs.txz..."
mkdir -p "$(dirname "$IMAGEFS_PATH")"
( 
  cd "$ROOTFS_DIR"
  tar -I 'xz -T8' -cf "$IMAGEFS_PATH" .
)

echo "[build-imagefs] Done: $IMAGEFS_PATH"
ls -lh "$IMAGEFS_PATH"
