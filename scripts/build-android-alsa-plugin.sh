#!/usr/bin/env bash
set -euo pipefail

# Builds a bionic-compatible ALSA PCM plugin for Winlator's Android AServer backend.
#
# Why: The Linux/glibc-built plugin fails to dlopen in the arm64ec "direct exec" path:
#   dlopen failed: library "libc.so.6" not found
#
# Output: aarch64 shared object suitable for:
#   imagefs/usr/lib/alsa-lib/libasound_module_pcm_android_aserver.so

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_PATH="${1:-$REPO_ROOT/out/audio/libasound_module_pcm_android_aserver.so}"

ALSALIB_VER="1.2.14"
ALSALIB_URL="https://www.alsa-project.org/files/pub/lib/alsa-lib-${ALSALIB_VER}.tar.bz2"

ndk_root="${ANDROID_NDK_HOME:-}"
if [[ -z "${ndk_root}" ]]; then
  # Prefer the newest installed NDK under the default macOS Android SDK location.
  ndk_base="$HOME/Library/Android/sdk/ndk"
  if [[ -d "$ndk_base" ]]; then
    ndk_root="$(ls -1 "$ndk_base" | sort -V | tail -n 1)"
    ndk_root="$ndk_base/$ndk_root"
  fi
fi

if [[ -z "${ndk_root}" || ! -d "${ndk_root}" ]]; then
  echo "Error: Android NDK not found. Set ANDROID_NDK_HOME or install under ~/Library/Android/sdk/ndk/." >&2
  exit 1
fi

clang="${ndk_root}/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android21-clang"
if [[ ! -x "${clang}" ]]; then
  echo "Error: NDK clang not found/executable: ${clang}" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

alsa_tar="${tmp_dir}/alsa-lib.tar.bz2"
alsa_src="${tmp_dir}/alsa-lib-src"

echo "Downloading ALSA headers: ${ALSALIB_URL}"
curl -fsSL -o "${alsa_tar}" "${ALSALIB_URL}"
mkdir -p "${alsa_src}"
tar -x -f "${alsa_tar}" -C "${alsa_src}"
alsa_include="$(find "${alsa_src}" -maxdepth 2 -type d -name include | head -n 1)"
if [[ -z "${alsa_include}" || ! -d "${alsa_include}" ]]; then
  echo "Error: failed to locate ALSA include dir in tarball" >&2
  exit 1
fi

# Extract the bionic libasound we ship inside imagefs for link-time resolution.
lib_dir="${tmp_dir}/libs"
mkdir -p "${lib_dir}"
xz -dc "${REPO_ROOT}/app/src/main/assets/imagefs.txz" | tar -x -f - -C "${lib_dir}" usr/lib/libasound.so.2.0.0
libasound_path="${lib_dir}/usr/lib/libasound.so.2.0.0"
if [[ ! -f "${libasound_path}" ]]; then
  echo "Error: failed to extract libasound.so.2.0.0 from imagefs.txz" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUT_PATH}")"

echo "Building: ${OUT_PATH}"
"${clang}" \
  -shared -fPIC -O2 -Wall \
  -DPIC \
  -I"${alsa_include}" \
  -Wl,-soname,libasound_module_pcm_android_aserver.so \
  "${REPO_ROOT}/audio_plugin/module_pcm_android_aserver.c" \
  "${libasound_path}" \
  -o "${OUT_PATH}"

echo
echo "Dynamic deps:"
objdump -p "${OUT_PATH}" | sed -n '1,120p' | awk '/Dynamic Section:/{p=1} p{print} /Version References:/{exit}'
