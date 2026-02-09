#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ASSET_REPO="${WINLATOR_ASSET_REPO:-FrontMage/winlator-llm}"
IMAGEFS_SOURCE="${WINLATOR_IMAGEFS_SOURCE:-bionic}"

BIONIC_IMAGEFS_BASE_URL="${WINLATOR_BIONIC_IMAGEFS_BASE_URL:-https://gitlab.com/winlator3/winlator-extra/-/raw/main/imagefs}"
BIONIC_IMAGEFS_PARTS="${WINLATOR_BIONIC_IMAGEFS_PARTS:-4}"
BIONIC_IMAGEFS_SHA_URL="${WINLATOR_BIONIC_IMAGEFS_SHA_URL:-${BIONIC_IMAGEFS_BASE_URL}/imagefs.txz.sha256sum}"

REQUIRED_FILES=(
  "app/src/main/assets/imagefs_patches.tzst"
  "app/src/main/assets/container_pattern_common.tzst"
  "app/src/main/assets/wincomponents/direct3d.tzst"
  "app/src/main/assets/graphics_driver/zink-22.2.5.tzst"
  "app/src/main/assets/graphics_driver/virgl-23.1.9.tzst"
  "app/src/main/assets/graphics_driver/turnip-24.1.0.tzst"
  "app/src/main/assets/dxwrapper/dxvk-2.4.1.tzst"
  "app/src/main/assets/dxwrapper/vkd3d-2.12.tzst"
  "app/src/main/assets/preinstall/proton-10-arm64ec.wcp.xz"
  "app/src/main/assets/wine-10.0-arm64ec_container_pattern.tzst"
  "rootfs/archives/data.tar.xz"
)

ASSET_GROUPS=(
  "wincomponents-v1|wincomponents-v1.tar.xz|app/src/main/assets/wincomponents/direct3d.tzst"
  "drivers-v1|drivers-v1.tar.xz|app/src/main/assets/graphics_driver/zink-22.2.5.tzst app/src/main/assets/graphics_driver/virgl-23.1.9.tzst app/src/main/assets/graphics_driver/turnip-24.1.0.tzst"
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

download_bionic_imagefs() {
  local dest="$1"
  local sha_url="$2"
  local base_url="$3"
  local parts="$4"

  if command -v curl >/dev/null 2>&1; then
    remote_sha="$(curl -L --fail "$sha_url" | awk '{print $1}')"
  elif command -v wget >/dev/null 2>&1; then
    remote_sha="$(wget -qO- "$sha_url" | awk '{print $1}')"
  else
    echo "[fetch-large-assets] Neither curl nor wget is available to fetch imagefs checksum." >&2
    exit 1
  fi

  local needs_download=1
  if [[ -f "$dest" ]]; then
    local_sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
    if [[ "$local_sha" == "$remote_sha" ]]; then
      needs_download=0
    fi
  fi

  if [[ "$needs_download" -eq 0 ]]; then
    echo "[fetch-large-assets] Using cached bionic imagefs (checksum match)."
    return 0
  fi

  echo "[fetch-large-assets] Downloading bionic imagefs from ${base_url} ..."
  tmp_dest="${dest}.download"
  : > "$tmp_dest"
  for ((i=0; i<parts; i++)); do
    part=$(printf "%02d" "$i")
    part_url="${base_url}/imagefs.txz.${part}"
    if command -v curl >/dev/null 2>&1; then
      curl -L --fail "$part_url" >> "$tmp_dest"
    else
      wget -qO- "$part_url" >> "$tmp_dest"
    fi
  done

  local_sha="$(shasum -a 256 "$tmp_dest" | awk '{print $1}')"
  if [[ "$local_sha" != "$remote_sha" ]]; then
    echo "[fetch-large-assets] imagefs checksum mismatch after download." >&2
    rm -f "$tmp_dest"
    exit 1
  fi

  mv "$tmp_dest" "$dest"
}

missing_any=0
for rel_path in "${REQUIRED_FILES[@]}"; do
  if [[ ! -f "$ROOT_DIR/$rel_path" ]]; then
    missing_any=1
    break
  fi
done

if [[ "$missing_any" -eq 0 && "$IMAGEFS_SOURCE" != "bionic" ]]; then
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

IMAGEFS_ASSET="$ROOT_DIR/app/src/main/assets/imagefs.txz"
if [[ "$IMAGEFS_SOURCE" == "bionic" ]]; then
  download_bionic_imagefs "$IMAGEFS_ASSET" "$BIONIC_IMAGEFS_SHA_URL" "$BIONIC_IMAGEFS_BASE_URL" "$BIONIC_IMAGEFS_PARTS"
else
  # Legacy: imagefs is provided by release bundle.
  if [[ ! -f "$IMAGEFS_ASSET" ]]; then
    echo "[fetch-large-assets] imagefs is missing and IMAGEFS_SOURCE=release; ensure release bundle includes it." >&2
    exit 1
  fi
fi

ARM64EC_WINE_ASSET="app/src/main/assets/preinstall/proton-10-arm64ec.wcp.xz"
ARM64EC_WINE_URL="${WINLATOR_ARM64EC_WINE_URL:-https://github.com/StevenMXZ/Winlator-Contents/releases/download/1.0/proton-10-arm64ec.wcp.xz}"
if [[ ! -f "$ROOT_DIR/$ARM64EC_WINE_ASSET" ]]; then
  echo "[fetch-large-assets] Downloading ARM64EC Wine from third-party ..."
  mkdir -p "$(dirname "$ROOT_DIR/$ARM64EC_WINE_ASSET")"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail -o "$ROOT_DIR/$ARM64EC_WINE_ASSET" "$ARM64EC_WINE_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$ROOT_DIR/$ARM64EC_WINE_ASSET" "$ARM64EC_WINE_URL"
  else
    echo "[fetch-large-assets] Neither curl nor wget is available to download ARM64EC Wine." >&2
    exit 1
  fi
fi

CONTAINER_PATTERN_COMMON_ASSET="app/src/main/assets/container_pattern_common.tzst"
CONTAINER_PATTERN_COMMON_URL="${WINLATOR_CONTAINER_PATTERN_COMMON_URL:-https://github.com/StevenMXZ/Winlator-Ludashi/raw/main/app/src/main/assets/container_pattern_common.tzst}"
if [[ ! -f "$ROOT_DIR/$CONTAINER_PATTERN_COMMON_ASSET" ]]; then
  src="$ROOT_DIR/third_party/Winlator-Ludashi/app/src/main/assets/container_pattern_common.tzst"
  if [[ -f "$src" ]]; then
    echo "[fetch-large-assets] Copying container_pattern_common.tzst from third_party/Winlator-Ludashi ..."
    cp -f "$src" "$ROOT_DIR/$CONTAINER_PATTERN_COMMON_ASSET"
  else
    echo "[fetch-large-assets] Downloading container_pattern_common.tzst from upstream ..."
    mkdir -p "$(dirname "$ROOT_DIR/$CONTAINER_PATTERN_COMMON_ASSET")"
    if command -v curl >/dev/null 2>&1; then
      curl -L --fail -o "$ROOT_DIR/$CONTAINER_PATTERN_COMMON_ASSET" "$CONTAINER_PATTERN_COMMON_URL"
    elif command -v wget >/dev/null 2>&1; then
      wget -O "$ROOT_DIR/$CONTAINER_PATTERN_COMMON_ASSET" "$CONTAINER_PATTERN_COMMON_URL"
    else
      echo "[fetch-large-assets] Neither curl nor wget is available to download container_pattern_common.tzst." >&2
      exit 1
    fi
  fi
fi

ARM64EC_WINE_CONTAINER_PATTERN_ASSET="app/src/main/assets/wine-10.0-arm64ec_container_pattern.tzst"
if [[ ! -f "$ROOT_DIR/$ARM64EC_WINE_CONTAINER_PATTERN_ASSET" ]]; then
  echo "[fetch-large-assets] Generating wine-10.0-arm64ec_container_pattern.tzst from prefixPack.txz ..."
  if ! command -v zstd >/dev/null 2>&1; then
    echo "[fetch-large-assets] zstd is required to generate $ARM64EC_WINE_CONTAINER_PATTERN_ASSET." >&2
    exit 1
  fi
  if ! command -v bsdtar >/dev/null 2>&1; then
    echo "[fetch-large-assets] bsdtar is required to generate $ARM64EC_WINE_CONTAINER_PATTERN_ASSET." >&2
    exit 1
  fi

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/winlator-prefixpack.XXXXXX")"
  # Extract prefixPack.txz from the WCP package (tar.xz)
  xz -dc "$ROOT_DIR/$ARM64EC_WINE_ASSET" | bsdtar -xf - -C "$tmp_dir" ./prefixPack.txz
  # Extract prefixPack.txz (contains .wine/)
  bsdtar -xf "$tmp_dir/prefixPack.txz" -C "$tmp_dir"
  # Produce tar.zst rooted at .wine/
  (cd "$tmp_dir" && bsdtar -cf - .wine | zstd -19 -T0 -o "$ROOT_DIR/$ARM64EC_WINE_CONTAINER_PATTERN_ASSET")
  rm -rf "$tmp_dir"
fi

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
