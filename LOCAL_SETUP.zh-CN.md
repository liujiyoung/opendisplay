# iPad Pro + 妙控键盘，作为 Mac 的显示与输入终端

此分支基于 [peetzweg/opendisplay](https://github.com/peetzweg/opendisplay) 的提交 `4e7c1f11597aeede1d62b7f38c2f556331b800d3`（1.30.1），增加 iPad 妙控键盘与触控板输入、可隐藏工具条，以及登录后的 Mac 自动启动。保留上游 GPL-3.0 许可证和作者归属。

## 功能与验证范围

- 硬件键盘通过 HID 键位映射转发给 Mac，由 Mac 当前输入法处理输入。
- 妙控键盘的 Caps Lock 单按切换 Mac 中英文（发送 Control-Space），长按只切换一次；不转发 iPad 的大小写锁定状态。需要大写时使用 Shift。Mac 的「选择上一个输入源」快捷键须保持为 Control-Space；显式启用 iPad 文本输入时，Caps Lock 交回 iPad 处理。
- 触控板支持悬停、单击、右键、拖动、双击和连续滚动。
- 全屏接收时捕获触控板相对移动，按 Mac 显示器排列在 iPad 与外接显示器之间移动光标、按住拖动；支持位于主屏左侧或上方的显示器。打开工具条、设置或 iPad 文本输入时释放捕获，关闭后恢复。
- 工具条默认完全隐藏；三指轻点 **iPad 屏幕** 显示或收起。展开后位于右上方，也可点 × 关闭，避免遮住 Dock。
- 工具条提供 Esc、Tab、Mac 快捷键菜单，以及可选的 iPad 文本输入模式。部分组合键由 iPadOS 保留，可从 Mac 菜单发送切换输入法、切换应用、复制和粘贴。
- 断线、应用进入后台或输入焦点离开时释放远端按键和鼠标按钮。
- 从 SSH 等应用返回前台时重新绑定触控板，核对当前场景的实际指针锁状态；触控板输入配置变更或临时丢锁时尝试恢复。诊断日志中的 `pointer input` 仅记录原始/已转发事件数量和捕获状态，不记录按键文字或屏幕内容。
- Mac 可通过用户级 LaunchAgent 在登录后自动启动、保持单实例，并在退出后重启。

已在 M4 Mac mini 与 11 英寸 M1 iPad Pro / 苹果妙控键盘上验证画面、键盘、触控板和输入法。USB 使用 2388×1668 HEVC，流内统计通常约 60 fps；该统计不是完整输入到光子的硬件延迟测量。162 项 Mac 测试及 2 项 iPad UIKit 回归测试覆盖跨屏坐标、拖动后的双击状态、视频布局、硬件键盘输入、Caps Lock 单次触发和修饰键过滤，以及控制通道的分帧、顺序屏障与真实 TCP 消息顺序。

已实测：拔掉 Mac 外接显示器后，可仅用 iPad 经 Wi-Fi 显示和控制；在此无显示器状态下，Wi-Fi → USB → Wi-Fi 自动切换正常。无外接显示器时正常退出发送端，LaunchAgent 能自动拉起应用、创建虚拟显示器并重连 Wi-Fi。以上是已登录图形会话内的测试，不能替代冷启动验收。

**冷启动、FileVault 预启动解锁、普通锁屏恢复及所有布局/快捷键组合尚未全部验收。** 自动启动项在用户登录后运行，不能替代登录前的画面和解锁步骤。

## 连接方式

Mac → USB-C 数据线 → **iPad 机身 USB-C 口**。妙控键盘通过 Smart Connector 连接 iPad；键盘转轴上的 USB-C 口仅供充电，不能传数据。

1. iPad 解锁，确认信任 Mac，并在前台打开接收应用。
2. Mac 打开 **OpenDisplay Dev**，在 Permissions 区域请求屏幕录制和辅助功能权限，再在系统设置中开启对应开关。
3. 根据系统提示重新打开应用。屏幕录制负责采集桌面，辅助功能负责注入输入。
4. 默认用 Extend、Best。Extend 是另一块桌面，已有窗口需拖到 iPad；需要相同画面时选 Mirror。显示大小使用设备行旁的箭头按钮调整。
5. 若双指右键无效，检查 iPadOS 触控板的辅助点按设置。
6. 同时连接外接显示器时，在 Mac 的 **系统设置 → 显示器 → 排列** 中确认两块屏幕的位置，再沿相邻边缘移动。iPad 保持全屏且工具条关闭，才能持续捕获触控板；三指轻点 iPad 屏幕可释放捕获并打开工具条。

正常使用时保持 iPad 应用在前台。断线后重插数据线，发送端会重连。主动点击 Disconnect 会记住断开选择，需要手动 Connect 恢复。

| 传输方式 | 支持与条件 |
| --- | --- |
| USB-C 数据线 | 支持；通过系统 usbmuxd 传输画面和键鼠，优先使用，不依赖 Wi-Fi。插入 iPad 机身接口，保持信任配对。 |
| Wi-Fi / 同一局域网 | 支持；Bonjour 发现、TCP 传输，两端需要本地网络权限。Mac 也可用网线接同一路由器，iPad 使用 Wi-Fi。首次在 Mac 点击 Connect，之后会记住该接收端。 |
| 蓝牙直连 | 不支持；此项目没有蓝牙画面或控制传输。妙控键盘通过 Smart Connector 接到 iPad，其输入与画面共同走 USB 或局域网。 |

有线会优先于 Wi-Fi；拔线时，如果能发现同一 iPad 的局域网服务，会尝试切换到 Wi-Fi，重新插线时再切回 USB。Wi-Fi 不要求互联网，但需要两端能够互访；访客网络隔离会阻止连接。当前没有配置跨网远程访问或无需路由器的无线直连。

OpenDisplay 的接收设备连接及有线链路探测显式使用局域网直连，避免系统 SOCKS/HTTP 代理接管设备流量或把代理回环误判为有线链路。此设置仅作用于应用的设备连接，不修改系统代理或 GitHub 的 Git 代理配置。

无线连接支持按会话绑定的独立可靠控制通道：默认视频 TCP 9000、光标 UDP 9001、键鼠与心跳 TCP 9002（自定义基准端口时分别为基准、+1、+2）。控制通道使用独立网络队列、关闭 Nagle，并绕过局域网代理；UDP 不可用时，光标也可经独立 TCP 返回。切换前等待旧通道输入顺序屏障，按键和鼠标按钮不跨连接乱序。独立通道在启用前失败时保留原通道；启用后失效则释放远端按键并重连，不重放可能已执行的点击。失败后冷却 30 秒再允许新尝试，避免反复中断无头桌面。旧版本和 USB 使用原有可靠通道。可在 Mac 启动参数追加 `-disableIndependentControl YES` 做同版本对照；此开关默认关闭，日常连接自动协商。

## 构建

需要 macOS 14+、Xcode 15+ 和 XcodeGen；具体可用 SDK 要能编译当前上游源码。iPad 实机安装还需要自己的 Apple 开发签名、配对设备和开发者模式。

```sh
brew install xcodegen
cp .env.example .env
```

编辑 `.env`，填入自己的团队号和唯一的 iOS bundle ID：

```dotenv
DEVELOPMENT_TEAM=YOURTEAMID
IOS_BUNDLE_IDENTIFIER=com.example.opendisplay.ios.dev
LAUNCH_AGENT_LABEL=com.peetzweg.opensidecar.headless
```

`.env`、构建产物、签名文件和本地依赖不应提交。示例 bundle ID 需要换成自己可签名的唯一标识。

保留上游的标准 `./generate.sh` 构建方式。以下本地脚本也可使用经校验的 Sparkle 归档，避免拉取其完整 Git 历史：

```sh
tools/local/bootstrap.sh
tools/local/build.sh mac
tools/local/build.sh ios-signed
tools/local/build.sh test
tools/local/build.sh ios-test
```

脚本优先使用 `.local/tools/xcodegen/2.46.0/bin/xcodegen`，否则使用 PATH 中的 XcodeGen。iPad 测试默认使用 `iPad Air 11-inch (M3)` 模拟器，需要相应运行时。

Sparkle 2.8.1 从 [官方发布](https://github.com/sparkle-project/Sparkle/releases/tag/2.8.1) 下载，SHA-256：

```text
995f913935fe903d50b3be5344fc52a638f56b39ef7984bf7a44244786d28638
```

缓存位于 `.local/downloads/`，框架位于 `.local/dependencies/`。解压必须保留框架符号链接，脚本使用 macOS `ditto`。本地工程关闭 Sparkle 自动检查；升级时重新合并源码并构建，避免安装官方更新后丢失此分支功能。

## 安装和登录后自动启动

Mac 产物为 `build/Build/Products/Debug/OpenDisplay Dev.app`。按上游开发规范使用稳定 Debug 身份，通过以下命令启动：

```sh
./run.sh
```

iPad 产物为 `build/ios-signed/Build/Products/Debug-iphoneos/OpenSidecariOS.app`。选择 `xcrun devicectl list devices` 中的设备，使用自己的 bundle ID：

```sh
xcrun devicectl device install app --device YOUR_IPAD_DEVICE \
  build/ios-signed/Build/Products/Debug-iphoneos/OpenSidecariOS.app
xcrun devicectl device process launch --device YOUR_IPAD_DEVICE \
  YOUR_IOS_BUNDLE_IDENTIFIER
```

安装用户级自动启动项：

```sh
python3 tools/local/login.py preview
python3 tools/local/login.py install
```

启动项通过 Launch Services 打开应用，使用 `open -W` 保持单实例，并通过 `caffeinate -s` 在运行期间阻止系统休眠。启动参数 `-autoReconnectWiFi YES` 让它持续等待此前手动连接过的 Wi-Fi 接收端，允许开机登录一段时间后才打开 iPad 应用；普通启动仍保留上游的 12 秒窗口。它会在应用退出后重启应用；需要正常退出时先移除启动项：

```sh
python3 tools/local/login.py uninstall
```

重建 Mac 前先移除启动项，构建后再安装。**测试过程中授予屏幕录制后，不要中途重签或重建 Mac 应用**，否则需要重新核查隐私授权。

Mac 运行日志位于 `~/Library/Logs/OpenDisplay Dev/`。iPad 连接日志可在应用 Settings & Help 中查看。个人签名、设备标识和本机路径只保留在本地配置与日志中。

## 无线延迟对比

先使用同一 Wi-Fi、设备位置、画质、分辨率和动态负载，预热后分别采集每次修改前后约 60 秒。正式采样时不构建应用、不切换 iPad 应用、不插拔数据线。混入 USB、重连、画质或控制通道切换的样本会被脚本拒绝；两端控制模式也须一致。真实的延迟尖峰和超时单独保留，避免只挑选流畅窗口。

测量开关默认关闭。启动 iPad 应用时追加 `-- -measureLatency YES`，并使用支持 `welcome.latencyProbes: 1` 的 Mac 测量版。每秒五个探针经 iPad → Mac 光标队列 → 实际光标返回路径 → iPad 主线程更新，用同一 iPad 单调时钟计时。它是应用层光标往返时间，不含手指采样和屏幕扫描；普通应用 RTT 另行记录。均值从全部原始样本计算，不能平均各窗口的中位数。

```sh
python3 tools/local/login.py install --test-pattern
python3 tools/local/latency.py --label step1-before --windows 12 --warmup 10
```

动态测试窗口跟随目标虚拟显示器的位置和 HiDPI 缩放变化，须确认在 iPad 上播放后开始采样。结果保存在忽略提交的 `build/Measurements/`。测试结束用 `python3 tools/local/login.py install` 恢复普通桌面；iPad 退出后不带 `-measureLatency YES` 重开即可关闭探针。

### UDP 修复验证（2026-11-02）

Mac mini 与 M1 iPad Pro 在同一局域 Wi-Fi 下，保持 Best、HEVC、2388×1668、目标 60 fps 和同一动态测试画面；每轮采集约 61.6 秒。测试窗口已核对位于 iPad 虚拟桌面，未使用误显示在外接显示器时的样本。

| 指标 | 修复前 | UDP 修复后 |
| --- | ---: | ---: |
| 光标应用层往返算术均值（各 308 个样本） | 6.91 ms | 6.36 ms |
| 光标往返 P95 | 9.29 ms | 8.37 ms |
| 普通应用 RTT 算术均值（各 30 个样本） | 6.54 ms | 6.60 ms |
| 光标 TCP / UDP 样本数 | 308 / 0 | 0 / 308 |
| UDP 确认窗口 / 总窗口 | 0 / 12 | 12 / 12 |
| 探针超时 | 0 | 0 |

修复将 UDP 首包的送达确认与 TCP/UDP 共用的显示序号去重分开，并让 UDP 使用直连局域网路径。TCP 镜像先到不会再抑制 UDP 回执；新 UDP 流也不会倒退显示序号。此次光标均值下降约 8%，普通 RTT 基本持平，证实 UDP 通道恢复；单组低负载对比不能证明拥塞时的卡顿或物理操作到显示的延迟已解决。原始数据分别保存在本机 `build/Measurements/step1-before-udp.json` 和 `step1-after-udp.json`。

### 独立控制通道验证（2026-11-02）

沿用同一 Wi-Fi、位置、Best、HEVC、2388×1668、目标 60 fps 和动态画面，每轮约 61 秒。第一步用户验收后重新采基线，网络已出现尖峰，不能直接拿第一步的低延迟数值比较。

| 指标 | 第二步修复前 | 首轮开启 | 同版本关闭对照 | 同版本重新开启 |
| --- | ---: | ---: | ---: | ---: |
| 光标往返算术均值 | 18.03 ms | 21.11 ms | 24.94 ms | 25.34 ms |
| 光标往返 P95 | 83.67 ms | 85.77 ms | 101.25 ms | 90.42 ms |
| 普通应用 RTT 算术均值 | 12.94 ms | 28.45 ms | 25.33 ms | 23.96 ms |
| 有效光标样本 | 306 | 308 | 306 | 308 |
| 普通 RTT 样本 | 31 | 31 | 31 | 31 |
| 探针超时 | 0 | 0 | 0 | 1 |
| 上行控制路径 | 视频 TCP | 独立 TCP | 视频 TCP | 独立 TCP |

所有有效光标样本均经 UDP 返回，12/12 窗口确认 UDP 送达。独立通道开启轮中，两端均报告 dedicated；USB → Wi-Fi 自动切换后，用户确认画面、键盘和触控板正常。均值只统计已返回样本，超时单列，不能将超时解释为低延迟。

**结果：独立通道功能生效，但本轮未测出稳定的平均延迟改善。** 首轮变慢后保留原始结果，使用同一安装包关闭再开启做相邻对照；该对照均值接近，P95 降低，仍不足以证明总体卡顿已修复。它隔离了控制与视频的 TCP 字节流及网络队列，无法消除共享 Wi-Fi 的空口竞争，输入注入仍在原有串行队列上保持顺序。尚未做强制丢包或通道故障的实机验收；测试覆盖分帧、缓冲上限和真实 TCP 连续消息顺序。后续自适应码率应单独采样和验收。

本机原始记录为 `build/Measurements/step2-before-control.json`、`step2-after-control.json`、`step2-control-off-adjacent.json`、`step2-control-on-adjacent.json`。同版本关闭对照可用 `python3 tools/local/login.py install --test-pattern --disable-independent-control`，恢复普通启动用 `python3 tools/local/login.py install`。

## 无头启动的边界

此启动项属于当前用户的 Aqua 图形会话：**用户登录后自启动，不是 FileVault 解锁前的系统服务。** 只有 SSH shell 登录并不等于已建立图形登录会话。FileVault 等待解锁、停留在登录窗口且用户会话尚未建立时，OpenDisplay 不能提供登录画面，也不能靠 iPad 中的 OpenDisplay 自行完成开机解锁。

先确认 iPad 的画面和输入正常，再断开原显示器的视频连接，验证 iPad 成为唯一显示器。第一次验收时保留恢复用的显示器和键盘。

Apple 文档说明：Apple 芯片 Mac 在 macOS 26 及以上、开启 Remote Login 且网络可用时，可通过 SSH 解锁 FileVault。见 [Apple 官方说明](https://support.apple.com/en-ca/guide/security/sec8447f5049/web)。是否能在具体网络的预启动环境连通，以及解锁后能否恢复用户会话，需要单独实测；此分支不会关闭 FileVault 或自动设置登录。

保留 FileVault 时，可先在 iPad 的 SSH 客户端配置 Mac 的局域网地址、端口 22、允许解锁 FileVault 的本地用户名，以及**密码认证**。先在正常运行时验证登录，再安排重启测试；密码仅在 SSH 客户端中输入。预启动阶段无法使用数据卷里的普通 SSH 密钥认证配置。成功解锁后 SSH 会暂时断开，等待 macOS 启动，再打开 iPad 的 OpenDisplay。若用户图形会话仍未建立，须先完成图形登录；不要把 SSH shell 登录视为图形登录。预启动可用网络条件见 [Apple FileVault 网络要求](https://support.apple.com/guide/deployment/dep82064ec40/web)。

## 协议扩展

沿用上游协议 3 对未知字段和类型的忽略规则，不改变视频和 USB 传输。Mac 在 welcome 中增加 `remoteInput: 2`。能力 1 支持基础输入，能力 2 另支持跨屏相对指针；接收端仅在收到对应能力后发送：

| type | 数据 |
| --- | --- |
| key | HID usage、down、modifiers |
| text | 已提交的 Unicode 文本 |
| pointer | phase=down/move/up、归一化 x/y、button=0/1/2、clicks、modifiers |
| pointerRelative | 能力 2；phase=down/move/up、dx/dy（Mac 全局桌面点，向右/向下为正）、button、clicks、modifiers |
| pointerScroll | 能力 2；dx/dy 滚动量，在 Mac 当前光标位置派发，不把光标移回 iPad |
| inputReset | 释放会话持有的按键和鼠标按钮 |

修饰键仅允许 caps、shift、control、option、command、keypad、fn。原有 touch、scroll、pencil 路径保持兼容。完整新增输入功能需要配套使用本分支的 Mac 和 iPad 应用。
