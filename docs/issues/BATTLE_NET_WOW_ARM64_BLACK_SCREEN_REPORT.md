# WoW ARM64 on Android: Black Screen After D3D11 Device Creation

## Summary
I can launch WoW ARM64 on Android (Winlator + Wine ARM64), and the game initializes graphics, but it stays black and never reaches a visible rendered frame.

This report is for Blizzard/Battle.net visibility and tracking.

## Environment
- Device: Snapdragon 8 Gen 2 (Adreno 740)
- Platform: Android
- Runtime: Winlator + Wine ARM64
- Game binary: `WowClassic-arm64.exe`
- Graphics path: `WoW ARM64 -> Wine (dxgi/d3d11) -> DXVK -> Vulkan wrapper ICD -> Turnip`
- Forced API: D3D11

## Repro
1. Start WoW ARM64 (`WowClassic-arm64.exe`) from Winlator.
2. Keep default test setup with D3D11 forced.
3. Observe process stays running, but screen remains black / no gameplay frame.

## Observed Behavior
- WoW main window is created.
- D3D11 device creation is successful.
- No visible rendering is presented.

## gx.log (inline excerpt)
```text
2/27 16:29:51.602  [0] Force API D3D11
2/27 16:29:52.149  [0] Adapter 0: "Turnip Adreno (TM) 740" 0GB family:Unknown type:Integrated location:0 driver_date:27-Feb-2026 driver_ver:65535.65535.65535.65535 vendor:0x5143 device:0x0a01 dx11:true dx12:false
2/27 16:29:52.149  [0]     Monitor 0 "Display2" Size(1280x720) Pos(0, 0) Refresh Rate(60Hz)
2/27 16:29:52.149  [0] Unable to load "d3d12.dll"
2/27 16:29:52.159  [0] GpuInfo: sm:dx_5_0, rt:None, vrs:0, bary:0, mesh:0 pull:1
2/27 16:29:54.792  [0] Dx11 Device Create Successful (2633.1 ms)
```

## Additional Notes
- I am intentionally not attaching `wine.log` in this post because it is large and noisy for forum consumption.
- I can provide full logs and exact runtime env on request.

## Expected
After successful D3D11 initialization, WoW should render and show the game frame.

## Actual
Initialization appears to succeed, but no rendered frame is shown (black screen / stalled visual output).

