# CLAUDE.md

## 上下文分层

| Tier | 加载时机 | 文件 |
|------|----------|------|
| **Tier 1 热加载** | 每次对话自动加载 | `CLAUDE.md`（本文件） |
| **Tier 2 按需读取** | 修改代码前 / 开始任务前 | `ARCHITECTURE.md`, `AGENTS.md` |
| **Tier 3 深度参考** | 需要时主动查询 | `docs/superpowers/specs/`, `.claude/memory/`, `git log` |

**引用指令**:
- **修改代码前**必读 [ARCHITECTURE.md](ARCHITECTURE.md) — 组件边界、数据流、安全模型
- **开始任务前**必读 [AGENTS.md](AGENTS.md) — 开发流程、反馈循环、变更检查清单

## Build & Dev Commands

```bash
# 编译
swift build                  # Debug build (两个 target: ZackEyes + bridge)
make app                     # Build + 组装 .app bundle

# 运行
make run                     # Build + open .build/ZackEyes.app

# 测试
swift test                   # 全量测试 (SharedTests + BridgeLibTests + AppLibTests)
swift test --filter SharedTests      # 仅 Shared 模块
swift test --filter BridgeLibTests   # 仅 Bridge 模块
swift test --filter AppLibTests      # 仅 App 模块

# Bridge 手动测试 (模拟 Claude Code hook 调用)
echo '{"hook_event_name":"SessionStart","session_id":"test","cwd":"/tmp"}' | \
  $(swift build --show-bin-path)/bridge --event SessionStart --agent claude

# 模拟 Codex hook 调用
echo '{"hook_event_name":"Stop","session_id":"test","cwd":"/tmp","last_assistant_message":"done"}' | \
  $(swift build --show-bin-path)/bridge --event Stop --agent codex

# 清理
make clean
```

## Mandatory Invariants

任何代码变更 **MUST** 遵守以下所有约束：

1. **用户配置零损坏** — Hook installer 操作用户配置文件时（`~/.claude/settings.json` for HookInstaller，`~/.codex/hooks.json` for CodexHookInstaller）：必须先备份（`{file}.backup.{timestamp}`）、只追加 hooks key 不动其他字段（Claude: `permissions`、`enabledPlugins`、`defaultMode`...；Codex: 用户已有的 hook 条目）、JSON 解析失败时不修改原文件。**永远不读不写 `~/.codex/config.toml`**（codex `[features].hooks` 默认 true，碰它会引入 TOML 解析依赖 + 用户配置损坏风险）。
2. **Bridge 永不污染 agent 终端** — Bridge 进程的任何受控失败路径必须以 `exit(0)` 退出且不写 stdout/stderr。Claude Code 新版把任何非 0 exit 显示成 hook error；Codex 同样宽容地处理 exit 0。Socket 连不上、超时、stdin 异常、未知 `--agent` 值 → 静默 `exit(0)`。永远不使用 `exit(2)`（阻塞错误）。PermissionRequest 失败时 exit 0 无 stdout → agent 回退到原生终端授权，行为正确。
3. **NotchPanel 不抢焦点** — NSPanel 必须是 `nonactivatingPanel`。`canBecomeMain` 返回 `false`。Collapsed/Compact 状态下 `ignoresMouseEvents = true`，只有 Expanded 状态才接收交互。
4. **Socket 连接不复用** — 每次 hook 调用创建新连接，用完即关。防止连接泄漏和状态混淆。
5. **Hook 配置可识别** — 注入到 `settings.json` / `hooks.json` 的 hook entries，command 路径必须包含 `zackeyes` 字符串 + 显式 `--agent claude|codex` flag，用于安全移除时精确匹配。Bridge 缺 `--agent` 时默认 `claude`，保证老 hook entry 升级时不掉链。
6. **零第三方依赖** — MVP 阶段只使用 Foundation + AppKit + SwiftUI。不引入 Sentry、Sparkle、CocoaPods、SPM 外部包。
7. **Codex 路径不进 LivenessFilter cwd 检测** — `LivenessFilter.filterLiveDetected` 和 `runLivenessSweep` 的 cwd→进程 map 是 claude-only（`runningClaudeCwds`），喂 codex session 进去会全部判死。Codex 有自己的 idle-time 剪枝路径（15 min 无 `lastActiveAt` 更新即剪）。任何动 LivenessFilter 的改动必须保持 codex 旁路或显式给 codex 加进程检测。

## Design Principles

- **避免过度设计** — 不为假设的未来需求编码。三行重复代码优于一个过早的抽象。
- **避免过度工程化** — 只在实际遇到痛点时增加基建。"我可能会需要"不是理由，"我已经被这个问题坑了两次"才是。
- **复杂度需要证明** — 每增加一层抽象、一个配置文件、一个新 target，都需要回答：它解决了什么已经存在的问题？
- **先建韧性，后加智能** — Bridge 的防御性设计（超时、静默失败）比花哨的功能更重要。

## Conventions

- Swift 6+ strict concurrency
- macOS 14.0 minimum deployment target
- `LSUIElement = true` — 无 Dock 图标
- SPM 五个 target: `Shared`（共享类型）、`BridgeLib`（Bridge 逻辑）、`AppLib`（App 逻辑）、`Bridge`（CLI 入口）、`ZackEyes`（App 入口）
- 可执行 target 是薄壳入口，逻辑在 library target 中（便于测试）
- Unix Socket 路径: `/tmp/zackeyes.sock`
- 用户数据目录: `~/.zackeyes/`
- JSON 通信使用 `Codable` 协议，newline 分隔
- NSPanel window level: `.screenSaver`
- Hook 配置格式: 嵌套结构 `[{ hooks: [{ type: "command", command: "..." }] }]`，matcher 省略（匹配所有）
