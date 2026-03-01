# WoW ARM64 on Wine ARM64: DXVK Initializes But No First Visible Frame

## Summary
I am running WoW ARM64 on Android through Wine ARM64 + DXVK + Turnip.  
D3D11 initialization succeeds, but the app does not progress to visible rendering.

## Environment
- Device: Snapdragon 8 Gen 2 (Adreno 740)
- Android + Winlator + Wine ARM64
- Game: `WowClassic-arm64.exe`
- Render chain: `WoW ARM64 -> Wine dxgi/d3d11 -> DXVK -> winevulkan/wrapper ICD -> Turnip`
- D3D11 forced
- Relevant env:
  - `DXVK_CONFIG=dxvk.enableGraphicsPipelineLibrary=False;dxvk.numCompilerThreads=1;dxvk.trackPipelineLifetime=True;dxgi.syncInterval=1;dxgi.tearFree=True`
  - `MESA_VK_WSI_PRESENT_MODE=fifo`
  - `DXVK_LOG_LEVEL=info`

## Repro
1. Launch `WowClassic-arm64.exe` under Wine ARM64.
2. Keep process alive for ~1-2 minutes.
3. Observe black screen / no visible frame.

## Evidence

### 1) WoW window is created in Wine
```text
WIN_CreateWindowEx L"World of Warcraft" L"waApplication Window" ... -324,0 1928x1106
NtUserCreateWindowEx created window 0x20142
NtUserSetWindowPos hwnd 0x20142 ... (1928x1106)
NtUserSetWindowPos hwnd 0x20142 ... (1242x720)
```

### 2) DXVK D3D11 device initialization succeeds
```text
[DXVK] info:  D3D11InternalCreateDevice: Maximum supported feature level: D3D_FEATURE_LEVEL_11_1
[DXVK] info:  D3D11InternalCreateDevice: Using feature level D3D_FEATURE_LEVEL_11_1
```

### 3) Pipeline worker queue drains to completion
```text
[DXVK] info:  SWAPTRACE_Q: compilePipelineLibrary queued priority=1, q_after=1, tasksTotal=19
[DXVK] info:  SWAPTRACE_Q: worker compile library begin maxPriority=1
[DXVK] info:  SWAPTRACE_Q: worker compile library end maxPriority=1
[DXVK] info:  SWAPTRACE_Q: worker task done maxPriority=1, tasksCompleted=19, tasksTotal=19
[DXVK] info:  SWAPTRACE_QW: all tasks reached tasksCompleted=19
[DXVK] info:  SWAPTRACE_Q: worker wait enter maxPriority=1, q0=0, q1=0, q2=0
```

### 4) gx.log confirms D3D11 path and successful device create
```text
2/27 16:29:51.602  [0] Force API D3D11
2/27 16:29:52.149  [0] Adapter 0: "Turnip Adreno (TM) 740" ... dx11:true dx12:false
2/27 16:29:52.149  [0] Unable to load "d3d12.dll"
2/27 16:29:54.792  [0] Dx11 Device Create Successful (2633.1 ms)
```

## Expected
After D3D11 device creation, game should enter render loop and present frames.

## Actual
No visible first frame appears, despite successful initialization.

## Ask
Does this pattern look like a known "init completed but no first present" path in DXVK/Wine interaction (especially ARM64 WoW on Wine ARM64), and what additional instrumentation points would you recommend for proving where present chain stalls?

## Notes
- `wine.log` is intentionally not attached in this issue draft due size/noise.
- I can provide full raw logs privately if needed.

