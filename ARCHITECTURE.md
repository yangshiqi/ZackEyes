# ARCHITECTURE.md

## 项目定位

ZackEyes 是 macOS 原生应用，将 MacBook 刘海（Dynamic Island）区域变为 AI 编码代理的实时控制面板。**自 v0.3.0 起同时支持 Claude Code 和 OpenAI Codex CLI**，两边会话并存于同一刘海面板。

## 组件架构

```
Claude Code  ──┐                                     ┌──> SocketServer
               ├── ~/.zackeyes/bin/bridge ───────────┤    (single socket /tmp/zackeyes.sock)
Codex CLI    ──┘     --event X --agent {claude|codex}     │
                     SAME BINARY, agent flag              ▼
                                                    SessionStore
                                                    (sessions tagged with agent)
                                                          │
                                                          ▼
                                                    NotchPanel UI
                                                    (AgentBadge per card)
```

三个组件，通过 Unix Domain Socket 连接：

| 组件 | 位置 | 职责 | 禁止 |
|------|------|------|------|
| **Bridge CLI** | `Bridge/` → 嵌入 `ZackEyes.app/Contents/Helpers/bridge` | 被 Claude Code 和 Codex CLI hook 调用，解析 `--event` + `--agent`，转发事件到主 App，返回权限决策；socket 不可达时把白名单生命周期事件落盘 ~/.zackeyes/pending/ 供启动补播（#89） | 不含 UI 逻辑，不直接读写用户配置文件 |
| **Main App** | `ZackEyes/` | Socket 监听、会话状态管理、NotchPanel UI、Hook 自动安装（Claude + Codex 各一套）、Codex jsonl 实时 tailer | 不直接与 agent 进程交互（全部通过 Bridge / jsonl tail） |
| **Launcher Script** | `~/.zackeyes/bin/bridge`（shell 脚本） | 定位 .app 路径，exec 到真实 Bridge 二进制。查找顺序：`~/.zackeyes/.app-path` → 常见安装路径 → Spotlight bundle id；找不到时静默 `exit 0` | 不含业务逻辑，只做路径查找和 exec；失败不写 stdout/stderr |

**依赖方向**: Agent → Bridge → Main App（单向）。Main App 不主动连接 Bridge，但会**单向反向读** Codex 的 session jsonl（通过 SessionScanner 启动扫描 + CodexJsonlTailer kqueue 实时监听）。

## 双 agent 兼容点速查

| 主题 | Claude | Codex |
|------|--------|-------|
| Hook 配置文件 | `~/.claude/settings.json`（`HookInstaller`） | `~/.codex/hooks.json`（`CodexHookInstaller`） |
| 启用 hooks 的额外 flag | 无（CC 默认） | `[features].hooks` 在 codex `default_enabled: true`，所以**我们也不碰 `config.toml`** |
| 支持的事件 | 12 个：基础 8 个 + compact/subagent lifecycle；另有 `StatusLine` | 6 个：无 Notification / SessionEnd / StatusLine |
| 5h/7d 配额数据源 | StatusLine hook 的 `rate_limits.{five_hour,seven_day}` | rollout jsonl 的 `event_msg.token_count.rate_limits.{primary,secondary}`（UsageTracker 周期扫描） |
| Permission 响应 JSON 形状 | `{hookSpecificOutput:{decision:{behavior,message}}}` | 同上（codex 文档形状完全一致，**Bridge 输出不需翻译**） |
| AskUserQuestion | 支持（PreToolUse 阻塞） | 不支持（codex 不定义此工具） |
| 进程探测（liveness sweep） | `TerminalLocator.runningClaudeCwds()` 走 `ps`/`lsof` | 暂无 `runningCodexCwds()`，改用 `lastActiveAt` 时间剪枝（15 min 阈值） |
| 无 hook 兜底发现 | 启动扫描 + 60s 周期重扫（SessionScanner，#83） | CodexJsonlTailer kqueue 实时 + 30s rediscovery |
| Detected session 启动扫描窗口 | 8h | 30 min（codex 一次 invocation = 一个 rollout，关掉就死） |
| 已运行 agent 的实时回退 | hook 自动接入 | hook 缓存的限制 → `CodexJsonlTailer` 监 `event_msg.task_started` / `event_msg.task_complete` 兜底 |

## 核心数据流

### 权限审批流（双向，同步）

```
Claude Code 触发 PermissionRequest hook
  → shell 执行 ~/.zackeyes/bin/bridge --event PermissionRequest
    → bridge 从 stdin 读取 JSON（tool_name, tool_input 等）
    → bridge 连接 /tmp/zackeyes.sock
    → bridge 发送事件 JSON + \n
    → SocketServer 接收，更新 SessionStore 状态为 "waiting"
    → NotchPanel 自动展开，显示审批 UI
    → 用户点击 Allow / Deny
    → SocketServer 通过同一 socket 连接发送响应 JSON
    → bridge 读取响应，输出到 stdout
    → bridge exit(0)
  → Claude Code 解析 stdout JSON，执行或跳过工具调用
```

### 状态更新流（单向，fire-and-forget）

```
Claude Code 触发 SessionStart/PreToolUse/PostToolUse/Stop hook
  → bridge 从 stdin 读取 JSON
  → bridge 连接 socket，发送事件，立即断开
  → bridge exit(0)
  → SocketServer 更新 SessionStore
  → NotchPanel 响应式更新 UI
```

### AskUserQuestion 自动作答流（双向，同步）

```
Claude Code 触发 PreToolUse hook (tool_name="AskUserQuestion")
  → bridge --event PreToolUse 阻塞 60s 等响应（其他 PreToolUse 仍 fire-and-forget）
    → SocketServer 持 fd（沿用 PermissionRequest 的 fd-hold 模式）
    → SessionStore 标 pending（responder 类型为 BridgeResponse）
    → NotchExpandedView 渲染**可点击**选项（单选 tap 直接提交，多选 checkbox + Submit）
    → 用户点 → submitAskUQAnswer 调 responder(.preToolUse(...))
    → bridge stdout = JSON → CC 消费 updatedInput.answers，跳过终端 UI
  → 60s 内未点 / app 崩 / socket 异常 → bridge 静默 exit 0 → CC 渲染终端 UI
    （SocketClient 用 poll() 检测 POLLHUP，app 崩溃时 < 1s 内回退）
```

`BridgeEvent.requiresBlockingResponse` 把"哪些 hook 走阻塞"集中起来：当前 `PermissionRequest` + `PreToolUse(AskUserQuestion)`。AskUQ 的 `answers` 形状由 spike 验证（2026-04-25）：单选 `{"<question>": "<label>"}`，多选 `{"<question>": "<label1>, <label2>"}` 单字符串逗号分隔。

⚠️ **PreToolUse 路径独占 AskUQ**。如果用户的 allow 列表没把 `AskUserQuestion` 加白，CC 还会另外发一次 `PermissionRequest` —— `AppDelegate.handleEvent` 里那条早期 `if event.toolName == "AskUserQuestion"` 自动 allow，避免老的"只读预览"块叠在新的可点击块后面。

### 失败流

```
bridge 连接 /tmp/zackeyes.sock 失败（App 未运行）
  → bridge exit(0) 且不写 stdout
  → 白名单生命周期事件（SessionStart/End、Stop、UserPromptSubmit、Notification、compact/subagent）先落盘 ~/.zackeyes/pending/（200 个上限 / 24h 过期，写盘失败同样静默）
  → Claude Code 视为无 hook 偏好，回退到终端审批 / 正常继续
```

### Rate-limit 数据流

```
Claude Code 周期性触发 statusLine command（每隔几秒）
  → bridge --event StatusLine
    → bridge 读 stdin（含 .rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}）
    → bridge fire-and-forget 转发到 socket
    → bridge stdout 返回空（不污染 statusline）
  → SocketServer 路由到 AppDelegate.handleEvent
    → UsageTracker.updateFromHook(rateLimits:) 解析并保存
    → SwiftUI 视图响应式更新（进度条 + 剩余百分比 + reset 倒计时）
```

⚠️ 与其他 statusLine 工具冲突时，HookInstaller 会**保留对方的安装**，不强占。没有第三方 statusLine 时，可选的 `~/.zackeyes/bin/statusline-user` 可作为用户自定义显示脚本；ZackEyes mux 会把同一份 stdin 同时喂给后台 bridge 和该脚本，并只透出用户脚本的 stdout。

### Simulated Notch 状态机

```
                    hover intent (250ms dwell)
        compact ─────────────────────────────────► full
          ▲                                          │
          │                              mouse leave (350ms grace)
          │                                          │
          │           tap (alternative)              │
          └──────────────────────────────────────────┘
```

`hoverWide` 是中间过渡态（保留代码以便未来按需使用）。当前主路径是 `compact ⇄ full`。
为避免上下排列的多屏幕跨屏误触，compact hover 使用共享的
`HoverIntentTracker`：鼠标在热区内稳定停留 250ms 才展开，8pt 以上的
持续移动会重置停留计时，离开热区则取消。真刘海和模拟刘海共用同一策略。

**可见性三态**（`#48`，存储于 `ConfigStore.notchVisibility`，缺省或解析失败时回退 `.always`）：

| 值 | 行为 |
|----|------|
| `.always`（默认） | Compact pill 始终在屏 |
| `.whenActive` | 仅当 ≥1 个会话存在时显示；最后一个会话结束时 AppDelegate 在 empty↔non-empty 边界（boundary-guard 防抖）调用 `applyVisibility(.whenActive)` 自动隐藏 |
| `.hidden` | 面板不可见，仅 hotkey / 菜单 / 事件唤起 |

`.whenActive`（及 `.hidden`）**不压制** `forceUiExpand`：PermissionRequest 和错误始终强制显示面板，避免用户失去对正在运行命令的审批入口。
Full 模式下：
- 高度按 session 数量 + 内容（prompt / reply / tool / tasks / errors / permission）启发式估算
- 内容变化时 debounced 120ms 重新计算高度并平滑动画
- 上限为 `screen.visibleFrame.height - 40`，超过则内部 ScrollView 滚动

### Pricing 数据流

```
PricingStore.start()
  → loadInitial(): max(version) of {bundled pricing.json, ~/.zackeyes/pricing-cache.json}
  → 24h Timer + 即刻一次: URLSession GET raw pricing.json
        → version 严格更新才 atomic 写缓存 + swap table；否则静默保持
消费方（后续 #84）: pricingStore.price(for: rawModelID) → ModelPrice?
```

## 模块职责

| 模块 | 文件 | 职责 |
|------|------|------|
**共享层**
| 模块 | 文件 | 职责 |
|------|------|------|
| `EventProtocol` | `Sources/Shared/EventProtocol.swift` | `BridgeEvent`（含 `rate_limits` / `lastAssistantMessage` / `bridgePpid` / `userPrompt` 透传）、`PermissionResponse`（`allow` / `deny` / `answer`）、`AnyCodable` |

**Bridge**
| 模块 | 文件 | 职责 |
|------|------|------|
| `SocketClient` | `Sources/BridgeLib/SocketClient.swift` | Unix Socket 客户端，`sendFireAndForget` / `sendAndWaitForResponse` |
| `PendingEventQueue` | `Sources/BridgeLib/PendingEventQueue.swift` | #89 写侧：socket 发送失败时白名单生命周期事件落盘 `<ms>-<pid>-<uuid>.json`；200 个上限裁剪最旧；一切失败静默（invariant #2） |
| `Bridge main` | `Sources/Bridge/main.swift` | CLI 入口。读 stdin、注入 `_bridge_event` + `_bridge_ppid`、按事件类型阻塞或非阻塞 |

**Socket / Session 核心**
| 模块 | 文件 | 职责 |
|------|------|------|
| `SocketServer` | `Sources/AppLib/Socket/SocketServer.swift` | 监听 `/tmp/zackeyes.sock`，`PermissionRequest` 连接保持到用户决策 / POLLHUP / 超时 |
| `SessionStore` | `Sources/AppLib/Session/SessionStore.swift` | 按 `session_id` 索引的多 session 状态机，含 `aggregateState` / `primarySession` / 错误检测。`SessionInfo.agent: AgentKind` 标记每个 session 的 agent。`recordCodexTaskComplete(...)` 处理来自 jsonl tailer 的 turn 完成事件。**#76 端口归属**：`SessionInfo.listeningPorts` 由 `applyListeningPorts(_:)` 写入，扫描根 pid 由纯函数 `portScanRoots(_:)` 决定——**只认 hook 的 `_bridge_ppid`**（`claudePidFromHook == true`），与 liveness 同一道闸（CLAUDE.md 铁律 #7 / #217）：`activateDetectedSessions` 猜的那个同 cwd 兄弟进程可以用来跳终端，但不能用来认领端口，否则会把别人的 dev server 印在这张卡上。`applyListeningPorts` 会把**结果里缺席的 session 一并清空**（这一 tick 没测到就不能继续声称它开着端口），因此调用方在快照失败时必须整个跳过、不能传 `[:]`。 |
| `SessionScanner` | `Sources/AppLib/Session/SessionScanner.swift` | 扫描 `~/.claude/projects/*.jsonl` + `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` 导入既有会话。两个 agent **使用独立 recency 窗口**（claude 默认 8h，codex 默认 30 min）。Codex 路径按 UTC 日期裁剪只走候选日期子目录；#83 起每 60s 随 sweep 重扫 Claude transcript（claude-only、活性过滤、ps 失败跳过本轮、未变化跳过），hook 缺失时启动后新会话 ≤60s 可见 |
| `LivenessFilter` | `Sources/AppLib/Session/LivenessFilter.swift` | 纯函数：根据 `cwd` → 运行中 `claude` 进程 map 决定哪些 detected session 还活着。Codex session 直接 pass-through 不参与（暂无 `runningCodexCwds()`）。 |
| `CodexJsonlTailer` | `Sources/AppLib/Session/CodexJsonlTailer.swift` | kqueue 实时监控 `~/.codex/sessions/*/rollout-*.jsonl`，看到 `event_msg.task_started` 即标记 working，看到用户可见的 `event_msg.task_complete` 即触发通知（内部审批 / 空结果不响），看到 `event_msg.token_count.info` 即更新 popup 的 per-session context bar，看到 `event_msg.error`（usage-limit hit / API 错误，带 `message` + `codex_error_info`）即 `recordCodexError` 弹错误横幅 + 通知 + 强制展开。**Codex hooks 不投递 error 事件，jsonl 是唯一来源**，所以 error 路径对 `.live`（已挂 hook）session 也照样上报（不像 task_complete 对 `.live` 跳过）。**用于覆盖那些启动早于 hooks 安装的 codex TUI**——它们永远不会 fire hook，但会持续写 jsonl。 |
| `PendingEventReplayer` | `Sources/AppLib/Session/PendingEventReplayer.swift` | #89 读侧：启动时按时间序补播 pending 事件进 handleEvent（isReplayed 抑制过期通知），24h 过期丢弃，文件一律消费删除 |
| `TaskExtractor` | `Sources/AppLib/Session/TaskExtractor.swift` | 解析 Claude transcript 重建任务列表，按用户 prompt 边界重置（只显示当前 turn）。Codex transcript schema 不同，目前不重建 task 列表。 |

**配置**
| 模块 | 文件 | 职责 |
|------|------|------|
| `HotKeyConfig` | `Sources/AppLib/Config/HotKeyConfig.swift` | 快捷键配置模型 + `HotKeyModifiers` OptionSet（Carbon/NSEvent flag 互转、Codable 字符串数组、显示符号） |
| `ConfigStore` | `Sources/AppLib/Config/ConfigStore.swift` | 读写 `~/.zackeyes/config.json`，原子写入，解析失败回退默认值 |
| `TimeProgressMode` | `Sources/AppLib/Config/TimeProgressMode.swift` | 配额窗口时间进度展示模式：Off / Icon / Overlap，默认 Off |
| `ProgressMode` | `Sources/AppLib/Config/ProgressMode.swift` | 配额展示偏好：Used / Left，Left 可选左到右或右到左；同文件定义 Overlap 内部不透明度默认40%、10%档位归一化，以及边框不透明度；读取兼容预发布版旧配置值 |

**设置窗口**
| 模块 | 文件 | 职责 |
|------|------|------|
| `SettingsWindowController` | `Sources/AppLib/Settings/SettingsWindowController.swift` | 单例、非模态的标准 macOS 设置窗口；首次 `show()` 才创建 SettingsViewModel / 读取配置；重复打开聚焦既有窗口，不阻塞权限 socket；获得焦点时用 floating level 可靠置前，失焦后降到 normal 避免遮挡其它应用 |
| `SettingsViewModel` | `Sources/AppLib/Settings/SettingsViewModel.swift` | 统一加载/保存 `ConfigStore` 偏好并发送既有运行时通知；聚合 Hook Health |
| `SettingsRootView` | `Sources/AppLib/Settings/SettingsRootView.swift` | General / Appearance / Notifications / Integrations / About 五分区设置 UI；沿用 About 卡片的深色表面、activity 强调色和半透明描边；General 支持 Preferred quota source、Progress mode、Left 填充方向、Window elapsed、Overlap 透明度和 Today's consumption；首选 Agent 无配额数据时自动回退另一方 |

**Hook 安装**
| 模块 | 文件 | 职责 |
|------|------|------|
| `HookInstaller` | `Sources/AppLib/Hooks/HookInstaller.swift` | Claude 路径——静默安装/卸载 `~/.claude/settings.json` 的 `hooks` + `statusLine`，备份保护，附加合并，支持可选 `~/.zackeyes/bin/statusline-user` 显示扩展，所有变更含 `zackeyes` 标识 + `--agent claude` flag；重装为 no-op 时跳过备份与写入（幂等，防 backup 刷屏）；卸载亦先备份 + no-op 跳过（#46） |
| `CodexHookInstaller` | `Sources/AppLib/Hooks/CodexHookInstaller.swift` | Codex 路径——静默安装/卸载 `~/.codex/hooks.json` 的 6 个事件，命令含 `--agent codex`。同样的备份 / 解析失败不动 / 用户内容保留契约。**不读不写 `~/.codex/config.toml`**（codex 默认开 hooks）；重装为 no-op 时跳过备份与写入（幂等，防 backup 刷屏）；卸载亦先备份 + no-op 跳过（#46） |
| `IntegrationUninstaller` | `Sources/AppLib/Hooks/IntegrationUninstaller.swift` | #46 完整卸载：只读 `preview()` 复用 installer 检测内核（与 `execute()` 不漂移）+ 尽力 `execute()`（双 `uninstallHooks()` + 清除 bridge/mux/.app-path/.statusline-original/pending）。保留第三方条目、config.json、pricing-cache.json、statusline-user；不碰 codex config.toml。 |
| `HookHealth` | `Sources/AppLib/Hooks/HookHealth.swift` | 只读健康检查（#38）：claude/codex hook 条目完整性、bridge launcher 可执行、launcher 解析是否指向当前 bundle、socket 存在性、statusLine 归属分类（direct/mux/userRenderer/thirdParty/absent/unreadable）。复用 installer 的事件表与条目识别，绝不写任何文件。 |
| `HookRepair` | `Sources/AppLib/Hooks/HookRepair.swift` | 共享修复入口 = deployLauncherScript + 双 installer 重装；AppDelegate 启动与 Hook Status 窗口 Repair 按钮共用。 |

**Notch UI（真刘海机型）**

架构直接参照两个事实标准的开源 Mac Dynamic Island 实现 —— 改这块代码前**必看**它们的对应文件：

- [boring.notch](https://github.com/TheBoredTeam/boring.notch)（`boringNotchApp.swift` / `components/Notch/BoringNotchWindow.swift` / `sizing/matters.swift` / `models/BoringViewModel.swift`）
- [DynamicIsland_Mac](https://github.com/NKR00711/DynamicIsland_Mac)（`DynamicIslandApp.swift` / `components/Notch/DynamicIslandWindow.swift` / `models/DynamicIslandViewModel.swift`）

两家的关键约定（我们已采纳，偏离必有理由）：

- **NSPanel styleMask**: `[.borderless, .nonactivatingPanel]`（实测：`.utilityWindow`/`.hudWindow` 会引入 title-bar inset，把内容往下挤，且无收益 —— `#64`）
- **level**: `CGShieldingWindowLevel()`，且**必须在 `isFloatingPanel = true` 之后设置**。`isFloatingPanel = true` 会把 level 打回 `.floating`（raw 3，**低于**菜单栏），导致面板渲染在刘海**下方**一条菜单栏的位置（`#64` 真机症状）。`.mainMenu + 3` 在没有 SkyLight NotchSpace 注入时无法盖住菜单栏；`SimulatedNotchPanel` 与真刘海 `NotchPanel` 现在统一用 `CGShieldingWindowLevel()`。
- **constrainFrameRect override**: 两个 panel 都覆写 `constrainFrameRect` 返回原 frame —— 否则 AppKit 会把顶边贴菜单栏上方的窗口往下推。
- **窗口尺寸固定**: 一次性设为 expanded 尺寸，此后不 resize；SwiftUI 内部按 `panelState` 切换 compact pill / 完整面板
- **定位公式**: `y = screen.frame.maxY - window.height`（窗口顶边贴屏幕顶）
- **Notch 探测**: `screen.safeAreaInsets.top > 0` + `notchWidth = frame.width - auxiliaryTopLeftArea.width - auxiliaryTopRightArea.width + 4`
- **屏幕选择**（`#64`）: 真刘海路径的判定与锚定用 `NSScreen.hasAnyNotch` / `NSScreen.withNotch`（"任一连接屏有刘海"），**不是** `NSScreen.main?.hasNotch`——`NSScreen.main` 跟随键盘焦点，外接显示器有 key window 时会指向无刘海的外接屏，导致真刘海机误走 simulated 路径或把面板锚到外接屏。`NotchWindowController.notchScreen()` 仅返回刘海屏（无则 nil），合盖/clamshell 下不再把 0 高度隐形面板贴到外接屏。
- **NotchShape**（`#64`）: 平顶 + 顶部外角向屏幕边缘外扩 + 圆底的灵动岛轮廓（照搬 DynamicNotchKit / boring.notch），真刘海与模拟刘海共用（模拟侧用 `init(cornerRadius:)` 退化成纯圆底，保持原样）。紧凑态用中间留 `notchSize.width` 空档、两侧放 5h/7d chips 的方式贴住物理刘海。

| 模块 | 文件 | 职责 |
|------|------|------|
| `NotchPanel` | `Sources/AppLib/Notch/NotchPanel.swift` | NSPanel 子类，刘海区域覆盖层 |
| `NotchWindowController` | `Sources/AppLib/Notch/NotchWindowController.swift` | 位置锚定、状态切换、鼠标追踪（固定窗口，不帧动画） |
| `NotchViewModel` | `Sources/AppLib/Notch/NotchViewModel.swift` | 桥接 `SessionStore` → SwiftUI；转发嵌套 `objectWillChange` |
| `NotchCompactView` | `Sources/AppLib/Notch/NotchCompactView.swift` | 折叠 / 紧凑状态视图；固定宽状态位按错误（红）→待用户（黄）→工作/空闲排序，多项注意事件显示数量；配额百分比保持无后缀的紧凑形式 |
| `NotchExpandedView` | `Sources/AppLib/Notch/NotchExpandedView.swift` | 完整 popover：按 Needs You / Running / Recent 分组（有其它分组时 Recent 默认折叠，仅剩 Recent 时自动展开）；会话卡片以项目名为主身份、Buddy 为辅助，同名可见项目追加短 session id；保留 tasks、permission、错误和 AskUserQuestion 内容 |
| `AgentBadge` | `Sources/AppLib/Notch/AgentBadge.swift` | 14×14 SwiftUI 角标：`[CLAUDE]` 紫色 / `[CODEX]` 绿色。也提供 `accentColor(for:)` 给其它视图染色（split usage bar / 通知标题映射）。 |
| `PortBadge` | `Sources/AppLib/Notch/PortBadge.swift` | #76 端口角标 `:3000`。多端口收敛成 `:3000 +2`（卡片一行已有项目名/agent/risk/耗时，不能被挤掉），取**最小**端口打头——它是用户认得的那个，不是框架顺带开的临时端口。`label(for:)` 为纯函数，无端口时返回 nil（不占位）。 |
| `BuddyAvatar` | `Sources/AppLib/Notch/BuddyAvatar.swift` | 动画化 buddy（headbang / 睡觉 / 惊慌）；自动尊重 macOS Reduce Motion，关闭无限动画但保留静态状态表达 |
| `Buddy` | `Sources/AppLib/Notch/Buddy.swift` | 摇滚传奇命名池（66 个）+ 性格标语池 |
| `PixelAvatar` | `Sources/AppLib/Notch/PixelAvatar.swift` | 9 种 8×8 像素图案 + 8 色摇滚配色 |
| `HotkeyRecorderView` | `Sources/AppLib/Notch/HotkeyRecorderView.swift` | SwiftUI 快捷键录入 overlay，NSEvent local monitor 捕获按键，验证 modifier |

**Simulated Notch（无刘海机型）**
| 模块 | 文件 | 职责 |
|------|------|------|
| `SimulatedNotchPanel` | `Sources/AppLib/SimulatedNotch/SimulatedNotchPanel.swift` | 顶部居中 NSPanel，`.screenSaver` 层级 |
| `SimulatedNotchView` | `Sources/AppLib/SimulatedNotch/SimulatedNotchView.swift` | Compact / hoverWide 内容（无文字后缀的 5h/7d 配额 + NotchShape）。读 `NotchModeStore.compactAgent` 决定显示哪个 agent 的配额 |
| `SimulatedNotchFullView` | `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` | Full 模式：5h/7d 进度条 header + 滚动 session 列表。当两 agent 都有数据时，header 自动左右切割（左 Claude / 右 Codex），用固定宽 gear 列保证 5h 与 7d 两行轨道对齐 |
| `SimulatedNotchController` | `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift` | 三态形变控制器，hover intent 进入 full，外部点击退出，内容自适应高度。启动时从 `ConfigStore.loadCompactAgent()` 注水 `modeStore.compactAgent` 避免首帧闪烁；`#48` 起 `applyVisibility` 支持 `.whenActive` 自动显隐 |
| `SimulatedNotchRoot` | `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift` | SwiftUI 根视图，compact/full 保持稳定 identity 以保留 Recent/recap/滚动状态；隐藏 Full 时取消 1s Timer 订阅并停止 Buddy 无限动画；透明尺寸骨架保持转场锚点稳定。`NotchModeStore` 含 `@Published compactAgent: AgentKind` |

**菜单栏 fallback**
| 模块 | 文件 | 职责 |
|------|------|------|
| `MenuBarFallback` | `Sources/AppLib/MenuBar/MenuBarFallback.swift` | sparkles 状态栏图标 + NSPopover；外部点击监听器自动关闭 |
| `HookStatusWindow` | `Sources/AppLib/MenuBar/HookStatusWindow.swift` | Hook Status 卡片（KeyablePanel + SwiftUI，仿 AboutWindow）：6 行健康状态 + Repair Hooks 按钮；状态栏右键菜单与齿轮菜单共用同一实现。 |
| `UninstallWindow` | `Sources/AppLib/MenuBar/UninstallWindow.swift` | #46 卸载确认卡片：预览将移除项 → Remove Integrations → 完成态可选 Quit / 继续运行（重新启动会自动重装集成）。两个菜单入口（状态栏右键菜单与齿轮菜单）共用。 |
| `Redactor` | `Sources/AppLib/Diagnostics/Redactor.swift` | #47 纯文本脱敏：home→`~`、用户名→`<user>`，注入式无 I/O，完全可测试。过度脱敏（短用户名）是安全方向——绝不为了美观而放宽，以防真实用户名泄漏。 |
| `DiagnosticsReport` | `Sources/AppLib/Diagnostics/DiagnosticsReport.swift` | #47 隐私安全诊断报告（固定 schema）：版本/OS/arch + HookHealth 布尔值 + 用量新鲜度，复用 `HookHealth`。唯一自由文本字段（statusLine 第三方命令）经 `Redactor` 脱敏；绝不含 prompt/assistant/工具参数/完整配置内容。`generate` 纯函数（依赖注入），`current()` 为薄 `@MainActor` 聚合层。 |
| `DiagnosticsWindow` | `Sources/AppLib/MenuBar/DiagnosticsWindow.swift` | #47 导出审阅窗口（`KeyablePanel` 仿 `HookStatusWindow`）：滚动展示脱敏报告 + Copy/Save…/Close，用户分享前可先审阅内容。两菜单"Export Diagnostics…"共用同一实例。 |

> **统一应用菜单**：物理刘海、模拟刘海的齿轮与状态栏图标右键都调用同一个 `StatusBarMenu.build()`。默认提供 Settings / About / Quit 三项，有可用更新时在顶部追加 Update；Settings 仍由 `AppDelegate` 持有的单例 `SettingsWindowController` 打开。菜单只保留应用级命令，不复制偏好设置。

**全局功能**
| 模块 | 文件 | 职责 |
|------|------|------|
| `AppColors` | `Sources/AppLib/Design/AppColors.swift` | 全局功能语义色唯一来源，同时提供 SwiftUI `Color` 与 AppKit `NSColor`：Activity、Information、Time Overlay、Attention、Critical、Success、Idle、No Data 和 Claude/Codex Identity；Buddy/F1 装饰色不纳入状态语义 |
| `HotKeyManager` | `Sources/AppLib/HotKey/HotKeyManager.swift` | Carbon `RegisterEventHotKey` 注册全局快捷键（可配置，默认 `Cmd+Shift+Z`），支持运行时 `reregister` 热更新 |
| `NotificationManager` | `Sources/AppLib/Notifications/NotificationManager.swift` | 时间敏感通知（session 完成 / API 错误 / 版本更新），点击跳转终端或打开 GitHub |
| `UpdateChecker` | `Sources/AppLib/Update/UpdateChecker.swift` | 轮询公开发布仓库（6h）获取最新 DMG，语义版本比较，`@Published dmgURL` 驱动齿轮红点 + 系统通知；`checkNow()` 手动检查入口（`#48`） |
| `UpdateDownloader` | `Sources/AppLib/Update/UpdateDownloader.swift` | URLSession 下载 DMG 到 `$TMPDIR`，通过 NSWorkspace 打开使 Finder 挂载；状态栏菜单 + 齿轮菜单 + 通知点击均通过此下载器 |
| `TerminalLocator` | `Sources/AppLib/Terminal/TerminalLocator.swift` | 进程树**向上**遍历 + iTerm2/Terminal AppleScript + Ghostty/Warp/Kitty Accessibility |
| `ProcessTreeInspector` | `Sources/AppLib/Process/ProcessTreeInspector.swift` | #81 进程树**向下**枚举 + 每进程 LISTEN 端口。纯内核 syscall、**零子进程**：进程表走 `sysctl KERN_PROC_ALL`（一次 syscall 拿全表 ~1.4ms），端口走 `proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`，按 `SOCKINFO_TCP` + `tcpsi_state == TSI_S_LISTEN` 过滤、`insi_lport` 按网络字节序还原。**刻意不用 issue 原定的 `ps` + `lsof -i`**：实测两者 ~116ms / ~180ms 且各起一次 fork+exec，而本实现算完全部会话 ~3ms，因此可直接搭 60s liveness sweep，不需要懒触发 + 缓存层（红线「禁止进轮询」随之失效）。**进程表不用 `proc_listpids` + `PROC_PIDTBSDINFO`**：后者按进程需同 uid 或 root，实测隐藏 974 个进程里的 349 个（36%），含 setuid root 的 `/usr/bin/login`——它位于每个终端会话的祖先链上，会把进程树切成孤岛。`Snapshot.descendants(of:limit:)` 是纯函数（BFS + visited 防 pid 复用成环 + 数量上限），可用合成表测试。**已知盲区**：`proc_pidfdinfo` 拒绝描述硬化/SIP 进程的 fd（实测系统级 21 个监听端口里看不到 2 个，均为 `ControlCenter`）——不影响本用途，因为只走 agent 自己的子树，系统守护进程永远不是 `claude`/`codex` 的后代。**刻意不做**：spawn shell 退出后 dev server 会被 launchd 收养、脱离任何会话子树，这类「孤儿端口」无法用任何基于 pid 的方法归属，故不猜。 |
| `UsageTracker` | `Sources/AppLib/Usage/UsageTracker.swift` | 双 agent 配额。Claude 数据来自 statusLine hook 的 `rate_limits.{five_hour,seven_day}`；Codex 数据来自周期扫描 `~/.codex/sessions/` rollout 的 `event_msg.token_count.rate_limits.{primary,secondary}`。**采集活跃度与额度有效期解耦**：15 min rollout mtime 窗口只用于发现新读数；Codex 空闲、没有新 rollout 时保留最后可信读数，并按 5h/7d 各自 `resets_at` 独立失效。`codexLastUpdated` 记录实际供应读数的 rollout mtime，重复扫描不会伪装成刚更新，UI 超过 15 min 后通过 freshness 警告标记陈旧。**跨并发 rollout 合并**：`firstActiveCodexReadings` 把 15 min 内所有活跃 rollout 的 scope 按 `limit_name` 合并，同名 scope 取 per-axis 非过期最大值——防止某个高频写 0% 的 per-model session（如 gpt-5.5 的 `GPT-5.3-Codex-Spark`）盖住另一个安静 session 写的真实账号用量。**账号级安全网**：5h/7d 百分比只在存在账号级 scope（空 `limit_name`，或缓存种子）时才可信；若当前只有 per-model scope（gpt-5.5 的账号 scope 在 rollout 里恒为 null），百分比留 nil（显示「—」/隐藏），**绝不把 per-model 0% 渲染成「100% 剩余」**。账号真实 5h/7d 仅存在于 codex 收到的响应头（`x-codex-*-used-percent`，落在 `~/.codex/logs_2.sqlite` DEBUG 日志或 app-server `account/rateLimits/read`），codex 不写进 rollout——刻意不接这两个重源（log DB 抓取 / 进程 spawn）以保持 widget 轻量，缺账号数据时诚实显示未知。`codexLimitReached`（out-of-credits `balance:"0"` / `rate_limit_reached_type` / 窗口 100%）独立于百分比，单独驱动「limit reached」徽标。Snapshot 含 claude + codex 平行字段，UI 按需呈现单条或左右切。 |
| `UsageProgressTrack` | `Sources/AppLib/Usage/UsageProgressTrack.swift` | 共享 5h/7d 配额轨道：Used / Left 与 Left 方向统一驱动额度和时间填充；Icon/Overlap 每30s更新；Overlap 使用可设的浅灰时间层（默认不透明度40%）及同色1px边框（比填充层低15个百分点），时间长于用量时在下层，否则在上层（含相等），不用于 session context bar |
| `PricingStore` / `PricingTable` | `Sources/AppLib/Usage/PricingStore.swift`、`PricingTable.swift` | 模型→单价查询（`price(for:)`）。`PricingTable` 纯解析+查找（exact→去日期后缀→alias→nil，仅接受原始 model id）；`PricingStore` 按 `version` 在 bundled 快照 / 磁盘缓存 / 24h 远端拉取间择新，失败静默。无 UI。 |
| `TodayConsumptionRow` | `Sources/AppLib/Usage/TodayConsumptionRow.swift` | #84 消费轴（与 5h/7d 配额轴分开）：full-view header 的 "Today" 行——今日 token + $ + 近 7 日 token sparkline + 每 agent 副行。纯静态格式化助手（humanize / cost / sparkline，`nonisolated`）+ 只读视图。数据来自 `UsageTracker.Snapshot.dailyUsage`（7 个本地日桶；Claude 侧 `computeSnapshot` 递归全 projects 树扫 transcript——含 `<session>/subagents/` 与 Workflow 工具的 `<session>/wf_*/` agent 文件，#116——并按 `(mtime,size)` per-file 缓存解析；Codex 侧缓存式 `scanCodexDailyTokens`；cost 在主 actor 用 `PricingStore` 折算）。嵌入 `UsageBarsView`（真刘海）与 `SimulatedNotchFullView.usageHeader`（模拟），`hasConsumption` 为空时隐藏；由齿轮菜单「Show today's consumption」开关控制（默认开，flag 在 `UsageTracker.showTodayConsumption`，持久化 `ConfigStore`，两个面板响应式）。**收起的 compact pill 始终只显示 5h/7d 配额，不显示消费**（产品决策）。 |

**App 入口**
| 模块 | 文件 | 职责 |
|------|------|------|
| `AppDelegate` | `Sources/ZackEyes/AppDelegate.swift` | 启动 / 路由 / 通知 / 禁用 macOS auto-termination |
| `main.swift` | `Sources/ZackEyes/main.swift` | NSApplication 启动 |

## Release distribution

Source code lives in **`yangshiqi/ZackEyes` (private)**; release artifacts (DMG) are published to **`yangshiqi/ZackEyes-release` (public)** so the in-app update checker can poll and download without requiring a GitHub token.

`make release VERSION=x.y.z` runs both: it tags and creates an empty release on the source repo (internal record), then `gh release create --repo yangshiqi/ZackEyes-release --target main` uploads the DMG to the public repo.

`UpdateChecker` polls `/repos/yangshiqi/ZackEyes-release/releases/latest` every 6 hours, parses `assets[]` for the first `.dmg`, and publishes its `browser_download_url` via `@Published dmgURL`. `UpdateDownloader` runs `URLSession.download` to `$TMPDIR/ZackEyes-x.y.z.dmg`, then `NSWorkspace.open` so Finder mounts the disk image and shows the drag-to-Applications layout. Both menu surfaces (status-bar right-click and simulated-notch gear menu) and the system notification tap route through the downloader.

## 安全模型

### Bridge 防御性设计

| 场景 | 行为 | Exit Code |
|------|------|-----------|
| 正常响应（权限决策） | stdout 输出 JSON | 0 |
| Socket 不存在 / App 未运行 | 静默退出（无 stdout）；白名单生命周期事件先落盘 pending 队列 | **0** |
| Socket 连接超时 | 静默退出（无 stdout） | **0** |
| stdin 为空 / JSON 解析失败 | 静默退出 | **0** |
| args 错误 | 静默退出 | **0** |
| Bridge 崩溃 | 静默退出 | 非 0（不可控） |
| 阻塞 Claude Code | **永远不会发生** | 永不使用 2 |

**铁律**: Bridge 的任何路径只要走到退出都返回 0（除了进程崩溃这种不可控情况）。Claude Code 的新版本会把任何非 0 退出码显示成 "hook error"，会污染用户终端；我们宁可丢事件也不弄脏显示。
- PermissionRequest socket 不通时 exit 0 且不写 stdout → Claude Code 视为"无 hook 偏好" → 回退到原生终端授权弹窗，行为正确。
- 其他 fire-and-forget hook socket 不通时就当这次事件没发生；App 重启后先补播 pending 队列，再靠 `SessionScanner` 做 catch-up sweep。

### Hook 注入安全

1. 写入前备份: `settings.json.backup.{timestamp}`（安装与卸载的每次写入均先备份）
2. 只追加 `hooks` key，不碰 `permissions` / `enabledPlugins` / `defaultMode` / `theme` 等
3. JSON 解析失败 → 不修改原文件
4. 我们的条目通过 command 路径中的 `zackeyes` 字符串可识别
5. 卸载时精确移除我们的条目，不影响其他 hooks

### 诊断导出安全

- **用户主动触发**：仅在"Export Diagnostics…"菜单项点击时生成，无自动触发、无定时器、不联网。
- **固定 schema**：只含版本/OS/arch + HookHealth 布尔摘要 + 用量时间戳，无会话内容。
- **脱敏**：home 路径压缩为 `~`，用户名替换为 `<user>`（`Redactor`）；唯一自由文本字段（statusLine 第三方命令路径）同样经过脱敏。
- **不含敏感内容**：绝不输出 prompt / assistant 回复 / 工具参数 / 完整配置文件内容。
- **不外发**：报告仅写到剪贴板或用户选定的本地文件，App 自身不上传。

### NotchPanel 安全

- `nonActivatingPanel` — 永不抢焦点
- `ignoresMouseEvents = true`（collapsed/compact）— 不挡菜单栏
- `canBecomeMain = false` — 不进入窗口循环
- `isMovable = false` — 不随 Space 切换漂移
- `.ignoresCycle` — 不出现在 Cmd+Tab 中

## 性能约束

| 指标 | 目标 |
|------|------|
| 内存 | < 30MB |
| CPU 空闲 | ~0%（事件驱动，socket accept 阻塞） |
| Bridge 单次 | < 10ms（连接 + 发送 + 断开） |
| UI 更新 | 仅状态变化时重绘 |

## 项目结构

> **技术债**: MVP 使用 SPM + Makefile 替代了设计文档中原定的 Xcode project。正式版前应迁回 Xcode project（详见 `.claude/memory/`）。

```
ccisland/
├── Package.swift               # SPM manifest (5 targets + 3 test targets)
├── Makefile                    # .app bundle 组装 + ad-hoc 签名
├── Resources/Info.plist        # LSUIElement, NSSupportsAutomaticTermination=false
├── Sources/
│   ├── Shared/                 # BridgeEvent, PermissionResponse, AnyCodable
│   ├── BridgeLib/              # SocketClient
│   ├── Bridge/                 # Bridge CLI 入口
│   ├── AppLib/
│   │   ├── Socket/             # SocketServer
│   │   ├── Session/            # SessionStore, SessionScanner, TaskExtractor
│   │   ├── Config/             # HotKeyConfig, ConfigStore (~/.zackeyes/config.json)
│   │   ├── Hooks/              # HookInstaller
│   │   ├── Notch/              # NotchPanel, Buddy, PixelAvatar, HotkeyRecorderView
│   │   ├── SimulatedNotch/     # 无刘海机型的灵动岛
│   │   ├── MenuBar/            # MenuBarFallback
│   │   ├── Settings/           # 统一非模态设置窗口
│   │   ├── HotKey/             # HotKeyManager（可配置快捷键）
│   │   ├── Notifications/      # NotificationManager
│   │   ├── Process/            # ProcessTreeInspector (向下进程树 + LISTEN 端口)
│   │   ├── Terminal/           # TerminalLocator (tab 跳转)
│   │   ├── Update/             # UpdateChecker (GitHub 版本检测)
│   │   └── Usage/              # UsageTracker (5h/7d 限额)
│   └── ZackEyes/               # main.swift + AppDelegate
└── Tests/
    ├── SharedTests/
    ├── BridgeLibTests/
    └── AppLibTests/
```

**依赖**: 零外部依赖。纯 Foundation + AppKit + SwiftUI。

## Known Risks

详见 [设计文档](docs/superpowers/specs/2026-04-05-zackeyes-mvp-design.md#known-risks):
- PermissionRequest hook 事件未在官方文档列出（已通过外部实践验证可行）
- PermissionRequest 响应格式基于逆向推断
- 已准备 PreToolUse `permissionDecision` 作为 fallback 方案
