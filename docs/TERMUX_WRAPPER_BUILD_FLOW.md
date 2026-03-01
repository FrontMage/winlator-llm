# Termux Wrapper 构建链路说明（Winlator LLM）

Last Updated: 2026-02-26

## 1. 背景

我们当前不走“裸编 bionic-vulkan-wrapper”，而走：

```bash
./build-package.sh --library bionic vulkan-wrapper-android -s -f
```

原因是这条链路是“打包系统 + 包定义 + 补丁 + 固定依赖”的组合，能规避直接构建时常见的不匹配问题。

## 2. 命令参数含义

命令位于 `out/_cache/vulkan_wrapper_termux-packages` 目录执行：

```bash
./build-package.sh --library bionic vulkan-wrapper-android -s -f
```

- `--library bionic`
  - 强制使用 bionic（Android）库体系，不走 glibc。
  - 对应构建变量 `TERMUX_PACKAGE_LIBRARY=bionic`。
- `vulkan-wrapper-android`
  - 指定包定义：`packages/vulkan-wrapper-android/build.sh`。
  - 该文件定义了源码来源、配置参数和预处理步骤。
- `-s`
  - 跳过依赖检查（dependency check），不是跳过编译。
- `-f`
  - 强制构建，即使之前有构建缓存。

## 3. 这条链路实际做了什么

核心阶段（由 `build-package.sh` 驱动）：

1. 加载包定义 `packages/vulkan-wrapper-android/build.sh`。
2. 执行统一流程：
   - `termux_step_get_source`
   - `termux_step_patch_package`
   - `termux_step_setup_toolchain`
   - `termux_step_configure`
   - `termux_step_make`
   - `termux_step_make_install`
   - `termux_step_massage` / 打包
3. 自动应用包目录内的 `.patch` 文件（例如 `leegao.patch`）。

## 4. 为什么它比直接编译更稳

直接编译失败通常来自“源码/补丁/SPIRV 版本/平台参数”不一致。  
Termux 链路更稳的原因：

1. **包定义固定**
   - `vulkan-wrapper-android/build.sh` 固定了 Meson/CMake 参数组合。
2. **补丁自动注入**
   - `termux_step_patch_package` 自动应用 `packages/vulkan-wrapper-android/*.patch`。
3. **SPIRV 静态库按包预期接入**
   - 包脚本在 pre-configure 阶段会将 `src/vulkan/wrapper/lib/*.a` 接入。
4. **工具链路径统一**
   - `--library bionic` 走 NDK 的 Android 目标路径，避免 glibc 路径干扰。

## 5. `leegao.patch` 的来源

`leegao.patch` 是本地基于 `mesa_bionic` 生成的差异补丁，不是在线拉取：

参考脚本：`out/_cache/vulkan_wrapper_termux-packages/wrapper.sh`

```bash
git diff 8c8e0079152a247dc37f1d81bb0162afcdba9e60 HEAD > packages/vulkan-wrapper-android/leegao.patch
```

也就是说，它是“基线 commit -> 当前 mesa_bionic HEAD”的增量集合。

## 6. bionic / glibc 依赖结论

在 `--library bionic` 下，产物应是 bionic 依赖模型。  
已验证现有 `wrapper.tzst` 中 `libvulkan_wrapper.so` 的 `NEEDED` 不包含 `libc.so.6` / `GLIBC_*`。

## 7. 在 x86 Linux 远程机构建（计划执行版）

说明：这部分是后续通过 SSH 执行的标准流程。

### 7.1 目标机基础要求

- Docker 可用
- 能访问 `ghcr.io/termux/package-builder`
- Git 可拉取本仓

### 7.2 预期目录

建议将仓库放在：

```bash
/home/<user>/winlator-mod
```

执行目录：

```bash
cd /home/<user>/winlator-mod/out/_cache/vulkan_wrapper_termux-packages
```

### 7.3 构建命令

```bash
./scripts/run-docker.sh bash -lc '
  cd /home/builder/termux-packages &&
  NDK=/home/builder/lib/android-ndk-r29 \
  ./build-package.sh --library bionic vulkan-wrapper-android -s -f
'
```

> 注：实际 NDK 路径以容器内存在的版本为准（例如 `android-ndk-r29`）。

### 7.4 产物提取

常见构建产物路径（容器内）：

```bash
~/.termux-build/vulkan-wrapper-android/build/src/vulkan/wrapper/libvulkan_wrapper.so
```

需要同时准备：
- `libvulkan_wrapper.so`
- `wrapper_icd.aarch64.json`

并打成 Winlator 需要的 `wrapper.tzst`（`usr/lib` + `usr/share/vulkan/icd.d`）。

## 8. 可复现性建议（必须项）

为了确保每次产物一致，建议 pin 以下版本：

1. `mesa_bionic` commit
2. `leegao.patch` 内容
3. SPIRV 静态库版本（与 wrapper 源码匹配）
4. NDK 版本（例如 r29）
5. 运行时 `WRAPPER_VK_VERSION`（环境变量）

---

如果后续要将这条链路固定进仓库脚本，建议新增一份“远端 x86 builder 自动化脚本”，并把以上 5 个 pin 项写成显式输入参数。

## 9. 一键远程构建（已落地）

已新增脚本：

- `scripts/build-wrapper-remote.sh`
  - 远端 x86 Linux 一键构建 `vulkan-wrapper-android`（aarch64）
  - 自动执行：
    - 拉取/对齐 `leegao/vulkan_wrapper_termux-packages`
    - 修补 `packages/vulkan-wrapper-android/build.sh`（确保 `-ladrenotools`、SPIRV 静态库拷贝）
    - 构建 SPIRV 静态库并注入 wrapper 目录
    - 容器内执行 `build-package.sh -I -w -a aarch64 -f vulkan-wrapper-android`
    - ABI 校验（AArch64 + `NEEDED: libadrenotools.so` + 无 `GLIBC_*`）
    - 拉回本地产物并生成 Winlator 包名路径版 ICD JSON

### 9.1 使用示例

```bash
scripts/build-wrapper-remote.sh \
  --host 192.168.0.111 \
  --user bazzite \
  --password 9527 \
  --package com.winlator.llm \
  --https-proxy http://192.168.0.102:8080
```

默认产物目录：

```bash
out/_cache/wrapper_remote_builds/<timestamp>/
```

并自动更新：

```bash
out/_cache/wrapper_remote_builds/latest -> <timestamp>
```

关键产物：

- `libvulkan_wrapper.so`
- `libadrenotools.so`
- `wrapper_icd.aarch64.json`（原始）
- `wrapper_icd.com.winlator.llm.aarch64.json`（已改 `library_path`）
- `SHA256SUMS`

## 10. 一键推送到当前容器（已落地）

已新增脚本：

- `scripts/push-wrapper-remote.sh`
  - 从 `out/_cache/wrapper_remote_builds/latest`（或指定目录）读取产物
  - 自动按 `--package` 修正 `wrapper_icd.aarch64.json` 的 `library_path`
  - 备份并替换容器内文件：
    - `files/imagefs/usr/lib/libvulkan_wrapper.so`
    - `files/imagefs/usr/lib/libadrenotools.so`
    - `files/imagefs/usr/share/vulkan/icd.d/wrapper_icd.aarch64.json`
  - 末尾做设备侧 hash 校验

### 10.1 使用示例

```bash
scripts/push-wrapper-remote.sh \
  --package com.winlator.llm
```

可选参数：

- `--serial <adb-serial>`
- `--artifact-dir <path>`
- `--device-stage <device-path>`
