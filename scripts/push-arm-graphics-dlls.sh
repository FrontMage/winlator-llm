#!/usr/bin/env bash
set -euo pipefail

# Push prebuilt aarch64 graphics DLLs into a running Winlator container prefix.
# This script is designed around Winlator on Android and avoids `run-as ... sh -lc`
# because that can resolve paths in a different namespace on some devices.

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ADB_BIN="adb"
ADB_SERIAL=""
PACKAGE_NAME="com.winlator.llm"
SRC_DIR="${ROOT_DIR}/out/arm-graphics/aarch64/system32"
LLVM_MINGW_AARCH64_BIN="${LLVM_MINGW_AARCH64_BIN:-${ROOT_DIR}/out/_cache/llvm-mingw-20250920-ucrt-ubuntu-22.04-aarch64/aarch64-w64-mingw32/bin}"
PREFIX_NAME="auto"
DEVICE_STAGE_DIR="/storage/emulated/0/Download/Winlator/arm-graphics-system32"
DRY_RUN="0"

REQUIRED_DLLS=(
  "d3d9.dll"
  "d3d10core.dll"
  "d3d11.dll"
  "dxgi.dll"
  "d3d12.dll"
  "libc++.dll"
  "libunwind.dll"
)

usage() {
  cat <<'USAGE'
Push aarch64 graphics DLLs into Winlator prefix system32 using adb run-as.

Usage:
  scripts/push-arm-graphics-dlls.sh [options]

Options:
  --serial <id>       adb device serial (adb -s <id>)
  --package <name>    package name (default: com.winlator.llm)
  --src <dir>         source dir containing *.dll (default: out/arm-graphics/aarch64/system32)
  --prefix <name>     prefix dir name under imagefs/home (default: auto)
                      Examples: xuser, xuser-1
  --device-stage <p>  device staging dir for adb push
                      (default: /storage/emulated/0/Download/Winlator/arm-graphics-system32)
  --dry-run           print commands only, do not execute
  -h, --help          show this message
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)
      ADB_SERIAL="${2:?missing value for --serial}"
      shift 2
      ;;
    --package)
      PACKAGE_NAME="${2:?missing value for --package}"
      shift 2
      ;;
    --src)
      SRC_DIR="${2:?missing value for --src}"
      shift 2
      ;;
    --prefix)
      PREFIX_NAME="${2:?missing value for --prefix}"
      shift 2
      ;;
    --device-stage)
      DEVICE_STAGE_DIR="${2:?missing value for --device-stage}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="1"
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

if ! command -v "${ADB_BIN}" >/dev/null 2>&1; then
  echo "adb not found in PATH" >&2
  exit 1
fi

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "Source dir not found: ${SRC_DIR}" >&2
  exit 1
fi

resolve_dll_source() {
  local dll="$1"
  if [[ -f "${SRC_DIR}/${dll}" ]]; then
    echo "${SRC_DIR}/${dll}"
    return 0
  fi
  case "${dll}" in
    "libc++.dll"|"libunwind.dll")
      if [[ -f "${LLVM_MINGW_AARCH64_BIN}/${dll}" ]]; then
        echo "${LLVM_MINGW_AARCH64_BIN}/${dll}"
        return 0
      fi
      ;;
  esac
  return 1
}

SOURCE_DLLS=()
for dll in "${REQUIRED_DLLS[@]}"; do
  src_path="$(resolve_dll_source "${dll}" || true)"
  if [[ -z "${src_path}" ]]; then
    echo "Missing source DLL: ${dll}" >&2
    echo "Checked: ${SRC_DIR}/${dll}" >&2
    if [[ "${dll}" == "libc++.dll" || "${dll}" == "libunwind.dll" ]]; then
      echo "Checked fallback: ${LLVM_MINGW_AARCH64_BIN}/${dll}" >&2
    fi
    exit 1
  fi
  SOURCE_DLLS+=("${src_path}")
done

adb_prefix=("${ADB_BIN}")
if [[ -n "${ADB_SERIAL}" ]]; then
  adb_prefix+=("-s" "${ADB_SERIAL}")
fi

run() {
  echo "+ $*"
  if [[ "${DRY_RUN}" != "1" ]]; then
    "$@"
  fi
}

adb_shell() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ ${adb_prefix[*]} shell $*"
    return 0
  fi
  "${adb_prefix[@]}" shell "$@"
}

adb_run_as() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ ${adb_prefix[*]} shell run-as ${PACKAGE_NAME} $*"
    return 0
  fi
  "${adb_prefix[@]}" shell run-as "${PACKAGE_NAME}" "$@"
}

host_md5() {
  local file="$1"
  if command -v md5 >/dev/null 2>&1; then
    md5 -q "${file}"
  else
    md5sum "${file}" | awk '{print $1}'
  fi
}

resolve_prefix_name() {
  if [[ "${PREFIX_NAME}" != "auto" ]]; then
    echo "${PREFIX_NAME}"
    return 0
  fi

  local home_dir="/data/user/0/${PACKAGE_NAME}/files/imagefs/home"
  local link_target=""
  link_target="$(adb_run_as readlink "${home_dir}/xuser" 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "${link_target}" ]]; then
    link_target="${link_target#./}"
    echo "${link_target##*/}"
    return 0
  fi

  local entries
  entries="$(adb_run_as ls -1 "${home_dir}" 2>/dev/null | tr -d '\r' || true)"
  mapfile -t xuser_dash < <(printf '%s\n' "${entries}" | grep -E '^xuser-[0-9]+$' | sort -V || true)
  if [[ ${#xuser_dash[@]} -gt 0 ]]; then
    echo "${xuser_dash[-1]}"
    return 0
  fi
  if printf '%s\n' "${entries}" | grep -qx 'xuser'; then
    echo "xuser"
    return 0
  fi

  return 1
}

PREFIX_REAL="$(resolve_prefix_name || true)"
if [[ -z "${PREFIX_REAL}" ]]; then
  echo "Failed to resolve prefix under /data/user/0/${PACKAGE_NAME}/files/imagefs/home" >&2
  exit 1
fi

APP_FILES_DIR="/data/user/0/${PACKAGE_NAME}/files"
TARGET_DIR="${APP_FILES_DIR}/imagefs/home/${PREFIX_REAL}/.wine/drive_c/windows/system32"

echo "Package:      ${PACKAGE_NAME}"
echo "Source dir:   ${SRC_DIR}"
echo "Prefix:       ${PREFIX_REAL}"
echo "Target dir:   ${TARGET_DIR}"
echo "Stage dir:    ${DEVICE_STAGE_DIR}"
echo "Dry-run:      ${DRY_RUN}"

adb_run_as ls -ld "${TARGET_DIR}" >/dev/null
run "${adb_prefix[@]}" shell mkdir -p "${DEVICE_STAGE_DIR}"

for i in "${!REQUIRED_DLLS[@]}"; do
  dll="${REQUIRED_DLLS[$i]}"
  src_path="${SOURCE_DLLS[$i]}"
  run "${adb_prefix[@]}" push "${src_path}" "${DEVICE_STAGE_DIR}/${dll}" >/dev/null
done

for dll in "${REQUIRED_DLLS[@]}"; do
  adb_run_as cp -f "${DEVICE_STAGE_DIR}/${dll}" "${TARGET_DIR}/${dll}"
done

echo "Verifying copied files:"
for dll in "${REQUIRED_DLLS[@]}"; do
  adb_run_as ls -l "${TARGET_DIR}/${dll}"
done

if [[ "${DRY_RUN}" != "1" ]]; then
  echo "Verifying md5:"
  for i in "${!REQUIRED_DLLS[@]}"; do
    dll="${REQUIRED_DLLS[$i]}"
    src_path="${SOURCE_DLLS[$i]}"
    local_md5="$(host_md5 "${src_path}")"
    remote_md5="$(adb_run_as md5sum "${TARGET_DIR}/${dll}" | awk '{print $1}' | tr -d '\r')"
    if [[ "${local_md5}" != "${remote_md5}" ]]; then
      echo "[FAIL] ${dll} local=${local_md5} remote=${remote_md5}" >&2
      exit 1
    fi
    echo "[OK] ${dll} ${local_md5}"
  done
fi

echo "Done."
