#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${PROJ_DIR}/out"

mkdir -p "${OUT_DIR}"

IMAGE="win-probes-mingw:20.04"

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  cat <<'DOCKERFILE' | docker build -t "${IMAGE}" -
FROM ubuntu:20.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     gcc-mingw-w64-x86-64 \
     make \
  && rm -rf /var/lib/apt/lists/*
DOCKERFILE
fi

docker run --rm \
  -v "${PROJ_DIR}:/src" \
  "${IMAGE}" \
  bash -lc "set -euo pipefail; \
    x86_64-w64-mingw32-gcc -O2 -s -o /src/out/clock_probe.exe /src/clock_probe.c; \
    x86_64-w64-mingw32-gcc -O2 -s -o /src/out/cpuid_probe.exe /src/cpuid_probe.c; \
    x86_64-w64-mingw32-gcc -O2 -s -maes -msse4.2 -o /src/out/crypto_probe.exe /src/crypto_probe.c"

echo "Built: ${OUT_DIR}/clock_probe.exe"
echo "Built: ${OUT_DIR}/cpuid_probe.exe"
echo "Built: ${OUT_DIR}/crypto_probe.exe"
