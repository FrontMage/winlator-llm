#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
TMP_DIR="${TMP_DIR:-/tmp/winlator-imagefs}"
ROOTFS_TZST_URL="${ROOTFS_TZST_URL:-https://github.com/Waim908/rootfs-custom-winlator/releases/download/ori-b11.0/rootfs.tzst}"
BASE_IMAGEFS_TAR_URL="${BASE_IMAGEFS_TAR_URL:-}"
ENABLE_AUTH_DEPS="${ENABLE_AUTH_DEPS:-0}"
TERMUX_SAMBA_DEB_URL="${TERMUX_SAMBA_DEB_URL:-https://packages.termux.org/apt/termux-main/pool/main/s/samba/samba_4.16.11-6_aarch64.deb}"
TERMUX_LIBTALLOC_DEB_URL="${TERMUX_LIBTALLOC_DEB_URL:-https://packages.termux.org/apt/termux-main/pool/main/libt/libtalloc/libtalloc_2.4.3_aarch64.deb}"

mkdir -p "$OUT_DIR" "$TMP_DIR"

ROOTFS_TZST_PATH="$TMP_DIR/rootfs.tzst"
ROOTFS_DIR="$TMP_DIR/rootfs"

_download() {
  local url="$1"
  local dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 3 -o "$dest" "$url"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -O "$dest" "$url"
    return 0
  fi
  echo "[build-imagefs] Neither curl nor wget found" >&2
  exit 1
}

extract_deb() {
  local deb_path="$1" dest_dir="$2" work_dir="$3"
  mkdir -p "$work_dir"
  if command -v bsdtar >/dev/null 2>&1; then
    (cd "$work_dir" && bsdtar -xf "$deb_path")
  else
    echo "[build-imagefs] bsdtar not found for .deb extraction" >&2
    exit 1
  fi
  if [[ ! -f "$work_dir/data.tar.xz" ]]; then
    echo "[build-imagefs] data.tar.xz missing in $deb_path" >&2
    exit 1
  fi
  tar -xf "$work_dir/data.tar.xz" -C "$dest_dir"
}

if [[ ! -f "$ROOTFS_TZST_PATH" ]]; then
  echo "[build-imagefs] Downloading rootfs.tzst..."
  _download "$ROOTFS_TZST_URL" "$ROOTFS_TZST_PATH"
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

if [[ "$ENABLE_AUTH_DEPS" == "1" ]]; then
  echo "[build-imagefs] Installing ntlm_auth from Termux packages..."
  TERMUX_TMP="$TMP_DIR/termux"
  TERMUX_ROOT="$TERMUX_TMP/root"
  mkdir -p "$TERMUX_ROOT"

  SAMBA_DEB="$TERMUX_TMP/samba.deb"
  LIBTALLOC_DEB="$TERMUX_TMP/libtalloc.deb"
  _download "$TERMUX_SAMBA_DEB_URL" "$SAMBA_DEB"
  _download "$TERMUX_LIBTALLOC_DEB_URL" "$LIBTALLOC_DEB"

  extract_deb "$SAMBA_DEB" "$TERMUX_ROOT" "$TERMUX_TMP/samba"
  extract_deb "$LIBTALLOC_DEB" "$TERMUX_ROOT" "$TERMUX_TMP/libtalloc"

  TERMUX_PREFIX="$TERMUX_ROOT/data/data/com.termux/files/usr"
  TERMUX_LIB="$TERMUX_PREFIX/lib"
  TERMUX_SAMBA_LIB="$TERMUX_PREFIX/lib/samba"

  if [[ ! -x "$TERMUX_PREFIX/bin/ntlm_auth" ]]; then
    echo "[build-imagefs] ERROR: ntlm_auth missing in Termux samba package" >&2
    exit 1
  fi

  mkdir -p "$ROOTFS_DIR/usr/bin"
  cp -a "$TERMUX_PREFIX/bin/ntlm_auth" "$ROOTFS_DIR/usr/bin/ntlm_auth"

  # Mirror Termux library layout so rpath works
  mkdir -p "$ROOTFS_DIR/data/data/com.termux/files/usr/lib"
  mkdir -p "$ROOTFS_DIR/data/data/com.termux/files/usr/lib/samba"
  cp -a "$TERMUX_LIB/"* "$ROOTFS_DIR/data/data/com.termux/files/usr/lib/"
  cp -a "$TERMUX_SAMBA_LIB/"* "$ROOTFS_DIR/data/data/com.termux/files/usr/lib/samba/"
fi

# Optionally overlay known-good wine from a base imagefs bundle
if [[ -n "$BASE_IMAGEFS_TAR_URL" ]]; then
  echo "[build-imagefs] Downloading base imagefs bundle..."
  BASE_TAR="$TMP_DIR/base-imagefs.tar.xz"
  BASE_EXTRACT_DIR="$TMP_DIR/base-imagefs"
  BASE_TXZ_DIR="$TMP_DIR/base-imagefs-txz"
  BASE_ROOTFS_DIR="$TMP_DIR/base-imagefs-root"
  _download "$BASE_IMAGEFS_TAR_URL" "$BASE_TAR"
  rm -rf "$BASE_EXTRACT_DIR" "$BASE_TXZ_DIR" "$BASE_ROOTFS_DIR"
  mkdir -p "$BASE_EXTRACT_DIR" "$BASE_TXZ_DIR" "$BASE_ROOTFS_DIR"
  tar -xJf "$BASE_TAR" -C "$BASE_EXTRACT_DIR" app/src/main/assets/imagefs.txz
  BASE_IMAGEFS_TXZ="$BASE_EXTRACT_DIR/app/src/main/assets/imagefs.txz"
  if [[ ! -f "$BASE_IMAGEFS_TXZ" ]]; then
    echo "[build-imagefs] base imagefs.txz missing inside bundle" >&2
    exit 1
  fi
  tar -xJf "$BASE_IMAGEFS_TXZ" -C "$BASE_ROOTFS_DIR" ./opt/wine
  if [[ -d "$BASE_ROOTFS_DIR/opt/wine" ]]; then
    echo "[build-imagefs] Overlaying /opt/wine from base imagefs"
    rsync -a "$BASE_ROOTFS_DIR/opt/wine/" "$ROOTFS_DIR/opt/wine/"
  else
    echo "[build-imagefs] base imagefs missing /opt/wine" >&2
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
