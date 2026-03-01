# Winlator LLM Known Issues & Debug Summary

Last Updated: 2026-02-24

## Scope

This document is a single checkpoint for:
- confirmed fixes already landed and verified,
- known unresolved issues,
- what has been tested and what should be tested next.

It is intentionally concise and execution-oriented.

## Confirmed Working Items

### 1) Baseline app/container path is stable
- Package rename to `com.winlator.llm` is in place.
- Fresh install + fresh container flow is reproducible.
- Main app and container startup path can reach desktop reliably.

### 2) X11 chain alignment to Ludashi/vanilla is effective
- X11-related Java/native path was aligned.
- `renderer` and `libwinlator.so` were aligned with the reference implementation.
- A previous container-start flash-crash on launch was resolved after this alignment.

### 3) ALSA service-level compatibility fix landed
- ALSA no-audio issue was reproduced and fixed by alignment work.
- Audio regression was closed in the validated build.

### 4) Service policy adjustment for Battle.net install path
- `seclogon` was added in NORMAL tier handling.
- Battle.net installer path requiring Secondary Logon behavior became testable and passed targeted validation.

### 5) APK slimming and asset cleanup completed
- Unused large assets were removed from APK packaging path.
- Build/install flow stayed functional after cleanup.

## Current Main Unresolved Problem

### WoW black-screen / no-forward-progress under Wine arm64ec + FEX

Current observed behavior (latest reproductions):
- `WowClassic.exe` process stays alive (not immediate process death).
- UI remains black / stuck.
- No transition to DXGI/D3D module initialization in this run.

### Important confirmed signal
- Repeated `Exception: Code: 80000002` appears in `wine.log` / `GuestDebug`.
- `0x80000002` = `EXCEPTION_DATATYPE_MISALIGNMENT` (misaligned data access / unaligned atomic handling path).
- We also see repeated `Handled unaligned atomic` messages.

Interpretation:
- This is not the old immediate `0xC0000005` loop failure mode.
- Execution now progresses farther, then gets trapped in heavy misalignment exception handling, which likely stalls forward progress.

## NX Fallback Experiment Result (Important)

Applied:
- `FEX_WIN_EXEC_QUERY_FALLBACK_MODE=2` (ignore NX executable query result).

Outcome:
- It bypasses the earlier "NoExec gating" class of failure.
- But it exposes a deeper blocker: heavy `0x80000002` exception storm and black-screen stall before render stack init.

Conclusion:
- NX handling was one blocker, not the final blocker.
- Current bottleneck is likely in deeper execution semantics under this WoW path (alignment/atomic-sensitive control flow).

## Rendering-Stack Status (What We Know)

- Environment alignment work against vanilla/ludashi was completed for major render-related vars.
- Multiple ARM graphics asset push experiments were executed.
- In the latest stuck state, logs do not show transition into `dxgi/d3d11/d3d12/vkd3d` loading for WoW.

Practical takeaway:
- Latest black-screen case is currently diagnosed as pre-render-init stall, not a pure swapchain-only regression in that run.

## FEX Tracking / Memory-Path Investigation Status

Work already done:
- Added targeted debug instrumentation and env toggles for FEX memory/exec tracking investigation.
- Traced map/unmap and execution-query related paths during WoW startup.
- Filed upstream issue with logs and full env context.

Upstream maintainer feedback indicated:
- There may be Wine arm64ec limitations around NX expectations for old applications.

Local result after applying NX fallback:
- Confirms problem shifts, but not resolved.

## Known Good / Known Bad Regression Anchors (Summary)

From prior bisect/rebuild rounds:
- There are historical commits/build windows that are known-good for specific startup/install behaviors.
- Mid/late windows introduced regressions in some scenarios.
- Current branch contains additional fixes beyond those checkpoints; issue behavior has evolved from hard-crash patterns to stall patterns in latest tests.

For exact commit-by-commit notes, keep using git history and test logs as source of truth.

## Logs and Evidence Sources

Primary:
- `/storage/emulated/0/Download/Winlator/wine.log`
- `/storage/emulated/0/Download/Winlator/guest.log`
- `adb logcat` filtered by `GuestLauncher|GuestDebug|winlator|wow|fex|dxvk|vkd3d`

Secondary:
- `/storage/emulated/0/Download/wow/...` (WoW-side logs when generated)
- Wrapper log path when enabled: `/storage/emulated/0/Download/Winlator/wrapper.log`

## Recommended Next-Step Matrix (Minimal Variable Strategy)

1. Keep binary set fixed, vary only FEX alignment-sensitive knobs (one at a time), record `0x80000002` rate and startup depth.
2. Keep env fixed, vary only FEX DLL build (single commit window step), reuse same test script and log parser.
3. Add a strict startup-depth marker set (e.g. reached loader, reached graphics module load, reached first frame) to avoid subjective "black screen" conclusions.
4. Only after startup-depth stabilizes, return to DXGI/VKD3D/WSI fine-tuning.

## Related Docs

- `docs/FEX_WOW_ISSUE_DRAFT.md`
- `docs/FEX_ENV_VARS_USED.md`
- `docs/FEX_STATUS.md`
- `docs/BUILD_FEXCORE_DLLS.md`
- `docs/BUILD_ARM_AARCH64_GRAPHICS_DLLS.md`
