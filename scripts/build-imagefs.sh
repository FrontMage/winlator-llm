#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
TMP_DIR="${TMP_DIR:-/tmp/winlator-imagefs}"
ROOTFS_TZST_URL="${ROOTFS_TZST_URL:-https://github.com/Waim908/rootfs-custom-winlator/releases/download/ori-b11.0/rootfs.tzst}"
BASE_IMAGEFS_TAR_URL="${BASE_IMAGEFS_TAR_URL:-}"
ENABLE_AUTH_DEPS="${ENABLE_AUTH_DEPS:-1}"

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

download_pkg_from_repo() {
  local repo_base="$1" pkg_prefix="$2" out_dir="$3"
  local listing
  listing=$(curl -fsSL "$repo_base" || true)
  if [[ -z "$listing" ]]; then
    return 1
  fi
  local pkg_file
  pkg_file=$(echo "$listing" | grep -Eo "${pkg_prefix}-[0-9][^\"']*\.pkg\.tar\.(xz|zst)" | sort -V | tail -n 1)
  if [[ -z "$pkg_file" ]]; then
    return 1
  fi
  mkdir -p "$out_dir"
  local dest="$out_dir/$pkg_file"
  if [[ ! -f "$dest" ]]; then
    echo "[build-imagefs] Downloading $pkg_file" >&2
    _download "${repo_base}/${pkg_file}" "$dest"
  fi
  echo "$dest"
}

extract_pkg() {
  local pkg_path="$1" dest_dir="$2"
  if [[ "$pkg_path" == *.pkg.tar.zst ]]; then
    if tar --zstd -tf "$pkg_path" >/dev/null 2>&1; then
      tar --zstd -xf "$pkg_path" -C "$dest_dir"
    elif command -v zstd >/dev/null 2>&1; then
      zstd -dc "$pkg_path" | tar -xf - -C "$dest_dir"
    else
      echo "[build-imagefs] zstd not available to extract $pkg_path" >&2
      exit 1
    fi
  else
    tar -xf "$pkg_path" -C "$dest_dir"
  fi
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
  echo "[build-imagefs] Ensuring NTLM/Kerberos dependencies..."
  PKG_TMP="$TMP_DIR/pkgs"
  mkdir -p "$PKG_TMP"
  REPO_BASES=(
    "http://mirror.archlinuxarm.org/aarch64/extra"
    "http://mirror.archlinuxarm.org/aarch64/community"
    "http://mirror.archlinuxarm.org/aarch64/core"
  )
  PKGS=(
    "samba"
    "libwbclient"
  )
  for pkg in "${PKGS[@]}"; do
    pkg_path=""
    for repo in "${REPO_BASES[@]}"; do
      if pkg_path=$(download_pkg_from_repo "$repo" "$pkg" "$PKG_TMP"); then
        break
      fi
    done
    if [[ -z "$pkg_path" ]]; then
      echo "[build-imagefs] Warning: package $pkg not found in repos" >&2
      continue
    fi
    extract_pkg "$pkg_path" "$ROOTFS_DIR"
  done

  if [[ ! -x "$ROOTFS_DIR/usr/bin/ntlm_auth" ]]; then
    echo "[build-imagefs] ERROR: ntlm_auth missing after package extraction" >&2
    exit 1
  fi
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
