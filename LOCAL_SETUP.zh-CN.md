# iPad Pro + 妙控键盘，作为 Mac 的显示与输入终端

此分支基于 [peetzweg/opendisplay](https://github.com/peetzweg/opendisplay) 的提交 `4e7c1f11597aeede1d62b7f38c2f556331b800d3`（1.30.1），增加 iPad 妙控键盘与触控板输入、可隐藏工具条，以及登录后的 Mac 自动启动。保留上游 GPL-3.0 许可证和作者归属。

## 功能与验证范围

- 硬件键盘通过 HID 键位映射转发给 Mac，由 Mac 当前输入法处理输入。
- Mac 界面提供 **Caps Lock switches input source** 开关，默认关闭，此时 Caps Lock 控制远程字母大小写；开启后单按切换 Mac 中英文（Control-Space），长按只触发一次。切换即时生效并保存选择，切换模式时清除远程大写锁定。输入法模式需要 Mac 的「选择上一个输入源」保持为 Control-Space；显式启用 iPad 文本输入时，Caps Lock 交回 iPad 处理。
- 触控板支持悬停、单击、右键、拖动、双击和连续滚动。
- 全屏接收时捕获触控板相对移动，按 Mac 显示器排列在 iPad 与外接显示器之间移动光标、按住拖动；支持位于主屏左侧或上方的显示器。打开工具条、设置或 iPad 文本输入时释放捕获，关闭后恢复。
- 工具条默认完全隐藏；三指轻点 **iPad 屏幕** 显示或收起。展开后位于右上方，也可点 × 关闭，避免遮住 Dock。
- 工具条提供 Esc、Tab、Mac 快捷键菜单，以及可选的 iPad 文本输入模式。部分组合键由 iPadOS 保留，可从 Mac 菜单发送切换输入法、切换应用、复制和粘贴。
- 断线、应用进入后台或输入焦点离开时释放远端按键和鼠标按钮。
- 针对 iPad Command+Tab 返回后单击 Dock 被当成 Command-click 的问题，在按键取消、场景失活和恢复时清理输入；相对移动、点按和滚动携带当前硬件修饰键状态，Mac 在派发前释放过期的远程修饰键。修正版已安装；2026-11-03 用户按五次往返切换及复制/粘贴的验收步骤确认：单击正常打开应用，快捷键正常。
- 从 SSH 等应用返回前台时重新绑定触控板，核对当前场景的实际指针锁状态；触控板输入配置变更或临时丢锁时尝试恢复。诊断日志中的 `pointer input` 仅记录原始/已转发事件数量和捕获状态，不记录按键文字或屏幕内容。
- Mac 收到实际键鼠或触控操作时，通过公开的用户活动接口请求显示器亮屏；不以视频、心跳、按键释放或输入重置维持亮屏。此修复用于已登录会话中的锁屏/显示器休眠，实机验收待确认，不能用于冷启动解锁 FileVault。
- Mac 可通过用户级 LaunchAgent 在登录后自动启动、保持单实例，并在退出后重启。

已在 M4 Mac mini 与 11 英寸 M1 iPad Pro / 苹果妙控键盘上验证画面、键盘、触控板和输入法。USB 使用 2388×1668 HEVC，流内统计通常约 60 fps；该统计不是完整输入到光子的硬件延迟测量。当前 192 项 Mac 测试及 10 项 iPad UIKit 回归测试通过，覆盖跨屏坐标、拖动后的双击状态、视频布局、硬件键盘输入、Caps Lock 单次触发和修饰键过滤、Command-Tab 后的远程修饰键释放、显示器唤醒的输入筛选和节流、控制通道的分帧与真实 TCP 消息顺序，以及视频停滞恢复条件；iPad 测试另覆盖登录客户端离线初始化、分段 Apple RFB 握手、普通传屏键盘的隔离，以及原始指针事件停滞的恢复条件。本轮指针修订只更新 iPad；前述网络修复需要配套更新 Mac 与 iPad，自动化测试通过不能替代真机验收。

已实测：拔掉 Mac 外接显示器后，可仅用 iPad 经 Wi-Fi 显示和控制；在此无显示器状态下，Wi-Fi → USB → Wi-Fi 自动切换正常。无外接显示器时正常退出发送端，LaunchAgent 能自动拉起应用、创建虚拟显示器并重连 Wi-Fi。以上是已登录图形会话内的测试，不能替代冷启动验收。

**随身 Wi-Fi 使用 WPA2/WPA3 混合模式时，冷启动验收失败：输入 Mac 密码前 Wi-Fi 未连接，iPad SSH 不可达；本地输入密码后才联网。** 经用户确认，已改为 WPA2-PSK 并验证 Mac 正常重连；FileVault 预启动联网仍待再次冷启动验收。普通锁屏恢复及所有布局/快捷键组合尚未全部验收。自动启动项在用户登录后运行，不能替代登录前的画面和解锁步骤。

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

2026-11-04 在随身 Wi-Fi 下复现 USB → Wi-Fi 停在 `Connected`：控制 TCP 已建立且收到 HEVC 配置，但视频 TCP 积压约 129 KiB，采样约 1.18 MB 发送计数中约 778 KB 为重传，接收端没有构建新的视频格式。相同局域网对照中，IPv4 1400 字节 ICMP 负载 4/4 通过、平均 5.86 ms；IPv6 1400 字节负载（总长 1448）4/4 丢失，而 1100 字节负载 4/4 通过、1232 字节负载（总长 1280）3/3 通过。该差异曾提示 MTU 问题，但后续普通 TCP 套接字在 IPv6 下仍能完整发送约 1 MB，因此不能仅凭 ICMP 结果认定根因；已建立控制连接也不等于视频可用。

第一版 `useMinimumMTU` 经用户复测仍停在 `Connected`，不标记成功。同路径的 Network.framework 受控约 1 MB 传输中，默认 IPv6 耗时约 2.04 秒，最小 IP MTU 模式 6 秒超时，显式 `maximumSegmentSize = 1200` 模式约 0.78 秒完成，IPv4 默认模式约 0.95 秒完成；这些是一次传输耗时，不是键鼠延迟或长期吞吐结论。

发送端据此改为对移动设备及尚未识别的 TCP 对端设置 `NWProtocolTCP.Options.maximumSegmentSize = 1200`，限制 TCP 段而不使用上述最小 IP MTU 模式；已识别的 Mac 对端保持原路径策略。用户曾确认一次拔线后自动出画、键鼠正常，但后续再次出现视频积压，因此不能视为稳定修复。单独增加 IPv4 优先后也复现停滞，不能将问题仅归因于 IPv6。

后续修订对移动接收端的 Bonjour 视频连接优先尝试 IPv4；拨号失败、等待或两秒内未建立时，回退至允许 IPv6 的原有选择。视频 TCP 使用交互视频服务等级，iPad 监听端也设置 1200 字节 MSS；已识别的 Mac 接收端和显式指定的主机地址保留原有 IP 选择。设置仅作用于应用套接字，不改变系统 MTU、路由器或 Git 代理，可能增加数据包数量。USB/usbmux 传输方式不变，但配套 iPad 版本的监听选项同样适用于 USB 转接的 TCP，需要一并验证。见 [Apple TCP 选项说明](https://developer.apple.com/documentation/network/nwprotocoltcp/options)。

同时补上独立控制通道下的视频恢复：Mac 桌面可交互、控制心跳正常，但存在至少五秒未完成的视频发送时，重建网络连接并保留虚拟显示器；不重放点击或按键。每两秒检查一次，因此触发可能晚于五秒。静态桌面没有待发送视频、Mac 锁屏或接收端整体失联时，沿用原有恢复流程。接收端若收到视频切片但缺少解码参数，会通过现有节流机制请求关键帧。TCP/USB 回调保留当前连接归属检查，迁移前解绑旧回调，避免旧连接影响新连接。此轮已完成两端编译，192 项 Mac 测试及 7 项 iPad 测试通过；尚待安装并完成连续 USB → Wi-Fi → USB → Wi-Fi 真机验收，不标记网络问题已解决。

无线连接支持按会话绑定的独立可靠控制通道：默认视频 TCP 9000、光标 UDP 9001、键鼠与心跳 TCP 9002（自定义基准端口时分别为基准、+1、+2）。控制通道使用独立网络队列、关闭 Nagle，并绕过局域网代理；UDP 不可用时，光标也可经独立 TCP 返回。切换前等待旧通道输入顺序屏障，按键和鼠标按钮不跨连接乱序。独立通道在启用前失败时保留原通道；启用后失效则释放远端按键并重连，不重放可能已执行的点击。失败后冷却 30 秒再允许新尝试，避免反复中断无头桌面。旧版本和 USB 使用原有可靠通道。可在 Mac 启动参数追加 `-disableIndependentControl YES` 做同版本对照；此开关默认关闭，日常连接自动协商。

Mac 操作界面在 **Quality 下方**提供 **Adaptive bitrate (Wi-Fi)** 开关，Wi-Fi 默认开启。可随时关闭，立即恢复当前画质档位的固定码率，无需重连或重建虚拟显示器；选择会保存，重启后保持。USB 始终使用固定码率，不受此开关影响；拔线回到 Wi-Fi 时使用保存的选择。已实机验证开关即时生效、关闭后重启仍关闭，并恢复为开启。

局域网 TCP 视频连接启用自适应时，Best / Balanced / Fast 的上限分别为 18 / 10 / 6 Mbps，初始下限为上限的 25% 且不低于 2 Mbps。分辨率和目标帧率保持原档位；拥塞时会降低画面细节。每两秒检查本地发送积压与不超过八秒的接收端反馈，有压力时降低目标 25%；稳定十二秒后，每隔至少五秒增加档位上限的 5%（至少 0.25 Mbps）。低流量桌面不会只因控制 RTT 尖峰降码率，过期反馈也不会触发向上恢复。

编码器若在至少十五次回调中主动丢掉 20% 以上的帧，策略会恢复上一档保持出帧的安全码率，并提高本连接的码率下限；内容变复杂时可继续提高安全下限。这样避免以持续大幅降帧换取较低平均延迟。新连接或编码器重建时重新评估；USB 恢复原档位固定码率。使用 VideoToolbox 的平均码率目标，不附加硬字节上限；可用 `-disableAdaptiveBitrate YES` 关闭自动调整。量化控制与码率属性采用公开接口，见 [Apple 的低延迟编码说明](https://developer.apple.com/videos/play/wwdc2021/10158/)。

Caps Lock 开关位于自适应码率开关下方。该选项要求配套更新本分支 Mac 与 iPad 应用：iPad 转发 Caps Lock 按键，由 Mac 决定大小写或输入法行为。为避免系统把 Caps Lock 修饰状态解释成输入法切换，默认模式仅处理字母大小写，保留数字、标点和 Ctrl / Command / Option 快捷键。iPad 自身的 Caps Lock 状态不会覆盖 Mac 会话中的大小写状态。已验证默认关闭、切换即时生效、重启保存；用户实测确认关闭时大小写往返且 Mac 的 ABC 输入源不变，开启时中英文往返正常且英文不锁大写。验收后恢复关闭，保持默认大小写模式。

## 触控板移动中断诊断

2026-11-06 用户复现「每次松手再滑约半秒后停住，键盘仍有效」。保留现场读取 iPad 日志时，`enabled/locked/active` 均为 true、检测到一只鼠标，但原始移动与转发计数在多个五秒窗口内仅为 4–8，且两者一致；Mac 同时保持正常 USB 画面和控制连接。该证据将调查范围缩小到 iPad 原始输入交付，不能据此确定系统内部原因，也不能简单归因于网络。

修订在重新获得指针锁及鼠标成为当前设备时，重新绑定原始移动和按钮处理；回调验证其输入对象仍属于当前设备。保留 UIKit 的独立移动计数作为诊断，若实际 UIKit 移动持续而原始回调至少停滞 250 ms，且距上次绑定至少一秒，则补绑处理器。普通闲置不触发；补绑同一输入对象不会解除指针锁、清除按钮或结束拖动。工具条和登录页仍按原有规则释放捕获。鼠标成为当前设备的接口见 [Apple GCMouse 文档](https://developer.apple.com/documentation/gamecontroller/gcmouse)。

此修订已完成 iPad 签名编译并安装，10 项 iPad 回归通过。用户随后确认两项结果：三指轻点 iPad 屏幕打开工具条、点 × 关闭后恢复持续移动；修正版下连续滑动和画圈 30 秒、按住拖动窗口约 10 秒均正常。新日志在 12:37:54 重新获得指针锁后，12:37:58–12:38:47 的十个活动窗口合计收到 2999 次原始移动，全部转发，期间还有按钮事件。**本次现场恢复及连续移动、拖动验收通过。**

该轮日志中 UIKit 移动计数为零，未触发自动补绑分支，因此不能将恢复归因于该分支，也不能据一次复测断言已消除所有偶发中断。长期使用及再次切换场景后的自动恢复仍需观察；如再次停滞，可用上述工具条开关重新申请捕获，再保留日志。新增诊断仅记录原始移动、UIKit 移动、转发及按钮事件数量与捕获状态，不记录输入文字、密码或指针坐标。

## 锁屏后通过妙控键盘点亮

用户报告：Mac 锁屏并熄屏后，iPad 黑屏，妙控键盘和触控板不能点亮；用直连 Mac 的蓝牙键鼠点亮后，iPad 能显示锁屏并用妙控键盘输入密码。日志同时存在显示器休眠时采集停止、等待控制台恢复的记录。

发送端在处理实际输入时，独立于采集管线调用 `IOPMAssertionDeclareUserActivity`，使用 `kIOPMUserActiveLocal` 请求本地显示器亮屏。该公开接口不需要新增特权，不解锁账户，也不改变密码要求或系统休眠设置。输入最多每秒更新一次活动；若检测到显示器刚进入休眠，下一次输入立即请求唤醒。调用在独立电源队列执行，不阻塞可靠控制通道；断线、会话停止或输入重置时释放 assertion。参见 [Apple 接口说明](https://developer.apple.com/documentation/iokit/1557127-iopmassertiondeclareuseractivity)。

本次只需更新 Mac 发送端，接收端和协议不变。验收时保持 iPad OpenDisplay 前台，在 Mac 锁屏并等到熄屏后，不碰蓝牙键鼠，分别测试妙控触控板移动和 Shift 键能否点亮，再输入密码恢复桌面。尚未完成该修复的实体机验收；完全系统睡眠导致网络断开、FileVault 预启动和已退出用户会话不属于此接口能直接恢复的情况。

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

### 自适应码率验证（2026-11-02）

正式有效对照使用同一安装包、同一连续渐变纹理、独立 TCP 控制和 UDP 光标，保持原 Wi-Fi、位置、Best、HEVC、2388×1668、目标 60 fps。关闭和开启自适应各采集约 61.4 秒。该负载与前两步不同，只比较本步同条件两轮。

| 指标 | 固定码率 | 自适应码率 |
| --- | ---: | ---: |
| 光标应用层往返算术均值 | 28.24 ms | 27.06 ms |
| 光标往返 P95 | 94.26 ms | 96.09 ms |
| 普通应用 RTT 算术均值（各 31 个样本） | 36.06 ms | 21.24 ms |
| 有效光标样本（全部 UDP） | 307 | 307 |
| 探针超时 | 0 | 0 |
| 本地提交视频码流 | 17.26 Mbps | 4.96 Mbps |
| 采样窗口记录的码率目标 | 18 Mbps | 4.50–6.60 Mbps |
| 接收 FPS 快照中位数 | 58 | 60 |
| 接收 FPS 快照范围 | 52–60 | 37–60 |

视频提交码流下降约 71%，光标均值本轮下降约 4.2%，但 P95 未改善；不能据此宣称无线卡顿已解决。FPS 是测量时段内接收端每五秒报告的单秒快照（两轮分别 12、11 个），不是全时段平均帧率；开启轮仍有短时 37 fps 快照。视频码流用本地提交的视频帧字节数除以对应时间，不含链路开销，不代表运营商出口流量。

早期不连续随机纹理在低码率下只有 7–18 fps，判为失败并加入编码器实际丢帧保护；该纹理之后会触发保护恢复高码率，无法作为有效降码率对照。上述数据均保留，未混入最终连续负载的结果。极难压缩的内容可能提升安全码率下限；不能只降低目标值而忽略实际出帧。

有效原始记录为本机 `build/Measurements/step3-smooth-before-adaptive.json`、`step3-smooth-after-adaptive.json`，FPS 快照与时间戳在 `step3-video-observations.json`；早期数据保留在同目录的 `step3-before/after-adaptive`、`step3-v2-*`、`step3-final-*` 文件。可用以下命令复测，完成后恢复普通桌面：

```sh
python3 tools/local/login.py install --stress-pattern --disable-adaptive-bitrate
python3 tools/local/latency.py --label adaptive-off --warmup 15 --windows 12
python3 tools/local/login.py install --stress-pattern
python3 tools/local/latency.py --label adaptive-on --warmup 15 --windows 12
python3 tools/local/login.py install
```

171 项 Mac 回归测试和 6 项测量脚本测试通过；iPad 接收端沿用第二步版本。仍需以实际手机热点、随身 Wi-Fi 的信道和空口情况验收尾延迟。

用户已完成本步插拔线验收：插线、拔线后画面和键鼠均正常；日志对应确认 USB 为 fixed、Wi-Fi 为 adaptive。界面开关补充后的 Mac 回归测试为 173 项，包含默认开启和保存选择。

## 无头启动的边界

此启动项属于当前用户的 Aqua 图形会话：**用户登录后自启动，不是 FileVault 解锁前的系统服务。** 只有 SSH shell 登录并不等于已建立图形登录会话。默认传屏通道依赖该会话；新增的 iPad「Mac 登录」入口改用系统屏幕共享连接登录窗口，但仍须先通过 SSH 解锁 FileVault，不能直接解锁尚未挂载的数据卷。

先确认 iPad 的画面和输入正常，再断开原显示器的视频连接，验证 iPad 成为唯一显示器。第一次验收时保留恢复用的显示器和键盘。

Apple 文档说明：Apple 芯片 Mac 在 macOS 26 及以上、开启 Remote Login 且网络可用时，可通过 SSH 解锁 FileVault。见 [Apple 官方说明](https://support.apple.com/en-ca/guide/security/sec8447f5049/web)。是否能在具体网络的预启动环境连通，以及解锁后能否恢复用户会话，需要单独实测；此分支不会关闭 FileVault 或自动设置登录。

保留 FileVault 时，可先在 iPad 的 SSH 客户端配置 Mac 的局域网地址、端口 22、允许解锁 FileVault 的本地用户名，以及**密码认证**。先在正常运行时验证登录，再安排重启测试；密码仅在 SSH 客户端中输入。预启动阶段无法使用数据卷里的普通 SSH 密钥认证配置。预启动可用网络条件见 [Apple FileVault 网络要求](https://support.apple.com/guide/deployment/dep82064ec40/web)。

2026-11-03 用户冷启动实测停在联网之前：Mac 密码界面 Wi-Fi 未连接，iPad 无法 SSH；输入本地 Mac 密码后才联网。正常系统中已确认该网络的「自动加入」开启；系统报告加密模式为 WPA2/WPA3 Personal 混合。随后在随身 Wi-Fi 管理页直接确认安全模式为 `WPA2-PSK/WPA3-SAE`，可选 `WPA2-PSK`，完全隔离关闭。Apple 的预启动网络要求明确列出已加入的 WPA2-PSK 网络，以及无需认证的以太网。混合模式的预启动兼容性是待验证因素，尚不能据此认定为唯一根因。

用户已确认将 5GHz 主网络改为 `WPA2-PSK` 做对照，并知悉无线设备会断开重连、WPA3 保护会停用。已应用该模式，保持原网络名称和密码；Mac 自动重连后，系统信息确认当前为 WPA2 Personal、802.11ax、5GHz 信道 36 / 40MHz，局域网路由、主机名下的 SSH 与屏幕共享端口可达，发送端带自动启动和无线重连参数运行。设置应用后管理页退回登录页，未再次获取管理凭据。FileVault 保持开启。用户随后选择**暂不关机，保留 WPA2 配置待测**；尚未进行这次设置后的冷启动，不能将正常图形会话中的重连视为预启动成功。如仍失败，可用 Mac 原生以太网接同一局域网进行对照；不能为排障直接关闭 Wi-Fi 加密。

### SSH 解锁磁盘与登录桌面是两步

SSH 解锁 FileVault 的动作发生在**密码认证时**，不需要进入 shell 后再运行某条解锁命令。Apple 随系统提供的 `man apple_ssh_and_filevault` 明确说明：解锁后 SSH 会短暂断开，系统挂载数据卷并启动其余服务，随后才恢复普通 SSH 会话。也可阅读 [Apple 发布的同一手册](https://github.com/apple-oss-distributions/OpenSSH/blob/main/apple_ssh_and_filevault.7)。

如果已经看到 `jiyang@…` 一类 shell 提示符，说明数据卷已经可用；继续输入 `login`、`sudo -i` 或重新 SSH 不会替代图形桌面登录。此时可在 iPad 的 SSH 命令行中只读检查：

```sh
stat -f '%Su' /dev/console
```

- 输出为 `root` 或 `loginwindow` 等系统账户：通常尚未建立用户的控制台图形会话，OpenDisplay 的 Aqua 启动项不能运行。
- 输出为自己的用户名：已有该用户的控制台会话，但仍可能锁屏；若 OpenDisplay 没画面，应继续检查应用、捕获权限和连接状态，不能再归因于 FileVault。

macOS 未提供这里可直接使用的通用 SSH 图形登录命令。为满足仅使用现有 SSH 客户端和 OpenDisplay 的要求，iPad 接收端增加「Mac 登录」入口，不依赖另装远程桌面应用。保留 FileVault 的恢复路径为：

1. 在 iPad 通过 SSH 密码认证解锁磁盘；若连接短暂断开，等待系统启动。
2. 回到 iPad 的 OpenDisplay，在等待连接页点**Mac 登录**，填写 Mac 的 `.local` 主机名、用户名和 Mac 登录密码，点「连接登录画面」。主机名见 Mac「系统设置 → 通用 → 共享」底部的「本地主机名」。若使用 IP，需重新核对当前地址，不能沿用 DHCP 变化前的旧地址。连接使用系统屏幕共享固定端口 `5900`，即使发送端尚未启动也可独立建立。
3. 在 Mac 登录窗口完成同一用户的图形登录。默认开启「辅助盲输（暂停登录画面）」：完整加密认证后，显示可点击的密码框参考位置，并暂停后续登录画面订阅。点击虚线框，再用妙控键盘输入密码并按 Return；关闭开关可恢复登录画面核对。底部提供 Tab、Return 和 Esc 按钮。连接共享控制台，不另建后台用户会话。
4. 登录后，OpenDisplay 的用户启动项运行并恢复原有视频连接；登录通道已完成加密认证且收到新的传屏帧后，iPad 自动返回传屏。也可点「返回 OpenDisplay」手动返回。返回时保留已认证的屏幕共享连接并暂停其画面和输入，避免断开最后一个登录连接使 Mac 再次锁屏；再次打开 **Mac 登录** 复用该连接。底部「重新连接」会主动断开并要求重新认证。当前已在传屏时，可三指轻点 iPad 屏幕，展开右上工具条，在 **Mac → Mac 登录** 中测试入口。

Mac 端路径是「系统设置 → 通用 → 共享 → 屏幕共享」，仅允许需要的账户访问；不需要另开匿名控制或单独的传统 VNC 密码。登录入口使用离线打包的 noVNC / noVNC-ARD 开源代码，来源、固定提交与许可证在 `ThirdParty/LoginVNC`。所有网络字节通过应用自己的直连 TCP 连接传送，不加载远程网页、CDN 或中转服务，也不增加 Mac 常驻服务。

界面只保存地址和用户名；密码不存入配置、Keychain、URL 或日志，认证完成后清除凭据。WebKit 使用临时数据存储；已认证的连接由接收主界面持有，返回传屏不销毁它；未完成认证时退出登录入口会取消连接。切出应用、锁定 iPad 或主动重新连接时断开并清理登录会话。登录界面出现时暂停普通传屏的键盘转发和相对触控板捕获；登录通道确认完整加密后才允许远端输入，隐藏后释放按键并暂停帧订阅（包括 Tickle 和显示器变化引起的订阅续订）。

辅助盲输（2026-11-04）：参考框位于远程屏幕水平中央、90% 高度处，按实际 Mac 帧缓冲尺寸、画布缩放和黑边定位，不依赖固定的 iPad 像素坐标。点击通过原有加密鼠标通道发送按下与松开，再将键盘焦点交给远程画布；页面本身没有密码输入框。该标记依据已观察到的单用户锁屏布局估算，并非识别到的真实密码框；不同用户选择页或屏幕布局可能偏移。未收到 Mac 的有效屏幕尺寸前禁用定位点击。暂停画面不关闭认证套接字，也不暂停可见登录页的键盘和触控板；加密握手、尺寸消息及少量在途画面仍会处理，关闭开关后请求完整画面。此选项只影响「Mac 登录」的屏幕共享画面，不关闭解锁后的正常 OpenDisplay 传屏。

此模式已通过 7 项 iPad 回归及 4 项 JavaScript 回归，覆盖暂停视频时仍能输入、加密前禁止控制、定位点击与缩放、无尺寸时禁用点击、恢复画面和隐藏期间禁止输入；已完成横竖屏参考框布局检查，并安装到 11 英寸 M1 iPad Pro。用户按普通锁屏测试步骤确认：点击参考框、输入密码并回车后，**已自动恢复桌面和键鼠**。该功能的普通锁屏验收通过；完整冷启动、SSH 解锁后首次图形登录仍待单独验证。

连接提示区分地址/端口连接失败、连接超时、已建立连接后的中断和服务器主动关闭；超时会提醒核对 IP 变化或改用 `.local` 主机名。临时等待网络可在十五秒连接期限内恢复，不会一进入 waiting 状态就被误报失败。诊断日志只记录连接阶段与错误类别，不记录认证数据或远程画面。

循环锁屏修复（2026-11-04）：故障时的系统日志显示，`screensharingd` 在 15:41:12 关闭连接，随后 `ScreensharingAgent` 在 15:41:13 向 `loginwindow` 请求立即锁屏。旧版自动返回传屏时销毁登录会话，触发了该断开。修复后已通过 7 项 iPad 模拟器测试及 2 项 JavaScript 生命周期回归，覆盖交接保活、复用同一 WebView、隐藏期间暂停画面和输入、旧回调隔离与取消清理；签名开发版已安装并启动于 11 英寸 M1 iPad Pro。用户在普通锁屏、通过「Mac 登录」认证和解锁后确认：**已恢复桌面和键鼠，OpenDisplay 保持前台 30 秒内未再次锁屏**。普通锁屏后的自动交接验收通过；此结果不替代冷启动后首次图形登录验收。

本机已只读确认屏幕共享、远程登录和所需账户访问权限已开启，且屏幕共享能响应协议协商；没有为此改变权限、关闭 FileVault 或设置自动登录。首次实体机连接失败是沿用了变化前的 DHCP 地址：旧地址端口超时，当前地址端口正常；改用 Mac 的 `.local` 主机名后，用户已确认**已连接并加密，能显示和控制 Mac 桌面**。**冷启动后首次图形登录及其自动交接 OpenDisplay 仍待实机验收。** 普通锁屏解锁后的成功交接不能替代该冷启动验收。

冷启动验收应在保存工作、准备好恢复用显示器和键盘后，由用户关机并重新开机：

1. iPad 与 Mac 接入可互访、符合 FileVault 预启动要求的网络。
2. 在 SSH 客户端通过 Mac 账户密码认证。预启动解锁成功后可能短暂断开；能进入普通 shell 则说明磁盘已经解锁。若主机名在预启动时不能解析，应在路由器设备列表确认当时分配的地址，不能继续尝试旧 IP。
3. 待正常 macOS 的屏幕共享服务启动，在 iPad 的 OpenDisplay → Mac 登录中，用保存的 `.local` 名称连接并完成 Mac 图形登录。
4. 确认自动恢复原有 OpenDisplay 视频和键鼠，再退出 SSH。若失败，记录停在哪一步；不要仅凭 SSH shell 可用就认定整条启动路径已通过。

## 协议扩展

沿用上游协议 3 对未知字段和类型的忽略规则，不改变视频和 USB 传输。Mac 在 welcome 中增加 `remoteInput: 2`。能力 1 支持基础输入，能力 2 另支持跨屏相对指针；接收端仅在收到对应能力后发送：

| type | 数据 |
| --- | --- |
| key | HID usage、down、modifiers |
| text | 已提交的 Unicode 文本 |
| pointer | phase=down/move/up、归一化 x/y、button=0/1/2、clicks、modifiers |
| pointerRelative | 能力 2；phase=down/move/up、dx/dy（Mac 全局桌面点，向右/向下为正）、button、clicks、modifiers |
| pointerScroll | 能力 2；dx/dy 滚动量、可选 modifiers 当前快照，在 Mac 当前光标位置派发，不把光标移回 iPad；旧接收端省略时保留此前远程修饰键状态 |
| inputReset | 释放会话持有的按键、修饰键标志和鼠标按钮，包括没有显式 modifier key-down 的远程标志 |

修饰键仅允许 caps、shift、control、option、command、keypad、fn。原有 touch、scroll、pencil 路径保持兼容。完整新增输入功能需要配套使用本分支的 Mac 和 iPad 应用。
