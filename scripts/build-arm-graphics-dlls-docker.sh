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
DOCKER_CONTAINER_NAME="${DOCKER_CONTAINER_NAME:-winlator-arm-graphics-builder}"

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
RECREATE_CONTAINER=0

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
  --container-name <name>   Default: winlator-arm-graphics-builder (or env DOCKER_CONTAINER_NAME)
  --recreate-container      Remove and recreate builder container before build
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
    --container-name)
      DOCKER_CONTAINER_NAME="${2:?missing value for --container-name}"
      shift 2
      ;;
    --recreate-container)
      RECREATE_CONTAINER=1
      shift
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
- Builder name:    ${DOCKER_CONTAINER_NAME}
- llvm-mingw:      ${TOOLCHAIN_TAR}
- DXVK:            ${DXVK_REPO_URL} @ ${DXVK_VERSION} (skip=${SKIP_DXVK})
- VKD3D:           ${VKD3D_REPO_URL} @ ${VKD3D_VERSION} (skip=${SKIP_VKD3D})

Output directory:
- ${OUT_DIR}/aarch64/system32
EOF

if [[ "${RECREATE_CONTAINER}" -eq 1 ]]; then
  docker rm -f "${DOCKER_CONTAINER_NAME}" >/dev/null 2>&1 || true
fi

if ! docker container inspect "${DOCKER_CONTAINER_NAME}" >/dev/null 2>&1; then
  docker_create_args=(create -it --name "${DOCKER_CONTAINER_NAME}")
  if [[ -n "${DOCKER_PLATFORM}" ]]; then
    docker_create_args+=(--platform "${DOCKER_PLATFORM}")
  fi
  docker_create_args+=(
    -v "${ROOT_DIR}:/work"
    -v "${ROOT_DIR}/${CACHE_DIR}:/cache"
    -w /work
    "${DOCKER_IMAGE}"
    bash -lc "while true; do sleep 3600; done"
  )
  docker "${docker_create_args[@]}" >/dev/null
fi

docker start "${DOCKER_CONTAINER_NAME}" >/dev/null 2>&1 || true

build_script_rel="out/_tmp_build_arm_graphics_container.sh"
build_script_abs="${ROOT_DIR}/${build_script_rel}"
cat > "${build_script_abs}" <<'BUILD_SCRIPT_EOF'
#!/usr/bin/env bash
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

apply_dxvk_swaptrace_patch() {
  local dxvk_src="$1"
  local file="${dxvk_src}/src/dxvk/dxvk_presenter.cpp"
  local d3d11_file="${dxvk_src}/src/d3d11/d3d11_swapchain.cpp"
  local dxgi_file="${dxvk_src}/src/dxgi/dxgi_swapchain.cpp"
  local dxgi_dispatch_file="${dxvk_src}/src/dxgi/dxgi_swapchain_dispatcher.h"
  local pipe_file="${dxvk_src}/src/dxvk/dxvk_pipemanager.cpp"
  local state_cache_file="${dxvk_src}/src/dxvk/dxvk_state_cache.cpp"
  local graphics_file="${dxvk_src}/src/dxvk/dxvk_graphics.cpp"
  local d3d11_context_file="${dxvk_src}/src/d3d11/d3d11_context.cpp"
  local dxvk_context_file="${dxvk_src}/src/dxvk/dxvk_context.cpp"
  local log_file="${dxvk_src}/src/util/log/log.cpp"

  if [[ ! -f "${file}" ]]; then
    echo "Missing DXVK presenter source: ${file}" >&2
    exit 1
  fi
  if [[ ! -f "${d3d11_file}" ]]; then
    echo "Missing DXVK D3D11 swapchain source: ${d3d11_file}" >&2
    exit 1
  fi
  if [[ ! -f "${dxgi_file}" ]]; then
    echo "Missing DXVK DXGI swapchain source: ${dxgi_file}" >&2
    exit 1
  fi
  if [[ ! -f "${dxgi_dispatch_file}" ]]; then
    echo "Missing DXVK DXGI dispatcher source: ${dxgi_dispatch_file}" >&2
    exit 1
  fi
  if [[ ! -f "${pipe_file}" ]]; then
    echo "Missing DXVK pipeline manager source: ${pipe_file}" >&2
    exit 1
  fi
  if [[ ! -f "${state_cache_file}" ]]; then
    echo "Missing DXVK state cache source: ${state_cache_file}" >&2
    exit 1
  fi
  if [[ ! -f "${graphics_file}" ]]; then
    echo "Missing DXVK graphics pipeline source: ${graphics_file}" >&2
    exit 1
  fi
  if [[ ! -f "${d3d11_context_file}" ]]; then
    echo "Missing DXVK D3D11 context source: ${d3d11_context_file}" >&2
    exit 1
  fi
  if [[ ! -f "${dxvk_context_file}" ]]; then
    echo "Missing DXVK context source: ${dxvk_context_file}" >&2
    exit 1
  fi
  if [[ ! -f "${log_file}" ]]; then
    echo "Missing DXVK logger source: ${log_file}" >&2
    exit 1
  fi

  if grep -q "SWAPTRACE_RT" "${file}"; then
    echo "DXVK SWAPTRACE_RT patch already present"
    return 0
  fi

  sed -i '/VkResult Presenter::recreateSwapChain(const PresenterDesc& desc) {/a\
    Logger::info(str::format("SWAPTRACE: recreateSwapChain enter: reqExtent=", desc.imageExtent.width, "x", desc.imageExtent.height, ", reqImages=", desc.imageCount, ", reqFormats=", desc.numFormats, ", fsExclusive=", desc.fullScreenExclusive));' "${file}"

  sed -i '/VkResult status;/a\
    Logger::info("SWAPTRACE: querying surface capabilities");' "${file}"

  perl -0777 -i -pe 's/if \(status\)\n      return status;/if (status) {\n      Logger::info(str::format("SWAPTRACE: surface capabilities query failed: ", status));\n      return status;\n    }\n\n    Logger::info("SWAPTRACE: surface capabilities query ok");/s' "${file}"

  perl -0777 -i -pe 's/if \(\(status = getSupportedFormats\(formats, desc\.fullScreenExclusive\)\)\)\n      return status;/Logger::info("SWAPTRACE: querying surface formats");\n    if ((status = getSupportedFormats(formats, desc.fullScreenExclusive))) {\n      Logger::info(str::format("SWAPTRACE: getSupportedFormats failed: ", status));\n      return status;\n    }\n\n    Logger::info(str::format("SWAPTRACE: getSupportedFormats ok count=", formats.size()));/s' "${file}"

  perl -0777 -i -pe 's/if \(\(status = getSupportedPresentModes\(modes, desc\.fullScreenExclusive\)\)\)\n      return status;/Logger::info("SWAPTRACE: querying present modes");\n    if ((status = getSupportedPresentModes(modes, desc.fullScreenExclusive))) {\n      Logger::info(str::format("SWAPTRACE: getSupportedPresentModes failed: ", status));\n      return status;\n    }\n\n    Logger::info(str::format("SWAPTRACE: getSupportedPresentModes ok count=", modes.size()));/s' "${file}"

  perl -0777 -i -pe 's/if \(\(status = m_vkd->vkCreateSwapchainKHR\(m_vkd->device\(\),\n        &swapInfo, nullptr, &m_swapchain\)\)\)\n      return status;/Logger::info("SWAPTRACE: before vkCreateSwapchainKHR");\n    status = m_vkd->vkCreateSwapchainKHR(m_vkd->device(),\n        \&swapInfo, nullptr, \&m_swapchain);\n    Logger::info(str::format("SWAPTRACE: vkCreateSwapchainKHR status=", status));\n    if (status)\n      return status;/s' "${file}"

  perl -0777 -i -pe 's/if \(\(status = getSwapImages\(images\)\)\)\n      return status;/Logger::info("SWAPTRACE: before getSwapImages");\n    status = getSwapImages(images);\n    Logger::info(str::format("SWAPTRACE: getSwapImages status=", status, ", count=", images.size()));\n    if (status)\n      return status;/s' "${file}"

  perl -0777 -i -pe 's/VkResult Presenter::getSwapImages\(std::vector<VkImage>& images\) {\n    uint32_t imageCount = 0;\n\n    VkResult status = m_vkd->vkGetSwapchainImagesKHR\(\n      m_vkd->device\(\), m_swapchain, &imageCount, nullptr\);\n    \n    if \(status != VK_SUCCESS\)\n      return status;\n    \n    images.resize\(imageCount\);\n\n    return m_vkd->vkGetSwapchainImagesKHR\(\n      m_vkd->device\(\), m_swapchain, &imageCount, images.data\(\)\);\n  }/VkResult Presenter::getSwapImages(std::vector<VkImage>& images) {\n    uint32_t imageCount = 0;\n\n    Logger::info("SWAPTRACE: getSwapImages call1 begin");\n    VkResult status = m_vkd->vkGetSwapchainImagesKHR(\n      m_vkd->device(), m_swapchain, &imageCount, nullptr);\n    Logger::info(str::format("SWAPTRACE: getSwapImages call1 end status=", status, ", imageCount=", imageCount));\n\n    if (status != VK_SUCCESS)\n      return status;\n\n    images.resize(imageCount);\n\n    Logger::info(str::format("SWAPTRACE: getSwapImages call2 begin imageCount=", imageCount));\n    status = m_vkd->vkGetSwapchainImagesKHR(\n      m_vkd->device(), m_swapchain, &imageCount, images.data());\n    Logger::info(str::format("SWAPTRACE: getSwapImages call2 end status=", status, ", imageCount=", imageCount));\n\n    return status;\n  }/s' "${file}"

  sed -i '/for (uint32_t i = 0; i < m_info.imageCount; i++) {/i\
    Logger::info(str::format("SWAPTRACE: creating image views count=", m_info.imageCount));' "${file}"
  sed -i '/\/\/ Create one set of semaphores per swap image/i\
    Logger::info("SWAPTRACE: image views created");' "${file}"
  sed -i '/for (uint32_t i = 0; i < m_semaphores.size(); i++) {/i\
    Logger::info(str::format("SWAPTRACE: creating semaphores count=", m_semaphores.size()));' "${file}"
  sed -i '/\/\/ Invalidate indices/i\
    Logger::info("SWAPTRACE: semaphores created");' "${file}"

  # Track acquire/present path after swapchain creation succeeds.
  perl -0777 -i -pe 's/if \(m_acquireStatus == VK_NOT_READY\) {\n      m_acquireStatus = m_vkd->vkAcquireNextImageKHR\(m_vkd->device\(\),\n        m_swapchain, std::numeric_limits<uint64_t>::max\(\),\n        sync.acquire, VK_NULL_HANDLE, &m_imageIndex\);\n    }/if (m_acquireStatus == VK_NOT_READY) {\n      Logger::info(str::format(\"SWAPTRACE: acquireNextImage call begin frameIndex=\", m_frameIndex));\n      m_acquireStatus = m_vkd->vkAcquireNextImageKHR(m_vkd->device(),\n        m_swapchain, std::numeric_limits<uint64_t>::max(),\n        sync.acquire, VK_NULL_HANDLE, &m_imageIndex);\n      Logger::info(str::format(\"SWAPTRACE: acquireNextImage call end status=\", m_acquireStatus, \", imageIndex=\", m_imageIndex));\n    }/s' "${file}"

  perl -0777 -i -pe 's/VkResult status = m_vkd->vkQueuePresentKHR\(\n      m_device->queues\(\)\.graphics\.queueHandle, &info\);/Logger::info(str::format(\"SWAPTRACE: vkQueuePresentKHR begin imageIndex=\", m_imageIndex, \", frameId=\", frameId, \", mode=\", mode));\n    VkResult status = m_vkd->vkQueuePresentKHR(\n      m_device->queues().graphics.queueHandle, &info);\n    Logger::info(str::format(\"SWAPTRACE: vkQueuePresentKHR end status=\", status));/s' "${file}"

  perl -0777 -i -pe 's/m_acquireStatus = m_vkd->vkAcquireNextImageKHR\(m_vkd->device\(\),\n      m_swapchain, std::numeric_limits<uint64_t>::max\(\),\n      sync.acquire, VK_NULL_HANDLE, &m_imageIndex\);\n\n    return status;/Logger::info(str::format(\"SWAPTRACE: prefetch acquire begin nextFrameIndex=\", m_frameIndex));\n    m_acquireStatus = m_vkd->vkAcquireNextImageKHR(m_vkd->device(),\n      m_swapchain, std::numeric_limits<uint64_t>::max(),\n      sync.acquire, VK_NULL_HANDLE, &m_imageIndex);\n    Logger::info(str::format(\"SWAPTRACE: prefetch acquire end status=\", m_acquireStatus, \", imageIndex=\", m_imageIndex));\n\n    return status;/s' "${file}"

  perl -0777 -i -pe 's/VkResult vr = m_vkd->vkWaitForPresentKHR\(m_vkd->device\(\),\n          m_swapchain, frame.frameId, std::numeric_limits<uint64_t>::max\(\)\);\n\n        if \(vr < 0 && vr != VK_ERROR_OUT_OF_DATE_KHR && vr != VK_ERROR_SURFACE_LOST_KHR\)\n          Logger::err\(str::format\("Presenter: vkWaitForPresentKHR failed: ", vr\)\);/Logger::info(str::format(\"SWAPTRACE: vkWaitForPresentKHR begin frameId=\", frame.frameId, \", mode=\", frame.mode));\n        VkResult vr = m_vkd->vkWaitForPresentKHR(m_vkd->device(),\n          m_swapchain, frame.frameId, std::numeric_limits<uint64_t>::max());\n        Logger::info(str::format(\"SWAPTRACE: vkWaitForPresentKHR end status=\", vr));\n\n        if (vr < 0 && vr != VK_ERROR_OUT_OF_DATE_KHR && vr != VK_ERROR_SURFACE_LOST_KHR)\n          Logger::err(str::format(\"Presenter: vkWaitForPresentKHR failed: \", vr));/s' "${file}"

  perl -0777 -i -pe 's/m_frameQueue\.push\(frame\);\n      m_frameCond\.notify_one\(\);/Logger::info(str::format(\"SWAPTRACE: frame enqueue begin frameId=\", frame.frameId, \", mode=\", frame.mode, \", result=\", frame.result, \", qsize_before=\", m_frameQueue.size()));\n      m_frameQueue.push(frame);\n      m_frameCond.notify_one();\n      Logger::info(str::format(\"SWAPTRACE: frame enqueue done qsize_after=\", m_frameQueue.size()));/s' "${file}"

  perl -0777 -i -pe 's/} else {\n      applyFrameRateLimit\(mode\);\n      m_signal->signal\(frameId\);\n    }/} else {\n      Logger::info(str::format(\"SWAPTRACE: signalFrame direct path frameId=\", frameId, \", mode=\", mode, \", result=\", result));\n      applyFrameRateLimit(mode);\n      m_signal->signal(frameId);\n      Logger::info(\"SWAPTRACE: signalFrame direct signaled\");\n    }/s' "${file}"

  perl -0777 -i -pe 's/m_frameCond\.wait\(lock, \[this\] {\n        return !m_frameQueue\.empty\(\);\n      }\);\n\n      PresenterFrame frame = m_frameQueue\.front\(\);\n      m_frameQueue\.pop\(\);/Logger::info(str::format(\"SWAPTRACE: frameThread waiting qsize=\", m_frameQueue.size()));\n      m_frameCond.wait(lock, [this] {\n        return !m_frameQueue.empty();\n      });\n      Logger::info(str::format(\"SWAPTRACE: frameThread woke qsize=\", m_frameQueue.size()));\n\n      PresenterFrame frame = m_frameQueue.front();\n      m_frameQueue.pop();\n      Logger::info(str::format(\"SWAPTRACE: frameThread pop frameId=\", frame.frameId, \", mode=\", frame.mode, \", result=\", frame.result, \", qsize_after=\", m_frameQueue.size()));/s' "${file}"

  perl -0777 -i -pe 's/if \(!frame\.frameId\)\n        return;/if (!frame.frameId) {\n        Logger::info(\"SWAPTRACE: frameThread exit sentinel\");\n        return;\n      }/s' "${file}"

  # Track D3D11 present thread flow: acquire -> submit -> present -> wait.
  perl -0777 -i -pe 's/VkResult status = m_presenter->acquireNextImage\(sync, imageIndex\);/Logger::info(str::format(\"SWAPTRACE: D3D11 acquire request begin repeat=\", i));\n      VkResult status = m_presenter->acquireNextImage(sync, imageIndex);\n      Logger::info(str::format(\"SWAPTRACE: D3D11 acquire request end status=\", status, \", imageIndex=\", imageIndex));/s' "${d3d11_file}"

  perl -0777 -i -pe 's/m_device->submitCommandList\(cCommandList, nullptr\);\n\n      if \(cHud != nullptr && !cRepeat\)\n        cHud->update\(\);\n\n      uint64_t frameId = cRepeat \? 0 : cFrameId;\n\n      m_device->presentImage\(m_presenter,\n        cPresentMode, frameId, &m_presentStatus\);/Logger::info(str::format(\"SWAPTRACE: D3D11 submit begin repeat=\", cRepeat, \", frameId=\", cFrameId));\n      m_device->submitCommandList(cCommandList, nullptr);\n      Logger::info(\"SWAPTRACE: D3D11 submit end\");\n\n      if (cHud != nullptr && !cRepeat)\n        cHud->update();\n\n      uint64_t frameId = cRepeat ? 0 : cFrameId;\n\n      Logger::info(str::format(\"SWAPTRACE: D3D11 present request begin frameId=\", frameId, \", mode=\", cPresentMode));\n      m_device->presentImage(m_presenter,\n        cPresentMode, frameId, &m_presentStatus);\n      Logger::info(\"SWAPTRACE: D3D11 present request queued\");/s' "${d3d11_file}"

  perl -0777 -i -pe 's/VkResult status = m_device->waitForSubmission\(&m_presentStatus\);\n    \n    if \(status != VK_SUCCESS\)\n      RecreateSwapChain\(\);/VkResult status = m_device->waitForSubmission(&m_presentStatus);\n    Logger::info(str::format(\"SWAPTRACE: D3D11 waitForSubmission status=\", status));\n\n    if (status != VK_SUCCESS)\n      RecreateSwapChain();/s' "${d3d11_file}"

  perl -0777 -i -pe 's/const DXGI_PRESENT_PARAMETERS\*  pPresentParameters\) {\n    if \(\!\(PresentFlags & DXGI_PRESENT_TEST\)\)/const DXGI_PRESENT_PARAMETERS*  pPresentParameters) {\n    Logger::info(str::format(\"SWAPTRACE: D3D11 Present enter sync=\", SyncInterval, \", flags=\", PresentFlags, \", hasSwapChain=\", m_presenter->hasSwapChain()));\n    if (!(PresentFlags & DXGI_PRESENT_TEST))/s' "${d3d11_file}"

  perl -0777 -i -pe 's/if \(std::exchange\(m_dirty, false\)\)\n      RecreateSwapChain\(\);/if (std::exchange(m_dirty, false)) {\n      Logger::info(\"SWAPTRACE: D3D11 Present dirty -> recreate\");\n      RecreateSwapChain();\n    }/s' "${d3d11_file}"

  perl -0777 -i -pe 's/try {\n      hr = PresentImage\(SyncInterval\);\n    } catch \(const DxvkError& e\) {/try {\n      Logger::info(\"SWAPTRACE: D3D11 Present calling PresentImage\");\n      hr = PresentImage(SyncInterval);\n      Logger::info(str::format(\"SWAPTRACE: D3D11 Present PresentImage returned hr=\", hr));\n    } catch (const DxvkError& e) {/s' "${d3d11_file}"

  perl -0777 -i -pe 's/HRESULT D3D11SwapChain::PresentImage\(UINT SyncInterval\) {/HRESULT D3D11SwapChain::PresentImage(UINT SyncInterval) {\n    Logger::info(str::format(\"SWAPTRACE: D3D11 PresentImage enter sync=\", SyncInterval));/s' "${d3d11_file}"

  perl -0777 -i -pe 's/for \(uint32_t i = 0; i < SyncInterval \|\| i < 1; i\+\+\) {\n      SynchronizePresent\(\);/for (uint32_t i = 0; i < SyncInterval || i < 1; i++) {\n      Logger::info(str::format(\"SWAPTRACE: D3D11 PresentImage loop begin i=\", i, \", sync=\", SyncInterval));\n      SynchronizePresent();/s' "${d3d11_file}"

  perl -0777 -i -pe 's/VkResult status = m_device->waitForSubmission\(&m_presentStatus\);\n    Logger::info\(str::format\(\"SWAPTRACE: D3D11 waitForSubmission status=\", status\)\);/Logger::info(\"SWAPTRACE: D3D11 waitForSubmission begin\");\n    VkResult status = m_device->waitForSubmission(&m_presentStatus);\n    Logger::info(str::format(\"SWAPTRACE: D3D11 waitForSubmission status=\", status));/s' "${d3d11_file}"

  # Track DXGI layer present routing and early-return conditions.
  perl -0777 -i -pe 's/HRESULT STDMETHODCALLTYPE DxgiSwapChain::Present\(UINT SyncInterval, UINT Flags\) {\n    return Present1\(SyncInterval, Flags, nullptr\);\n  }/HRESULT STDMETHODCALLTYPE DxgiSwapChain::Present(UINT SyncInterval, UINT Flags) {\n    Logger::info(str::format(\"SWAPTRACE: DXGI Present enter sync=\", SyncInterval, \", flags=\", Flags, \", hwnd=\", reinterpret_cast<uint64_t>(m_window)));\n    HRESULT hr = Present1(SyncInterval, Flags, nullptr);\n    Logger::info(str::format(\"SWAPTRACE: DXGI Present exit hr=\", hr));\n    return hr;\n  }/s' "${dxgi_file}"

  perl -0777 -i -pe 's/HRESULT STDMETHODCALLTYPE DxgiSwapChain::Present1\(\n          UINT                      SyncInterval,\n          UINT                      PresentFlags,\n    const DXGI_PRESENT_PARAMETERS\*  pPresentParameters\) {\n\n    if \(SyncInterval > 4\)\n      return DXGI_ERROR_INVALID_CALL;/HRESULT STDMETHODCALLTYPE DxgiSwapChain::Present1(\n          UINT                      SyncInterval,\n          UINT                      PresentFlags,\n    const DXGI_PRESENT_PARAMETERS*  pPresentParameters) {\n\n    Logger::info(str::format(\"SWAPTRACE: DXGI Present1 enter sync=\", SyncInterval,\n      \", flags=\", PresentFlags,\n      \", hwnd=\", reinterpret_cast<uint64_t>(m_window),\n      \", hasParams=\", pPresentParameters != nullptr));\n\n    if (SyncInterval > 4) {\n      Logger::info(str::format(\"SWAPTRACE: DXGI Present1 early invalid sync=\", SyncInterval));\n      return DXGI_ERROR_INVALID_CALL;\n    }/s' "${dxgi_file}"

  perl -0777 -i -pe 's/std::lock_guard<dxvk::recursive_mutex> lockWin\(m_lockWindow\);\n    HRESULT hr = S_OK;\n\n    if \(wsi::isWindow\(m_window\)\) {\n      std::lock_guard<dxvk::mutex> lockBuf\(m_lockBuffer\);\n      hr = m_presenter->Present\(SyncInterval, PresentFlags, nullptr\);\n    }\n\n    if \(PresentFlags & DXGI_PRESENT_TEST\)\n      return hr;/std::lock_guard<dxvk::recursive_mutex> lockWin(m_lockWindow);\n    HRESULT hr = S_OK;\n\n    bool isWindow = wsi::isWindow(m_window);\n    Logger::info(str::format(\"SWAPTRACE: DXGI Present1 window check isWindow=\", isWindow,\n      \", hwnd=\", reinterpret_cast<uint64_t>(m_window)));\n\n    if (isWindow) {\n      std::lock_guard<dxvk::mutex> lockBuf(m_lockBuffer);\n      Logger::info(\"SWAPTRACE: DXGI Present1 calling m_presenter->Present\");\n      hr = m_presenter->Present(SyncInterval, PresentFlags, nullptr);\n      Logger::info(str::format(\"SWAPTRACE: DXGI Present1 m_presenter->Present hr=\", hr));\n    } else {\n      Logger::info(\"SWAPTRACE: DXGI Present1 skipped presenter call because isWindow=0\");\n    }\n\n    if (PresentFlags & DXGI_PRESENT_TEST) {\n      Logger::info(str::format(\"SWAPTRACE: DXGI Present1 early test-flag hr=\", hr));\n      return hr;\n    }/s' "${dxgi_file}"

  perl -0777 -i -pe 's/return hr;\n  }\n/Logger::info(str::format(\"SWAPTRACE: DXGI Present1 exit hr=\", hr, \", presentId=\", m_presentId));\n    return hr;\n  }\n/s' "${dxgi_file}"

  # Confirm which interface entrypoints app actually uses.
  perl -0777 -i -pe 's/HRESULT STDMETHODCALLTYPE Present\(\n            UINT                      SyncInterval,\n            UINT                      Flags\) final {\n      return m_dispatch->Present\(SyncInterval, Flags\);\n    }/HRESULT STDMETHODCALLTYPE Present(\n            UINT                      SyncInterval,\n            UINT                      Flags) final {\n      Logger::info(str::format(\"SWAPTRACE: Dispatcher Present sync=\", SyncInterval, \", flags=\", Flags));\n      HRESULT hr = m_dispatch->Present(SyncInterval, Flags);\n      Logger::info(str::format(\"SWAPTRACE: Dispatcher Present hr=\", hr));\n      return hr;\n    }/s' "${dxgi_dispatch_file}"

  perl -0777 -i -pe 's/HRESULT STDMETHODCALLTYPE Present1\(\n            UINT                      SyncInterval,\n            UINT                      PresentFlags,\n      const DXGI_PRESENT_PARAMETERS\*  pPresentParameters\) final {\n      return m_dispatch->Present1\(SyncInterval, PresentFlags, pPresentParameters\);\n    }/HRESULT STDMETHODCALLTYPE Present1(\n            UINT                      SyncInterval,\n            UINT                      PresentFlags,\n      const DXGI_PRESENT_PARAMETERS*  pPresentParameters) final {\n      Logger::info(str::format(\"SWAPTRACE: Dispatcher Present1 sync=\", SyncInterval,\n        \", flags=\", PresentFlags, \", hasParams=\", pPresentParameters != nullptr));\n      HRESULT hr = m_dispatch->Present1(SyncInterval, PresentFlags, pPresentParameters);\n      Logger::info(str::format(\"SWAPTRACE: Dispatcher Present1 hr=\", hr));\n      return hr;\n    }/s' "${dxgi_dispatch_file}"

  # Track pipeline worker queue and early-return behavior after "Using N compiler threads".
  perl -0777 -i -pe 's/void DxvkPipelineWorkers::compilePipelineLibrary\(\n          DxvkShaderPipelineLibrary\*      library,\n          DxvkPipelinePriority            priority\) {\n    std::unique_lock lock\(m_lock\);\n    this->startWorkers\(\);\n\n    m_tasksTotal \+= 1;\n\n    m_buckets\[uint32_t\(priority\)\]\.queue\.emplace\(library\);\n    notifyWorkers\(priority\);\n  }/void DxvkPipelineWorkers::compilePipelineLibrary(\n          DxvkShaderPipelineLibrary*      library,\n          DxvkPipelinePriority            priority) {\n    std::unique_lock lock(m_lock);\n    uint32_t index = uint32_t(priority);\n    auto before = m_buckets[index].queue.size();\n    Logger::info(str::format(\"SWAPTRACE_Q: compilePipelineLibrary enter priority=\", index,\n      \", q_before=\", before, \", tasksTotal=\", m_tasksTotal.load(std::memory_order_relaxed)));\n\n    this->startWorkers();\n\n    m_tasksTotal += 1;\n\n    m_buckets[index].queue.emplace(library);\n    Logger::info(str::format(\"SWAPTRACE_Q: compilePipelineLibrary queued priority=\", index,\n      \", q_after=\", m_buckets[index].queue.size(), \", tasksTotal=\", m_tasksTotal.load(std::memory_order_relaxed)));\n    notifyWorkers(priority);\n  }/s' "${pipe_file}"

  perl -0777 -i -pe 's/void DxvkPipelineWorkers::compileGraphicsPipeline\(\n          DxvkGraphicsPipeline\*           pipeline,\n    const DxvkGraphicsPipelineStateInfo&  state,\n          DxvkPipelinePriority            priority\) {\n    std::unique_lock lock\(m_lock\);\n    this->startWorkers\(\);\n\n    pipeline->acquirePipeline\(\);\n    m_tasksTotal \+= 1;\n\n    m_buckets\[uint32_t\(priority\)\]\.queue\.emplace\(pipeline, state\);\n    notifyWorkers\(priority\);\n  }/void DxvkPipelineWorkers::compileGraphicsPipeline(\n          DxvkGraphicsPipeline*           pipeline,\n    const DxvkGraphicsPipelineStateInfo&  state,\n          DxvkPipelinePriority            priority) {\n    std::unique_lock lock(m_lock);\n    uint32_t index = uint32_t(priority);\n    auto before = m_buckets[index].queue.size();\n    Logger::info(str::format(\"SWAPTRACE_Q: compileGraphicsPipeline enter priority=\", index,\n      \", q_before=\", before, \", tasksTotal=\", m_tasksTotal.load(std::memory_order_relaxed)));\n\n    this->startWorkers();\n\n    pipeline->acquirePipeline();\n    m_tasksTotal += 1;\n\n    m_buckets[index].queue.emplace(pipeline, state);\n    Logger::info(str::format(\"SWAPTRACE_Q: compileGraphicsPipeline queued priority=\", index,\n      \", q_after=\", m_buckets[index].queue.size(), \", tasksTotal=\", m_tasksTotal.load(std::memory_order_relaxed)));\n    notifyWorkers(priority);\n  }/s' "${pipe_file}"

  perl -0777 -i -pe 's/bucket\.cond\.wait\(lock, \[this, maxPriorityIndex, &entry\] {\n          \/\/ Attempt to fetch a work item from the\n          \/\/ highest-priority queue that is not empty\n          for \(uint32_t i = 0; i <= maxPriorityIndex; i\+\+\) {\n            if \(!m_buckets\[i\]\.queue\.empty\(\)\) {\n              entry = m_buckets\[i\]\.queue\.front\(\);\n              m_buckets\[i\]\.queue\.pop\(\);\n              return true;\n            }\n          }\n\n          return !m_workersRunning;\n        }\);/Logger::info(str::format(\"SWAPTRACE_Q: worker wait enter maxPriority=\", maxPriorityIndex,\n          \", q0=\", m_buckets[0].queue.size(), \", q1=\", m_buckets[1].queue.size(), \", q2=\", m_buckets[2].queue.size()));\n        bucket.cond.wait(lock, [this, maxPriorityIndex, &entry] {\n          for (uint32_t i = 0; i <= maxPriorityIndex; i++) {\n            if (!m_buckets[i].queue.empty()) {\n              entry = m_buckets[i].queue.front();\n              m_buckets[i].queue.pop();\n              return true;\n            }\n          }\n\n          return !m_workersRunning;\n        });\n        Logger::info(str::format(\"SWAPTRACE_Q: worker wake maxPriority=\", maxPriorityIndex,\n          \", running=\", m_workersRunning,\n          \", q0=\", m_buckets[0].queue.size(), \", q1=\", m_buckets[1].queue.size(), \", q2=\", m_buckets[2].queue.size()));/s' "${pipe_file}"

  perl -0777 -i -pe 's/if \(!m_workersRunning\)\n          break;/if (!m_workersRunning) {\n          Logger::info(str::format(\"SWAPTRACE_Q: worker exit maxPriority=\", maxPriorityIndex));\n          break;\n        }/s' "${pipe_file}"

  perl -0777 -i -pe 's/if \(entry\.pipelineLibrary\) {\n        entry\.pipelineLibrary->compilePipeline\(\);\n      } else if \(entry\.graphicsPipeline\) {\n        entry\.graphicsPipeline->compilePipeline\(entry\.graphicsState\);\n        entry\.graphicsPipeline->releasePipeline\(\);\n      }\n\n      m_tasksCompleted \+= 1;/if (entry.pipelineLibrary) {\n        Logger::info(str::format(\"SWAPTRACE_Q: worker compile library begin maxPriority=\", maxPriorityIndex));\n        entry.pipelineLibrary->compilePipeline();\n        Logger::info(str::format(\"SWAPTRACE_Q: worker compile library end maxPriority=\", maxPriorityIndex));\n      } else if (entry.graphicsPipeline) {\n        Logger::info(str::format(\"SWAPTRACE_Q: worker compile graphics begin maxPriority=\", maxPriorityIndex));\n        entry.graphicsPipeline->compilePipeline(entry.graphicsState);\n        entry.graphicsPipeline->releasePipeline();\n        Logger::info(str::format(\"SWAPTRACE_Q: worker compile graphics end maxPriority=\", maxPriorityIndex));\n      } else {\n        Logger::info(str::format(\"SWAPTRACE_Q: worker woke with empty entry maxPriority=\", maxPriorityIndex));\n      }\n\n      m_tasksCompleted += 1;\n      Logger::info(str::format(\"SWAPTRACE_Q: worker task done maxPriority=\", maxPriorityIndex,\n        \", tasksCompleted=\", m_tasksCompleted.load(std::memory_order_relaxed),\n        \", tasksTotal=\", m_tasksTotal.load(std::memory_order_relaxed)));/s' "${pipe_file}"

  perl -0777 -i -pe 's/void DxvkPipelineManager::requestCompileShader\(\n    const Rc<DxvkShader>&         shader\) {\n    if \(!shader->needsLibraryCompile\(\)\)\n      return;/void DxvkPipelineManager::requestCompileShader(\n    const Rc<DxvkShader>&         shader) {\n    if (!shader->needsLibraryCompile()) {\n      Logger::info(\"SWAPTRACE_Q: requestCompileShader skip needsLibraryCompile=0\");\n      return;\n    }\n\n    Logger::info(\"SWAPTRACE_Q: requestCompileShader dispatch\");/s' "${pipe_file}"

  perl -0777 -i -pe 's/if \(library\)\n      m_workers\.compilePipelineLibrary\(library, DxvkPipelinePriority::High\);/if (library) {\n      Logger::info(\"SWAPTRACE_Q: requestCompileShader queue high-priority library\");\n      m_workers.compilePipelineLibrary(library, DxvkPipelinePriority::High);\n    } else {\n      Logger::info(\"SWAPTRACE_Q: requestCompileShader no library found\");\n    }/s' "${pipe_file}"

  perl -0777 -i -pe 's/std::pair<VkPipeline, DxvkGraphicsPipelineType> DxvkGraphicsPipeline::getPipelineHandle\(\n    const DxvkGraphicsPipelineStateInfo& state\) {\n    DxvkGraphicsPipelineInstance\* instance = this->findInstance\(state\);/std::pair<VkPipeline, DxvkGraphicsPipelineType> DxvkGraphicsPipeline::getPipelineHandle(\n    const DxvkGraphicsPipelineStateInfo& state) {\n    Logger::info(\"SWAPTRACE_Q: getPipelineHandle enter\");\n    DxvkGraphicsPipelineInstance* instance = this->findInstance(state);/s' "${graphics_file}"

  perl -0777 -i -pe 's/if \(!this->validatePipelineState\(state, true\)\)\n        return std::make_pair\(VK_NULL_HANDLE, DxvkGraphicsPipelineType::FastPipeline\);/if (!this->validatePipelineState(state, true)) {\n        Logger::info(\"SWAPTRACE_Q: getPipelineHandle early invalid state\");\n        return std::make_pair(VK_NULL_HANDLE, DxvkGraphicsPipelineType::FastPipeline);\n      }/s' "${graphics_file}"

  perl -0777 -i -pe 's/bool canCreateBasePipeline = this->canCreateBasePipeline\(state\);\n        instance = this->createInstance\(state, canCreateBasePipeline\);/bool canCreateBasePipeline = this->canCreateBasePipeline(state);\n        Logger::info(str::format(\"SWAPTRACE_Q: getPipelineHandle createInstance canCreateBase=\", canCreateBasePipeline));\n        instance = this->createInstance(state, canCreateBasePipeline);/s' "${graphics_file}"

  perl -0777 -i -pe 's/if \(!instance->fastHandle\.load\(\)\)\n          m_workers->compileGraphicsPipeline\(this, state, DxvkPipelinePriority::Low\);/if (!instance->fastHandle.load()) {\n          Logger::info(\"SWAPTRACE_Q: getPipelineHandle queue low-priority compileGraphicsPipeline\");\n          m_workers->compileGraphicsPipeline(this, state, DxvkPipelinePriority::Low);\n        } else {\n          Logger::info(\"SWAPTRACE_Q: getPipelineHandle fastHandle already ready\");\n        }/s' "${graphics_file}"

  perl -0777 -i -pe 's/void DxvkGraphicsPipeline::compilePipeline\(\n    const DxvkGraphicsPipelineStateInfo& state\) {\n    if \(m_device->config\(\)\.enableGraphicsPipelineLibrary == Tristate::True\)\n      return;/void DxvkGraphicsPipeline::compilePipeline(\n    const DxvkGraphicsPipelineStateInfo& state) {\n    if (m_device->config().enableGraphicsPipelineLibrary == Tristate::True) {\n      Logger::info(\"SWAPTRACE_Q: compilePipeline early skip enableGraphicsPipelineLibrary=True\");\n      return;\n    }/s' "${graphics_file}"

  perl -0777 -i -pe 's/if \(!this->validatePipelineState\(state, false\)\)\n        return;/if (!this->validatePipelineState(state, false)) {\n        Logger::info(\"SWAPTRACE_Q: compilePipeline early invalid state\");\n        return;\n      }/s' "${graphics_file}"

  perl -0777 -i -pe 's/if \(this->canCreateBasePipeline\(state\)\)\n        return;/if (this->canCreateBasePipeline(state)) {\n        Logger::info(\"SWAPTRACE_Q: compilePipeline early canCreateBasePipeline=1\");\n        return;\n      }/s' "${graphics_file}"

  perl -0777 -i -pe 's/if \(instance->isCompiling\.load\(\)\n     \|\| instance->isCompiling\.exchange\(VK_TRUE, std::memory_order_acquire\)\)\n      return;/if (instance->isCompiling.load()\n     || instance->isCompiling.exchange(VK_TRUE, std::memory_order_acquire)) {\n      Logger::info(\"SWAPTRACE_Q: compilePipeline early already compiling\");\n      return;\n    }/s' "${graphics_file}"

  perl -0777 -i -pe 's/VkPipeline pipeline = this->getOptimizedPipeline\(state\);\n    instance->fastHandle\.store\(pipeline, std::memory_order_release\);/Logger::info(\"SWAPTRACE_Q: compilePipeline getOptimizedPipeline begin\");\n    VkPipeline pipeline = this->getOptimizedPipeline(state);\n    instance->fastHandle.store(pipeline, std::memory_order_release);\n    Logger::info(str::format(\"SWAPTRACE_Q: compilePipeline getOptimizedPipeline end pipeline=\", (uint64_t)pipeline));/s' "${graphics_file}"

  # Track whether draw calls are actually emitted and committed to DXVK context.
  perl -0777 -i -pe 's/void STDMETHODCALLTYPE D3D11CommonContext<ContextType>::Draw\(\n          UINT            VertexCount,\n          UINT            StartVertexLocation\) {\n    D3D10DeviceLock lock = LockContext\(\);\n\n    EmitCs\(\[=\] \(DxvkContext\* ctx\) {\n      ctx->draw\(\n        VertexCount, 1,\n        StartVertexLocation, 0\);\n    }\);\n  }/void STDMETHODCALLTYPE D3D11CommonContext<ContextType>::Draw(\n          UINT            VertexCount,\n          UINT            StartVertexLocation) {\n    D3D10DeviceLock lock = LockContext();\n\n    static std::atomic<uint32_t> sSwaptraceD3d11DrawCount { 0u };\n    uint32_t drawCount = sSwaptraceD3d11DrawCount.fetch_add(1u, std::memory_order_relaxed);\n    if (drawCount < 128u) {\n      std::fprintf(stderr, \"SWAPTRACE_Q2 D3D11::Draw count=%u vc=%u sv=%u\\\\n\",\n        unsigned(drawCount), unsigned(VertexCount), unsigned(StartVertexLocation));\n      std::fflush(stderr);\n    }\n\n    EmitCs([=] (DxvkContext* ctx) {\n      ctx->draw(\n        VertexCount, 1,\n        StartVertexLocation, 0);\n    });\n  }/s' "${d3d11_context_file}"

  perl -0777 -i -pe 's/void STDMETHODCALLTYPE D3D11CommonContext<ContextType>::DrawIndexed\(\n          UINT            IndexCount,\n          UINT            StartIndexLocation,\n          INT             BaseVertexLocation\) {\n    D3D10DeviceLock lock = LockContext\(\);\n\n    EmitCs\(\[=\] \(DxvkContext\* ctx\) {\n      ctx->drawIndexed\(\n        IndexCount, 1,\n        StartIndexLocation,\n        BaseVertexLocation, 0\);\n    }\);\n  }/void STDMETHODCALLTYPE D3D11CommonContext<ContextType>::DrawIndexed(\n          UINT            IndexCount,\n          UINT            StartIndexLocation,\n          INT             BaseVertexLocation) {\n    D3D10DeviceLock lock = LockContext();\n\n    static std::atomic<uint32_t> sSwaptraceD3d11DrawIndexedCount { 0u };\n    uint32_t drawCount = sSwaptraceD3d11DrawIndexedCount.fetch_add(1u, std::memory_order_relaxed);\n    if (drawCount < 128u) {\n      std::fprintf(stderr, \"SWAPTRACE_Q2 D3D11::DrawIndexed count=%u ic=%u si=%u bv=%d\\\\n\",\n        unsigned(drawCount), unsigned(IndexCount), unsigned(StartIndexLocation), int(BaseVertexLocation));\n      std::fflush(stderr);\n    }\n\n    EmitCs([=] (DxvkContext* ctx) {\n      ctx->drawIndexed(\n        IndexCount, 1,\n        StartIndexLocation,\n        BaseVertexLocation, 0);\n    });\n  }/s' "${d3d11_context_file}"

  perl -0777 -i -pe 's/void DxvkContext::flushCommandList\(DxvkSubmitStatus\* status\) {\n    m_device->submitCommandList\(\n      this->endRecording\(\), status\);\n    \n    this->beginRecording\(\n      m_device->createCommandList\(\)\);\n  }/void DxvkContext::flushCommandList(DxvkSubmitStatus* status) {\n    static std::atomic<uint32_t> sSwaptraceFlushCount { 0u };\n    uint32_t flushCount = sSwaptraceFlushCount.fetch_add(1u, std::memory_order_relaxed);\n    if (flushCount < 128u) {\n      std::fprintf(stderr, \"SWAPTRACE_Q2 DxvkContext::flushCommandList count=%u status_ptr=%p\\\\n\",\n        unsigned(flushCount), reinterpret_cast<void*>(status));\n      std::fflush(stderr);\n    }\n\n    m_device->submitCommandList(\n      this->endRecording(), status);\n\n    this->beginRecording(\n      m_device->createCommandList());\n  }/s' "${dxvk_context_file}"

  perl -0777 -i -pe 's/void DxvkContext::draw\(\n          uint32_t vertexCount,\n          uint32_t instanceCount,\n          uint32_t firstVertex,\n          uint32_t firstInstance\) {\n    if \(this->commitGraphicsState<false, false>\(\)\) {\n      m_cmd->cmdDraw\(\n        vertexCount, instanceCount,\n        firstVertex, firstInstance\);\n    }\n    \n    m_cmd->addStatCtr\(DxvkStatCounter::CmdDrawCalls, 1\);\n  }/void DxvkContext::draw(\n          uint32_t vertexCount,\n          uint32_t instanceCount,\n          uint32_t firstVertex,\n          uint32_t firstInstance) {\n    bool committed = this->commitGraphicsState<false, false>();\n\n    static std::atomic<uint32_t> sSwaptraceCtxDrawCount { 0u };\n    uint32_t drawCount = sSwaptraceCtxDrawCount.fetch_add(1u, std::memory_order_relaxed);\n    if (drawCount < 256u) {\n      std::fprintf(stderr, \"SWAPTRACE_Q2 DxvkContext::draw count=%u committed=%d vc=%u ic=%u fv=%u fi=%u\\\\n\",\n        unsigned(drawCount), int(committed), unsigned(vertexCount), unsigned(instanceCount), unsigned(firstVertex), unsigned(firstInstance));\n      std::fflush(stderr);\n    }\n\n    if (committed) {\n      m_cmd->cmdDraw(\n        vertexCount, instanceCount,\n        firstVertex, firstInstance);\n    }\n\n    m_cmd->addStatCtr(DxvkStatCounter::CmdDrawCalls, 1);\n  }/s' "${dxvk_context_file}"

  perl -0777 -i -pe 's/void DxvkContext::drawIndexed\(\n          uint32_t indexCount,\n          uint32_t instanceCount,\n          uint32_t firstIndex,\n          int32_t  vertexOffset,\n          uint32_t firstInstance\) {\n    if \(this->commitGraphicsState<true, false>\(\)\) {\n      m_cmd->cmdDrawIndexed\(\n        indexCount, instanceCount,\n        firstIndex, vertexOffset,\n        firstInstance\);\n    }\n    \n    m_cmd->addStatCtr\(DxvkStatCounter::CmdDrawCalls, 1\);\n  }/void DxvkContext::drawIndexed(\n          uint32_t indexCount,\n          uint32_t instanceCount,\n          uint32_t firstIndex,\n          int32_t  vertexOffset,\n          uint32_t firstInstance) {\n    bool committed = this->commitGraphicsState<true, false>();\n\n    static std::atomic<uint32_t> sSwaptraceCtxDrawIndexedCount { 0u };\n    uint32_t drawCount = sSwaptraceCtxDrawIndexedCount.fetch_add(1u, std::memory_order_relaxed);\n    if (drawCount < 256u) {\n      std::fprintf(stderr, \"SWAPTRACE_Q2 DxvkContext::drawIndexed count=%u committed=%d ic=%u inst=%u fi=%u vo=%d fInst=%u\\\\n\",\n        unsigned(drawCount), int(committed), unsigned(indexCount), unsigned(instanceCount), unsigned(firstIndex), int(vertexOffset), unsigned(firstInstance));\n      std::fflush(stderr);\n    }\n\n    if (committed) {\n      m_cmd->cmdDrawIndexed(\n        indexCount, instanceCount,\n        firstIndex, vertexOffset,\n        firstInstance);\n    }\n\n    m_cmd->addStatCtr(DxvkStatCounter::CmdDrawCalls, 1);\n  }/s' "${dxvk_context_file}"

  # Track pre-present D3D11 state setup to verify first-frame pipeline reaches render setup.
  perl -0777 -i -pe 's/void STDMETHODCALLTYPE D3D11CommonContext<ContextType>::OMSetRenderTargets\(\n          UINT                              NumViews,\n          ID3D11RenderTargetView\* const\*    ppRenderTargetViews,\n          ID3D11DepthStencilView\*           pDepthStencilView\) {\n    D3D10DeviceLock lock = LockContext\(\);\n\n    SetRenderTargetsAndUnorderedAccessViews\(\n      NumViews, ppRenderTargetViews, pDepthStencilView,\n      NumViews, 0, nullptr, nullptr\);\n  }/void STDMETHODCALLTYPE D3D11CommonContext<ContextType>::OMSetRenderTargets(\n          UINT                              NumViews,\n          ID3D11RenderTargetView* const*    ppRenderTargetViews,\n          ID3D11DepthStencilView*           pDepthStencilView) {\n    D3D10DeviceLock lock = LockContext();\n\n    static std::atomic<uint32_t> sSwaptraceOmSetRtCount { 0u };\n    uint32_t callCount = sSwaptraceOmSetRtCount.fetch_add(1u, std::memory_order_relaxed);\n    if (callCount < 256u) {\n      std::fprintf(stderr, \"SWAPTRACE_Q3 D3D11::OMSetRenderTargets count=%u numViews=%u hasDsv=%d\\\\n\",\n        unsigned(callCount), unsigned(NumViews), int(pDepthStencilView != nullptr));\n      std::fflush(stderr);\n    }\n\n    SetRenderTargetsAndUnorderedAccessViews(\n      NumViews, ppRenderTargetViews, pDepthStencilView,\n      NumViews, 0, nullptr, nullptr);\n  }/s' "${d3d11_context_file}"

  perl -0777 -i -pe 's/void STDMETHODCALLTYPE D3D11CommonContext<ContextType>::ClearRenderTargetView\(\n          ID3D11RenderTargetView\*           pRenderTargetView,\n    const FLOAT                             ColorRGBA\[4\]\) {\n    D3D10DeviceLock lock = LockContext\(\);\n\n    auto rtv = static_cast<D3D11RenderTargetView\*>\(pRenderTargetView\);\n\n    if \(!rtv\)\n      return;/void STDMETHODCALLTYPE D3D11CommonContext<ContextType>::ClearRenderTargetView(\n          ID3D11RenderTargetView*           pRenderTargetView,\n    const FLOAT                             ColorRGBA[4]) {\n    D3D10DeviceLock lock = LockContext();\n\n    static std::atomic<uint32_t> sSwaptraceClearRtCount { 0u };\n    uint32_t callCount = sSwaptraceClearRtCount.fetch_add(1u, std::memory_order_relaxed);\n    if (callCount < 256u) {\n      std::fprintf(stderr, \"SWAPTRACE_Q3 D3D11::ClearRenderTargetView count=%u hasRtv=%d rgba=%g,%g,%g,%g\\\\n\",\n        unsigned(callCount), int(pRenderTargetView != nullptr),\n        double(ColorRGBA[0]), double(ColorRGBA[1]), double(ColorRGBA[2]), double(ColorRGBA[3]));\n      std::fflush(stderr);\n    }\n\n    auto rtv = static_cast<D3D11RenderTargetView*>(pRenderTargetView);\n\n    if (!rtv)\n      return;/s' "${d3d11_context_file}"

  perl -0777 -i -pe 's/void STDMETHODCALLTYPE D3D11CommonContext<ContextType>::ClearDepthStencilView\(\n          ID3D11DepthStencilView\*           pDepthStencilView,\n          UINT                              ClearFlags,\n          FLOAT                             Depth,\n          UINT8                             Stencil\) {\n    D3D10DeviceLock lock = LockContext\(\);\n\n    auto dsv = static_cast<D3D11DepthStencilView\*>\(pDepthStencilView\);\n\n    if \(!dsv\)\n      return;/void STDMETHODCALLTYPE D3D11CommonContext<ContextType>::ClearDepthStencilView(\n          ID3D11DepthStencilView*           pDepthStencilView,\n          UINT                              ClearFlags,\n          FLOAT                             Depth,\n          UINT8                             Stencil) {\n    D3D10DeviceLock lock = LockContext();\n\n    static std::atomic<uint32_t> sSwaptraceClearDsvCount { 0u };\n    uint32_t callCount = sSwaptraceClearDsvCount.fetch_add(1u, std::memory_order_relaxed);\n    if (callCount < 256u) {\n      std::fprintf(stderr, \"SWAPTRACE_Q3 D3D11::ClearDepthStencilView count=%u hasDsv=%d flags=0x%x depth=%g stencil=%u\\\\n\",\n        unsigned(callCount), int(pDepthStencilView != nullptr), unsigned(ClearFlags), double(Depth), unsigned(Stencil));\n      std::fflush(stderr);\n    }\n\n    auto dsv = static_cast<D3D11DepthStencilView*>(pDepthStencilView);\n\n    if (!dsv)\n      return;/s' "${d3d11_context_file}"

  perl -0777 -i -pe 's/void STDMETHODCALLTYPE D3D11CommonContext<ContextType>::IASetPrimitiveTopology\(D3D11_PRIMITIVE_TOPOLOGY Topology\) {\n    D3D10DeviceLock lock = LockContext\(\);\n\n    if \(m_state\.ia\.primitiveTopology != Topology\) {\n      m_state\.ia\.primitiveTopology = Topology;\n      ApplyPrimitiveTopology\(\);\n    }\n  }/void STDMETHODCALLTYPE D3D11CommonContext<ContextType>::IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY Topology) {\n    D3D10DeviceLock lock = LockContext();\n\n    static std::atomic<uint32_t> sSwaptraceIaTopoCount { 0u };\n    uint32_t callCount = sSwaptraceIaTopoCount.fetch_add(1u, std::memory_order_relaxed);\n    if (callCount < 256u) {\n      std::fprintf(stderr, \"SWAPTRACE_Q3 D3D11::IASetPrimitiveTopology count=%u topology=%u\\\\n\",\n        unsigned(callCount), unsigned(Topology));\n      std::fflush(stderr);\n    }\n\n    if (m_state.ia.primitiveTopology != Topology) {\n      m_state.ia.primitiveTopology = Topology;\n      ApplyPrimitiveTopology();\n    }\n  }/s' "${d3d11_context_file}"

  perl -0777 -i -pe 's/void STDMETHODCALLTYPE D3D11CommonContext<ContextType>::RSSetViewports\(\n          UINT                              NumViewports,\n    const D3D11_VIEWPORT\*                   pViewports\) {\n    D3D10DeviceLock lock = LockContext\(\);\n\n    if \(unlikely\(NumViewports > m_state\.rs\.viewports\.size\(\)\)\)\n      return;/void STDMETHODCALLTYPE D3D11CommonContext<ContextType>::RSSetViewports(\n          UINT                              NumViewports,\n    const D3D11_VIEWPORT*                   pViewports) {\n    D3D10DeviceLock lock = LockContext();\n\n    static std::atomic<uint32_t> sSwaptraceRsVpCount { 0u };\n    uint32_t callCount = sSwaptraceRsVpCount.fetch_add(1u, std::memory_order_relaxed);\n    if (callCount < 256u) {\n      double w = NumViewports && pViewports ? double(pViewports[0].Width) : 0.0;\n      double h = NumViewports && pViewports ? double(pViewports[0].Height) : 0.0;\n      std::fprintf(stderr, \"SWAPTRACE_Q3 D3D11::RSSetViewports count=%u num=%u first=%gx%g\\\\n\",\n        unsigned(callCount), unsigned(NumViewports), w, h);\n      std::fflush(stderr);\n    }\n\n    if (unlikely(NumViewports > m_state.rs.viewports.size()))\n      return;/s' "${d3d11_context_file}"

  # Add realtime stderr logging to avoid buffered Logger truncation.
  if ! grep -q '#include <cstdio>' "${file}"; then
    sed -i '1i #include <cstdio>' "${file}"
  fi
  if ! grep -q '#include <cstdio>' "${d3d11_file}"; then
    sed -i '1i #include <cstdio>' "${d3d11_file}"
  fi
  if ! grep -q '#include <cstdio>' "${dxgi_file}"; then
    sed -i '1i #include <cstdio>' "${dxgi_file}"
  fi
  if ! grep -q '#include <cstdio>' "${d3d11_context_file}"; then
    sed -i '1i #include <cstdio>' "${d3d11_context_file}"
  fi
  if ! grep -q '#include <atomic>' "${d3d11_context_file}"; then
    sed -i '1i #include <atomic>' "${d3d11_context_file}"
  fi
  if ! grep -q '#include <cstdio>' "${dxvk_context_file}"; then
    sed -i '1i #include <cstdio>' "${dxvk_context_file}"
  fi
  if ! grep -q '#include <atomic>' "${dxvk_context_file}"; then
    sed -i '1i #include <atomic>' "${dxvk_context_file}"
  fi

  perl -0777 -i -pe 's/Logger::info\("SWAPTRACE: before getSwapImages"\);/Logger::info("SWAPTRACE: before getSwapImages");\n    std::fprintf(stderr, "SWAPTRACE_RT before getSwapImages\\n");\n    std::fflush(stderr);/s' "${file}"
  perl -0777 -i -pe 's/Logger::info\("SWAPTRACE: getSwapImages call1 begin"\);/Logger::info("SWAPTRACE: getSwapImages call1 begin");\n    std::fprintf(stderr, "SWAPTRACE_RT getSwapImages call1 begin\\n");\n    std::fflush(stderr);/s' "${file}"
  perl -0777 -i -pe 's/Logger::info\(str::format\("SWAPTRACE: getSwapImages call1 end status=", status, ", imageCount=", imageCount\)\);/Logger::info(str::format("SWAPTRACE: getSwapImages call1 end status=", status, ", imageCount=", imageCount));\n    std::fprintf(stderr, "SWAPTRACE_RT getSwapImages call1 end status=%d imageCount=%u\\n", int(status), unsigned(imageCount));\n    std::fflush(stderr);/s' "${file}"
  perl -0777 -i -pe 's/Logger::info\(str::format\("SWAPTRACE: getSwapImages call2 begin imageCount=", imageCount\)\);/Logger::info(str::format("SWAPTRACE: getSwapImages call2 begin imageCount=", imageCount));\n    std::fprintf(stderr, "SWAPTRACE_RT getSwapImages call2 begin imageCount=%u\\n", unsigned(imageCount));\n    std::fflush(stderr);/s' "${file}"
  perl -0777 -i -pe 's/Logger::info\(str::format\("SWAPTRACE: getSwapImages call2 end status=", status, ", imageCount=", imageCount\)\);/Logger::info(str::format("SWAPTRACE: getSwapImages call2 end status=", status, ", imageCount=", imageCount));\n    std::fprintf(stderr, "SWAPTRACE_RT getSwapImages call2 end status=%d imageCount=%u\\n", int(status), unsigned(imageCount));\n    std::fflush(stderr);/s' "${file}"

  perl -0777 -i -pe 's/Logger::info\(str::format\("SWAPTRACE: D3D11 Present enter sync=", SyncInterval, ", flags=", PresentFlags, ", hasSwapChain=", m_presenter->hasSwapChain\(\)\)\);/Logger::info(str::format("SWAPTRACE: D3D11 Present enter sync=", SyncInterval, ", flags=", PresentFlags, ", hasSwapChain=", m_presenter->hasSwapChain()));\n    std::fprintf(stderr, "SWAPTRACE_RT D3D11 Present enter sync=%u flags=%u hasSwap=%d\\n", unsigned(SyncInterval), unsigned(PresentFlags), int(m_presenter->hasSwapChain()));\n    std::fflush(stderr);/s' "${d3d11_file}"
  perl -0777 -i -pe 's/Logger::info\("SWAPTRACE: D3D11 Present calling PresentImage"\);/Logger::info("SWAPTRACE: D3D11 Present calling PresentImage");\n      std::fprintf(stderr, "SWAPTRACE_RT D3D11 Present calling PresentImage\\n");\n      std::fflush(stderr);/s' "${d3d11_file}"
  perl -0777 -i -pe 's/Logger::info\(str::format\("SWAPTRACE: D3D11 Present PresentImage returned hr=", hr\)\);/Logger::info(str::format("SWAPTRACE: D3D11 Present PresentImage returned hr=", hr));\n      std::fprintf(stderr, "SWAPTRACE_RT D3D11 Present PresentImage returned hr=%ld\\n", long(hr));\n      std::fflush(stderr);/s' "${d3d11_file}"

  perl -0777 -i -pe 's/Logger::info\(str::format\("SWAPTRACE: DXGI Present enter sync=", SyncInterval, ", flags=", Flags, ", hwnd=", reinterpret_cast<uint64_t>\(m_window\)\)\);/Logger::info(str::format("SWAPTRACE: DXGI Present enter sync=", SyncInterval, ", flags=", Flags, ", hwnd=", reinterpret_cast<uint64_t>(m_window)));\n    std::fprintf(stderr, "SWAPTRACE_RT DXGI Present enter sync=%u flags=%u hwnd=%llu\\n", unsigned(SyncInterval), unsigned(Flags), (unsigned long long)reinterpret_cast<uint64_t>(m_window));\n    std::fflush(stderr);/s' "${dxgi_file}"
  perl -0777 -i -pe 's/Logger::info\(str::format\("SWAPTRACE: DXGI Present1 enter sync=", SyncInterval,\n      ", flags=", PresentFlags,\n      ", hwnd=", reinterpret_cast<uint64_t>\(m_window\),\n      ", hasParams=", pPresentParameters != nullptr\)\);/Logger::info(str::format("SWAPTRACE: DXGI Present1 enter sync=", SyncInterval,\n      ", flags=", PresentFlags,\n      ", hwnd=", reinterpret_cast<uint64_t>(m_window),\n      ", hasParams=", pPresentParameters != nullptr));\n    std::fprintf(stderr, "SWAPTRACE_RT DXGI Present1 enter sync=%u flags=%u hwnd=%llu hasParams=%d\\n", unsigned(SyncInterval), unsigned(PresentFlags), (unsigned long long)reinterpret_cast<uint64_t>(m_window), int(pPresentParameters != nullptr));\n    std::fflush(stderr);/s' "${dxgi_file}"
  perl -0777 -i -pe 's/Logger::info\("SWAPTRACE: DXGI Present1 calling m_presenter->Present"\);/Logger::info("SWAPTRACE: DXGI Present1 calling m_presenter->Present");\n      std::fprintf(stderr, "SWAPTRACE_RT DXGI Present1 calling presenter\\n");\n      std::fflush(stderr);/s' "${dxgi_file}"

  # Add wait/notify-side diagnostics for queue wakeups and state-cache worker flow.
  perl -0777 -i -pe 's/void DxvkPipelineWorkers::notifyWorkers\(DxvkPipelinePriority priority\) {\n    uint32_t index = uint32_t\(priority\);\n\n    \/\/ If any workers are idle in a suitable set, notify the corresponding\n    \/\/ condition variable\. If all workers are busy anyway, we know that the\n    \/\/ job is going to be picked up at some point anyway\.\n    for \(uint32_t i = index; i < m_buckets.size\(\); i\+\+\) {\n      if \(m_buckets\[i\]\.idleWorkers\) {\n        m_buckets\[i\]\.cond\.notify_one\(\);\n        break;\n      }\n    }\n  }/void DxvkPipelineWorkers::notifyWorkers(DxvkPipelinePriority priority) {\n    uint32_t index = uint32_t(priority);\n\n    Logger::info(str::format(\"SWAPTRACE_QW: notify enter req=\", index,\n      \", idle0=\", m_buckets[0].idleWorkers, \", idle1=\", m_buckets[1].idleWorkers, \", idle2=\", m_buckets[2].idleWorkers,\n      \", q0=\", m_buckets[0].queue.size(), \", q1=\", m_buckets[1].queue.size(), \", q2=\", m_buckets[2].queue.size()));\n\n    for (uint32_t i = index; i < m_buckets.size(); i++) {\n      if (m_buckets[i].idleWorkers) {\n        Logger::info(str::format(\"SWAPTRACE_QW: notify bucket=\", i, \", req=\", index));\n        m_buckets[i].cond.notify_one();\n        break;\n      }\n    }\n  }/s' "${pipe_file}"

  perl -0777 -i -pe 's/Logger::info\(str::format\(\"SWAPTRACE_Q: worker task done maxPriority=\", maxPriorityIndex,\n        \", tasksCompleted=\", m_tasksCompleted.load\(std::memory_order_relaxed\),\n        \", tasksTotal=\", m_tasksTotal.load\(std::memory_order_relaxed\)\)\);/Logger::info(str::format(\"SWAPTRACE_Q: worker task done maxPriority=\", maxPriorityIndex,\n        \", tasksCompleted=\", m_tasksCompleted.load(std::memory_order_relaxed),\n        \", tasksTotal=\", m_tasksTotal.load(std::memory_order_relaxed)));\n\n      if (m_tasksCompleted.load(std::memory_order_relaxed) == m_tasksTotal.load(std::memory_order_relaxed)) {\n        Logger::info(str::format(\"SWAPTRACE_QW: all tasks reached tasksCompleted=\", m_tasksCompleted.load(std::memory_order_relaxed)));\n      }/s' "${pipe_file}"

  perl -0777 -i -pe 's/if \(unlikely\(shader->needsLibraryCompile\(\)\)\)\n        m_device->requestCompileShader\(shader\);/if (unlikely(shader->needsLibraryCompile())) {\n        Logger::info(str::format(\"SWAPTRACE_QW: BindShader requestCompileShader stage=\", uint32_t(GetShaderStage(ShaderStage))));\n        m_device->requestCompileShader(shader);\n      }/s' "${d3d11_context_file}"

  perl -0777 -i -pe 's/if \(!workerLock\)\n        workerLock = std::unique_lock<dxvk::mutex>\(m_workerLock\);\n      \n      m_workerQueue\.push\(item\);/if (!workerLock)\n        workerLock = std::unique_lock<dxvk::mutex>(m_workerLock);\n\n      Logger::info(str::format(\"SWAPTRACE_SC: registerShader queue push before=\", m_workerQueue.size()));\n      m_workerQueue.push(item);\n      Logger::info(str::format(\"SWAPTRACE_SC: registerShader queue push after=\", m_workerQueue.size()));/s' "${state_cache_file}"

  perl -0777 -i -pe 's/if \(workerLock\) {\n      m_workerCond\.notify_all\(\);\n      createWorker\(\);\n    }/if (workerLock) {\n      Logger::info(str::format(\"SWAPTRACE_SC: registerShader notify workerQueue=\", m_workerQueue.size()));\n      m_workerCond.notify_all();\n      createWorker();\n    }/s' "${state_cache_file}"

  perl -0777 -i -pe 's/void DxvkStateCache::workerFunc\(\) {\n    env::setThreadName\(\"dxvk-worker\"\);\n\n    while \(!m_stopThreads.load\(\)\) {\n      WorkerItem item;\n\n      \{ std::unique_lock<dxvk::mutex> lock\(m_workerLock\);\n\n        if \(m_workerQueue.empty\(\)\) {\n          m_workerCond.wait\(lock, \[this\] \(\) {\n            return m_workerQueue.size\(\)\n                \|\| m_stopThreads.load\(\);\n          }\);\n        }\n\n        if \(m_workerQueue.empty\(\)\)\n          break;\n        \n        item = m_workerQueue.front\(\);\n        m_workerQueue.pop\(\);\n      }\n\n      compilePipelines\(item\);\n    }\n  }/void DxvkStateCache::workerFunc() {\n    env::setThreadName(\"dxvk-worker\");\n\n    while (!m_stopThreads.load()) {\n      WorkerItem item;\n\n      { std::unique_lock<dxvk::mutex> lock(m_workerLock);\n        Logger::info(str::format(\"SWAPTRACE_SC: worker wait enter queue=\", m_workerQueue.size(), \", stop=\", m_stopThreads.load()));\n\n        if (m_workerQueue.empty()) {\n          m_workerCond.wait(lock, [this] () {\n            return m_workerQueue.size()\n                || m_stopThreads.load();\n          });\n        }\n\n        Logger::info(str::format(\"SWAPTRACE_SC: worker wake queue=\", m_workerQueue.size(), \", stop=\", m_stopThreads.load()));\n\n        if (m_workerQueue.empty()) {\n          Logger::info(\"SWAPTRACE_SC: worker exit empty queue\");\n          break;\n        }\n\n        item = m_workerQueue.front();\n        m_workerQueue.pop();\n        Logger::info(str::format(\"SWAPTRACE_SC: worker pop queue_after=\", m_workerQueue.size()));\n      }\n\n      Logger::info(\"SWAPTRACE_SC: worker compilePipelines begin\");\n      compilePipelines(item);\n      Logger::info(\"SWAPTRACE_SC: worker compilePipelines end\");\n    }\n  }/s' "${state_cache_file}"

  # Route DXVK Logger output to realtime stderr regardless of wine dbg channel.
  if ! grep -q "DXVK_RT_STDERR" "${log_file}"; then
    perl -0777 -i -pe 's/outstream << prefix << line << std::endl;/outstream << "[DXVK] " << prefix << line << std::endl;/g' "${log_file}"
    perl -0777 -i -pe 's@if \(!adjusted\.empty\(\)\) \{\s*if \(m_wineLogOutput\)\s*m_wineLogOutput\(adjusted\.c_str\(\)\);\s*else\s*std::cerr << adjusted;\s*\}@if (!adjusted.empty()) {\n          if (m_wineLogOutput)\n            m_wineLogOutput(adjusted.c_str());\n\n          // DXVK_RT_STDERR: always mirror logs to stderr for Android-side realtime capture.\n          std::cerr << adjusted;\n          std::cerr.flush();\n        }@s' "${log_file}"
  fi
}

deps_ready_marker="/var/tmp/winlator_arm_graphics_deps_ready_v1"
if [[ ! -f "${deps_ready_marker}" ]]; then
  if ! apt_install_deps; then
    echo "apt-get failed (possibly due to proxy). Retrying without http(s)_proxy..." >&2
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
    apt_install_deps
  fi
  touch "${deps_ready_marker}"
else
  echo "Using cached container dependencies (${deps_ready_marker})"
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
c = 'aarch64-w64-mingw32-gcc'
cpp = 'aarch64-w64-mingw32-g++'
ar = 'aarch64-w64-mingw32-ar'
strip = 'aarch64-w64-mingw32-strip'
windres = 'aarch64-w64-mingw32-windres'
ld = 'aarch64-w64-mingw32-ld'
widl = 'aarch64-w64-mingw32-widl'

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

if [[ "${SKIP_DXVK}" != "1" ]]; then
  echo "==> Building DXVK ${DXVK_VERSION} (aarch64)"
  run_with_proxy_fallback git clone --depth 1 --branch "${DXVK_VERSION}" "${DXVK_REPO_URL}" "${DXVK_SRC}"

  # Avoid flaky GitLab submodule fetches inside container by preferring a cached
  # libdisplay-info checkout from host-mounted /cache.
  DISPLAY_INFO_CACHE="/cache/libdisplay-info-windows"
  if [[ -f "${DISPLAY_INFO_CACHE}/meson.build" ]]; then
    echo "Using cached libdisplay-info from ${DISPLAY_INFO_CACHE}"
    rm -rf "${DXVK_SRC}/subprojects/libdisplay-info"
    mkdir -p "${DXVK_SRC}/subprojects"
    cp -a "${DISPLAY_INFO_CACHE}" "${DXVK_SRC}/subprojects/libdisplay-info"
  else
    run_with_proxy_fallback git -C "${DXVK_SRC}" submodule update --init --depth 1 --recursive
  fi
  if [[ ! -f "${DXVK_SRC}/subprojects/libdisplay-info/meson.build" ]]; then
    echo "Missing DXVK subproject: subprojects/libdisplay-info" >&2
    exit 1
  fi

  apply_dxvk_swaptrace_patch "${DXVK_SRC}"

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
BUILD_SCRIPT_EOF

chmod +x "${build_script_abs}"

docker exec -t \
  -e "https_proxy=${https_proxy-}" -e "http_proxy=${http_proxy-}" -e "no_proxy=${no_proxy-}" \
  -e "HTTPS_PROXY=${HTTPS_PROXY-}" -e "HTTP_PROXY=${HTTP_PROXY-}" -e "NO_PROXY=${NO_PROXY-}" \
  -e "DXVK_REPO_URL=${DXVK_REPO_URL}" -e "DXVK_VERSION=${DXVK_VERSION}" \
  -e "VKD3D_REPO_URL=${VKD3D_REPO_URL}" -e "VKD3D_VERSION=${VKD3D_VERSION}" \
  -e "TOOLCHAIN_TAR=${TOOLCHAIN_TAR}" -e "TOOLCHAIN_URL=${TOOLCHAIN_URL}" \
  -e "SKIP_DXVK=${SKIP_DXVK}" -e "SKIP_VKD3D=${SKIP_VKD3D}" \
  "${DOCKER_CONTAINER_NAME}" \
  bash "/work/${build_script_rel}"

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
