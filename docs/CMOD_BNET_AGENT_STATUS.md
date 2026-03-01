# CMOD: box64rc / Build / libgnutls / Battle.net-Agent 现状记录

## 1. box64rc 在 CMOD 下的格式与生效链路

### 1.1 配置来源（`.rcp`）
- 预置配置在：`third_party/winlator-cmod/app/src/main/assets/box86_64/rcfiles/`
- 示例：`third_party/winlator-cmod/app/src/main/assets/box86_64/rcfiles/box86_64rc-1.rcp`
- `.rcp` 本质是 JSON，结构为：
  - `id`, `name`
  - `groups[]`
  - `groups[].items[]`
  - `items[].processName`
  - `items[].vars`（如 `BOX64_DYNAREC_*`）

### 1.2 运行时转换为真正的 `.box64rc`
- 代码路径：
  - `third_party/winlator-cmod/app/src/main/java/com/winlator/cmod/box86_64/rc/RCFile.java`
  - `third_party/winlator-cmod/app/src/main/java/com/winlator/cmod/XServerDisplayActivity.java`
- 关键行为：
  1. 读取选中的 `.rcp`
  2. `generateBox86_64rc()` 生成文本配置（INI 风格）
  3. 写入容器根目录：`<container_root>/.box64rc`
  4. 注入环境变量：`BOX64_RCFILE=<container_root>/.box64rc`

### 1.3 真正生效的 box64rc 文本格式
格式为：
```ini
[process_name.exe]
BOX64_DYNAREC_BIGBLOCK=...
BOX64_DYNAREC_SAFEFLAGS=...
```
- 每个 section 对应 `processName`
- 仅启用的 group 会参与生成
- 同名 `processName` 的变量最终按 Map 合并，后写值会覆盖前写值

## 2. CMOD APK 构建流程

### 2.1 工程入口
- 项目目录：`third_party/winlator-cmod`
- 包名：`com.winlator.cmod`
- Gradle配置：`third_party/winlator-cmod/app/build.gradle`

### 2.2 标准构建命令
在 `third_party/winlator-cmod` 下执行：
```bash
./gradlew :app:assembleDebug
```
产物路径：
```bash
third_party/winlator-cmod/app/build/outputs/apk/debug/app-debug.apk
```

### 2.3 本地构建前置条件
- `third_party/winlator-cmod/local.properties` 需要正确 `sdk.dir`
- 当前仓库中的该文件是历史 Windows 路径（不可直接用于当前环境），不改会报 `SDK location not found`

### 2.4 关于 imagefs 是否由 GitHub Actions 构建
- 在当前 `third_party/winlator-cmod` checkout（含其 cmod 相关远端分支）未发现 `.github/workflows` 的 imagefs 构建流程。
- 当前可见事实是：`imagefs.txz` 被视为 LFS/预制资产。
- 因此在本仓可确认的是“消费预制 imagefs 资产”，而不是“本仓 workflow 内生成 imagefs”。

## 3. libgnutls 在 APK/资产中的位置与替换方式

### 3.1 资产来源定位
- `ImageFsInstaller` 通过 `imagefs.txz` 解包系统文件到应用私有目录 `files/imagefs`
- 代码：`third_party/winlator-cmod/app/src/main/java/com/winlator/cmod/xenvironment/ImageFsInstaller.java`
- `libgnutls.so` 的运行时位置：
  - `/data/user/0/com.winlator.cmod/files/imagefs/usr/lib/libgnutls.so`

### 3.2 替换策略
CMOD 下替换 `libgnutls` 有两种路径：

1. APK 资产级替换（长期）
- 解包 `app/src/main/assets/imagefs.txz`
- 替换其中 `usr/lib/libgnutls.so`
- 重新打包 `imagefs.txz`
- 重构建 APK 并安装

2. 运行时热替换（快速验证）
- 直接 push 到容器：
  - `/data/user/0/com.winlator.cmod/files/imagefs/usr/lib/libgnutls.so`
- 适合快速 A/B 验证，不改 APK

### 3.3 注意
- `proton-9.0-*_container_pattern.tzst` 中未定位到 `libgnutls.so`，其主要来源不是 container pattern，而是 imagefs 基础层。

## 4. CMOD 下 Battle.net / Agent 当前问题记录

### 4.1 本次分析使用日志
- `tmp/cmod_logs/wfm_2026-02-24_20-24-56.txt`
- `tmp/cmod_logs/wfm_2026-02-24_20-31-24.txt`

### 4.2 主要现象（聚焦 CMOD）
1. Agent 反复拉起
- 观察到 `Agent.exe` 与 `Agent.9390\\Agent.exe` 多轮启动
- `init_peb starting ... Agent.exe in experimental wow64 mode` 重复出现

2. Wine 模块分配异常高频刷屏
- `err:module:alloc_module rtl_rb_tree_put failed.` 在单次日志内出现数百次（>800）
- 这是当前最稳定、最显著异常信号

3. gnutls 符号缺失信号
- 在可复现样本中可见：
  - `_gnutls_ecdh_compute_key` not found
  - `gnutls_ecdh_compute_key` not found

### 4.3 明确排除项
- 本文不把 `libgmp.so` 加载失败作为 cmod 当前主问题结论（该项已按要求排除，不作为本轮判断依据）。

## 5. 当前结论（面向后续排查）

1. box64rc 机制本身是通的：`.rcp -> .box64rc -> BOX64_RCFILE` 路径完整。
2. cmod 构建是独立 Gradle 工程流程，可直接产出 `app-debug.apk`。
3. `libgnutls` 在 cmod 中属于 imagefs 基础层内容，替换入口应优先走 imagefs（资产级或运行时热替换）。
4. Battle.net/Agent 当前更需要优先定位 `rtl_rb_tree_put failed` 大量触发的根因链路，`gnutls` 符号缺失作为并行线索。

