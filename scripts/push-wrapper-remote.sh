#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

ADB_BIN="${ADB_BIN:-adb}"
ADB_SERIAL="${ADB_SERIAL:-}"
PACKAGE_NAME="${PACKAGE_NAME:-com.winlator.llm}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT_DIR}/out/_cache/wrapper_remote_builds/latest}"
DEVICE_STAGE_DIR="${DEVICE_STAGE_DIR:-/storage/emulated/0/Download/Winlator/wrapper_push}"

usage() {
  cat <<'USAGE'
Push wrapper artifacts (libvulkan_wrapper.so, libadrenotools.so, ICD JSON) into
current Winlator imagefs and verify remote hashes.

Usage:
  scripts/push-wrapper-remote.sh [options]

Options:
  --serial <id>          adb serial
  --package <name>       package name (default: com.winlator.llm)
  --artifact-dir <dir>   artifact dir (default: out/_cache/wrapper_remote_builds/latest)
  --device-stage <path>  device staging dir (default: /storage/emulated/0/Download/Winlator/wrapper_push)
  -h, --help             show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) ADB_SERIAL="${2:?missing value}"; shift 2 ;;
    --package) PACKAGE_NAME="${2:?missing value}"; shift 2 ;;
    --artifact-dir) ARTIFACT_DIR="${2:?missing value}"; shift 2 ;;
    --device-stage) DEVICE_STAGE_DIR="${2:?missing value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }
}

need_cmd "${ADB_BIN}"
need_cmd python3
need_cmd sha256sum

if [[ ! -d "${ARTIFACT_DIR}" ]]; then
  echo "Artifact dir not found: ${ARTIFACT_DIR}" >&2
  exit 1
fi

SRC_SO="${ARTIFACT_DIR}/libvulkan_wrapper.so"
SRC_ADT="${ARTIFACT_DIR}/libadrenotools.so"
SRC_JSON="${ARTIFACT_DIR}/wrapper_icd.${PACKAGE_NAME}.aarch64.json"
if [[ ! -f "${SRC_JSON}" ]]; then
  SRC_JSON="${ARTIFACT_DIR}/wrapper_icd.aarch64.json"
fi

[[ -f "${SRC_SO}" ]] || { echo "Missing ${SRC_SO}" >&2; exit 1; }
[[ -f "${SRC_ADT}" ]] || { echo "Missing ${SRC_ADT}" >&2; exit 1; }
[[ -f "${SRC_JSON}" ]] || { echo "Missing wrapper ICD json in ${ARTIFACT_DIR}" >&2; exit 1; }

ADB=("${ADB_BIN}")
if [[ -n "${ADB_SERIAL}" ]]; then
  ADB+=("-s" "${ADB_SERIAL}")
fi

TMP_DIR="$(mktemp -d)"
TMP_JSON="${TMP_DIR}/wrapper_icd.aarch64.json"

python3 - "${SRC_JSON}" "${TMP_JSON}" "${PACKAGE_NAME}" <<'PY'
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

echo "[push-wrapper-remote] package=${PACKAGE_NAME}"
echo "[push-wrapper-remote] artifact_dir=${ARTIFACT_DIR}"
echo "[push-wrapper-remote] device_stage=${DEVICE_STAGE_DIR}"

"${ADB[@]}" shell run-as "${PACKAGE_NAME}" sh -c 'id' >/dev/null

"${ADB[@]}" shell "mkdir -p '${DEVICE_STAGE_DIR}'"
"${ADB[@]}" push "${SRC_SO}" "${DEVICE_STAGE_DIR}/libvulkan_wrapper.so" >/dev/null
"${ADB[@]}" push "${SRC_ADT}" "${DEVICE_STAGE_DIR}/libadrenotools.so" >/dev/null
"${ADB[@]}" push "${TMP_JSON}" "${DEVICE_STAGE_DIR}/wrapper_icd.aarch64.json" >/dev/null

"${ADB[@]}" shell run-as "${PACKAGE_NAME}" sh <<EOS
set -e
BASE="/data/user/0/${PACKAGE_NAME}/files/imagefs/usr"
LIB="\$BASE/lib"
ICD="\$BASE/share/vulkan/icd.d"
BK="/data/user/0/${PACKAGE_NAME}/files/wrapper_backup_\$(date +%Y%m%d_%H%M%S)"
mkdir -p "\$BK"
[ -f "\$LIB/libvulkan_wrapper.so" ] && cp "\$LIB/libvulkan_wrapper.so" "\$BK/libvulkan_wrapper.so.bak" || true
[ -f "\$LIB/libadrenotools.so" ] && cp "\$LIB/libadrenotools.so" "\$BK/libadrenotools.so.bak" || true
[ -f "\$ICD/wrapper_icd.aarch64.json" ] && cp "\$ICD/wrapper_icd.aarch64.json" "\$BK/wrapper_icd.aarch64.json.bak" || true
cp "${DEVICE_STAGE_DIR}/libvulkan_wrapper.so" "\$LIB/libvulkan_wrapper.so"
cp "${DEVICE_STAGE_DIR}/libadrenotools.so" "\$LIB/libadrenotools.so"
cp "${DEVICE_STAGE_DIR}/wrapper_icd.aarch64.json" "\$ICD/wrapper_icd.aarch64.json"
chmod 0755 "\$LIB/libvulkan_wrapper.so" "\$LIB/libadrenotools.so"
chmod 0644 "\$ICD/wrapper_icd.aarch64.json"
echo "backup_dir=\$BK"
sha256sum "\$LIB/libvulkan_wrapper.so" "\$LIB/libadrenotools.so" "\$ICD/wrapper_icd.aarch64.json"
EOS

LOCAL_SO_SHA="$(sha256sum "${SRC_SO}" | awk '{print $1}')"
LOCAL_ADT_SHA="$(sha256sum "${SRC_ADT}" | awk '{print $1}')"
LOCAL_JSON_SHA="$(sha256sum "${TMP_JSON}" | awk '{print $1}')"

REMOTE_SHA_OUT="$("${ADB[@]}" shell run-as "${PACKAGE_NAME}" sh <<EOS
sha256sum /data/user/0/${PACKAGE_NAME}/files/imagefs/usr/lib/libvulkan_wrapper.so /data/user/0/${PACKAGE_NAME}/files/imagefs/usr/lib/libadrenotools.so /data/user/0/${PACKAGE_NAME}/files/imagefs/usr/share/vulkan/icd.d/wrapper_icd.aarch64.json
EOS
)"
REMOTE_SHA_OUT="$(printf '%s' "${REMOTE_SHA_OUT}" | tr -d '\r')"

REMOTE_SO_SHA="$(printf '%s\n' "${REMOTE_SHA_OUT}" | sed -n '1p' | awk '{print $1}')"
REMOTE_ADT_SHA="$(printf '%s\n' "${REMOTE_SHA_OUT}" | sed -n '2p' | awk '{print $1}')"
REMOTE_JSON_SHA="$(printf '%s\n' "${REMOTE_SHA_OUT}" | sed -n '3p' | awk '{print $1}')"

[[ "${LOCAL_SO_SHA}" == "${REMOTE_SO_SHA}" ]] || { echo "hash mismatch libvulkan_wrapper.so" >&2; exit 1; }
[[ "${LOCAL_ADT_SHA}" == "${REMOTE_ADT_SHA}" ]] || { echo "hash mismatch libadrenotools.so" >&2; exit 1; }
[[ "${LOCAL_JSON_SHA}" == "${REMOTE_JSON_SHA}" ]] || { echo "hash mismatch wrapper_icd.aarch64.json" >&2; exit 1; }

rm -rf "${TMP_DIR}"

echo "[push-wrapper-remote] done"
echo "  libvulkan_wrapper.so: ${LOCAL_SO_SHA}"
echo "  libadrenotools.so:    ${LOCAL_ADT_SHA}"
echo "  wrapper_icd.aarch64.json: ${LOCAL_JSON_SHA}"
