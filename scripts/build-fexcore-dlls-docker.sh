#!/usr/bin/env bash
set -euo pipefail

# Build FEX's Wine-on-ARM Windows DLLs (libwow64fex.dll + libarm64ecfex.dll)
# inside a Linux/arm64 Docker container, then package them as a .tzst that
# Winlator can extract into wineprefix system32.
#
# This is intentionally different from "traditional" FEX builds: we are building
# the Windows bridge DLLs that Wine loads, not the Linux FEX binaries.
#
# Outputs:
# - out/fexcore/libwow64fex.dll
# - out/fexcore/libarm64ecfex.dll
# - out/fexcore/fexcore-<ver>.tzst
#
# Usage:
#   scripts/build-fexcore-dlls-docker.sh
#   scripts/build-fexcore-dlls-docker.sh --fexcore-version 2508 --update-assets
#

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

FEXCORE_VERSION="2508"
UPDATE_ASSETS="0"
DOCKER_IMAGE="ubuntu:latest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fexcore-version)
      FEXCORE_VERSION="${2:?missing value for --fexcore-version}"
      shift 2
      ;;
    --update-assets)
      UPDATE_ASSETS="1"
      shift
      ;;
    --docker-image)
      DOCKER_IMAGE="${2:?missing value for --docker-image}"
      shift 2
      ;;
    -h|--help)
      sed -n '1,120p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found" >&2
  exit 1
fi

if [[ ! -d third_party/FEX ]]; then
  echo "third_party/FEX not found (run from repo root)" >&2
  exit 1
fi

OUT_DIR="out/fexcore"
CACHE_DIR="out/_cache"
mkdir -p "${OUT_DIR}" "${CACHE_DIR}"

# Keep the toolchain in sync with FEX's own WineOnArm nix shell.
TOOLCHAIN_TAG="20250920"
TOOLCHAIN_TAR="llvm-mingw-${TOOLCHAIN_TAG}-ucrt-ubuntu-22.04-aarch64.tar.xz"
TOOLCHAIN_URL="https://github.com/bylaws/llvm-mingw/releases/download/${TOOLCHAIN_TAG}/${TOOLCHAIN_TAR}"

cat <<EOF
Build inputs:
- Docker image: ${DOCKER_IMAGE}
- llvm-mingw:   ${TOOLCHAIN_TAR}
- FEX source:   third_party/FEX

Outputs:
- ${OUT_DIR}/libwow64fex.dll
- ${OUT_DIR}/libarm64ecfex.dll
- ${OUT_DIR}/fexcore-${FEXCORE_VERSION}.tzst
EOF

docker run --rm -t \
  -e https_proxy -e http_proxy -e no_proxy \
  -e HTTPS_PROXY -e HTTP_PROXY -e NO_PROXY \
  -v "${ROOT_DIR}:/work" \
  -v "${ROOT_DIR}/${CACHE_DIR}:/cache" \
  -w /work \
  "${DOCKER_IMAGE}" \
  bash -lc "
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt_install_deps() {
  apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update -y
  apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 install -y --no-install-recommends \
    ca-certificates curl xz-utils zstd \
    cmake ninja-build python3 pkg-config \
    python3-packaging python3-setuptools \
    git file
}

# Proxies help for some networks, but can also fail (502/timeout). If apt fails,
# retry once with proxies disabled inside the container.
if ! apt_install_deps; then
  echo \"apt-get failed (possibly due to proxy). Retrying without http(s)_proxy...\" >&2
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
  apt_install_deps
fi

TOOLCHAIN_DIR=\"/cache/${TOOLCHAIN_TAR%.tar.xz}\"
TOOLCHAIN_TAR=\"/cache/${TOOLCHAIN_TAR}\"
if [[ ! -d \"\$TOOLCHAIN_DIR\" ]]; then
  if [[ ! -f \"\$TOOLCHAIN_TAR\" ]]; then
    echo \"Downloading toolchain: ${TOOLCHAIN_URL}\"
    curl -L --fail -o \"\$TOOLCHAIN_TAR\" \"${TOOLCHAIN_URL}\"
  fi
  tar -C /cache -xf \"\$TOOLCHAIN_TAR\"
fi

export PATH=\"\$TOOLCHAIN_DIR/bin:\$PATH\"

TOOLCHAIN_FILE=\"/work/third_party/FEX/Data/CMake/toolchain_mingw.cmake\"

build_one() {
  local name=\"\$1\"
  local mingw_triple=\"\$2\"
  local target=\"\$3\"
  local build_dir=\"/work/out/_build_fexcore_\${name}\"
  local stage_dir=\"/work/out/_stage_fexcore_\${name}\"

  rm -rf \"\$build_dir\" \"\$stage_dir\"
  mkdir -p \"\$build_dir\" \"\$stage_dir\"

  cmake -S /work/third_party/FEX -B \"\$build_dir\" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=\"\$TOOLCHAIN_FILE\" \
    -DMINGW_TRIPLE=\"\$mingw_triple\" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=/usr/lib/wine/aarch64-windows \
    -DTUNE_CPU=none \
    -DENABLE_LTO=OFF \
    -DBUILD_TESTING=OFF

  ninja -C \"\$build_dir\" \"\$target\"
  DESTDIR=\"\$stage_dir\" ninja -C \"\$build_dir\" install

  ls -la \"\$stage_dir/usr/lib/wine/aarch64-windows\" || true
}

build_one wow64   aarch64-w64-mingw32 wow64fex
build_one arm64ec arm64ec-w64-mingw32 arm64ecfex

WOW64_DLL=\"/work/out/_stage_fexcore_wow64/usr/lib/wine/aarch64-windows/libwow64fex.dll\"
ARM64EC_DLL=\"/work/out/_stage_fexcore_arm64ec/usr/lib/wine/aarch64-windows/libarm64ecfex.dll\"

if [[ ! -f \"\$WOW64_DLL\" ]]; then
  echo \"Missing built dll: \$WOW64_DLL\" >&2
  exit 1
fi
if [[ ! -f \"\$ARM64EC_DLL\" ]]; then
  echo \"Missing built dll: \$ARM64EC_DLL\" >&2
  exit 1
fi

mkdir -p /work/${OUT_DIR}
cp -f \"\$WOW64_DLL\" /work/${OUT_DIR}/libwow64fex.dll
cp -f \"\$ARM64EC_DLL\" /work/${OUT_DIR}/libarm64ecfex.dll

echo \"Packaging tzst...\"
tmpdir=\$(mktemp -d)
cp -f /work/${OUT_DIR}/libwow64fex.dll \"\$tmpdir/\"
cp -f /work/${OUT_DIR}/libarm64ecfex.dll \"\$tmpdir/\"
 tar -C \"\$tmpdir\" -cf - libwow64fex.dll libarm64ecfex.dll | zstd -f -T0 -19 -o /work/${OUT_DIR}/fexcore-${FEXCORE_VERSION}.tzst
rm -rf \"\$tmpdir\"

file /work/${OUT_DIR}/libwow64fex.dll || true
file /work/${OUT_DIR}/libarm64ecfex.dll || true
zstd -dc /work/${OUT_DIR}/fexcore-${FEXCORE_VERSION}.tzst | tar -tf - | sed -n '1,20p'
"

if [[ "${UPDATE_ASSETS}" == "1" ]]; then
  ASSET_PATH="app/src/main/assets/fexcore/fexcore-${FEXCORE_VERSION}.tzst"
  mkdir -p "$(dirname -- "${ASSET_PATH}")"
  cp -f "${OUT_DIR}/fexcore-${FEXCORE_VERSION}.tzst" "${ASSET_PATH}"
  echo "Updated asset: ${ASSET_PATH}"
else
  echo "Not updating app assets (pass --update-assets to overwrite app/src/main/assets/fexcore/...)."
fi
