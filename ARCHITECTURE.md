# ARCHITECTURE.md

## 项目定位

ZackEyes 是 macOS 原生应用，将 MacBook 刘海（Dynamic Island）区域变为 AI 编码代理的实时控制面板。**自 v0.3.0 起同时支持 Claude Code 和 OpenAI Codex CLI**，两边会话并存于同一刘海面板。定位为 Vibe Island 的免费替代品。

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
| **Bridge CLI** | `Bridge/` → 嵌入 `ZackEyes.app/Contents/Helpers/bridge` | 被 Claude Code 和 Codex CLI hook 调用，解析 `--event` + `--agent`，转发事件到主 App，返回权限决策 | 不含 UI 逻辑，不直接读写用户配置文件 |
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

⚠️ 与其他 statusLine 工具（如 Vibe Island）冲突时，HookInstaller 会**保留对方的安装**，不强占。没有第三方 statusLine 时，可选的 `~/.zackeyes/bin/statusline-user` 可作为用户自定义显示脚本；ZackEyes mux 会把同一份 stdin 同时喂给后台 bridge 和该脚本，并只透出用户脚本的 stdout。

### Simulated Notch 状态机

```
                      hover (mouse near notch)
        compact ─────────────────────────────────► full
          ▲                                          │
          │                              mouse leave (350ms grace)
          │                                          │
          │           tap (alternative)              │
          └──────────────────────────────────────────┘
```

`hoverWide` 是中间过渡态（保留代码以便未来按需使用）。当前主路径是 `compact ⇄ full`。
Full 模式下：
- 高度按 session 数量 + 内容（prompt / reply / tool / tasks / errors / permission）启发式估算
- 内容变化时 debounced 120ms 重新计算高度并平滑动画
- 上限为 `screen.visibleFrame.height - 40`，超过则内部 ScrollView 滚动

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
| `Bridge main` | `Sources/Bridge/main.swift` | CLI 入口。读 stdin、注入 `_bridge_event` + `_bridge_ppid`、按事件类型阻塞或非阻塞 |

**Socket / Session 核心**
| 模块 | 文件 | 职责 |
|------|------|------|
| `SocketServer` | `Sources/AppLib/Socket/SocketServer.swift` | 监听 `/tmp/zackeyes.sock`，`PermissionRequest` 连接保持到用户决策 / POLLHUP / 超时 |
| `SessionStore` | `Sources/AppLib/Session/SessionStore.swift` | 按 `session_id` 索引的多 session 状态机，含 `aggregateState` / `primarySession` / 错误检测。`SessionInfo.agent: AgentKind` 标记每个 session 的 agent。`recordCodexTaskComplete(...)` 处理来自 jsonl tailer 的 turn 完成事件。 |
| `SessionScanner` | `Sources/AppLib/Session/SessionScanner.swift` | 扫描 `~/.claude/projects/*.jsonl` + `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` 导入既有会话。两个 agent **使用独立 recency 窗口**（claude 默认 8h，codex 默认 30 min）。Codex 路径按 UTC 日期裁剪只走候选日期子目录。 |
| `LivenessFilter` | `Sources/AppLib/Session/LivenessFilter.swift` | 纯函数：根据 `cwd` → 运行中 `claude` 进程 map 决定哪些 detected session 还活着。Codex session 直接 pass-through 不参与（暂无 `runningCodexCwds()`）。 |
| `CodexJsonlTailer` | `Sources/AppLib/Session/CodexJsonlTailer.swift` | kqueue 实时监控 `~/.codex/sessions/*/rollout-*.jsonl`，看到 `event_msg.task_started` 即标记 working，看到 `event_msg.task_complete` 即触发通知。**用于覆盖那些启动早于 hooks 安装的 codex TUI**——它们永远不会 fire hook，但会持续写 jsonl。 |
| `TaskExtractor` | `Sources/AppLib/Session/TaskExtractor.swift` | 解析 Claude transcript 重建任务列表，按用户 prompt 边界重置（只显示当前 turn）。Codex transcript schema 不同，目前不重建 task 列表。 |

**配置**
| 模块 | 文件 | 职责 |
|------|------|------|
| `HotKeyConfig` | `Sources/AppLib/Config/HotKeyConfig.swift` | 快捷键配置模型 + `HotKeyModifiers` OptionSet（Carbon/NSEvent flag 互转、Codable 字符串数组、显示符号） |
| `ConfigStore` | `Sources/AppLib/Config/ConfigStore.swift` | 读写 `~/.zackeyes/config.json`，原子写入，解析失败回退默认值 |

**Hook 安装**
| 模块 | 文件 | 职责 |
|------|------|------|
| `HookInstaller` | `Sources/AppLib/Hooks/HookInstaller.swift` | Claude 路径——静默安装/卸载 `~/.claude/settings.json` 的 `hooks` + `statusLine`，备份保护，附加合并，支持可选 `~/.zackeyes/bin/statusline-user` 显示扩展，所有变更含 `zackeyes` 标识 + `--agent claude` flag |
| `CodexHookInstaller` | `Sources/AppLib/Hooks/CodexHookInstaller.swift` | Codex 路径——静默安装/卸载 `~/.codex/hooks.json` 的 6 个事件，命令含 `--agent codex`。同样的备份 / 解析失败不动 / 用户内容保留契约。**不读不写 `~/.codex/config.toml`**（codex 默认开 hooks）。 |

**Notch UI（真刘海机型）**

架构直接参照两个事实标准的开源 Mac Dynamic Island 实现 —— 改这块代码前**必看**它们的对应文件：

- [boring.notch](https://github.com/TheBoredTeam/boring.notch)（`boringNotchApp.swift` / `components/Notch/BoringNotchWindow.swift` / `sizing/matters.swift` / `models/BoringViewModel.swift`）
- [DynamicIsland_Mac](https://github.com/NKR00711/DynamicIsland_Mac)（`DynamicIslandApp.swift` / `components/Notch/DynamicIslandWindow.swift` / `models/DynamicIslandViewModel.swift`）

两家的关键约定（我们已采纳，偏离必有理由）：

- **NSPanel styleMask**: `[.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]`
- **level**: `.mainMenu + 3`（**不是** `.screenSaver` —— 那个 level 在菜单栏边缘行为不文档化）
- **窗口尺寸固定**: 一次性设为 expanded 尺寸，此后不 resize；SwiftUI 内部按 `panelState` 切换 compact pill / 完整面板
- **定位公式**: `y = screen.frame.maxY - window.height`（窗口顶边贴屏幕顶）
- **Notch 探测**: `screen.safeAreaInsets.top > 0` + `notchWidth = frame.width - auxiliaryTopLeftArea.width - auxiliaryTopRightArea.width + 4`

| 模块 | 文件 | 职责 |
|------|------|------|
| `NotchPanel` | `Sources/AppLib/Notch/NotchPanel.swift` | NSPanel 子类，刘海区域覆盖层 |
| `NotchWindowController` | `Sources/AppLib/Notch/NotchWindowController.swift` | 位置锚定、状态切换、鼠标追踪（固定窗口，不帧动画） |
| `NotchViewModel` | `Sources/AppLib/Notch/NotchViewModel.swift` | 桥接 `SessionStore` → SwiftUI；转发嵌套 `objectWillChange` |
| `NotchCompactView` | `Sources/AppLib/Notch/NotchCompactView.swift` | 折叠 / 紧凑状态视图 |
| `NotchExpandedView` | `Sources/AppLib/Notch/NotchExpandedView.swift` | 完整 popover：会话卡片、tasks、permission 审批、错误横幅、AskUserQuestion 选项卡。卡片右上角带 `AgentBadge`。 |
| `AgentBadge` | `Sources/AppLib/Notch/AgentBadge.swift` | 14×14 SwiftUI 角标：`[CLAUDE]` 紫色 / `[CODEX]` 绿色。也提供 `accentColor(for:)` 给其它视图染色（split usage bar / 通知标题映射）。 |
| `BuddyAvatar` | `Sources/AppLib/Notch/BuddyAvatar.swift` | 动画化 buddy（headbang / 睡觉 / 惊慌） |
| `Buddy` | `Sources/AppLib/Notch/Buddy.swift` | 摇滚传奇命名池（66 个）+ 性格标语池 |
| `PixelAvatar` | `Sources/AppLib/Notch/PixelAvatar.swift` | 9 种 8×8 像素图案 + 8 色摇滚配色 |
| `HotkeyRecorderView` | `Sources/AppLib/Notch/HotkeyRecorderView.swift` | SwiftUI 快捷键录入 overlay，NSEvent local monitor 捕获按键，验证 modifier |

**Simulated Notch（无刘海机型）**
| 模块 | 文件 | 职责 |
|------|------|------|
| `SimulatedNotchPanel` | `Sources/AppLib/SimulatedNotch/SimulatedNotchPanel.swift` | 顶部居中 NSPanel，`.screenSaver` 层级 |
| `SimulatedNotchView` | `Sources/AppLib/SimulatedNotch/SimulatedNotchView.swift` | Compact / hoverWide 内容（5h/7d 剩余 + NotchShape）。读 `NotchModeStore.compactAgent` 决定显示哪个 agent 的配额 |
| `SimulatedNotchFullView` | `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` | Full 模式：5h/7d 进度条 header + 滚动 session 列表。当两 agent 都有数据时，header 自动左右切割（左 Claude / 右 Codex），用固定宽 gear 列保证 5h 与 7d 两行轨道对齐 |
| `SimulatedNotchController` | `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift` | 三态形变控制器，hover 进入 full，外部点击退出，内容自适应高度。启动时从 `ConfigStore.loadCompactAgent()` 注水 `modeStore.compactAgent` 避免首帧闪烁 |
| `SimulatedNotchRoot` | `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift` | SwiftUI 根视图，compact/full 切换 + overlay 层叠。`NotchModeStore` 含 `@Published compactAgent: AgentKind` |
| `GearMenuTarget` | `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift` | NSMenu 动作目标（About / Change Hotkey / Theme / Compact display / Update） |
| `HostViewProbe` | `Sources/AppLib/SimulatedNotch/HostViewProbe.swift` | SwiftUI → NSView 桥接，用于齿轮菜单锚点定位 |

**菜单栏 fallback**
| 模块 | 文件 | 职责 |
|------|------|------|
| `MenuBarFallback` | `Sources/AppLib/MenuBar/MenuBarFallback.swift` | sparkles 状态栏图标 + NSPopover；外部点击监听器自动关闭 |

**全局功能**
| 模块 | 文件 | 职责 |
|------|------|------|
| `HotKeyManager` | `Sources/AppLib/HotKey/HotKeyManager.swift` | Carbon `RegisterEventHotKey` 注册全局快捷键（可配置，默认 `Cmd+Shift+Z`），支持运行时 `reregister` 热更新 |
| `NotificationManager` | `Sources/AppLib/Notifications/NotificationManager.swift` | 时间敏感通知（session 完成 / API 错误 / 版本更新），点击跳转终端或打开 GitHub |
| `UpdateChecker` | `Sources/AppLib/Update/UpdateChecker.swift` | 轮询公开发布仓库（6h）获取最新 DMG，语义版本比较，`@Published dmgURL` 驱动齿轮红点 + 系统通知 |
| `UpdateDownloader` | `Sources/AppLib/Update/UpdateDownloader.swift` | URLSession 下载 DMG 到 `$TMPDIR`，通过 NSWorkspace 打开使 Finder 挂载；状态栏菜单 + 齿轮菜单 + 通知点击均通过此下载器 |
| `TerminalLocator` | `Sources/AppLib/Terminal/TerminalLocator.swift` | 进程树遍历 + iTerm2/Terminal AppleScript + Ghostty/Warp/Kitty Accessibility |
| `UsageTracker` | `Sources/AppLib/Usage/UsageTracker.swift` | 双 agent 配额。Claude 数据来自 statusLine hook 的 `rate_limits.{five_hour,seven_day}`；Codex 数据来自周期扫描 `~/.codex/sessions/` 最新 rollout 的 `event_msg.token_count.rate_limits.{primary,secondary}`。Snapshot 含 claude + codex 平行字段，UI 按需呈现单条或左右切。 |

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
| Socket 不存在 / App 未运行 | 静默退出（无 stdout） | **0** |
| Socket 连接超时 | 静默退出（无 stdout） | **0** |
| stdin 为空 / JSON 解析失败 | 静默退出 | **0** |
| args 错误 | 静默退出 | **0** |
| Bridge 崩溃 | 静默退出 | 非 0（不可控） |
| 阻塞 Claude Code | **永远不会发生** | 永不使用 2 |

**铁律**: Bridge 的任何路径只要走到退出都返回 0（除了进程崩溃这种不可控情况）。Claude Code 的新版本会把任何非 0 退出码显示成 "hook error"，会污染用户终端；我们宁可丢事件也不弄脏显示。
- PermissionRequest socket 不通时 exit 0 且不写 stdout → Claude Code 视为"无 hook 偏好" → 回退到原生终端授权弹窗，行为正确。
- 其他 fire-and-forget hook socket 不通时就当这次事件没发生；App 重连后靠 `SessionScanner` 做 catch-up sweep。

### Hook 注入安全

1. 写入前备份: `settings.json.backup.{timestamp}`
2. 只追加 `hooks` key，不碰 `permissions` / `enabledPlugins` / `defaultMode` / `theme` 等
3. JSON 解析失败 → 不修改原文件
4. 我们的条目通过 command 路径中的 `zackeyes` 字符串可识别
5. 卸载时精确移除我们的条目，不影响其他 hooks

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
│   │   ├── HotKey/             # HotKeyManager（可配置快捷键）
│   │   ├── Notifications/      # NotificationManager
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
- PermissionRequest hook 事件未在官方文档列出（Vibe Island 验证可行）
- PermissionRequest 响应格式基于逆向推断
- 已准备 PreToolUse `permissionDecision` 作为 fallback 方案
