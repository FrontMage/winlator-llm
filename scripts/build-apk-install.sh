#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADB_BIN="adb"
ADB_SERIAL=""
FORCE_INSTALL=0
RESET_GRADLE=0

usage() {
  cat <<'USAGE'
Build the debug APK (JDK 17) and install via adb.

Usage:
  scripts/build-apk-install.sh [-f|--force] [--reset-gradle] [--serial <id>]

Options:
  -f, --force     Uninstall existing app(s) before installing.
  --reset-gradle   Clear Gradle native and wrapper caches (~/.gradle) before build.
  --serial <id>    adb device serial to target (adb -s <id>).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--force)
      FORCE_INSTALL=1
      shift
      ;;
    --reset-gradle)
      RESET_GRADLE=1
      shift
      ;;
    --serial)
      ADB_SERIAL="${2:-}"
      if [[ -z "$ADB_SERIAL" ]]; then
        echo "[build-apk-install] --serial requires a value" >&2
        exit 2
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v "$ADB_BIN" >/dev/null 2>&1; then
  echo "[build-apk-install] adb not found in PATH" >&2
  exit 1
fi

BUILD_ARGS=()
if [[ "$RESET_GRADLE" -eq 1 ]]; then
  BUILD_ARGS+=("--reset-gradle")
fi

if [[ ${#BUILD_ARGS[@]} -gt 0 ]]; then
  "$ROOT_DIR/scripts/build-apk.sh" "${BUILD_ARGS[@]}"
else
  "$ROOT_DIR/scripts/build-apk.sh"
fi

APK_PATH="$ROOT_DIR/app/build/outputs/apk/debug/app-debug.apk"
if [[ ! -f "$APK_PATH" ]]; then
  echo "[build-apk-install] APK not found at $APK_PATH" >&2
  exit 1
fi

uninstall_packages() {
  local adb_prefix=("$ADB_BIN")
  if [[ -n "$ADB_SERIAL" ]]; then
    adb_prefix+=("-s" "$ADB_SERIAL")
  fi

  for pkg in com.winlator com.winlator.cmod; do
    "${adb_prefix[@]}" uninstall "$pkg" || true
  done
}

if [[ "$FORCE_INSTALL" -eq 1 ]]; then
  uninstall_packages
fi

if [[ -n "$ADB_SERIAL" ]]; then
  "$ADB_BIN" -s "$ADB_SERIAL" install -r "$APK_PATH"
else
  "$ADB_BIN" install -r "$APK_PATH"
fi

echo "[build-apk-install] Installed: $APK_PATH"
