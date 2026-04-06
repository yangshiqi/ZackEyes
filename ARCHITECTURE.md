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

### 失败流

```
bridge 连接 /tmp/zackeyes.sock 失败（App 未运行）
  → bridge exit(1)（非阻塞错误）
  → Claude Code 正常继续，回退到终端审批
```

## 模块职责

| 模块 | 文件 | 职责 |
|------|------|------|
| `SocketServer` | `ZackEyes/Socket/SocketServer.swift` | 监听 Unix Socket，accept 连接，解析 JSON，路由到 SessionStore，发送响应 |
| `EventProtocol` | `ZackEyes/Socket/EventProtocol.swift` | Codable 结构体定义：BridgeEvent、PermissionResponse |
| `SessionStore` | `ZackEyes/Session/SessionStore.swift` | ObservableObject，维护当前会话状态（idle/working/waiting/stopped） |
| `NotchPanel` | `ZackEyes/Notch/NotchPanel.swift` | NSPanel 子类，刘海区域覆盖层 |
| `NotchWindowController` | `ZackEyes/Notch/NotchWindowController.swift` | 位置锚定（notch 几何计算）、展开/收缩动画、鼠标追踪 |
| `NotchViewModel` | `ZackEyes/Notch/NotchViewModel.swift` | ObservableObject，桥接 SessionStore → SwiftUI Views |
| `NotchCompactView` | `ZackEyes/Notch/NotchCompactView.swift` | Compact 状态 SwiftUI 视图 |
| `NotchExpandedView` | `ZackEyes/Notch/NotchExpandedView.swift` | Expanded 状态 SwiftUI 视图（含审批按钮） |
| `MenuBarFallback` | `ZackEyes/MenuBar/MenuBarFallback.swift` | NSStatusItem + NSPopover，无刘海 Mac 的 fallback |
| `HookInstaller` | `ZackEyes/Hooks/HookInstaller.swift` | 静默注入/移除 ~/.claude/settings.json 的 hooks 配置 |
| `AppDelegate` | `ZackEyes/App/AppDelegate.swift` | 启动入口，初始化 SocketServer、HookInstaller、NotchPanel |

## 安全模型

### Bridge 防御性设计

| 场景 | 行为 | Exit Code |
|------|------|-----------|
| 正常响应（权限决策） | stdout 输出 JSON | 0 |
| Socket 不存在 / App 未运行 | 静默退出 | 1 |
| Socket 连接超时（15s） | 静默退出 | 1 |
| stdin JSON 解析失败 | 静默退出 | 1 |
| Bridge 崩溃 | 静默退出 | 1 |
| 阻塞 Claude Code | **永远不会发生** | 永不使用 2 |

**铁律**: ZackEyes 的任何故障对用户的 Claude Code 体验完全不可见。

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

```
zackeyes/
├── ZackEyes.xcodeproj          # 包含两个 target
├── ZackEyes/                   # 主 App target
│   ├── App/                    # 启动入口
│   ├── Notch/                  # NotchPanel + Views
│   ├── MenuBar/                # 菜单栏 fallback
│   ├── Socket/                 # Unix Socket 服务端 + 协议定义
│   ├── Session/                # 会话状态管理
│   ├── Hooks/                  # Hook 自动安装/卸载
│   └── Resources/              # Assets, Info.plist
├── Bridge/                     # Bridge CLI target
│   ├── main.swift
│   └── SocketClient.swift
└── Scripts/
    └── install-bridge.sh       # 构建后部署 bridge
```

**依赖**: 零外部依赖。纯 Foundation + AppKit + SwiftUI。

## Known Risks

详见 [设计文档](docs/superpowers/specs/2026-04-05-zackeyes-mvp-design.md#known-risks):
- PermissionRequest hook 事件未在官方文档列出（Vibe Island 验证可行）
- PermissionRequest 响应格式基于逆向推断
- 已准备 PreToolUse `permissionDecision` 作为 fallback 方案
