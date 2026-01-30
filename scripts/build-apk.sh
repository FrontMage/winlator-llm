#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_JAVA17="/Library/Java/JavaVirtualMachines/openjdk-17.jdk/Contents/Home"
GRADLE_RESET=0

usage() {
  cat <<'USAGE'
Build the debug APK with a known-good JDK (17).

Usage:
  scripts/build-apk.sh [--reset-gradle]

Options:
  --reset-gradle   Clear Gradle native and wrapper caches (~/.gradle) before build.
                   Use this if you see "libnative-platform.dylib" errors.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --reset-gradle)
      GRADLE_RESET=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$GRADLE_RESET" -eq 1 ]]; then
  echo "[build-apk] Resetting Gradle caches in ~/.gradle ..."
  rm -rf "$HOME/.gradle/wrapper/dists/gradle-7.4-bin"* "$HOME/.gradle/native"
fi

if [[ -z "${JAVA_HOME:-}" ]]; then
  if [[ -d "$DEFAULT_JAVA17" ]]; then
    export JAVA_HOME="$DEFAULT_JAVA17"
  elif command -v /usr/libexec/java_home >/dev/null 2>&1; then
    export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
  else
    echo "[build-apk] Could not find JDK 17. Set JAVA_HOME to a JDK 17 install." >&2
    exit 1
  fi
fi

if [[ ! -x "$JAVA_HOME/bin/java" ]]; then
  echo "[build-apk] JAVA_HOME does not contain a usable java binary: $JAVA_HOME" >&2
  exit 1
fi

echo "[build-apk] Using JAVA_HOME=$JAVA_HOME"
"$JAVA_HOME/bin/java" -version

cd "$ROOT_DIR"

echo "[build-apk] Ensuring large assets are available..."
"$ROOT_DIR/scripts/fetch-large-assets.sh"

echo "[build-apk] Running Gradle assembleDebug ..."
./gradlew :app:assembleDebug

APK_PATH="app/build/outputs/apk/debug/app-debug.apk"
if [[ -f "$APK_PATH" ]]; then
  echo "[build-apk] Build succeeded: $APK_PATH"
else
  echo "[build-apk] Build completed but APK not found at $APK_PATH" >&2
  exit 1
fi
