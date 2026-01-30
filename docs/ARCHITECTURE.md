# 项目架构概览

Winlator-mod 是一个以 Android 应用为壳、在应用私有目录中展开 Linux RootFS，并通过 PRoot + Box86/Box64 + Wine 运行 Windows 程序的复合型项目。代码主体位于 `app` 模块，同时包含大量运行时解压的资产（drivers、dxvk、rootfs 等）以及用于产出这些资产的脚本与 CI 工作流。

## 分层视角
- 表现层（Android UI）：Activity/Fragment 负责容器管理、设置与启动流程。
- 编排层（运行时 orchestration）：`xenvironment` 组件系统负责把 XServer、音频、VirGL、Guest Launcher 等拼装为一个可运行环境。
- 协议与窗口系统层：`xconnector` + `xserver` 在 Android 侧实现 AF_UNIX Socket 通道与 X11 协议处理。
- 渲染层：`renderer` + `widget/XServerView` 使用 OpenGL ES 将 XServer 的窗口内容绘制到屏幕。
- 客体执行层（Guest Runtime）：通过 `libproot.so` 进入 RootFS，使用 box64/box86 执行 Wine 与目标程序。
- Native 支撑层：C/C++ 提供 epoll/socket、共享内存、图形缓冲与 VirGL/OpenXR 能力。

## 关键目录与职责
- Android 应用主模块：`app`
- Java/Kotlin（当前为 Java）核心代码：`app/src/main/java/com/winlator`
- Native 代码与三方子模块：`app/src/main/cpp`
- 运行时资产（会被解压到 RootFS）：`app/src/main/assets`
- 额外的底层组件工程：`android_sysvshm`、`audio_plugin`
- RootFS/依赖产物与补丁：`10.0`、`path`
- 构建与产物流水线（CI）：`.github/workflows`
- RootFS 构建脚本（本地/CI 共用）：`build-rootfs.sh`、`arch-bootstrap.sh`

## 运行时主流程（从启动到进程跑起来）
1. 应用启动进入 `app/src/main/java/com/winlator/MainActivity.java`。
2. `ImageFsInstaller.installIfNeeded(...)` 确保 `filesDir/imagefs` 下的 RootFS 已就绪，必要时从 `app/src/main/assets/imagefs.txz` 解压安装。
3. 容器列表由 `app/src/main/java/com/winlator/container/ContainerManager.java` 加载。容器实际位于 RootFS 内：`imagefs/home/xuser-<id>`，配置文件为容器根目录下的 `.container`。
4. 用户点击运行后进入 `app/src/main/java/com/winlator/XServerDisplayActivity.java`。

在该 Activity 中会执行以下动作：
- 激活容器（把 `imagefs/home/xuser` 软链到当前容器目录）。
- 构建 XServer、输入系统与渲染视图。
- 在后台线程完成 Wine 前缀修补、图形驱动与组件解压、音频驱动切换等准备动作。
- 组装 `XEnvironment` 并启动全部组件。
- 在 `setupWineSystemFiles()` 中应用 rootfs 工具补丁（`rootfs-utils`），修复 `/usr/bin/env`、`/usr/bin/cat`、`/usr/bin/lscpu` 的可执行性，并用 `rootfsUtilsPatchVersion` 做幂等控制。

## XEnvironment 组件装配模型
`app/src/main/java/com/winlator/xenvironment/XEnvironment.java` 提供一个非常清晰的“可插拔组件容器”，每个组件继承 `EnvironmentComponent`，并在 `start()`/`stop()` 生命周期内完成自己的资源创建与清理。

在 `XServerDisplayActivity` 中，常见组件装配如下：
- `SysVSharedMemoryComponent`：建立 SysV SHM 服务并向 XServer 注入 `SHMSegmentManager`。
- `XServerComponent`：在 AF_UNIX Socket 上接受 X11 客户端请求。
- `NetworkInfoUpdateComponent`：更新网络信息相关状态。
- `ALSAServerComponent` 或 `PulseAudioComponent`：提供音频服务端桥接。
- `VirGLRendererComponent`：当图形驱动为 virgl 时启用 3D 渲染服务端。
- `GuestProgramLauncherComponent`：最后启动客体进程（Wine + 目标程序）。

这种结构让“新增一个后台服务端能力”变得直接：实现组件、在装配阶段 add 即可。

## 客体进程如何被真正拉起
客体启动的关键逻辑在 `app/src/main/java/com/winlator/xenvironment/components/GuestProgramLauncherComponent.java`：
- 启动前会根据设置解压 box86/box64 到 RootFS。
- 组装环境变量（DISPLAY、WINEPREFIX、LD_LIBRARY_PATH、BOX64_* 等）。
- 构造命令：以 `nativeLibraryDir/libproot.so` 为入口，将 RootFS 作为 `--rootfs`，然后通过 `/usr/bin/env ... box64 <wine-exe> ...` 启动。
- 进程生命周期由 `ProcessHelper.exec(...)` 管理，并在退出时回调到 UI 层执行收尾动作。

可以把它理解为：Android 侧负责“准备舞台与灯光”，真正的表演（Wine + Windows 程序）在 RootFS 内完成。

## 协议通道与 X11 处理
X11 通道建立在 AF_UNIX Socket 之上：
- `app/src/main/java/com/winlator/xconnector/XConnectorEpoll.java` 负责监听 socket、接入连接并驱动请求处理循环。
- epoll、eventfd、ancillary fd 等底层能力由 `winlator` native 库提供。
- `app/src/main/java/com/winlator/xserver/XServer.java` 及其子系统（WindowManager、DrawableManager、extensions、requests）承担协议处理与状态管理。

从职责上看：`xconnector` 更像“IO 反应堆”，`xserver` 是“协议与状态机”。

## 渲染管线（XServer -> OpenGL ES）
渲染核心链路如下：
- `app/src/main/java/com/winlator/widget/XServerView.java` 是 GLSurfaceView 容器。
- `app/src/main/java/com/winlator/renderer/GLRenderer.java` 订阅窗口变化与指针移动事件，并在 `onDrawFrame` 中绘制所有可见窗口与光标。
- `Drawable`/`Pixmap` 等对象既能走纯 CPU 路径，也能在支持时借助 `GPUImage` 走硬件缓冲路径。

当启用 VirGL 时：
- `VirGLRendererComponent` 通过 JNI 调用 `virglrenderer` native 库处理 3D 请求。
- 通过共享 EGL context 与 frontbuffer flush，将 3D 输出回灌到 XServer 的 Drawable 纹理。

## 输入与控制桥接
输入有两条并行链路：
- XServer 内部输入：触控板与屏幕控件会直接调用 XServer 的注入接口（指针/键盘）。
- Guest 侧输入与控制：`app/src/main/java/com/winlator/winhandler/WinHandler.java` 通过 UDP 与 RootFS 内的配套服务通信，用于发送输入事件、列举/结束进程、前置窗口与设置亲和性等。

这两条链路分别覆盖“X11 层输入”和“Windows 侧控制面”。

## Native 代码在整体中的位置
Native 代码的入口与装配点在 `app/src/main/cpp/CMakeLists.txt`，它会：
- 编译 `winlator` 共享库（socket/epoll、共享内存、位图操作、硬件缓冲等 JNI 能力）。
- 编译 `proot` 子模块，产出 `libproot.so` 与 loader。
- 编译 `virglrenderer` 子模块。
- 编译 OpenXR 相关依赖与 `xr/*` 代码，服务于 `XrActivity`。

可以把 native 层理解为 Java 层的“硬件加速与系统调用扩展包”。

## 资产与构建流水线（为什么仓库里有这么多 tzst/xz）
这个项目强依赖“运行时解压资产”：
- RootFS 基础镜像：`app/src/main/assets/imagefs.txz`
- 容器模板：`app/src/main/assets/container_pattern.tzst`
- 图形驱动、DXVK/VKD3D、Win 组件、box86/64 等：集中在 `app/src/main/assets` 与仓库根目录的若干产物目录

这些资产通常由脚本与 CI 产出：
- 本地/CI RootFS 构建：`build-rootfs.sh`、`arch-bootstrap.sh`
- CI 工作流：`.github/workflows` 下多个工作流用于构建 RootFS、Mesa、Box64、Wine 变体与相关组件

因此，“应用代码 + 资产产线”共同构成了这个项目的完整架构。

## 快速心智模型（建议记住这三句话）
- UI 负责配置与装配，XEnvironment 负责把服务拼起来。
- 客体真正运行在 RootFS 内，通过 proot + box64 + wine 进入。
- XServer/xconnector/renderer 这三者构成了 Android 侧的窗口系统与显示管线。
