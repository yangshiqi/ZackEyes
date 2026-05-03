# AGENTS.md

Agent 操作手册 — 开发流程、反馈循环、变更检查清单。

## 开发流程

每个任务按以下步骤执行：

1. **理解任务** — 读 `ARCHITECTURE.md` 确认影响的组件（Bridge / SocketServer / NotchPanel / HookInstaller / SessionStore）
2. **检查进度** — 读 memory + `git log` 了解前序工作，避免重复
3. **制定计划** — 复杂任务先 brainstorm 输出 spec（`docs/superpowers/specs/`），简单任务直接开始
4. **增量实现** — 一次只做一个组件/功能，不混合无关变更
5. **测试验证** — 编译通过 + 跑相关测试，确认不破坏现有功能（见反馈循环）
6. **提交** — conventional commit，scope 对应组件（见提交规范）

## 反馈循环

### 编译验证

```bash
# 编译全部
swift build 2>&1 | tail -5

# 全量测试
swift test 2>&1 | tail -20

# 组装 .app bundle
make app 2>&1 | tail -3
```

### 手动验证（编码过程中）

```bash
# Bridge 功能验证 — 模拟各种 hook 事件
echo '{"hook_event_name":"SessionStart","session_id":"test-123","cwd":"/tmp"}' | \
  $(swift build --show-bin-path)/bridge --event SessionStart
echo $?  # 应该是 0（App 运行中）或 1（App 未运行，静默失败）

# Socket 连通性测试
ls -la /tmp/zackeyes.sock  # App 运行时应该存在

# Hook 注入安全性验证
diff ~/.claude/settings.json ~/.claude/settings.json.backup.*  # 确认只改了 hooks key
```

### 硬性规则

- 编译错误 → 先修再继续，不注释掉代码绕过
- Bridge 任何代码路径 → 受控失败时 exit(0) 静默；永不 exit(2)（旧版文档写的 exit(1) 已失效，Claude Code 新版会把它显示成 hook error）
- NSPanel 相关变更 → 手动验证不抢焦点、不挡菜单栏点击
- HookInstaller 变更 → 先备份一份 settings.json，测完恢复
- 新代码应有测试覆盖（XCTest）

## 进度追踪

| 场景 | 方式 |
|------|------|
| 单会话任务 | Claude Code task 系统 |
| 跨会话决策记录 | `.claude/memory/` |
| 大型 feature spec | `docs/superpowers/specs/YYYY-MM-DD-<topic>.md` |
| 实现计划 | `docs/superpowers/plans/YYYY-MM-DD-<topic>.md` |

**跨会话恢复**: 新对话开始时，先读 memory + `git log` 了解之前做到哪了，再继续。不要从头开始。

## 变更检查清单

提交前逐项确认：

- [ ] 影响范围确认（哪些组件受影响：Bridge / Socket / Notch / Hooks / Session）
- [ ] 编译通过（两个 target 都能 build）
- [ ] 新代码有测试覆盖
- [ ] 相关测试通过
- [ ] 不引入安全风险（见下方额外检查）
- [ ] 文档更新：ARCHITECTURE.md（架构变了）、CLAUDE.md（约束变了）

### 安全相关变更额外检查

当修改以下组件时，额外确认：

**HookInstaller / CodexHookInstaller:**
- [ ] 写入前备份 `settings.json.backup.{timestamp}` / `hooks.json.backup.{timestamp}`
- [ ] 只追加 `hooks` key（Claude 还有 `statusLine`），不修改 `permissions` / `enabledPlugins` / `defaultMode` / `theme` / Codex 任何其它字段
- [ ] JSON 解析失败时不修改原文件
- [ ] hook command 路径包含 `zackeyes` 标识 + 显式 `--agent claude|codex` flag
- [ ] 卸载逻辑只移除包含 `zackeyes` 的条目
- [ ] **永远不读不写 `~/.codex/config.toml`**（codex 默认开 hooks，碰它会引入 TOML 解析依赖 / 用户配置损坏风险）

**Bridge:**
- [ ] 所有受控失败路径 → `exit(0)`（不写 stdout/stderr）
- [ ] 永不使用 `exit(2)`
- [ ] Socket 超时 / 连不上 → `exit(0)` 静默
- [ ] stdin 为空 / 解析失败 / args 错误 → `exit(0)` 静默
- [ ] PermissionRequest 失败 → `exit(0)` 且不写 stdout（Claude Code 回退到原生授权）

**NotchPanel:**
- [ ] `styleMask` 包含 `.nonactivatingPanel`
- [ ] `canBecomeMain` 返回 `false`
- [ ] Collapsed/Compact 状态 `ignoresMouseEvents = true`
- [ ] `isMovable = false`
- [ ] `collectionBehavior` 包含 `.ignoresCycle`

## 提交规范

格式: `<type>(<scope>): <description>`

**type**: `feat` | `fix` | `refactor` | `docs` | `test` | `chore`

**scope** 对应组件:

| scope | 组件 |
|-------|------|
| `bridge` | Bridge CLI（`Bridge/`） |
| `socket` | SocketServer（`AppLib/Socket/`） |
| `notch` | NotchPanel + Views + AgentBadge + SimulatedNotch（`AppLib/Notch/`、`AppLib/SimulatedNotch/`） |
| `menubar` | MenuBar fallback（`AppLib/MenuBar/`） |
| `hooks` | HookInstaller（Claude）+ CodexHookInstaller |
| `session` | SessionStore + SessionScanner + LivenessFilter（`AppLib/Session/`） |
| `codex` | Codex 专属：CodexJsonlTailer / CodexHookInstaller / SessionStore.recordCodexTaskComplete / Codex usage 数据源 |
| `usage` | UsageTracker（5h/7d，双 agent） |
| `notify` | NotificationManager（agent 标签 / 错误 / 完成） |
| `app` | App 级别变更（`ZackEyes/`） |

**规则**:
- 每个 commit 是一个原子变更，可独立 revert
- Imperative mood: "add feature" not "added feature"
- 跨多个组件的变更可省略 scope
