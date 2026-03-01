#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

REMOTE_HOST="${REMOTE_HOST:-192.168.0.111}"
REMOTE_USER="${REMOTE_USER:-bazzite}"
REMOTE_PASSWORD="${REMOTE_PASSWORD:-9527}"
REMOTE_ROOT="${REMOTE_ROOT:-/var/home/${REMOTE_USER}/Downloads/wine_build}"
REMOTE_SRC_DIR="${REMOTE_SRC_DIR:-${REMOTE_ROOT}/src/winlator-mod}"
CONTAINER_NAME="${CONTAINER_NAME:-winlator-wine-x86-builder}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-ubuntu:24.04}"

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/TGP-17/wine.git}"
UPSTREAM_REF="${UPSTREAM_REF:-proton-9.0-x86_64-ci-test}"
NDK_VER_DIR="${NDK_VER_DIR:-27.2.12479018}"
NDK_ZIP_URL="${NDK_ZIP_URL:-https://dl.google.com/android/repository/android-ndk-r27c-linux.zip}"
LLVM_MINGW_URL="${LLVM_MINGW_URL:-https://github.com/bylaws/llvm-mingw/releases/download/20250305/llvm-mingw-20250305-ucrt-ubuntu-20.04-x86_64.tar.xz}"
TERMUXFS_URL="${TERMUXFS_URL:-https://github.com/TGP-17/termux-on-gha/releases/download/test/termuxfs.tar}"
APT_MIRROR_URL="${APT_MIRROR_URL:-http://mirrors.ustc.edu.cn/ubuntu}"
JOBS="${JOBS:-16}"

VERSION_NAME="${VERSION_NAME:-10.4-2-x86_64}"
VERSION_CODE="${VERSION_CODE:-1}"
DESCRIPTION="${DESCRIPTION:-Proton 10.4-2 x86_64 (remote build) for cmod}"
PREFIXPACK_WCP_XZ="${PREFIXPACK_WCP_XZ:-/private/tmp/proton-10-4-x86_64.wcp.xz}"

ARTIFACT_ROOT="${ARTIFACT_ROOT:-${ROOT_DIR}/out/_cache/wine_remote_builds}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/out/cmod-wine}"
PUSH_TO_DOWNLOAD="${PUSH_TO_DOWNLOAD:-0}"
PREPARE_ONLY="${PREPARE_ONLY:-0}"
SYNC_REPO="${SYNC_REPO:-1}"
REUSE_TREE="${REUSE_TREE:-0}"
# Important for remote runs:
# Don't inherit local proxy env by default (e.g. localhost:8080 on host machine),
# because that value is usually invalid from remote/container network namespace.
HTTPS_PROXY_VAL="${HTTPS_PROXY_VAL:-}"

usage() {
  cat <<'USAGE'
Remote x86 Linux Wine build (persistent Docker builder + cmod .wcp packaging).

Usage:
  scripts/build-wine-x86-cmod-remote.sh [options]

Options:
  --host <host>                Remote SSH host (default: 192.168.0.111)
  --user <user>                Remote SSH user (default: bazzite)
  --password <pass>            Remote SSH password (default: 9527)
  --remote-root <path>         Remote root (default: /var/home/<user>/Downloads/wine_build)
  --container-name <name>      Docker container name (default: winlator-wine-x86-builder)
  --container-image <image>    Docker image (default: ubuntu:24.04)
  --upstream-repo <url>        Wine upstream repo (default: TGP-17/wine)
  --upstream-ref <ref>         Wine branch/ref (default: proton-9.0-x86_64-ci-test)
  --version-name <name>        profile.json versionName (default: 10.4-2-x86_64)
  --version-code <int>         profile.json versionCode (default: 1)
  --description <text>         profile.json description
  --prefixpack-wcp-xz <path>   Existing x86 .wcp.xz used as prefixPack source
  --artifact-root <dir>        Local run artifact root
  --out-dir <dir>              Local packaged wcp output dir
  --push-download              adb push final .wcp to /storage/emulated/0/Download
  --prepare-only               Only prepare remote dirs/container; skip build
  --no-sync                    Skip rsync repo to remote src
  --reuse-tree                 Reuse /work/build/upstream-wine as-is (skip fetch/checkout/reset)
  --https-proxy <url>          Proxy URL used on remote and in builder container
  --apt-mirror <url>           APT mirror base URL (default: http://mirrors.ustc.edu.cn/ubuntu)
  --jobs <n>                   Parallel make jobs (default: 16)
  -h, --help                   Show this help

Remote persistent volumes under <remote-root>:
  src/, ccache/, build/, out/, toolchains/
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) REMOTE_HOST="${2:?missing value}"; shift 2 ;;
    --user) REMOTE_USER="${2:?missing value}"; shift 2 ;;
    --password) REMOTE_PASSWORD="${2:?missing value}"; shift 2 ;;
    --remote-root) REMOTE_ROOT="${2:?missing value}"; shift 2 ;;
    --container-name) CONTAINER_NAME="${2:?missing value}"; shift 2 ;;
    --container-image) CONTAINER_IMAGE="${2:?missing value}"; shift 2 ;;
    --upstream-repo) UPSTREAM_REPO="${2:?missing value}"; shift 2 ;;
    --upstream-ref) UPSTREAM_REF="${2:?missing value}"; shift 2 ;;
    --version-name) VERSION_NAME="${2:?missing value}"; shift 2 ;;
    --version-code) VERSION_CODE="${2:?missing value}"; shift 2 ;;
    --description) DESCRIPTION="${2:?missing value}"; shift 2 ;;
    --prefixpack-wcp-xz) PREFIXPACK_WCP_XZ="${2:?missing value}"; shift 2 ;;
    --artifact-root) ARTIFACT_ROOT="${2:?missing value}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:?missing value}"; shift 2 ;;
    --push-download) PUSH_TO_DOWNLOAD=1; shift ;;
    --prepare-only) PREPARE_ONLY=1; shift ;;
    --no-sync) SYNC_REPO=0; shift ;;
    --reuse-tree) REUSE_TREE=1; shift ;;
    --https-proxy) HTTPS_PROXY_VAL="${2:?missing value}"; shift 2 ;;
    --apt-mirror) APT_MIRROR_URL="${2:?missing value}"; shift 2 ;;
    --jobs) JOBS="${2:?missing value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "${REMOTE_ROOT}" == "~" ]]; then
  REMOTE_ROOT="/var/home/${REMOTE_USER}"
elif [[ "${REMOTE_ROOT}" == "~/"* ]]; then
  REMOTE_ROOT="/var/home/${REMOTE_USER}/${REMOTE_ROOT:2}"
fi

REMOTE_SRC_DIR="${REMOTE_ROOT}/src/winlator-mod"
REMOTE_OUT_DIR="${REMOTE_ROOT}/out"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }
}

need_cmd sshpass
need_cmd ssh
need_cmd scp
need_cmd rsync
need_cmd tar
need_cmd bsdtar
need_cmd xz
need_cmd sha256sum

[[ -f "${PREFIXPACK_WCP_XZ}" ]] || { echo "Missing prefixpack source: ${PREFIXPACK_WCP_XZ}" >&2; exit 1; }

SSH_BASE=(sshpass -p "${REMOTE_PASSWORD}" ssh -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}")
SCP_BASE=(sshpass -p "${REMOTE_PASSWORD}" scp -o StrictHostKeyChecking=no)
RSYNC_SSH="sshpass -p ${REMOTE_PASSWORD} ssh -o StrictHostKeyChecking=no"

q() { printf '%q' "$1"; }

RUN_ID="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${ARTIFACT_ROOT}/${RUN_ID}"
mkdir -p "${RUN_DIR}" "${OUT_DIR}"

echo "[wine-remote] host=${REMOTE_USER}@${REMOTE_HOST}"
echo "[wine-remote] remote_root=${REMOTE_ROOT}"
echo "[wine-remote] container=${CONTAINER_NAME} image=${CONTAINER_IMAGE}"
echo "[wine-remote] upstream=${UPSTREAM_REPO} ref=${UPSTREAM_REF}"
echo "[wine-remote] version_name=${VERSION_NAME}"
echo "[wine-remote] apt_mirror=${APT_MIRROR_URL}"
echo "[wine-remote] jobs=${JOBS}"
if [[ -n "${HTTPS_PROXY_VAL}" ]]; then
  echo "[wine-remote] https_proxy=${HTTPS_PROXY_VAL}"
else
  echo "[wine-remote] https_proxy=<empty>"
fi

if [[ "${SYNC_REPO}" == "1" ]]; then
  echo "[wine-remote] syncing repo -> remote src volume"
  "${SSH_BASE[@]}" "mkdir -p $(q "${REMOTE_SRC_DIR}")"
  rsync -az \
    --exclude '.git/' \
    --exclude '.gradle/' \
    --exclude 'out/' \
    --exclude 'app/build/' \
    --exclude 'third_party/**/build/' \
    -e "${RSYNC_SSH}" \
    "${ROOT_DIR}/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_SRC_DIR}/"
fi

REMOTE_PREP_ENV="REMOTE_ROOT=$(q "${REMOTE_ROOT}") CONTAINER_NAME=$(q "${CONTAINER_NAME}") CONTAINER_IMAGE=$(q "${CONTAINER_IMAGE}") HTTPS_PROXY_VAL=$(q "${HTTPS_PROXY_VAL}") bash -s"
"${SSH_BASE[@]}" "${REMOTE_PREP_ENV}" <<'REMOTE_PREP'
set -euo pipefail

mkdir -p "${REMOTE_ROOT}"/{src,ccache,build,out,toolchains,logs}
chmod 0777 "${REMOTE_ROOT}"/{ccache,build,out,toolchains,logs} || true

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found on remote host" >&2
  exit 1
fi

create_builder_container() {
  docker create -it \
    --name "${CONTAINER_NAME}" \
    -v "${REMOTE_ROOT}/src:/work/src:Z" \
    -v "${REMOTE_ROOT}/ccache:/work/.ccache:Z" \
    -v "${REMOTE_ROOT}/build:/work/build:Z" \
    -v "${REMOTE_ROOT}/out:/work/out:Z" \
    -v "${REMOTE_ROOT}/toolchains:/work/toolchains:Z" \
    "${CONTAINER_IMAGE}" sleep infinity >/dev/null
}

if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  create_builder_container
fi

docker start "${CONTAINER_NAME}" >/dev/null 2>&1 || true

# Validate mounted volume writeability. If this container was created earlier
# without proper SELinux relabeling, recreate once with :Z mounts.
if ! docker exec "${CONTAINER_NAME}" bash -lc 'touch /work/build/.codex_write_test && rm -f /work/build/.codex_write_test' >/dev/null 2>&1; then
  echo "[remote-prep] existing container has non-writable mounts, recreating..."
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  create_builder_container
  docker start "${CONTAINER_NAME}" >/dev/null 2>&1 || true
fi

echo "[remote-prep] container mounts:"
docker inspect "${CONTAINER_NAME}" --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
REMOTE_PREP

if [[ "${PREPARE_ONLY}" == "1" ]]; then
  echo "[wine-remote] prepare-only complete"
  exit 0
fi

REMOTE_BUILD_ENV="CONTAINER_NAME=$(q "${CONTAINER_NAME}") REMOTE_ROOT=$(q "${REMOTE_ROOT}") UPSTREAM_REPO=$(q "${UPSTREAM_REPO}") UPSTREAM_REF=$(q "${UPSTREAM_REF}") NDK_VER_DIR=$(q "${NDK_VER_DIR}") NDK_ZIP_URL=$(q "${NDK_ZIP_URL}") LLVM_MINGW_URL=$(q "${LLVM_MINGW_URL}") TERMUXFS_URL=$(q "${TERMUXFS_URL}") APT_MIRROR_URL=$(q "${APT_MIRROR_URL}") JOBS=$(q "${JOBS}") REUSE_TREE=$(q "${REUSE_TREE}") HTTPS_PROXY_VAL=$(q "${HTTPS_PROXY_VAL}") bash -s"
"${SSH_BASE[@]}" "${REMOTE_BUILD_ENV}" <<'REMOTE_BUILD'
set -euo pipefail

if [[ -n "${HTTPS_PROXY_VAL:-}" ]]; then
  export http_proxy="${HTTPS_PROXY_VAL}" https_proxy="${HTTPS_PROXY_VAL}"
  export HTTP_PROXY="${HTTPS_PROXY_VAL}" HTTPS_PROXY="${HTTPS_PROXY_VAL}"
fi

APT_PACKAGES=(
  build-essential gcc-multilib
  debhelper-compat=13 gcc-mingw-w64 libz-mingw-w64-dev
  lzma flex bison quilt unzip gettext icoutils sharutils pkg-config dctrl-tools
  imagemagick librsvg2-bin fontforge-nox khronos-api unicode-data unicode-idna
  libgl-dev libxi-dev libxt-dev libxmu-dev libx11-dev libxinerama-dev libxcursor-dev
  libxext-dev libxfixes-dev libxrandr-dev libxrender-dev libxkbfile-dev libxxf86vm-dev
  libxxf86dga-dev libglu1-mesa-dev libxcomposite-dev libxkbregistry-dev libxml-libxml-perl
  libssl-dev libv4l-dev libsdl2-dev libkrb5-dev libudev-dev libpulse-dev libldap2-dev
  unixodbc-dev libcups2-dev libcapi20-dev libvulkan-dev libopenal-dev libdbus-1-dev
  freeglut3-dev libunwind-dev libpcap0.8-dev libasound2-dev libgphoto2-dev libosmesa6-dev
  libncurses-dev libwayland-dev libfreetype-dev libgnutls28-dev libpcsclite-dev
  libusb-1.0-0-dev libgettextpo-dev libfontconfig-dev ocl-icd-opencl-dev
  libgstreamer-plugins-base1.0-dev libdrm2 libdrm-dev
  libvulkan-dev:i386 libdrm2:i386 libdrm-dev:i386
  libx11-dev:i386 libfreetype6-dev:i386 libxcursor-dev:i386 libxi-dev:i386
  libxshmfence-dev:i386 libxxf86vm-dev:i386 libxrandr-dev:i386 libxinerama-dev:i386
  libxcomposite-dev:i386 libglu1-mesa-dev:i386 libosmesa6-dev:i386 libdbus-1-dev:i386
  libncurses5-dev:i386 libsane-dev:i386 libv4l-dev:i386 libgphoto2-dev:i386
  liblcms2-dev:i386 libcapi20-dev:i386 libcups2-dev:i386 libfontconfig1-dev:i386
  libgsm1-dev:i386 libtiff5-dev:i386 libmpg123-dev:i386 libopenal-dev:i386
  libldap2-dev:i386 libjpeg-dev:i386 ccache ca-certificates wget curl git xz-utils file
)

docker exec \
  -e http_proxy="${http_proxy:-}" \
  -e https_proxy="${https_proxy:-}" \
  -e HTTP_PROXY="${HTTP_PROXY:-}" \
  -e HTTPS_PROXY="${HTTPS_PROXY:-}" \
  -e DEBIAN_FRONTEND=noninteractive \
  "${CONTAINER_NAME}" bash -lc '
set -euo pipefail

mkdir -p /work/toolchains /work/build /work/out /work/.ccache
chmod -R u+rwX /work/.ccache || true
echo "max_size = 20.0G" > /work/.ccache/ccache.conf || true

if [[ -n "'"${APT_MIRROR_URL}"'" ]]; then
  if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
    sed -i -E "s#https?://(archive|security)\.ubuntu\.com/ubuntu/?#'"${APT_MIRROR_URL}"'/#g" /etc/apt/sources.list.d/ubuntu.sources
    sed -i -E "s#https?://mirrors\.ustc\.edu\.cn/ubuntu/?#'"${APT_MIRROR_URL}"'/#g" /etc/apt/sources.list.d/ubuntu.sources
  fi
  if [[ -f /etc/apt/sources.list ]]; then
    sed -i -E "s#https?://(archive|security)\.ubuntu\.com/ubuntu/?#'"${APT_MIRROR_URL}"'/#g" /etc/apt/sources.list
    sed -i -E "s#https?://mirrors\.ustc\.edu\.cn/ubuntu/?#'"${APT_MIRROR_URL}"'/#g" /etc/apt/sources.list
  fi
fi

if [[ ! -f /work/toolchains/.apt_ready ]]; then
  dpkg --add-architecture i386
  apt_update() {
    apt-get -o Acquire::Retries=6 -o Acquire::http::Timeout=30 update
  }
  apt_install() {
    apt-get -o Acquire::Retries=6 -o Acquire::http::Timeout=30 install -y --fix-missing '"${APT_PACKAGES[*]}"'
  }

  apt_update
  if ! apt_install; then
    echo "[builder] apt install failed once, retrying..." >&2
    apt_update
    apt_install
  fi

  touch /work/toolchains/.apt_ready
fi

if [[ ! -d /data/data/com.termux/files/usr ]]; then
  mkdir -p /tmp/termuxfs && cd /tmp/termuxfs
  wget -O termuxfs.tar "'"${TERMUXFS_URL}"'"
  tar xf termuxfs.tar
  rm -rf /data || true
  mv data /
fi

if [[ ! -d /opt/llvm-mingw/bin ]]; then
  mkdir -p /tmp/llvm-mingw && cd /tmp/llvm-mingw
  wget -O llvm-mingw.tar.xz "'"${LLVM_MINGW_URL}"'"
  tar -xf llvm-mingw.tar.xz
  extracted="$(find . -maxdepth 1 -type d -name "llvm-mingw-*" | head -n1)"
  [[ -n "$extracted" ]] || { echo "llvm-mingw extract failed" >&2; exit 1; }
  rm -rf /opt/llvm-mingw
  mv "$extracted" /opt/llvm-mingw
fi

if [[ ! -d /usr/local/lib/android/sdk/ndk/'"${NDK_VER_DIR}"' ]]; then
  mkdir -p /tmp/ndk /usr/local/lib/android/sdk/ndk && cd /tmp/ndk
  wget -O ndk.zip "'"${NDK_ZIP_URL}"'"
  unzip -q -o ndk.zip
  extracted="$(find . -maxdepth 1 -type d -name "android-ndk-*" | head -n1)"
  [[ -n "$extracted" ]] || { echo "NDK extract failed" >&2; exit 1; }
  rm -rf /usr/local/lib/android/sdk/ndk/'"${NDK_VER_DIR}"'
  mv "$extracted" /usr/local/lib/android/sdk/ndk/'"${NDK_VER_DIR}"'
fi

mkdir -p /work/build
if [[ "'"${REUSE_TREE}"'" == "1" ]]; then
  if [[ ! -d /work/build/upstream-wine/.git ]]; then
    echo "reuse-tree requested but /work/build/upstream-wine is missing" >&2
    exit 1
  fi
  cd /work/build/upstream-wine
  echo "[builder] reusing existing upstream-wine tree at $(pwd)"
else
  if [[ ! -d /work/build/upstream-wine/.git ]]; then
    git clone --branch "'"${UPSTREAM_REF}"'" "'"${UPSTREAM_REPO}"'" /work/build/upstream-wine
  else
    cd /work/build/upstream-wine
    git fetch --all --tags
    git checkout -f "'"${UPSTREAM_REF}"'"
    if git rev-parse --verify --quiet "origin/'"${UPSTREAM_REF}"'" >/dev/null; then
      git reset --hard "origin/'"${UPSTREAM_REF}"'"
    fi
  fi
fi

cd /work/build/upstream-wine
if [[ ! -x ./wine-tools/tools/widl/widl ]]; then
  mkdir -p tmp wine-tools
  cd tmp
  wget -O tools.zip https://github.com/TGP-17/wine/releases/download/wine-tools/tools.zip
  unzip -o tools.zip
  rm -rf ../wine-tools/tools
  mv tools ../wine-tools/tools
  cd ..
fi

# Patch make parallelism in upstream build helper.
if grep -qE "make -j[0-9]+ install" ./build.sh; then
  sed -i -E "s/make -j[0-9]+ install/make -j'"${JOBS}"' install/g" ./build.sh
elif grep -q "make install" ./build.sh; then
  sed -i -E "s/make install/make -j'"${JOBS}"' install/g" ./build.sh
fi
echo "[builder] using make jobs: '"${JOBS}"'"
grep -n "make -j.* install" ./build.sh || true

mkdir -p /home/runner/work/wine
ln -sfn /work/build/upstream-wine /home/runner/work/wine/wine

chmod +x build.sh clang-wrapper.sh clang++-wrapper.sh
mkdir -p build
cp build.sh build/build.sh
cd build
export DEPS=/data/data/com.termux/files/usr
export ARCH=x86_64
export WINARCH=x86_64,i386
export CCACHE_DIR=/work/.ccache
./build.sh --configure
./build.sh --build
./build.sh --compress

cp -f /root/wine-build.tar.xz /work/out/wine-build-'"${UPSTREAM_REF}"'.tar.xz
ccache -s > /work/out/ccache-stats-'"${UPSTREAM_REF}"'.txt || true
'

echo "[remote-build] done: ${REMOTE_ROOT}/out/wine-build-${UPSTREAM_REF}.tar.xz"
REMOTE_BUILD

REMOTE_TAR="${REMOTE_OUT_DIR}/wine-build-${UPSTREAM_REF}.tar.xz"
LOCAL_TAR="${RUN_DIR}/wine-build.tar.xz"
"${SCP_BASE[@]}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_TAR}" "${LOCAL_TAR}"

if [[ "${SYNC_REPO}" == "1" ]]; then
  "${SCP_BASE[@]}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_OUT_DIR}/ccache-stats-${UPSTREAM_REF}.txt" "${RUN_DIR}/" || true
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/stage"
tar -xJf "${LOCAL_TAR}" -C "${WORK}/stage"
xz -dc "${PREFIXPACK_WCP_XZ}" > "${WORK}/prefix_src.wcp"
bsdtar -xOf "${WORK}/prefix_src.wcp" ./prefixPack.txz > "${WORK}/stage/prefixPack.txz"

cat > "${WORK}/stage/profile.json" <<JSON
{
  "type": "Wine",
  "versionName": "${VERSION_NAME}",
  "versionCode": ${VERSION_CODE},
  "description": "${DESCRIPTION}",
  "files": [],
  "wine": {
    "binPath": "bin",
    "libPath": "lib",
    "prefixPack": "prefixPack.txz"
  }
}
JSON

OUT_WCP_BASENAME="proton-${VERSION_NAME}.wcp"
OUT_WCP_RUN="${RUN_DIR}/${OUT_WCP_BASENAME}"
OUT_WCP_FINAL="${OUT_DIR}/${OUT_WCP_BASENAME}"
TMP_TAR="${WORK}/payload.tar"
bsdtar --format gnutar --uid 10314 --gid 1023 -cf "${TMP_TAR}" -C "${WORK}/stage" .
xz --check=crc32 -c "${TMP_TAR}" > "${OUT_WCP_RUN}"
cp -f "${OUT_WCP_RUN}" "${OUT_WCP_FINAL}"

{
  echo "remote_host=${REMOTE_USER}@${REMOTE_HOST}"
  echo "remote_root=${REMOTE_ROOT}"
  echo "container=${CONTAINER_NAME}"
  echo "upstream_repo=${UPSTREAM_REPO}"
  echo "upstream_ref=${UPSTREAM_REF}"
  echo "version_name=${VERSION_NAME}"
  echo "version_code=${VERSION_CODE}"
  echo "prefixpack_source=${PREFIXPACK_WCP_XZ}"
} > "${RUN_DIR}/build-meta.txt"

sha256sum "${LOCAL_TAR}" "${OUT_WCP_RUN}" > "${RUN_DIR}/SHA256SUMS"
bsdtar -xOf "${OUT_WCP_RUN}" ./profile.json > "${RUN_DIR}/profile.json"

if [[ "${PUSH_TO_DOWNLOAD}" == "1" ]]; then
  need_cmd adb
  adb push "${OUT_WCP_RUN}" "/storage/emulated/0/Download/${OUT_WCP_BASENAME}"
fi

echo "[wine-remote] done"
echo "[wine-remote] run_dir=${RUN_DIR}"
echo "[wine-remote] wcp=${OUT_WCP_FINAL}"
echo "[wine-remote] sha256:"
sha256sum "${OUT_WCP_FINAL}"
