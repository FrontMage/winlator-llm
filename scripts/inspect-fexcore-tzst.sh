#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <path/to/fexcore-XXXX.tzst>" >&2
  exit 2
fi

TZST_PATH="$1"
if [[ ! -f "$TZST_PATH" ]]; then
  echo "Error: file not found: $TZST_PATH" >&2
  exit 2
fi

tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

sha256="$(shasum -a 256 "$TZST_PATH" | awk '{print $1}')"
echo "tzst: $TZST_PATH"
echo "sha256: $sha256"
echo

echo "Contents:"
zstd -q -dc "$TZST_PATH" | tar -t -f - | sed 's/^/  /'
echo

zstd -q -dc "$TZST_PATH" | tar -x -f - -C "$tmp_dir"

echo "DLL hashes (if present):"
found=0
while IFS= read -r -d '' f; do
  found=1
  md5sum "$f"
done < <(find "$tmp_dir" -type f \( -name 'libwow64fex.dll' -o -name 'libarm64ecfex.dll' \) -print0 | sort -z)

if [[ "$found" -eq 0 ]]; then
  echo "  (no libwow64fex.dll/libarm64ecfex.dll found in archive)"
fi

