# Build ARM (aarch64) Graphics DLLs

This workflow builds and injects **aarch64-windows** graphics DLLs for ARM64 game processes (e.g. `WowClassic-arm64.exe`):

- DXVK: `dxgi.dll`, `d3d11.dll`, `d3d10core.dll`, `d3d9.dll`
- VKD3D-Proton: `d3d12.dll` (and `d3d12core.dll` if available in selected version)

It does **not** modify `arm64ec` assets.

## 1) Build in Docker

```bash
scripts/build-arm-graphics-dlls-docker.sh
```

Default versions:

- DXVK: `v2.3.1`
- VKD3D-Proton: `v2.8`

Output:

- `out/arm-graphics/aarch64/system32/*.dll`
- `out/arm-graphics/aarch64/system32/manifest.txt`

If your network is unstable, set proxy first:

```bash
export https_proxy="http://<host-lan-ip>:8080"
export http_proxy="http://<host-lan-ip>:8080"
scripts/build-arm-graphics-dlls-docker.sh
```

Do not use `localhost` here for Docker builds unless proxy runs inside the container.

## 2) Inject into current container

Start the target Winlator container first, then run:

```bash
scripts/push-arm-graphics-dlls.sh --package com.winlator.llm
```

With explicit device:

```bash
scripts/push-arm-graphics-dlls.sh --serial <adb-serial> --package com.winlator.llm
```

Default target path inside app sandbox:

- `files/imagefs/home/xuser/.wine/drive_c/windows/system32`

## 3) Quick verification

Check logs for DLL load path and D3D init:

```bash
adb logcat | grep -Ei "winlator|wine|dxgi|d3d11|d3d12|vulkan"
```

If needed, enable Wine debug temporarily:

```bash
WINEDEBUG=+loaddll,+dxgi,+d3d11,+d3d12,+vulkan
```

## Notes

- Container restart may overwrite injected files from packaged assets. Re-run the push script after restart.
- This is a focused ARM64-game path workflow; x86/x64/FEX paths are intentionally unchanged.
