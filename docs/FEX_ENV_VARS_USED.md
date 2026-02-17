# FEX Environment Variables (Used By Winlator-Mod)

This repo uses a mix of:
- **FEX preset defaults** (applied first)
- **Container/Shortcut env vars** (applied next; user overrides)
- **Winlator safety/compat overrides** for `arm64ec + WoW64` sessions (applied last, unless the user explicitly set the same variable)

## Where Variables Are Set

- **Preset**: `app/src/main/java/com/winlator/fexcore/FEXCorePresetManager.java`
  - Always merged into the environment at launch.
- **Launch-time policy (WoW64 quirks / diagnostics)**:
  - `app/src/main/java/com/winlator/xenvironment/components/GuestProgramLauncherComponent.java`
- **Default container env vars**:
  - `app/src/main/java/com/winlator/container/Container.java` (`DEFAULT_ENV_VARS`)

## Preset Variables (FEXCorePresetManager)

These are always set by the selected **FEXCore preset**:
- `FEX_TSOENABLED` (`0/1`)
- `FEX_VECTORTSOENABLED` (`0/1`)
- `FEX_MEMCPYSETTSOENABLED` (`0/1`)
- `FEX_HALFBARRIERTSOENABLED` (`0/1`)
- `FEX_X87REDUCEDPRECISION` (`0/1`)
- `FEX_MULTIBLOCK` (`0/1`)

## Launch-Time WoW64 Policy (GuestProgramLauncherComponent)

For `arm64ec + WoW64` sessions, Winlator applies conservative defaults **unless you already set the variable** in container/shortcut env vars:

- `FEX_SMC_CHECKS` (string: `none|mtrack|full`)
  - Defaulted to `full` if not user-specified.
- `FEX_MULTIBLOCK` (`0/1`)
  - Defaulted to `0` if not user-specified.
- `FEX_SILENTLOG` (`0/1`)
  - Defaulted to `0` if not user-specified (so FEX logs appear in `wine.log`).
- `FEX_X87REDUCEDPRECISION` (`0/1`)
  - If not user-specified and preset set it to `1`, Winlator forces it back to `0` for WoW64.
- `FEX_HIDEHYPERVISORBIT` (`0/1`)
  - Defaulted to `1` if not user-specified.
- `FEX_DIAG_SIGILL` (`0/1`)
  - Defaulted to `1` if not user-specified.
- `FEX_DIAG_SMC` (`0/1`)
  - Defaulted to `1` if not user-specified.

## WoW/Warden Heuristic Variables (DEFAULT_ENV_VARS)

These are present in the container default env var string (can be overridden per container/shortcut):
- `FEX_BNET_FORCE_X86` (`0/1`)
- `FEX_BNET_DETECT_LOG` (`0/1`)
- `FEX_BNET_ID_NTQUERYSYSTEMINFORMATION` (text, e.g. `0x9A`)
- `FEX_BNET_ID_NTQUERYINFORMATIONPROCESS` (text, e.g. `0x89`)
- `FEX_BNET_ID_NTQUERYINFORMATIONTHREAD` (text, e.g. `0x8A`)

