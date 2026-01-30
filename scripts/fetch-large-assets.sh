#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ASSET_REPO="${WINLATOR_ASSET_REPO:-FrontMage/winlator-llm}"

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

ASSET_GROUPS=(
  "imagefs-v1|imagefs-v1.tar.xz|app/src/main/assets/imagefs.txz app/src/main/assets/imagefs_patches.tzst"
  "container-pattern-v1|container-pattern-v1.tar.xz|app/src/main/assets/container_pattern.tzst"
  "wincomponents-v1|wincomponents-v1.tar.xz|app/src/main/assets/wincomponents/direct3d.tzst"
  "drivers-v1|drivers-v1.tar.xz|app/src/main/assets/graphics_driver/zink-22.2.5.tzst app/src/main/assets/graphics_driver/virgl-23.1.9.tzst app/src/main/assets/graphics_driver/turnip-24.1.0.tzst"
  "box64-v1|box64-v1.tar.xz|app/src/main/assets/box86_64/box64-0.3.6.tzst app/src/main/assets/box86_64/box64-0.4.0.tzst"
  "dx-wrapper-v1|dx-wrapper-v1.tar.xz|app/src/main/assets/dxwrapper/dxvk-2.4.1.tzst app/src/main/assets/dxwrapper/vkd3d-2.12.tzst"
  "rootfs-archives-v1|rootfs-archives-v1.tar.xz|rootfs/archives/data.tar.xz"
)

download_asset() {
  local tag="$1"
  local name="$2"
  local dest="$3"

  if [[ -f "$dest" ]]; then
    echo "[fetch-large-assets] Using cached bundle: $dest"
    return 0
  fi

  if command -v gh >/dev/null 2>&1; then
    gh release download "$tag" -R "$ASSET_REPO" -p "$name" -O "$dest"
    return 0
  fi

  local url="https://github.com/${ASSET_REPO}/releases/download/${tag}/${name}"
  if command -v curl >/dev/null 2>&1; then
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      curl -L --fail -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/octet-stream" -o "$dest" "$url"
    else
      curl -L --fail -o "$dest" "$url"
    fi
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      wget --header="Authorization: Bearer ${GITHUB_TOKEN}" --header="Accept: application/octet-stream" -O "$dest" "$url"
    else
      wget -O "$dest" "$url"
    fi
    return 0
  fi

  echo "[fetch-large-assets] Neither gh, curl nor wget is available." >&2
  exit 1
}

missing_any=0
for rel_path in "${REQUIRED_FILES[@]}"; do
  if [[ ! -f "$ROOT_DIR/$rel_path" ]]; then
    missing_any=1
    break
  fi
done

if [[ "$missing_any" -eq 0 ]]; then
  echo "[fetch-large-assets] All required assets are present."
  exit 0
fi

echo "[fetch-large-assets] Resolving missing assets from release bundles..."

for group in "${ASSET_GROUPS[@]}"; do
  IFS='|' read -r tag name files <<< "$group"
  needs_download=0
  for rel_path in $files; do
    if [[ ! -f "$ROOT_DIR/$rel_path" ]]; then
      needs_download=1
      break
    fi
  done
  if [[ "$needs_download" -eq 0 ]]; then
    continue
  fi

  asset_tmp="/tmp/${name}"
  echo "[fetch-large-assets] Downloading $name from $ASSET_REPO:$tag ..."
  download_asset "$tag" "$name" "$asset_tmp"
  echo "[fetch-large-assets] Extracting $name ..."
  tar -xJf "$asset_tmp" -C "$ROOT_DIR"
done

missing_after=()
for rel_path in "${REQUIRED_FILES[@]}"; do
  if [[ ! -f "$ROOT_DIR/$rel_path" ]]; then
    missing_after+=("$rel_path")
  fi
done

if [[ "${#missing_after[@]}" -ne 0 ]]; then
  echo "[fetch-large-assets] Extraction completed, but some files are still missing:" >&2
  printf '  - %s\n' "${missing_after[@]}" >&2
  echo "[fetch-large-assets] If repo is private, ensure gh auth or GITHUB_TOKEN is available." >&2
  exit 1
fi

echo "[fetch-large-assets] Done."
