# Build FEXCore DLLs (Wine-on-ARM)

This project uses FEX in the **Wine-on-ARM** configuration: Wine loads two Windows DLLs built from FEX:

- `libwow64fex.dll` (WOW64 bridge for x86/x64 processes under arm64ec Wine)
- `libarm64ecfex.dll` (arm64ec side)

These are shipped in `app/src/main/assets/fexcore/fexcore-<version>.tzst` and extracted into
`C:\\windows\\system32` in the container prefix.

This is **not** a traditional Linux FEX build (no `FEXInterpreter`/`FEXBash`). We build the Windows DLLs.

## One-Command Build (Docker, linux/arm64)

The FEX tree already includes a reference toolchain + config in:

- `third_party/FEX/Data/nix/WineOnArm/shell.nix`
- `third_party/FEX/Data/CMake/toolchain_mingw.cmake`

We provide a Docker wrapper to do the same thing without Nix:

```bash
scripts/build-fexcore-dlls-docker.sh --fexcore-version 2508 --update-assets
```

Outputs:

- `out/fexcore/libwow64fex.dll`
- `out/fexcore/libarm64ecfex.dll`
- `out/fexcore/fexcore-2508.tzst`
- Updates `app/src/main/assets/fexcore/fexcore-2508.tzst` (when `--update-assets` is used)

Notes:

- Toolchain is downloaded and cached under `out/_cache/`.
- Docker base image defaults to `ubuntu:latest` (override with `--docker-image`).
  This matters because the llvm-mingw toolchain is built on Ubuntu 22.04 and requires a newer glibc than 20.04.

## CMake Targets

In FEX:

- WOW64 DLL target: `wow64fex` (outputs `libwow64fex.dll`)
- ARM64EC DLL target: `arm64ecfex` (outputs `libarm64ecfex.dll`)

Source locations:

- `third_party/FEX/Source/Windows/WOW64/`
- `third_party/FEX/Source/Windows/ARM64EC/`

## Iteration Workflow

1. Patch FEX (typically under `third_party/FEX/Source/Windows/...`).
2. Run the docker build script above.
3. Rebuild and install the APK as usual.
