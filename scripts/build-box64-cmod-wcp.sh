#!/usr/bin/env bash
set -euo pipefail

log() { printf '[build-box64-cmod-wcp] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BOX64_SRC="${BOX64_SRC:-$HOME/Documents/box64}"
NDK_DIR="${NDK_DIR:-$HOME/Library/Android/sdk/ndk/26.1.10909125}"
ANDROID_PLATFORM="${ANDROID_PLATFORM:-android-31}"
ANDROID_ABI="${ANDROID_ABI:-arm64-v8a}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
BUILD_DIR="${BUILD_DIR:-/tmp/box64_cmod_build_${ANDROID_PLATFORM}_ndk26b}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/box64-cmod-wcp}"

VERSION_NAME="${VERSION_NAME:-}"
VERSION_CODE="${VERSION_CODE:-0}"
DESCRIPTION="${DESCRIPTION:-}"
PROFILE_TARGET="${PROFILE_TARGET:-\${bindir}/box64}"

FORTIFY="${FORTIFY:-off}" # off|on
STRIP_BIN="${STRIP_BIN:-1}" # 1|0
TAR_UID="${TAR_UID:-10314}"
TAR_GID="${TAR_GID:-1023}"

usage() {
  cat <<'USAGE'
Build Box64 from source and package it as a cmod-style .wcp (0.4.1-fix format).

Usage:
  scripts/build-box64-cmod-wcp.sh [options]

Options:
  --box64-src <dir>         Box64 source dir (default: ~/Documents/box64)
  --ndk-dir <dir>           Android NDK dir (default: ~/Library/Android/sdk/ndk/26.1.10909125)
  --platform <android-xx>   Android platform (default: android-31)
  --abi <abi>               ABI (default: arm64-v8a)
  --build-type <type>       CMake build type (default: Release)
  --build-dir <dir>         Build dir (default: /tmp/box64_cmod_build_android-31_ndk26b)
  --out-dir <dir>           Output dir (default: ./out/box64-cmod-wcp)
  --version-name <name>     profile.json versionName (default: <box64-version>-fix)
  --version-code <num>      profile.json versionCode (default: 0)
  --description <text>      profile.json description (default: "Box64-<versionName> | Built from Pypetto-Crypto.")
  --profile-target <path>   profile target (default: ${bindir}/box64)
  --fortify <off|on>        Disable/enable _FORTIFY_SOURCE (default: off)
  --strip <0|1>             Strip binary (default: 1)
  --tar-uid <uid>           Archive UID for entries (default: 10314)
  --tar-gid <gid>           Archive GID for entries (default: 1023)
  -h, --help                Show this help

Env passthrough:
  BOX64_EXTRA_CMAKE_ARGS    Extra arguments appended to cmake configure command.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --box64-src) BOX64_SRC="${2:-}"; shift 2 ;;
    --ndk-dir) NDK_DIR="${2:-}"; shift 2 ;;
    --platform) ANDROID_PLATFORM="${2:-}"; shift 2 ;;
    --abi) ANDROID_ABI="${2:-}"; shift 2 ;;
    --build-type) BUILD_TYPE="${2:-}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --version-name) VERSION_NAME="${2:-}"; shift 2 ;;
    --version-code) VERSION_CODE="${2:-}"; shift 2 ;;
    --description) DESCRIPTION="${2:-}"; shift 2 ;;
    --profile-target) PROFILE_TARGET="${2:-}"; shift 2 ;;
    --fortify) FORTIFY="${2:-}"; shift 2 ;;
    --strip) STRIP_BIN="${2:-}"; shift 2 ;;
    --tar-uid) TAR_UID="${2:-}"; shift 2 ;;
    --tar-gid) TAR_GID="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

pick_ndk_prebuilt_dir() {
  local base="$NDK_DIR/toolchains/llvm/prebuilt"
  [[ -d "$base" ]] || die "NDK prebuilt dir missing: $base"

  if [[ -d "$base/darwin-arm64" ]]; then
    printf '%s\n' "$base/darwin-arm64"
    return 0
  fi
  if [[ -d "$base/darwin-x86_64" ]]; then
    printf '%s\n' "$base/darwin-x86_64"
    return 0
  fi

  local first
  first="$(find "$base" -maxdepth 1 -type d -name 'darwin-*' | head -n 1 || true)"
  [[ -n "$first" ]] || die "No darwin-* prebuilt found under $base"
  printf '%s\n' "$first"
}

compute_default_version_name() {
  local ver
  ver="$(python3 - <<PY
import pathlib, re
p = pathlib.Path("$BOX64_SRC") / "src/box64version.h"
txt = p.read_text(encoding="utf-8", errors="replace")
def get(name):
    m = re.search(rf"{name}\\s+(\\d+)", txt)
    return m.group(1) if m else "0"
print(f"{get('BOX64_MAJOR')}.{get('BOX64_MINOR')}.{get('BOX64_REVISION')}-fix")
PY
)"
  printf '%s\n' "$ver"
}

main() {
  ensure_cmd cmake
  ensure_cmd python3
  ensure_cmd xz
  ensure_cmd bsdtar
  ensure_cmd file

  [[ -d "$BOX64_SRC" ]] || die "BOX64 source dir not found: $BOX64_SRC"
  [[ -f "$BOX64_SRC/CMakeLists.txt" ]] || die "Not a Box64 source tree: $BOX64_SRC"

  local toolchain="$NDK_DIR/build/cmake/android.toolchain.cmake"
  [[ -f "$toolchain" ]] || die "Missing Android toolchain file: $toolchain"

  local prebuilt
  prebuilt="$(pick_ndk_prebuilt_dir)"
  local llvm_strip="$prebuilt/bin/llvm-strip"
  local llvm_readelf="$prebuilt/bin/llvm-readelf"
  [[ -x "$llvm_strip" ]] || die "Missing llvm-strip at $llvm_strip"
  [[ -x "$llvm_readelf" ]] || die "Missing llvm-readelf at $llvm_readelf"

  if [[ -z "$VERSION_NAME" ]]; then
    VERSION_NAME="$(compute_default_version_name)"
  fi
  if [[ -z "$DESCRIPTION" ]]; then
    DESCRIPTION="Box64-${VERSION_NAME} | Built from Pypetto-Crypto."
  fi
  if [[ "$PROFILE_TARGET" == *'${bindir/'* ]]; then
    die "PROFILE_TARGET looks malformed: $PROFILE_TARGET (did you mean \${bindir}/box64?)"
  fi

  case "$FORTIFY" in
    on|off) ;;
    *) die "--fortify must be off|on (got: $FORTIFY)" ;;
  esac
  case "$STRIP_BIN" in
    0|1) ;;
    *) die "--strip must be 0|1 (got: $STRIP_BIN)" ;;
  esac

  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"

  local -a cmake_args=(
    -DCMAKE_TOOLCHAIN_FILE="$toolchain"
    -DANDROID_ABI="$ANDROID_ABI"
    -DANDROID_PLATFORM="$ANDROID_PLATFORM"
    -DANDROID=1
    -DARM_DYNAREC=1
    -DBAD_SIGNAL=1
    -DCI=0
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
  )

  if [[ "$FORTIFY" == "off" ]]; then
    cmake_args+=(
      -DCMAKE_C_FLAGS="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"
      -DCMAKE_CXX_FLAGS="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"
    )
  fi

  if [[ -n "${BOX64_EXTRA_CMAKE_ARGS:-}" ]]; then
    # Intentional word splitting for custom cmake args.
    # shellcheck disable=SC2206
    local extra=(${BOX64_EXTRA_CMAKE_ARGS})
    cmake_args+=("${extra[@]}")
  fi

  log "Configuring Box64 (platform=$ANDROID_PLATFORM abi=$ANDROID_ABI fortify=$FORTIFY)"
  cmake "$BOX64_SRC" "${cmake_args[@]}" -B "$BUILD_DIR"

  log "Building Box64"
  cmake --build "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)"
  [[ -f "$BUILD_DIR/box64" ]] || die "Build output not found: $BUILD_DIR/box64"

  if [[ "$STRIP_BIN" == "1" ]]; then
    "$llvm_strip" -s "$BUILD_DIR/box64" || true
  fi

  mkdir -p "$OUT_DIR"
  local stage tmp_tar out_wcp
  stage="$(mktemp -d)"
  tmp_tar="$(mktemp -t box64-cmod-XXXXXX.tar)"
  out_wcp="$OUT_DIR/box64-${VERSION_NAME}.wcp"

  cp "$BUILD_DIR/box64" "$stage/box64"
  chmod 660 "$stage/box64"

  cat >"$stage/profile.json" <<JSON
{
  "type": "Box64",
  "versionName": "${VERSION_NAME}",
  "versionCode": ${VERSION_CODE},
  "description": "${DESCRIPTION}",
  "files": [
    {
      "source": "box64",
      "target": "${PROFILE_TARGET}"
    }
  ]
}
JSON
  chmod 660 "$stage/profile.json"
  chmod 2770 "$stage"

  log "Packaging cmod-style archive: GNU tar + xz(CRC32)"
  bsdtar --format gnutar --uid "$TAR_UID" --gid "$TAR_GID" -cf "$tmp_tar" -C "$stage" .
  xz --check=crc32 -c "$tmp_tar" > "$out_wcp"

  log "Wrote: $out_wcp"
  file "$out_wcp"
  bsdtar -tvvvf "$out_wcp"
  log "profile.json:"
  bsdtar -xOf "$out_wcp" ./profile.json
  log "box64 hash:"
  bsdtar -xOf "$out_wcp" ./box64 | shasum -a 256
  log "dynamic symbols check (_chk means fortify path):"
  "$llvm_readelf" -s "$BUILD_DIR/box64" | awk '/__strlen_chk|__strcpy_chk|__strcat_chk| strlen$| strcpy$| strcat$/ {print}' | sed -n '1,40p'

  rm -rf "$stage"
  rm -f "$tmp_tar"
}

main "$@"
