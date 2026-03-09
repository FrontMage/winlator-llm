#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC="${PROJ_DIR}/src/winhandler-lite.c"
OUT_DIR="${PROJ_DIR}/out"
OUT_EXE="${OUT_DIR}/winhandler-lite.exe"

mkdir -p "${OUT_DIR}"

IMAGE="win-probes-mingw:20.04-v3"
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  cat <<'DOCKERFILE' | docker build -t "${IMAGE}" -
FROM ubuntu:20.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
  && apt-get install -y --no-install-recommends --fix-missing -o Acquire::Retries=5 \
     gcc-mingw-w64-i686 \
     make \
  && rm -rf /var/lib/apt/lists/*
DOCKERFILE
fi

docker run --rm \
  -v "${PROJ_DIR}:/src" \
  "${IMAGE}" \
  bash -lc "set -euo pipefail; \
    i686-w64-mingw32-gcc -O2 -s -o /src/out/winhandler-lite.exe /src/src/winhandler-lite.c -lws2_32"

echo "Built: ${OUT_EXE}"
