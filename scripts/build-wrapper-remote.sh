#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

REMOTE_HOST="${REMOTE_HOST:-192.168.0.111}"
REMOTE_USER="${REMOTE_USER:-bazzite}"
REMOTE_PASSWORD="${REMOTE_PASSWORD:-9527}"
REMOTE_DIR="${REMOTE_DIR:-/var/home/${REMOTE_USER}/build/vulkan_wrapper_termux-packages-x86}"
REPO_URL="${REPO_URL:-https://github.com/leegao/vulkan_wrapper_termux-packages}"
REPO_REF="${REPO_REF:-dev/wrapper}"

PACKAGE_NAME="${PACKAGE_NAME:-com.winlator.llm}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-${ROOT_DIR}/out/_cache/wrapper_remote_builds}"
HTTPS_PROXY_VAL="${HTTPS_PROXY_VAL:-${https_proxy:-${HTTPS_PROXY:-}}}"

usage() {
  cat <<'USAGE'
Build vulkan-wrapper-android remotely (x86 Linux builder), pull artifacts locally,
patch ICD JSON for Winlator package path, and verify ABI.

Usage:
  scripts/build-wrapper-remote.sh [options]

Options:
  --host <host>            Remote SSH host (default: 192.168.0.111)
  --user <user>            Remote SSH user (default: bazzite)
  --password <pass>        Remote SSH password (default: 9527)
  --remote-dir <path>      Remote work dir (default: /var/home/<user>/build/vulkan_wrapper_termux-packages-x86)
  --repo-url <url>         Remote git repo url
  --repo-ref <ref>         Remote git ref/branch/tag/commit (default: dev/wrapper)
  --package <name>         Android package for ICD library_path (default: com.winlator.llm)
  --artifact-root <path>   Local artifact root (default: out/_cache/wrapper_remote_builds)
  --https-proxy <url>      Proxy url for remote/container network (optional)
  -h, --help               Show this help

Outputs (in <artifact-root>/<timestamp>/):
  - vulkan-wrapper-android_*_aarch64.deb
  - libvulkan_wrapper.so
  - libadrenotools.so
  - wrapper_icd.aarch64.json
  - wrapper_icd.<package>.aarch64.json
  - SHA256SUMS
  - build-meta.txt
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) REMOTE_HOST="${2:?missing value}"; shift 2 ;;
    --user) REMOTE_USER="${2:?missing value}"; shift 2 ;;
    --password) REMOTE_PASSWORD="${2:?missing value}"; shift 2 ;;
    --remote-dir) REMOTE_DIR="${2:?missing value}"; shift 2 ;;
    --repo-url) REPO_URL="${2:?missing value}"; shift 2 ;;
    --repo-ref) REPO_REF="${2:?missing value}"; shift 2 ;;
    --package) PACKAGE_NAME="${2:?missing value}"; shift 2 ;;
    --artifact-root) ARTIFACT_ROOT="${2:?missing value}"; shift 2 ;;
    --https-proxy) HTTPS_PROXY_VAL="${2:?missing value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }
}

need_cmd sshpass
need_cmd ssh
need_cmd scp
need_cmd python3
need_cmd bsdtar
need_cmd tar
need_cmd file
need_cmd sha256sum

SSH_BASE=(sshpass -p "${REMOTE_PASSWORD}" ssh -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}")
SCP_BASE=(sshpass -p "${REMOTE_PASSWORD}" scp -o StrictHostKeyChecking=no)

q() { printf '%q' "$1"; }

RUN_ID="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${ARTIFACT_ROOT}/${RUN_ID}"
mkdir -p "${RUN_DIR}"

echo "[build-wrapper-remote] host=${REMOTE_USER}@${REMOTE_HOST}"
echo "[build-wrapper-remote] remote_dir=${REMOTE_DIR}"
echo "[build-wrapper-remote] repo=${REPO_URL} ref=${REPO_REF}"
echo "[build-wrapper-remote] package=${PACKAGE_NAME}"
if [[ -n "${HTTPS_PROXY_VAL}" ]]; then
  echo "[build-wrapper-remote] https_proxy=${HTTPS_PROXY_VAL}"
else
  echo "[build-wrapper-remote] https_proxy=<empty>"
fi

REMOTE_ENV_CMD="REMOTE_DIR=$(q "${REMOTE_DIR}") REPO_URL=$(q "${REPO_URL}") REPO_REF=$(q "${REPO_REF}") HTTPS_PROXY_VAL=$(q "${HTTPS_PROXY_VAL}") bash -s"

"${SSH_BASE[@]}" "${REMOTE_ENV_CMD}" <<'REMOTE_SCRIPT'
set -euo pipefail

if [[ -n "${HTTPS_PROXY_VAL:-}" ]]; then
  export https_proxy="${HTTPS_PROXY_VAL}" http_proxy="${HTTPS_PROXY_VAL}" \
         HTTPS_PROXY="${HTTPS_PROXY_VAL}" HTTP_PROXY="${HTTPS_PROXY_VAL}"
fi

mkdir -p "$(dirname "${REMOTE_DIR}")"

if [[ ! -d "${REMOTE_DIR}/.git" ]]; then
  rm -rf "${REMOTE_DIR}"
  git clone "${REPO_URL}" "${REMOTE_DIR}"
fi

cd "${REMOTE_DIR}"
git fetch --tags origin

if git rev-parse --verify --quiet "origin/${REPO_REF}" >/dev/null; then
  git checkout -f "${REPO_REF}"
  git reset --hard "origin/${REPO_REF}"
else
  DEFAULT_REMOTE_BRANCH="$(git ls-remote --symref origin HEAD | awk '/^ref:/ {sub("refs/heads/","",$2); print $2; exit}')"
  if [[ -n "${DEFAULT_REMOTE_BRANCH}" ]] && git rev-parse --verify --quiet "origin/${DEFAULT_REMOTE_BRANCH}" >/dev/null; then
    echo "WARN: repo ref '${REPO_REF}' not found, fallback to '${DEFAULT_REMOTE_BRANCH}'" >&2
    git checkout -f "${DEFAULT_REMOTE_BRANCH}"
    git reset --hard "origin/${DEFAULT_REMOTE_BRANCH}"
  else
    git checkout -f "${REPO_REF}"
  fi
fi

if [[ -f .gitmodules ]]; then
  git submodule sync --recursive >/dev/null 2>&1 || true
  git submodule update --init --recursive >/dev/null 2>&1 || true
fi

# The current mesa_bionic branch already carries wrapper changes; forcing this
# legacy patch now causes interactive/reverse-patch conflicts and unstable builds.
if [[ -f packages/vulkan-wrapper-android/leegao.patch ]]; then
  mv -f packages/vulkan-wrapper-android/leegao.patch packages/vulkan-wrapper-android/leegao.patch.disabled
fi

python3 - <<'PY'
from pathlib import Path
import re

p = Path("packages/vulkan-wrapper-android/build.sh")
s = p.read_text(encoding="utf-8")

# Use direct upstream source for wrapper build (no local mesa patchset chain).
s = re.sub(
    r'^TERMUX_PKG_SRCURL=.*$',
    'TERMUX_PKG_SRCURL=git+https://github.com/leegao/bionic-vulkan-wrapper',
    s,
    flags=re.MULTILINE,
)
s = re.sub(
    r'^TERMUX_PKG_GIT_BRANCH=.*$',
    'TERMUX_PKG_GIT_BRANCH=wrapper',
    s,
    flags=re.MULTILINE,
)

s = s.replace('LDFLAGS+=" -landroid-sysvshm -ladrenotools"', 'LDFLAGS+=" -landroid-shmem -ladrenotools"')
s = s.replace('LDFLAGS+=" -landroid-shmem"', 'LDFLAGS+=" -landroid-shmem -ladrenotools"')

if 'LDFLAGS+=" -landroid-shmem -ladrenotools"' not in s:
    s = re.sub(
        r'(\s*CPPFLAGS\+\="\s*-D__USE_GNU"\s*\n)',
        r'\1\tLDFLAGS+=" -landroid-shmem -ladrenotools"\n',
        s,
        count=1
    )

need_spirv = 'cp /home/builder/termux-packages/mesa_bionic/src/vulkan/wrapper/lib/*.a src/vulkan/wrapper/lib/'
need_adt = 'cp /home/builder/termux-packages/wrapper/usr/lib/libadrenotools.so $TERMUX_PREFIX/lib/'
need_wsi_overlay = 'cp /home/builder/termux-packages/mesa_bionic/src/vulkan/wsi/wsi_common.c $TERMUX_PKG_SRCDIR/src/vulkan/wsi/wsi_common.c'
need_wsi_grep = 'grep -n "\\\\[DXVK\\\\]\\|Inside of wsi_CreateSwapchainKHR" $TERMUX_PKG_SRCDIR/src/vulkan/wsi/wsi_common.c | head -n 20 || true'

if need_spirv not in s:
    s = s.replace(
        'mkdir -p src/vulkan/wrapper/lib/\n',
        'mkdir -p src/vulkan/wrapper/lib/\n\t' + need_spirv + '\n'
    )

if need_adt not in s and need_spirv in s:
    s = s.replace(need_spirv + '\n', need_spirv + '\n\t' + need_adt + '\n')

if need_wsi_overlay not in s:
    s = s.replace(
        '\tgit log\n',
        '\tgit log\n'
        '\t' + need_wsi_overlay + '\n'
        '\t' + need_wsi_grep + '\n'
    )

s = s.replace(
    '\techo "PRECONFIGURE"\n\techo $PWD\n',
    '\techo "PRECONFIGURE"\n\techo $PWD\n\t' + need_wsi_overlay + '\n'
    '\t' + need_wsi_grep + '\n'
)

p.write_text(s, encoding="utf-8")
print("patched", p)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("mesa_bionic/src/vulkan/wsi/wsi_common.c")
s = p.read_text(encoding="utf-8")

if '[DXVK] wsi_GetSwapchainImagesKHR enter' not in s:
    s = s.replace(
        '   LOG_A("Inside of wsi_CreateSwapchainKHR");',
        '   LOG_A("Inside of wsi_CreateSwapchainKHR");\n'
        '   LOG_A("[DXVK] wsi_CreateSwapchainKHR enter extent=%ux%u images=%u mode=%u",\n'
        '       pCreateInfo->imageExtent.width, pCreateInfo->imageExtent.height,\n'
        '       pCreateInfo->minImageCount, pCreateInfo->presentMode);'
    )

    s = s.replace(
        '   LOG_A("iface->create_swapchain: %d", result);',
        '   LOG_A("iface->create_swapchain: %d", result);\n'
        '   LOG_A("[DXVK] wsi_CreateSwapchainKHR iface->create_swapchain result=%d", result);'
    )

    s = s.replace(
        'VKAPI_ATTR VkResult VKAPI_CALL\n'
        'wsi_GetSwapchainImagesKHR(VkDevice device,\n'
        '                          VkSwapchainKHR swapchain,\n'
        '                          uint32_t *pSwapchainImageCount,\n'
        '                          VkImage *pSwapchainImages)\n'
        '{\n'
        '   MESA_TRACE_FUNC();\n'
        '   return wsi_common_get_images(swapchain,\n'
        '                                pSwapchainImageCount,\n'
        '                                pSwapchainImages);\n'
        '}\n',
        'VKAPI_ATTR VkResult VKAPI_CALL\n'
        'wsi_GetSwapchainImagesKHR(VkDevice device,\n'
        '                          VkSwapchainKHR swapchain,\n'
        '                          uint32_t *pSwapchainImageCount,\n'
        '                          VkImage *pSwapchainImages)\n'
        '{\n'
        '   MESA_TRACE_FUNC();\n'
        '   LOG_A("[DXVK] wsi_GetSwapchainImagesKHR enter count_ptr=%p images_ptr=%p req_count=%u",\n'
        '       pSwapchainImageCount, pSwapchainImages,\n'
        '       pSwapchainImageCount ? *pSwapchainImageCount : 0);\n'
        '   VkResult result = wsi_common_get_images(swapchain,\n'
        '                                pSwapchainImageCount,\n'
        '                                pSwapchainImages);\n'
        '   LOG_A("[DXVK] wsi_GetSwapchainImagesKHR exit result=%d out_count=%u",\n'
        '       result, pSwapchainImageCount ? *pSwapchainImageCount : 0);\n'
        '   return result;\n'
        '}\n'
    )

    s = s.replace(
        '   return device->dispatch_table.AcquireNextImage2KHR(_device, &acquire_info,\n'
        '                                                      pImageIndex);',
        '   LOG_A("[DXVK] wsi_AcquireNextImageKHR enter timeout=%llu semaphore=%p fence=%p",\n'
        '       (unsigned long long)timeout, (void*)semaphore, (void*)fence);\n'
        '   VkResult result = device->dispatch_table.AcquireNextImage2KHR(_device, &acquire_info,\n'
        '                                                      pImageIndex);\n'
        '   LOG_A("[DXVK] wsi_AcquireNextImageKHR exit result=%d imageIndex=%u",\n'
        '       result, pImageIndex ? *pImageIndex : 0);\n'
        '   return result;'
    )

    s = s.replace(
        'VKAPI_ATTR VkResult VKAPI_CALL\n'
        'wsi_QueuePresentKHR(VkQueue _queue, const VkPresentInfoKHR *pPresentInfo)\n'
        '{\n'
        '   MESA_TRACE_FUNC();\n'
        '   VK_FROM_HANDLE(vk_queue, queue, _queue);\n'
        '\n'
        '   return wsi_common_queue_present(queue->base.device->physical->wsi_device,\n'
        '                                   vk_device_to_handle(queue->base.device),\n'
        '                                   _queue,\n'
        '                                   queue->queue_family_index,\n'
        '                                   pPresentInfo);\n'
        '}\n',
        'VKAPI_ATTR VkResult VKAPI_CALL\n'
        'wsi_QueuePresentKHR(VkQueue _queue, const VkPresentInfoKHR *pPresentInfo)\n'
        '{\n'
        '   MESA_TRACE_FUNC();\n'
        '   VK_FROM_HANDLE(vk_queue, queue, _queue);\n'
        '\n'
        '   LOG_A("[DXVK] wsi_QueuePresentKHR enter swapchains=%u waits=%u",\n'
        '       pPresentInfo ? pPresentInfo->swapchainCount : 0,\n'
        '       pPresentInfo ? pPresentInfo->waitSemaphoreCount : 0);\n'
        '   VkResult result = wsi_common_queue_present(queue->base.device->physical->wsi_device,\n'
        '                                   vk_device_to_handle(queue->base.device),\n'
        '                                   _queue,\n'
        '                                   queue->queue_family_index,\n'
        '                                   pPresentInfo);\n'
        '   LOG_A("[DXVK] wsi_QueuePresentKHR exit result=%d", result);\n'
        '   return result;\n'
        '}\n'
    )

# Normalize previous injections from older script revisions that used LOG(...)
# so instrumentation always survives this build path.
s = s.replace('LOG("[DXVK]', 'LOG_A("[DXVK]')

p.write_text(s, encoding="utf-8")
print("patched", p)
PY

ENV_ARGS=(env)
if [[ -n "${HTTPS_PROXY_VAL}" ]]; then
  ENV_ARGS+=("https_proxy=${HTTPS_PROXY_VAL}" "http_proxy=${HTTPS_PROXY_VAL}" "HTTPS_PROXY=${HTTPS_PROXY_VAL}" "HTTP_PROXY=${HTTPS_PROXY_VAL}")
fi

./scripts/run-docker.sh "${ENV_ARGS[@]}" bash -lc '
set -euo pipefail
cd /home/builder/termux-packages
TERMUX_SCRIPTDIR=/home/builder/termux-packages ./scripts/setup-android-sdk.sh
'

./scripts/run-docker.sh "${ENV_ARGS[@]}" bash -lc '
set -euo pipefail
cd /home/builder/termux-packages
NDK=/home/builder/lib/android-ndk-r27c
test -f "$NDK/build/cmake/android.toolchain.cmake"

cd /home/builder/termux-packages/SPIRV-Tools
git submodule update --init --recursive
rm -rf build-android
cmake -S . -B build-android -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-26 \
  -DSPIRV_SKIP_TESTS=ON \
  -DSPIRV_SKIP_EXECUTABLES=ON \
  -DBUILD_SHARED_LIBS=OFF
cmake --build build-android -j"$(nproc)"

mkdir -p /home/builder/termux-packages/mesa_bionic/src/vulkan/wrapper/lib
cp -f build-android/source/libSPIRV-Tools.a build-android/source/opt/libSPIRV-Tools-opt.a \
  /home/builder/termux-packages/mesa_bionic/src/vulkan/wrapper/lib/

mkdir -p /home/builder/termux-packages/mesa_bionic/src/vulkan/wrapper/include/spirv-tools
cp -f include/spirv-tools/*.h /home/builder/termux-packages/mesa_bionic/src/vulkan/wrapper/include/spirv-tools/
'

./scripts/run-docker.sh "${ENV_ARGS[@]}" bash -lc '
set -euo pipefail
cd /home/builder/termux-packages
# Force a clean rebuild so wrapper source instrumentation is guaranteed to land.
rm -rf /home/builder/.termux-build/vulkan-wrapper-android
rm -f output/vulkan-wrapper-android_*_aarch64.deb
rm -f /data/data/.built-packages/vulkan-wrapper-android*
NDK=/home/builder/lib/android-ndk-r27c ./build-package.sh -I -w -a aarch64 -f vulkan-wrapper-android
'

PKG_REL="$(ls -1t output/vulkan-wrapper-android_*_aarch64.deb | head -n1)"
test -n "${PKG_REL}"
test -f "${PKG_REL}"

WORK="$(mktemp -d)"
cp "${PKG_REL}" "${WORK}/pkg.deb"
cd "${WORK}"
ar x pkg.deb
mkdir -p root
if [[ -f data.tar.xz ]]; then
  tar -xJf data.tar.xz -C root
elif [[ -f data.tar.zst ]]; then
  tar --zstd -xf data.tar.zst -C root
elif [[ -f data.tar.gz ]]; then
  tar -xzf data.tar.gz -C root
else
  tar -xf data.tar -C root
fi

SO="root/data/data/com.termux/files/usr/lib/libvulkan_wrapper.so"
ADT="root/data/data/com.termux/files/usr/lib/libadrenotools.so"
JSON="root/data/data/com.termux/files/usr/share/vulkan/icd.d/wrapper_icd.aarch64.json"

test -f "${SO}"
test -f "${ADT}"
test -f "${JSON}"

file "${SO}" | grep -q "ARM aarch64"
file "${ADT}" | grep -q "ARM aarch64"

readelf -h "${SO}" | grep -q "Machine:.*AArch64"
readelf -d "${SO}" | grep -q "Shared library: \\[libadrenotools.so\\]"
if readelf -d "${SO}" | grep -q "GLIBC_"; then
  echo "ERROR: GLIBC dependency detected in libvulkan_wrapper.so" >&2
  exit 1
fi
if ! strings "${SO}" | grep -F "[DXVK] wsi_GetSwapchainImagesKHR enter" >/dev/null; then
  echo "ERROR: missing [DXVK] wrapper instrumentation in libvulkan_wrapper.so" >&2
  exit 1
fi

rm -rf "${WORK}"
echo "${PKG_REL}"
REMOTE_SCRIPT

REMOTE_DEB_REL="$("${SSH_BASE[@]}" "cd $(q "${REMOTE_DIR}") && ls -1t output/vulkan-wrapper-android_*_aarch64.deb | head -n1" | tr -d '\r')"
[[ -n "${REMOTE_DEB_REL}" ]] || { echo "Failed to locate remote .deb artifact" >&2; exit 1; }

DEB_NAME="$(basename "${REMOTE_DEB_REL}")"
DEB_LOCAL="${RUN_DIR}/${DEB_NAME}"

"${SCP_BASE[@]}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/${REMOTE_DEB_REL}" "${DEB_LOCAL}"

REMOTE_HEAD="$("${SSH_BASE[@]}" "cd $(q "${REMOTE_DIR}") && git rev-parse HEAD" | tr -d '\r')"

mkdir -p "${RUN_DIR}/extract/deb" "${RUN_DIR}/extract/root"
bsdtar -xf "${DEB_LOCAL}" -C "${RUN_DIR}/extract/deb"

DATA_TAR="$(find "${RUN_DIR}/extract/deb" -maxdepth 1 -type f -name 'data.tar.*' | head -n1)"
if [[ -z "${DATA_TAR}" ]]; then
  echo "Failed to locate data.tar.* in ${DEB_LOCAL}" >&2
  exit 1
fi

case "${DATA_TAR}" in
  *.xz) tar -xJf "${DATA_TAR}" -C "${RUN_DIR}/extract/root" ;;
  *.zst) tar --zstd -xf "${DATA_TAR}" -C "${RUN_DIR}/extract/root" ;;
  *.gz) tar -xzf "${DATA_TAR}" -C "${RUN_DIR}/extract/root" ;;
  *) tar -xf "${DATA_TAR}" -C "${RUN_DIR}/extract/root" ;;
esac

SRC_USR="${RUN_DIR}/extract/root/data/data/com.termux/files/usr"
cp -f "${SRC_USR}/lib/libvulkan_wrapper.so" "${RUN_DIR}/libvulkan_wrapper.so"
cp -f "${SRC_USR}/lib/libadrenotools.so" "${RUN_DIR}/libadrenotools.so"
cp -f "${SRC_USR}/share/vulkan/icd.d/wrapper_icd.aarch64.json" "${RUN_DIR}/wrapper_icd.aarch64.json"

if ! strings "${RUN_DIR}/libvulkan_wrapper.so" | grep -F "[DXVK] wsi_GetSwapchainImagesKHR enter" >/dev/null; then
  echo "ERROR: local artifact missing [DXVK] wrapper instrumentation in libvulkan_wrapper.so" >&2
  exit 1
fi

PACKAGE_JSON="${RUN_DIR}/wrapper_icd.${PACKAGE_NAME}.aarch64.json"
python3 - "${RUN_DIR}/wrapper_icd.aarch64.json" "${PACKAGE_JSON}" "${PACKAGE_NAME}" <<'PY'
import json
import sys

src, dst, pkg = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)
data["ICD"]["library_path"] = f"/data/user/0/{pkg}/files/imagefs/usr/lib/libvulkan_wrapper.so"
with open(dst, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=4)
    f.write("\n")
PY

(
  cd "${RUN_DIR}"
  sha256sum \
    "${DEB_NAME}" \
    libvulkan_wrapper.so \
    libadrenotools.so \
    wrapper_icd.aarch64.json \
    "wrapper_icd.${PACKAGE_NAME}.aarch64.json" \
    > SHA256SUMS
)

cat > "${RUN_DIR}/build-meta.txt" <<EOF
remote_host=${REMOTE_USER}@${REMOTE_HOST}
remote_dir=${REMOTE_DIR}
repo_url=${REPO_URL}
repo_ref=${REPO_REF}
repo_head=${REMOTE_HEAD}
package_name=${PACKAGE_NAME}
deb_rel=${REMOTE_DEB_REL}
https_proxy=${HTTPS_PROXY_VAL}
build_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

ln -sfn "${RUN_ID}" "${ARTIFACT_ROOT}/latest"

echo "[build-wrapper-remote] done"
echo "[build-wrapper-remote] artifact_dir=${RUN_DIR}"
echo "[build-wrapper-remote] latest_link=${ARTIFACT_ROOT}/latest"
echo "[build-wrapper-remote] files:"
ls -lh "${RUN_DIR}" | sed -n '1,200p'
