# FEX-Only (arm64ec) Status / Debug Notes

Date: 2026-02-06

This document is a running snapshot of the current **FEX-only** direction (Winlator as UI/container shell, using an **arm64ec Wine build + FEX WOW64 bridge**), what was changed, what is currently broken, and how we are debugging it.

Scope:
- Only FEX / arm64ec Wine startup path and related packaging/logging.
- This doc intentionally does **not** cover Box64/Battle.net/NTLM workstreams unless they intersect this startup path.

## Goal

Make containers run using:
- `wine-10.0-arm64ec` (aarch64 PE DLLs + arm64ec loader behavior)
- FEX wow64 bridge DLLs (from `assets/fexcore/*.tzst`), so that running x86_64 Windows binaries is possible via Wine’s WOW64 layer.

Avoid:
- PRoot-based guest launcher for the arm64ec path (align with the bionic-derived implementation that launches Wine directly).

## Current Symptom

Container startup flashes and then exits (UI returns to launcher). The guest process terminates quickly with status `53`.

From `/storage/emulated/0/Download/Winlator/wine.log`:
- Wine starts (esync banner appears).
- Some modules are loaded (kernelbase/kernel32/etc).
- Then it fails again with:
  `wine: could not load kernel32.dll, status c0000135`

This is confusing because the log also contains successful `loaddll` lines for `kernel32.dll` earlier in the same run.

## New Finding (Most Likely Root Cause)

Filesystem checks on device showed the prefix did **not** contain core built-in DLLs/exes under:
- `C:\\windows\\system32\\kernel32.dll`
- `C:\\windows\\syswow64\\kernel32.dll`
- `C:\\windows\\system32\\winemenubuilder.exe`

Even though the Wine installation directory does contain them under:
- `<wine>/lib/wine/aarch64-windows/`
- `<wine>/lib/wine/i386-windows/`

This points to the prefix being created before the selected Wine package was fully installed/extracted into `imagefs/opt/`,
so the “copy builtins into prefix” step was skipped (because the source dir didn’t exist yet).

## Repro Steps (Current)

1. Install APK (force uninstall first):
   - `./scripts/build-apk-install.sh -f`
2. Launch Winlator.
3. Start any container (default arm64ec Wine is selected by current defaults).
4. After it exits, pull logs:
   - `adb shell cat /storage/emulated/0/Download/Winlator/wine.log`
   - Optional: `adb logcat -d | rg "GuestLauncher|GuestDebug|wine:"`

## What We Changed So Far

### 1) Package / install targeting

We updated the install script to avoid installing over the wrong package name.

- `scripts/build-apk-install.sh`
  - `-f/--force` now uninstalls **both** `com.winlator` and `com.winlator.cmod` before install.

We also verified via adb that only `com.winlator.cmod` is present after force-install:
- `adb shell pm list packages | rg winlator`

### 1.5) Container prefix extraction (align with bionic/Ludashi)

We aligned non-main Wine container creation with the bionic/Ludashi approach:
- Prefer extracting a per-wine container pattern asset (`<wineVersion>_container_pattern.tzst`) when present.
- Fallback to extracting `prefixPack.txz` shipped inside the installed Wine directory (e.g. `<rootfs>/opt/wine-10.0-arm64ec/prefixPack.txz`).
- After extraction, populate `C:\\windows\\system32` and `C:\\windows\\syswow64` by copying built-in Wine PE DLL sets from:
  - arm64ec: `<wine>/lib/wine/aarch64-windows` -> `system32`
  - all: `<wine>/lib/wine/i386-windows` -> `syswow64`

This matches how bionic/Ludashi avoids “thin prefix” failures (missing `kernel32.dll`/core DLLs in prefix).

We also added a matching per-wine pattern asset for the current default arm64ec build:
- `app/src/main/assets/wine-10.0-arm64ec_container_pattern.tzst` (generated from `prefixPack.txz` inside the preinstalled Wine package)

### 2) arm64ec launch path: direct Wine execution

The arm64ec path was moved to “direct exec” (no proot command wrapper), and the environment was aligned to the bionic-derived implementation:

- `app/src/main/java/com/winlator/xenvironment/components/GuestProgramLauncherComponent.java`
  - arm64ec uses **absolute** rootfs paths:
    - `HOME=/data/user/0/<pkg>/files/imagefs/home/xuser`
    - `WINEPREFIX=/data/user/0/<pkg>/files/imagefs/home/xuser/.wine`
    - `TMPDIR=/data/user/0/<pkg>/files/imagefs/usr/tmp`
  - arm64ec sets “bionic style” runtime env:
    - `PATH=<rootfs>/opt/wine-10.0-arm64ec/bin:<rootfs>/usr/bin`
    - `LD_LIBRARY_PATH=<rootfs>/usr/lib:/system/lib64`
    - `LD_PRELOAD=<rootfs>/usr/lib/libandroid-sysvshm.so` (if present)
    - `ANDROID_SYSVSHM_SERVER` and `ANDROID_ALSA_SERVER` as absolute rootfs paths
  - FEX bridge:
    - `HODLL=libwow64fex.dll`
  - `WINEDEBUG` defaulting for arm64ec (always-on unless user overrides):
    - if `WINEDEBUG` is missing or `-all`, we set `WINEDEBUG=+loaddll,+err,+warn,+process`
  - Note: we currently do **not** rely on `WINEDLLPATH` being correct; we instead ensure the prefix contains the
    required PE builtins in `system32` and `syswow64` (see “Fix In Progress” below).

### 3) Wine stdout/stderr capture to disk

Because `logcat` alone didn’t contain enough context, we added a “write Wine output to a file” mechanism for the arm64ec path:

- `app/src/main/java/com/winlator/xenvironment/components/GuestProgramLauncherComponent.java`
  - When launching arm64ec guest, a debug callback is attached to `ProcessHelper` and writes lines to:
    - `/storage/emulated/0/Download/Winlator/wine.log`

Note:
- This uses `ProcessHelper.addDebugCallback(...)`, which reads stdout+stderr only when callbacks exist.
- This is intended for debugging and may need to be gated behind a setting later.

### 4) Container pattern fix: add winhandler.exe and wfm.exe

The default start command in `XServerDisplayActivity` is:
- `winhandler.exe "wfm.exe"`

We discovered our `container_pattern.tzst` did **not** include those files, leading to “Starting up...” spinner hangs and/or immediate failure.

We imported them from the bionic-derived third_party container pattern:
- Source:
  - `third_party/Winlator-Ludashi/app/src/main/assets/container_pattern_common.tzst`
  - Paths inside that archive:
    - `home/xuser/.wine/drive_c/windows/wfm.exe`
    - `home/xuser/.wine/drive_c/windows/winhandler.exe`
- Applied into:
  - `app/src/main/assets/container_pattern.tzst`

Verification on device:
- `.../home/xuser/.wine/drive_c/windows/winhandler.exe` exists and is `PE32+ x86-64`
- `.../home/xuser/.wine/drive_c/windows/wfm.exe` exists and is `PE32+ x86-64`

Note:
- bionic/Ludashi applies these via a “common pattern” patch extracted into rootfs (affecting the active container through the `/home/xuser` symlink).
- We aligned `app/src/main/assets/container_pattern_common.tzst` with bionic/Ludashi so common prefix files (including `winhandler.exe`/`wfm.exe`) are applied the same way.

### 5) ImageFS/Wine path layout adjustments (relative vs absolute)

We touched ImageFS logic while aligning to the bionic layout:
- `app/src/main/java/com/winlator/xenvironment/ImageFs.java`
- `app/src/main/java/com/winlator/xenvironment/ImageFsInstaller.java`

Key goal:
- Ensure Wine path resolves to `<rootfs>/opt/wine-10.0-arm64ec` and doesn’t accidentally double-prefix or produce a relative path.

## What We Observed (Ground Truth Logs)

From `adb logcat` (trimmed):
- Guest is launched as:
  - `<rootfs>/opt/wine-10.0-arm64ec/bin/wine explorer /desktop=shell,1280x720 winhandler.exe "wfm.exe"`
- Environment contains:
  - `HODLL=libwow64fex.dll`
  - `WINEDLLPATH=<rootfs>/opt/wine-10.0-arm64ec/lib/wine/aarch64-windows:...`

From `wine.log`:
- There are successful module loads early:
  - `Loaded ... kernelbase.dll ... builtin`
  - `Loaded ... kernel32.dll ... builtin`
  - `Loaded ... ws2_32.dll ... builtin`
- Then later in the same run:
  - `wine: could not load kernel32.dll, status c0000135`

From filesystem checks:
- `<wine>/lib/wine/aarch64-windows/kernel32.dll` exists and is `PE32+ Aarch64`.

## Working Hypotheses (Prioritized)

1. **Second-stage Wine process is 32-bit / mismatched architecture**:
   - The log shows `start.exe` is loaded shortly before the final kernel32 failure.
   - If the second-stage process is 32-bit (i386) but the required i386 `kernel32.dll` (or loader path) is missing/mismatched, it would produce exactly this “kernel32 not loadable” error even if the aarch64 version exists.
   - Action: verify i386 wine dll set and how the arm64ec build expects to locate it.

2. **WinHandler handshake failure triggers a fallback codepath**:
   - `winhandler.exe` is x86_64 and requires WOW64 translation.
   - If WinHandler cannot start or cannot communicate (UDP ports 7946/7947), the session may restart/exit.
   - However, the terminal error reported is kernel32 load failure, which looks lower-level than an app-level handshake issue.

3. **WINEPREFIX mismatch / wrong prefix content**:
   - There is evidence of `home/xuser-1/.wine` on disk, while env points to `/home/xuser/.wine`.
   - `home/xuser` is a symlink to `home/xuser-1`, so this should be fine, but prefix initialization might still be inconsistent.

## Next Debug Actions (Concrete)

1. Confirm whether the failing stage is attempting to execute i386 binaries:
   - Add `+process` and inspect whether a child process is spawned that is i386/WoW64.
2. Dump `file` type of key executables and confirm expected architecture:
   - `wineboot.exe`, `services.exe`, `start.exe`, `winhandler.exe`, `wfm.exe`
3. Validate presence and layout of i386 wine DLL directory:
   - `<wine>/lib/wine/i386-windows/`
   - Ensure it contains core DLLs needed for the stage that fails.

## Fix In Progress

We added a startup-time prefix repair step:
- On every container launch, if `system32/kernel32.dll` or `syswow64/kernel32.dll` is missing in the active container,
  we copy built-in PE DLLs/exes from the selected Wine installation into the prefix:
  - arm64ec: `<wine>/lib/wine/aarch64-windows/*` -> `C:\\windows\\system32\\`
  - all: `<wine>/lib/wine/i386-windows/*` -> `C:\\windows\\syswow64\\`
- The copy logic matches Ludashi/bionic behavior (including `iexplore.exe` fallback + skipping `tabtip.exe`/`icu.dll`).

Expected impact:
- `winemenubuilder.exe` should no longer fail with “file not found”.
- The final `kernel32.dll c0000135` failure should go away if it was due to missing prefix builtins.

## Notes / Constraints

- We can’t rely on ptrace/winedbg on Android (permissions).
- `logcat` is insufficient; `wine.log` is now the primary signal.
- `DELETE_FAILED_INTERNAL_ERROR` during install appears sporadic, but install succeeds afterward. Treat as noise unless it correlates with missing files.
