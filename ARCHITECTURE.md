# ARCHITECTURE.md

## 项目定位

ZackEyes 是 macOS 原生应用，将 MacBook 刘海（Dynamic Island）区域变为 AI 编码代理的实时控制面板。MVP 聚焦 Claude Code 单 Agent 监控 + 权限审批。定位为 Vibe Island 的免费替代品。

## 组件架构

```
Claude Code                    Bridge CLI                     ZackEyes.app
(hooks in settings.json)  -->  (~/.zackeyes/bin/bridge)  <->  (SwiftUI + AppKit)
                               Swift CLI ~200 LOC             /tmp/zackeyes.sock
```

三个组件，通过 Unix Domain Socket 连接：

| 组件 | 位置 | 职责 | 禁止 |
|------|------|------|------|
| **Bridge CLI** | `Bridge/` → 嵌入 `ZackEyes.app/Contents/Helpers/bridge` | 被 Claude Code hook 调用，转发事件到主 App，返回权限决策 | 不含 UI 逻辑，不直接读写用户配置文件 |
| **Main App** | `ZackEyes/` | Socket 监听、会话状态管理、NotchPanel UI、Hook 自动安装 | 不直接与 Claude Code 进程交互（全部通过 Bridge） |
| **Launcher Script** | `~/.zackeyes/bin/bridge`（shell 脚本） | 定位 .app 路径，exec 到真实 Bridge 二进制 | 不含业务逻辑，只做路径查找和 exec |

**依赖方向**: Claude Code → Bridge → Main App（单向）。Main App 不主动连接 Bridge。

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

⚠️ 与其他 statusLine 工具（如 Vibe Island）冲突时，HookInstaller 会**保留对方的安装**，不强占。

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
| `SessionStore` | `Sources/AppLib/Session/SessionStore.swift` | 按 `session_id` 索引的多 session 状态机，含 `aggregateState` / `primarySession` / 错误检测 |
| `SessionScanner` | `Sources/AppLib/Session/SessionScanner.swift` | 扫描 `~/.claude/projects/*.jsonl` 导入既有会话 |
| `TaskExtractor` | `Sources/AppLib/Session/TaskExtractor.swift` | 解析 transcript 重建任务列表，按用户 prompt 边界重置（只显示当前 turn） |

**配置**
| 模块 | 文件 | 职责 |
|------|------|------|
| `HotKeyConfig` | `Sources/AppLib/Config/HotKeyConfig.swift` | 快捷键配置模型 + `HotKeyModifiers` OptionSet（Carbon/NSEvent flag 互转、Codable 字符串数组、显示符号） |
| `ConfigStore` | `Sources/AppLib/Config/ConfigStore.swift` | 读写 `~/.zackeyes/config.json`，原子写入，解析失败回退默认值 |

**Hook 安装**
| 模块 | 文件 | 职责 |
|------|------|------|
| `HookInstaller` | `Sources/AppLib/Hooks/HookInstaller.swift` | 静默安装/卸载 `hooks` + `statusLine`，备份保护，附加合并，所有变更含 `zackeyes` 标识 |

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
| `NotchExpandedView` | `Sources/AppLib/Notch/NotchExpandedView.swift` | 完整 popover：会话卡片、tasks、permission 审批、错误横幅、AskUserQuestion 选项卡 |
| `BuddyAvatar` | `Sources/AppLib/Notch/BuddyAvatar.swift` | 动画化 buddy（headbang / 睡觉 / 惊慌） |
| `Buddy` | `Sources/AppLib/Notch/Buddy.swift` | 摇滚传奇命名池（66 个）+ 性格标语池 |
| `PixelAvatar` | `Sources/AppLib/Notch/PixelAvatar.swift` | 9 种 8×8 像素图案 + 8 色摇滚配色 |
| `HotkeyRecorderView` | `Sources/AppLib/Notch/HotkeyRecorderView.swift` | SwiftUI 快捷键录入 overlay，NSEvent local monitor 捕获按键，验证 modifier |

**Simulated Notch（无刘海机型）**
| 模块 | 文件 | 职责 |
|------|------|------|
| `SimulatedNotchPanel` | `Sources/AppLib/SimulatedNotch/SimulatedNotchPanel.swift` | 顶部居中 NSPanel，`.screenSaver` 层级 |
| `SimulatedNotchView` | `Sources/AppLib/SimulatedNotch/SimulatedNotchView.swift` | Compact / hoverWide 内容（5h/7d 剩余 + NotchShape） |
| `SimulatedNotchFullView` | `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` | Full 模式：5h/7d 进度条 header + 滚动 session 列表 |
| `SimulatedNotchController` | `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift` | 三态形变控制器，hover 进入 full，外部点击退出，内容自适应高度 |
| `SimulatedNotchRoot` | `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift` | SwiftUI 根视图，compact/full 切换 + overlay 层叠 |
| `GearMenuTarget` | `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift` | NSMenu 动作目标（About / Change Hotkey / Update） |
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
| `UpdateChecker` | `Sources/AppLib/Update/UpdateChecker.swift` | GitHub Releases API 轮询（6h），语义版本比较，`@Published` 状态驱动齿轮红点 + 系统通知 |
| `TerminalLocator` | `Sources/AppLib/Terminal/TerminalLocator.swift` | 进程树遍历 + iTerm2/Terminal AppleScript + Ghostty/Warp/Kitty Accessibility |
| `UsageTracker` | `Sources/AppLib/Usage/UsageTracker.swift` | hook stdin 的真实 `rate_limits` 优先，transcript token fallback |

**App 入口**
| 模块 | 文件 | 职责 |
|------|------|------|
| `AppDelegate` | `Sources/ZackEyes/AppDelegate.swift` | 启动 / 路由 / 通知 / 禁用 macOS auto-termination |
| `main.swift` | `Sources/ZackEyes/main.swift` | NSApplication 启动 |

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
