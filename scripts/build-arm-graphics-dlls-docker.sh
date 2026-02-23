#!/usr/bin/env bash
set -euo pipefail

# Build ARM64 (aarch64-windows) graphics DLLs for Winlator prefixes:
# - DXVK:  dxgi.dll d3d11.dll d3d10core.dll d3d9.dll
# - VKD3D: d3d12.dll (d3d12core.dll when present in chosen version)
#
# Default versions are intentionally conservative for D3D12 swapchain debugging:
# - DXVK v2.3.1
# - VKD3D-Proton v2.8
#
# Usage:
#   scripts/build-arm-graphics-dlls-docker.sh
#   scripts/build-arm-graphics-dlls-docker.sh --skip-vkd3d
#   scripts/build-arm-graphics-dlls-docker.sh --dxvk-version v2.4.1 --vkd3d-version v2.9

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:22.04}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/arm64}"

DXVK_REPO_URL="https://github.com/doitsujin/dxvk"
DXVK_VERSION="v2.3.1"
VKD3D_REPO_URL="https://github.com/HansKristian-Work/vkd3d-proton"
VKD3D_VERSION="v2.8"

TOOLCHAIN_TAG="20250920"
TOOLCHAIN_TAR="llvm-mingw-${TOOLCHAIN_TAG}-ucrt-ubuntu-22.04-aarch64.tar.xz"
TOOLCHAIN_URL="https://github.com/bylaws/llvm-mingw/releases/download/${TOOLCHAIN_TAG}/${TOOLCHAIN_TAR}"

OUT_DIR="out/arm-graphics"
CACHE_DIR="out/_cache"
SKIP_DXVK=0
SKIP_VKD3D=0

usage() {
  cat <<'USAGE'
Build aarch64 Windows graphics DLLs inside Docker.

Usage:
  scripts/build-arm-graphics-dlls-docker.sh [options]

Options:
  --dxvk-version <tag>      Default: v2.3.1
  --vkd3d-version <tag>     Default: v2.8
  --skip-dxvk               Build only vkd3d-proton
  --skip-vkd3d              Build only dxvk
  --docker-image <image>    Default: ubuntu:22.04 (or env DOCKER_IMAGE)
  --docker-platform <plat>  Default: linux/arm64 (or env DOCKER_PLATFORM)
  -h, --help                Show this message.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dxvk-version)
      DXVK_VERSION="${2:?missing value for --dxvk-version}"
      shift 2
      ;;
    --vkd3d-version)
      VKD3D_VERSION="${2:?missing value for --vkd3d-version}"
      shift 2
      ;;
    --skip-dxvk)
      SKIP_DXVK=1
      shift
      ;;
    --skip-vkd3d)
      SKIP_VKD3D=1
      shift
      ;;
    --docker-image)
      DOCKER_IMAGE="${2:?missing value for --docker-image}"
      shift 2
      ;;
    --docker-platform)
      DOCKER_PLATFORM="${2:?missing value for --docker-platform}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "${SKIP_DXVK}" -eq 1 && "${SKIP_VKD3D}" -eq 1 ]]; then
  echo "Both --skip-dxvk and --skip-vkd3d were set. Nothing to build." >&2
  exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}/aarch64/system32" "${CACHE_DIR}"

cat <<EOF
Build inputs:
- Docker image:    ${DOCKER_IMAGE}
- Docker platform: ${DOCKER_PLATFORM}
- llvm-mingw:      ${TOOLCHAIN_TAR}
- DXVK:            ${DXVK_REPO_URL} @ ${DXVK_VERSION} (skip=${SKIP_DXVK})
- VKD3D:           ${VKD3D_REPO_URL} @ ${VKD3D_VERSION} (skip=${SKIP_VKD3D})

Output directory:
- ${OUT_DIR}/aarch64/system32
EOF

docker_args=(run --rm -t)
if [[ -n "${DOCKER_PLATFORM}" ]]; then
  docker_args+=(--platform "${DOCKER_PLATFORM}")
fi
docker_args+=(
  -e https_proxy -e http_proxy -e no_proxy
  -e HTTPS_PROXY -e HTTP_PROXY -e NO_PROXY
  -e "DXVK_REPO_URL=${DXVK_REPO_URL}" -e "DXVK_VERSION=${DXVK_VERSION}"
  -e "VKD3D_REPO_URL=${VKD3D_REPO_URL}" -e "VKD3D_VERSION=${VKD3D_VERSION}"
  -e "TOOLCHAIN_TAR=${TOOLCHAIN_TAR}" -e "TOOLCHAIN_URL=${TOOLCHAIN_URL}"
  -e "SKIP_DXVK=${SKIP_DXVK}" -e "SKIP_VKD3D=${SKIP_VKD3D}"
  -v "${ROOT_DIR}:/work"
  -v "${ROOT_DIR}/${CACHE_DIR}:/cache"
  -w /work
  "${DOCKER_IMAGE}"
)

docker "${docker_args[@]}" bash -lc '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt_install_deps() {
  local proxy_cleared=0
  apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update -y
  local attempt
  for attempt in 1 2 3 4 5; do
    if apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 install -y --no-install-recommends \
      --fix-missing \
      ca-certificates curl git file xz-utils \
      meson ninja-build pkg-config python3 \
      glslang-tools \
      gcc g++ make \
      zlib1g-dev \
      libvulkan-dev; then
      return 0
    fi
    echo "apt-get install failed (attempt ${attempt}/5), retrying..." >&2
    apt-get -y -f install || true
    if [[ "${proxy_cleared}" -eq 0 ]]; then
      echo "apt retry: disabling http(s)_proxy inside container." >&2
      unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
      proxy_cleared=1
    fi
    sleep 2
    apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update -y || true
  done
  return 1
}

run_with_proxy_fallback() {
  if "$@"; then
    return 0
  fi
  echo "Command failed (possibly due to proxy). Retrying without http(s)_proxy..." >&2
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
  "$@"
}

if ! apt_install_deps; then
  echo "apt-get failed (possibly due to proxy). Retrying without http(s)_proxy..." >&2
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
  apt_install_deps
fi

TOOLCHAIN_DIR="/cache/${TOOLCHAIN_TAR%.tar.xz}"
TOOLCHAIN_ARCHIVE="/cache/${TOOLCHAIN_TAR}"
if [[ ! -d "${TOOLCHAIN_DIR}" ]]; then
  if [[ ! -f "${TOOLCHAIN_ARCHIVE}" ]]; then
    echo "Downloading toolchain: ${TOOLCHAIN_URL}"
    run_with_proxy_fallback curl -L --fail -o "${TOOLCHAIN_ARCHIVE}" "${TOOLCHAIN_URL}"
  fi
  tar -C /cache -xf "${TOOLCHAIN_ARCHIVE}"
fi

export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"

VK_HEADERS_SRC="/work/out/_src_vulkan_headers"
VK_HEADERS_REPO="https://github.com/KhronosGroup/Vulkan-Headers"
if [[ ! -f "${VK_HEADERS_SRC}/include/vulkan/vulkan.h" ]]; then
  rm -rf "${VK_HEADERS_SRC}"
  run_with_proxy_fallback git clone --depth 1 "${VK_HEADERS_REPO}" "${VK_HEADERS_SRC}"
fi
if [[ ! -f "${VK_HEADERS_SRC}/include/vulkan/vulkan.h" ]]; then
  echo "Missing Vulkan-Headers include/vulkan/vulkan.h" >&2
  exit 1
fi
SPIRV_HEADERS_SRC="/work/out/_src_spirv_headers"
SPIRV_HEADERS_REPO="https://github.com/KhronosGroup/SPIRV-Headers"
if [[ ! -f "${SPIRV_HEADERS_SRC}/include/spirv/unified1/spirv.hpp" ]]; then
  rm -rf "${SPIRV_HEADERS_SRC}"
  run_with_proxy_fallback git clone --depth 1 "${SPIRV_HEADERS_REPO}" "${SPIRV_HEADERS_SRC}"
fi
if [[ ! -f "${SPIRV_HEADERS_SRC}/include/spirv/unified1/spirv.hpp" ]]; then
  echo "Missing SPIRV-Headers include/spirv/unified1/spirv.hpp" >&2
  exit 1
fi

GRAPHICS_HEADERS="/work/out/_graphics_headers/include"
rm -rf "/work/out/_graphics_headers"
mkdir -p "${GRAPHICS_HEADERS}"
cp -a "${VK_HEADERS_SRC}/include/vulkan" "${GRAPHICS_HEADERS}/"
if [[ -d "${VK_HEADERS_SRC}/include/vk_video" ]]; then
  cp -a "${VK_HEADERS_SRC}/include/vk_video" "${GRAPHICS_HEADERS}/"
fi
cp -a "${SPIRV_HEADERS_SRC}/include/spirv" "${GRAPHICS_HEADERS}/"

DXVK_SRC="/work/out/_src_dxvk"
VKD3D_SRC="/work/out/_src_vkd3d"
DXVK_BUILD="/work/out/_build_dxvk_aarch64"
VKD3D_BUILD="/work/out/_build_vkd3d_aarch64"
DXVK_STAGE="/work/out/_stage_dxvk_aarch64"
VKD3D_STAGE="/work/out/_stage_vkd3d_aarch64"
OUT_DIR="/work/out/arm-graphics/aarch64/system32"

rm -rf "${DXVK_SRC}" "${VKD3D_SRC}" "${DXVK_BUILD}" "${VKD3D_BUILD}" "${DXVK_STAGE}" "${VKD3D_STAGE}"
mkdir -p "${OUT_DIR}"

cat > /tmp/build-winaarch64.txt <<EOF
[binaries]
c = '\''aarch64-w64-mingw32-gcc'\''
cpp = '\''aarch64-w64-mingw32-g++'\''
ar = '\''aarch64-w64-mingw32-ar'\''
strip = '\''aarch64-w64-mingw32-strip'\''
windres = '\''aarch64-w64-mingw32-windres'\''
ld = '\''aarch64-w64-mingw32-ld'\''
widl = '\''aarch64-w64-mingw32-widl'\''

[properties]
needs_exe_wrapper = true

[host_machine]
system = '\''windows'\''
cpu_family = '\''aarch64'\''
cpu = '\''aarch64'\''
endian = '\''little'\''
EOF

if [[ "${SKIP_DXVK}" != "1" ]]; then
  echo "==> Building DXVK ${DXVK_VERSION} (aarch64)"
  run_with_proxy_fallback git clone --depth 1 --branch "${DXVK_VERSION}" "${DXVK_REPO_URL}" "${DXVK_SRC}"

  # Newer llvm-mingw d3d9 headers already define D3DDEVINFO_RESOURCEMANAGER.
  # DXVK v2.3.1 carries an old MinGW fallback typedef that then causes redefinition.
  # Keep behavior for other toolchains but disable the fallback on MinGW.
  if grep -q "typedef struct _D3DDEVINFO_RESOURCEMANAGER" "${DXVK_SRC}/src/d3d9/d3d9_include.h"; then
    sed -i \
      -e "s/^#ifndef _MSC_VER$/#if !defined(_MSC_VER) \&\& !defined(__MINGW64_VERSION_MAJOR)/" \
      "${DXVK_SRC}/src/d3d9/d3d9_include.h"
  fi

  # Newer llvm-mingw may not resolve __mingw_uuidof<IDirect3DDevice9On12>().
  # Replace this one QueryInterface check with an explicit GUID comparison.
  if grep -q "__uuidof(IDirect3DDevice9On12)" "${DXVK_SRC}/src/d3d9/d3d9_device.cpp"; then
    sed -i \
      -e "/\\*ppvObject = nullptr;/a\\
\\
    static const GUID kIID_IDirect3DDevice9On12 =\\
      { 0xe7fda234, 0xb589, 0x4049, { 0x94, 0x0d, 0x88, 0x78, 0x97, 0x75, 0x31, 0xc8 } };\
" \
      "${DXVK_SRC}/src/d3d9/d3d9_device.cpp"
    sed -i \
      -e "s/riid == __uuidof(IDirect3DDevice9On12)/riid == kIID_IDirect3DDevice9On12/" \
      "${DXVK_SRC}/src/d3d9/d3d9_device.cpp"
  fi

  meson setup --cross-file /tmp/build-winaarch64.txt \
    --buildtype release \
    --prefix "${DXVK_STAGE}" \
    --bindir aarch64 \
    --libdir aarch64 \
    -Db_ndebug=if-release \
    -Dbuild_id=false \
    -Dc_args=-I"${GRAPHICS_HEADERS}" \
    -Dcpp_args=-I"${GRAPHICS_HEADERS}" \
    "${DXVK_BUILD}" "${DXVK_SRC}"

  ninja -C "${DXVK_BUILD}" install

  for dll in dxgi.dll d3d11.dll d3d10core.dll d3d9.dll; do
    src="$(find "${DXVK_STAGE}" -type f -iname "${dll}" | head -n1 || true)"
    if [[ -z "${src}" ]]; then
      echo "Missing DXVK DLL: ${dll}" >&2
      exit 1
    fi
    cp -f "${src}" "${OUT_DIR}/${dll}"
  done
fi

if [[ "${SKIP_VKD3D}" != "1" ]]; then
  echo "==> Building VKD3D-Proton ${VKD3D_VERSION} (aarch64)"
  run_with_proxy_fallback git clone --depth 1 --branch "${VKD3D_VERSION}" "${VKD3D_REPO_URL}" "${VKD3D_SRC}"
  run_with_proxy_fallback git -C "${VKD3D_SRC}" submodule update --init --depth 1 --recursive

  meson setup --cross-file /tmp/build-winaarch64.txt \
    --buildtype release \
    --prefix "${VKD3D_STAGE}" \
    --bindir aarch64 \
    --libdir aarch64 \
    -Denable_tests=false \
    -Denable_extras=false \
    -Denable_trace=false \
    -Dc_args=-I"${GRAPHICS_HEADERS}" \
    -Dcpp_args=-I"${GRAPHICS_HEADERS}" \
    "${VKD3D_BUILD}" "${VKD3D_SRC}"

  ninja -C "${VKD3D_BUILD}" install

  for dll in d3d12.dll d3d12core.dll; do
    src="$(find "${VKD3D_STAGE}" "${VKD3D_BUILD}" -type f -iname "${dll}" 2>/dev/null | head -n1 || true)"
    if [[ -n "${src}" ]]; then
      cp -f "${src}" "${OUT_DIR}/${dll}"
    elif [[ "${dll}" == "d3d12.dll" ]]; then
      echo "Missing required VKD3D DLL: d3d12.dll" >&2
      exit 1
    else
      echo "Note: ${dll} not found in ${VKD3D_VERSION}; skipping."
    fi
  done
fi

echo "==> Built DLLs:"
ls -la "${OUT_DIR}"
for f in "${OUT_DIR}"/*.dll; do
  file "${f}" || true
done
'

manifest="${OUT_DIR}/aarch64/system32/manifest.txt"
mkdir -p "$(dirname -- "${manifest}")"
{
  echo "dxvk_repo=${DXVK_REPO_URL}"
  echo "dxvk_version=${DXVK_VERSION}"
  echo "vkd3d_repo=${VKD3D_REPO_URL}"
  echo "vkd3d_version=${VKD3D_VERSION}"
  echo "toolchain=${TOOLCHAIN_TAR}"
  echo "built_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${manifest}"

echo "Wrote manifest: ${manifest}"
echo "Done."
