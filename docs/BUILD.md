# 构建 APK（本地）

这个项目使用 Gradle Wrapper（`gradlew`）与 Android Gradle Plugin 7.0.4。为了避免已知的构建坑，推荐直接使用仓库内的脚本构建。

## 推荐方式（脚本）

在仓库根目录执行：

```bash
scripts/build-rootfs-utils.sh
scripts/build-apk.sh
```

如果需要直接安装到设备（adb）：

```bash
scripts/build-apk-install.sh
# 或指定设备
scripts/build-apk-install.sh --serial <device-id>
# 强制卸载后再安装
scripts/build-apk-install.sh -f
```

产物路径：

- `app/build/outputs/apk/debug/app-debug.apk`

## Rootfs 工具补丁（重要）

这次排查发现 `imagefs` 里有一批基础工具是指向 32-bit busybox 的符号链接（例如 `/usr/bin/env`、`/usr/bin/cat`、`/usr/bin/lscpu`）。在当前的启动链路下，这些工具会在 proot 中直接 `execve()`，从而触发：

- `proot error: execve(\"/usr/bin/env\"): No such file or directory`

为此仓库新增了静态 aarch64 工具的补丁资产与脚本：

- 脚本：`scripts/build-rootfs-utils.sh`
- 源码：`tools/rootfs-utils/`
- 资产输出：`app/src/main/assets/rootfs-utils/aarch64/`

首次构建或修改这些小工具后，请先运行：

```bash
scripts/build-rootfs-utils.sh
scripts/build-apk.sh
```

运行时会在容器启动阶段自动把这些工具覆盖到 rootfs 中，并记录 `rootfsUtilsPatchVersion`，避免每次都重复覆盖。

## 遇到问题时的修复开关

如果你在 macOS Apple Silicon（aarch64）上遇到如下错误：

- `Failed to load native library 'libnative-platform.dylib'`

可以用脚本的重置选项清理 Gradle 缓存后重试：

```bash
scripts/build-apk.sh --reset-gradle
```

这会删除：

- `~/.gradle/wrapper/dists/gradle-7.4-bin*`
- `~/.gradle/native`

然后让 Gradle Wrapper 重新下载干净的分发包与 native 组件。

## 已知坑与原因（这次实际踩到的）

1. Gradle native 平台库加载失败（`libnative-platform.dylib`）

现象：

- Gradle 连 `--version` 都起不来。

原因（常见）：

- `~/.gradle` 下的 Gradle 分发或 native 缓存损坏/不完整。

解决：

- 清理上面的缓存并重新下载（脚本提供 `--reset-gradle`）。

2. D8 在 JDK 22 上崩溃（`NullPointerException`）

现象：

- `:app:dexBuilderDebug` 失败，报 NPE（多个不相关 class）。

原因：

- 这个项目的 Gradle/AGP 组合较老（Gradle 7.4 + AGP 7.0.4），与 JDK 22 兼容性不稳定。

解决：

- 使用 JDK 17 构建（脚本会优先选择 JDK 17）。

3. 手动用 proot 复现问题时总是 “No such file or directory”

现象：

- 直接用 `libproot.so ... /usr/bin/env` 或 `/usr/bin/cat` 会报找不到文件/loader。

原因：

- 这个 proot 需要显式提供 loader 与临时目录环境变量。

解决（关键点）：

- 手动测试时务必带上 `PROOT_LOADER=/data/app/.../lib/arm64/libproot-loader.so`
- 手动测试时务必带上 `PROOT_TMP_DIR=/data/user/0/com.winlator/files/imagefs/tmp`

## 手动构建（不走脚本）

如果你更喜欢手动执行，请显式指定 JDK 17：

```bash
env JAVA_HOME=/Library/Java/JavaVirtualMachines/openjdk-17.jdk/Contents/Home ./gradlew :app:assembleDebug
```

如果你的 JDK 17 不在这个路径，可以改成你自己的 JDK 17 路径，或者在 macOS 上用：

```bash
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
./gradlew :app:assembleDebug
```

## UTM Ubuntu（ARM）SSH 连接信息

在 macOS 本机通过端口转发连接 UTM Ubuntu（ARM）：

```bash
sshpass -p ubuntu ssh -p 2222 ubuntu@127.0.0.1
```

共享目录挂载：

- TurtleWoW 已挂载到 Ubuntu 内的：`/mnt/macos`
