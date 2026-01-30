#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ASSET_REPO="${WINLATOR_ASSET_REPO:-FrontMage/winlator-llm}"
ASSET_TAG="${WINLATOR_ASSET_TAG:-assets-v1}"
ASSET_NAME="${WINLATOR_ASSET_NAME:-winlator-assets-v1.tar.xz}"
ASSET_URL="${WINLATOR_ASSET_URL:-https://github.com/${ASSET_REPO}/releases/download/${ASSET_TAG}/${ASSET_NAME}}"
ASSET_TMP="${WINLATOR_ASSET_TMP:-/tmp/${ASSET_NAME}}"

REQUIRED_FILES=(
  "app/src/main/assets/imagefs.txz"
  "app/src/main/assets/imagefs_patches.tzst"
  "app/src/main/assets/container_pattern.tzst"
  "app/src/main/assets/wincomponents/direct3d.tzst"
  "app/src/main/assets/graphics_driver/zink-22.2.5.tzst"
  "app/src/main/assets/graphics_driver/virgl-23.1.9.tzst"
  "app/src/main/assets/graphics_driver/turnip-24.1.0.tzst"
  "app/src/main/assets/box86_64/box64-0.3.6.tzst"
  "app/src/main/assets/box86_64/box64-0.4.0.tzst"
  "app/src/main/assets/dxwrapper/dxvk-2.4.1.tzst"
  "app/src/main/assets/dxwrapper/vkd3d-2.12.tzst"
  "rootfs/archives/data.tar.xz"
)

missing=()
for rel_path in "${REQUIRED_FILES[@]}"; do
  if [[ ! -f "$ROOT_DIR/$rel_path" ]]; then
    missing+=("$rel_path")
  fi
done

if [[ "${#missing[@]}" -eq 0 ]]; then
  echo "[fetch-large-assets] All required assets are present."
  exit 0
fi

echo "[fetch-large-assets] Missing assets:"
printf '  - %s\n' "${missing[@]}"
echo "[fetch-large-assets] Downloading asset bundle:"
echo "  $ASSET_URL"

mkdir -p "$(dirname "$ASSET_TMP")"

if command -v curl >/dev/null 2>&1; then
  curl -L --fail -o "$ASSET_TMP" "$ASSET_URL"
elif command -v wget >/dev/null 2>&1; then
  wget -O "$ASSET_TMP" "$ASSET_URL"
else
  echo "[fetch-large-assets] Neither curl nor wget is available." >&2
  exit 1
fi

echo "[fetch-large-assets] Extracting $ASSET_TMP into repo root..."
tar -xJf "$ASSET_TMP" -C "$ROOT_DIR"

missing_after=()
for rel_path in "${REQUIRED_FILES[@]}"; do
  if [[ ! -f "$ROOT_DIR/$rel_path" ]]; then
    missing_after+=("$rel_path")
  fi
done

if [[ "${#missing_after[@]}" -ne 0 ]]; then
  echo "[fetch-large-assets] Extraction completed, but some files are still missing:" >&2
  printf '  - %s\n' "${missing_after[@]}" >&2
  exit 1
fi

echo "[fetch-large-assets] Done."
