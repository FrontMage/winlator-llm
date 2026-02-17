# TurtleWoW 断联排查记录

## 现象
- Winlator 中启动 WoW.exe 能登录账号，但在“进入世界/角色列表阶段”会断联。
- 断联表现为客户端已登录后突然被踢或直接断开。

## 已验证结论
- 不是 DNS/端口不可达问题。
  - Android 侧 `toybox nc` 测试 169.150.222.70:3724、169.150.222.69:8090 可达。
  - `cn.turtle-wow.org` 只影响公告栏，不影响登录流程。
- 抓包显示 world 服是主动断开连接。
  - `tw.pcapng` 中 8090 连接约 0.29s 后由服务端先发送 FIN。
  - `tw2.pcapng` 中 8090 连接约 8.48s，有数据往返与重传，最终客户端先发 FIN，服务端再 FIN。
- Box64 的常见稳定性疑点已排除。
  - `clock_probe`：QPC/TSC 单调，无 Large Gap。
  - `cpuid_probe`：多线程 CPUID 一致。
  - `crypto_probe`：AES/CRC32C 测试正确。

## 关键信息
- Wine 日志中常见：`connect failed, status 0xc00000a3`。
- 该状态符合“连接被中止”，与服务端主动断开一致。
- `tw2` 为一次成功登录的抓包，`tw` 为断开抓包。

## 排查步骤与工具
- Winlator 日志输出目录：`/storage/emulated/0/Download/Winlator/`
  - `guest.log`
  - `logs.txt`
- 抓包文件：`tw.pcapng`、`tw2.pcapng`

### 探针工具
位置：`tools/win-probes/`

- `clock_probe.exe`
  - 输出：`/storage/emulated/0/Download/Winlator/clock_probe.log`
- `cpuid_probe.exe`
  - 输出：`/storage/emulated/0/Download/Winlator/cpuid_probe.log`
- `crypto_probe.exe`
  - 输出：`/storage/emulated/0/Download/Winlator/crypto_probe.log`

构建脚本：`tools/win-probes/scripts/build_win_probes_docker.sh`

## 当前结论
- 断联更像是 world 服握手阶段的服务端主动关闭。
- 已排除“时间源不稳定”“CPU 特征不一致”“加密结果错误”等显著 Box64 计算问题。
- 如需进一步定位，需要更长的“稳定进入世界”抓包或协议层解析世界服握手阶段的数据。
