# AskUserQuestion Click-to-Answer — Design

**状态**: 设计定稿，实现前需补 Spike #2 验证
**分支**: 待定（建议 `feat/askuq-click-to-answer`）
**日期**: 2026-04-25

## 动机

当 Claude Code 调用 `AskUserQuestion` 工具向用户提问时，目前 ZackEyes 灵动岛只能展示**只读**选项预览，配一句"请在终端回答"——用户必须切换到终端窗口、按数字键 + 回车作答。

实测（spike 2026-04-25）发现 Claude Code 的 PreToolUse hook 现在支持通过 `updatedInput.answers` 路径**直接替用户作答**，CC 整个 AskUQ 终端 UI 不渲染。这意味着用户可以在灵动岛上一键作答，零终端切换。

旧 memory `project_askuserquestion_hook_limit.md` 里"PreToolUse 超时太短"的结论基于 CC v2.1.3 之前的 60s 默认超时；现版默认 600s 且可配置，限制已消失。

## 目标 & 非目标

**In scope**:
- Bridge 拦截 `PreToolUse + tool_name == "AskUserQuestion"`，阻塞至用户作答或 60s 软超时
- 灵动岛 `askUserQuestionBlock` 选项从只读改为可点击 / 可勾选 + Submit
- 60s 内无作答 → bridge 静默回退 → CC 渲染原生终端 UI
- 实现前完成 **Spike #2**（fallback 形状 + 多 hook 共存行为验证）—— hard gate

**Out of scope**:
- "Other" 自由输入（v1 不做，需要 Other 的用户等待 60s 软超时让终端 UI 接管）
- 单选误触保护（一键提交，无二次确认；如使用反馈差再迭代）
- 倒计时 UI（60s 静默，避免给用户压迫感）
- ExitPlanMode 等其他可能可拦截的工具
- 配置开关（默认开启；不需要的用户禁用整个 ZackEyes hook）

## Spike #2 — 实现前的硬阻塞验证

写代码前必须完成以下两个验证。任一项失败需重新讨论设计。

### 2A. Fallback JSON 形状

测试 60s 软超时回退到终端 UI 的最干净写法。三种候选：

| 候选 | bridge stdout | 期望行为 |
|------|-------|---------|
| (a) | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}` | CC 跑工具原始 input → 终端 AskUQ UI |
| (b) | 空 stdout | CC 视为"无 hook 偏好" → 终端 AskUQ UI |
| (c) | `{}` 空 JSON object | 未知 |

**判断标准**：
- 终端真的弹出 AskUQ UI（数字键 + 回车那个 UI）
- CC 不报 hook error
- 模型最终拿到正确的用户答案

记录哪种形状最干净，写进实现里。

### 2B. 多 hook 共存行为

用户的 `~/.claude/settings.json` 现有三条 PreToolUse hook（Vibe Island、RTK、ZackEyes）。Spike #1 替换了整个数组只剩 spike，未验证多 hook 场景。

**实验**：保留 Vibe Island 和 RTK 的 PreToolUse 条目，加上 ZackEyes spike（同时返回 `updatedInput.answers`）。触发 AskUQ。

**关注点**：
- 多个 hook 的 stdout 是否被 CC 合并 / 取一 / 报错？
- Vibe Island 是否也在拦 AskUQ？冲突时谁的 answers 生效？
- 首返回 vs 后返回，CC 的优先级？
- 终端 UI 是否仍被跳过？

**判断标准**：
- ✅ 我们的 answers 被 CC 接受 → 设计成立，无需特殊处理
- ⚠️ Vibe Island 的 answers 优先 → 实现需要 HookInstaller 检测 Vibe Island 并提示用户禁用其 PreToolUse 拦截
- ❌ CC 报 hook 冲突错误 → 设计需重新评估，考虑 HookInstaller 主动管理冲突

## 架构

### Hook 调用流

```
CC PreToolUse fires
  → bridge stdin: {tool_name, tool_input.questions, ...}
  → bridge: tool_name == "AskUserQuestion"?
      ├─ no  → fire-and-forget（现状不变）
      └─ yes → sendAndWaitForResponse(timeoutSeconds: 60, pollHUP: true)
                ↓
              SocketServer 持 fd
                ↓
              SessionStore 标 PendingPermission（已有数据模型）
                ↓
              NotchExpandedView 渲染**可点击**选项
                ↓
              用户点击 → responder(.preToolUse(.askUQAnswers(...)))
                ↓
              JSON 回 bridge stdout → CC 消费 → tool 直接完成，无终端 UI

            (60s 内无点击 / app 未运行 / app 崩溃)
                ↓
              bridge 写 fallback JSON（Spike #2A 决定形状）→ exit 0
                ↓
              CC 渲染终端 AskUQ UI
                ↓
              （灵动岛此时已收回—POLLHUP 触发 onPermissionAbandoned）
```

### 与现有 PermissionRequest 路径的关系

现有 `NotchExpandedView.swift:413` 的 `askUserQuestionBlock` 通过 `PermissionRequest` 路径触发——仅当用户的 settings.json 没把 `AskUserQuestion` 加入 allow 列表时 CC 才发该 hook。新 PreToolUse 路径**对所有用户都触发**，覆盖范围更广。

**决定**：v1 移除 PermissionRequest 路径上的 AskUQ 处理。所有 AskUQ 走 PreToolUse，避免双 UI 同时呈现。具体：
- `SessionStore.PendingPermission.isAskUserQuestion` 仍保留（数据模型通用）
- `SocketServer.handleConnection` 的 PermissionRequest 分支若收到 `tool_name == "AskUserQuestion"`，**视为 fallthrough**：立即 responder 一个 `.permissionAllow`（不展示 UI），让 PreToolUse 路径独占 AskUQ 处理

## 数据模型

### `BridgeResponse` enum（新增）

位置：`Sources/Shared/EventProtocol.swift`

```swift
public enum BridgeResponse: Sendable {
    case permission(PermissionResponse)
    case preToolUse(PreToolUseHookResponse)

    public func encode() throws -> Data {
        switch self {
        case .permission(let r): return try JSONEncoder().encode(r)
        case .preToolUse(let r): return try JSONEncoder().encode(r)
        }
    }
}
```

### `PreToolUseHookResponse`（新增）

位置：`Sources/Shared/EventProtocol.swift`

```swift
public struct PreToolUseHookResponse: Codable, Sendable {
    public let hookSpecificOutput: HookSpecificOutput

    public struct HookSpecificOutput: Codable, Sendable {
        public let hookEventName: String  // 始终 "PreToolUse"
        public let permissionDecision: String  // "allow"
        public let updatedInput: [String: AnyCodable]?
    }

    public static func askUQAnswers(
        questions: [[String: Any]],
        answers: [String: String]
    ) -> PreToolUseHookResponse { ... }
}
```

Fallback 写入由 bridge 直接处理，不构造 `PreToolUseHookResponse` 实例：
- 若 Spike #2A 选 (a)（allow 无 updatedInput）：bridge 写预先准备好的字面 JSON 字符串
- 若 Spike #2A 选 (b)（空 stdout）：bridge 直接 exit 0 不写 stdout

无论哪条，spec 里其他位置写"fallback JSON"指的都是 spike 决定的具体形式。
```

### `PermissionResponse` 不动

保留现有结构（`decision: {behavior, message}` 嵌套），不参与重构。`PermissionRequest` hook 的响应继续走它。

### `PendingPermission` 责任扩展

位置：`Sources/AppLib/Session/SessionStore.swift`

- 数据字段（`toolName`, `toolInput`, `cwd`, `questions`）不变
- `responder` 类型从 `(PermissionResponse) -> Void` 改为 `(BridgeResponse) -> Void`
- 新增 `bridgeEventOrigin: String` 字段（`"PermissionRequest"` 或 `"PreToolUse"`），用于 UI 判断走哪种应答路径

## 组件改动

### `Sources/Bridge/main.swift`

新增分支：
```swift
case "PreToolUse":
    if jsonObject["tool_name"] as? String == "AskUserQuestion" {
        guard let responseData = client.sendAndWaitForResponse(
            data: payloadData, timeoutSeconds: 60
        ) else {
            // Socket fail / POLLHUP / 60s soft timeout → fallback to terminal UI.
            // Concrete behavior decided by Spike #2A:
            //   (a) write literal fallback JSON to stdout, OR
            //   (b) exit 0 with empty stdout (current PermissionRequest pattern)
            exit(0)  // placeholder — replace with chosen path after Spike #2A
        }
        FileHandle.standardOutput.write(responseData)
        exit(0)
    }
    _ = client.sendFireAndForget(data: payloadData)
    exit(0)
```

其他 PreToolUse 调用保持 fire-and-forget（不阻塞、不影响整体性能）。

### `Sources/BridgeLib/SocketClient.swift`

`sendAndWaitForResponse(timeoutSeconds:)`:
- 在 select / poll loop 里加 `POLLHUP` 探测，若服务端断开立即返回 `nil`（不再死等到超时）
- 用户场景：app 运行中崩溃，bridge 立即拿到 POLLHUP → 走 fallback 路径

### `Sources/AppLib/Socket/SocketServer.swift`

阻塞条件抽出 helper：
```swift
extension BridgeEvent {
    var requiresBlockingResponse: Bool {
        if bridgeEvent == "PermissionRequest" { return true }
        if bridgeEvent == "PreToolUse" && toolName == "AskUserQuestion" {
            return true
        }
        return false
    }
}
```

`handleConnection` 把当前的 `event.bridgeEvent == "PermissionRequest"` 分支换成 `event.requiresBlockingResponse`。同一套 fd-hold + responder + POLLHUP 监控 + `onPermissionAbandoned` 路径，同时服务两种 hook。

PermissionRequest 分支若 `tool_name == "AskUserQuestion"`，立即 responder 一个 `.permission(.allow(message: "Handled by PreToolUse"))` 跳过 UI（见上"与现有 PermissionRequest 路径的关系"）。

### `Sources/AppLib/Session/SessionStore.swift`

- `PendingPermission.responder` 类型改为 `(BridgeResponse) -> Void`
- `PendingPermission` 新增 `bridgeEventOrigin: String`
- 新增辅助方法 `submitAskUQAnswer(sessionId:, answers:)`：构造 `PreToolUseHookResponse.askUQAnswers(...)`，包成 `.preToolUse(...)`，调用 responder，清 pending state

### `Sources/AppLib/Notch/NotchExpandedView.swift`

`askUserQuestionBlock` 大改：

**单选**：
- 选项 `Text` 包成 `Button(action: { submitSingle(label) })`
- 整行 hover 高亮、tap 时 100ms 延迟收回灵动岛后调 responder
- 移除 "请在终端回答" footer

**多选**：
- 每行加左侧 checkbox（local `@State Set<String>`）
- 底部 Submit 按钮（`Button("Submit")`)
  - `disabled` when `selected.isEmpty`
  - 点击 → 拼 `selected.sorted().joined(separator: ", ")` → submitMulti(joined)
- 同样 100ms 后收回灵动岛

**辅助**：
```swift
private func submitSingle(_ label: String) {
    viewModel.submitAskUQAnswer(
        sessionId: session.id,
        answers: [question.text: label]
    )
}
private func submitMulti(_ joined: String) {
    viewModel.submitAskUQAnswer(
        sessionId: session.id,
        answers: [question.text: joined]
    )
}
```

### `Sources/AppLib/Hooks/HookInstaller.swift`

**不动**。CC 默认 PreToolUse timeout 600s >> 我们内部 60s 软超时。无需写 timeout 字段。

## UX 细节

| 行为 | 设计 |
|------|------|
| AskUQ 触发时灵动岛状态 | 自动展开（沿用 PermissionRequest 现有路径，复用 `forceUiExpand`） |
| 单选交互 | 一键直接提交，无确认 |
| 多选交互 | checkbox 累计 + Submit 按钮，零选中时 Submit disabled |
| 选项 hover/tap 反馈 | 行背景色淡化 → 选中时背景色加深 → 收回 |
| 提交后到收回 | 100ms 延迟，给视觉反馈 |
| 倒计时显示 | 不显示（避免压迫感） |
| 软超时静默回退 | 灵动岛收回，终端 AskUQ UI 弹出，无过渡提示 |
| "Other" 选项 | v1 不做。诉求 Other 的用户不点灵动岛，等 60s 自动接管到终端 UI |
| 多 session 并发 AskUQ | 复用现有 per-session pending 渲染（已支持） |

## 失败模式

| 场景 | 行为 | 路径 |
|------|------|------|
| App 未启动 | bridge 连不上 socket → exit 0 静默 → CC 终端 UI | 现有 silent-exit 路径 |
| App 跑着用户没点（60s） | bridge 软超时 → 写 fallback JSON → CC 终端 UI | bridge `sendAndWaitForResponse` 返 nil → fallback 分支 |
| App 跑着用户跨 session 在终端答 | 不会发生（bridge 阻塞期间终端 AskUQ UI 不存在） | 物理隔离 |
| App 中途崩溃 | bridge 收到 POLLHUP → 立即 fallback | SocketClient POLLHUP 监听 |
| Bridge socket 异常 | exit 0 静默 → CC 终端 UI | 现有 silent-exit 路径 |
| 多 hook（Vibe Island）冲突 | **未知**（Spike #2B 验证后定 mitigation） | 见 Known Risks |

## 测试

### Unit

- `SharedTests`: `BridgeResponse.permission` 与 `.preToolUse` 各自 JSON 编码形状正确
- `SharedTests`: `PreToolUseHookResponse.askUQAnswers` 编码出 `{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"allow", updatedInput:{questions:[...], answers:{...}}}}`
- `BridgeLibTests`: `SocketClient.sendAndWaitForResponse` POLLHUP 立即返回 nil
- `AppLibTests`: `BridgeEvent.requiresBlockingResponse` 矩阵
- `AppLibTests`: `SessionStore.submitAskUQAnswer` 调 responder 后清 pending

### Manual Integration（在 Spike #2 通过后跑）

| # | 操作 | 预期 |
|---|------|------|
| 1 | 触发 AskUQ → 在灵动岛点选项 | CC 拿到答案，终端无 UI |
| 2 | 触发 AskUQ → 不点击等 60s | 灵动岛收回，终端 UI 弹出 |
| 3 | 多选触发 → 勾两个 → Submit | CC 拿到 `"a, b"` 字符串 |
| 4 | App 未启动时触发 AskUQ | 终端 UI 立即弹出（无延迟） |
| 5 | App 跑着但 quit ZackEyes 后触发 | 同 #4 |
| 6 | 触发后 quit ZackEyes（bridge 阻塞中） | bridge 收到 POLLHUP → 终端 UI 弹出（< 1s） |
| 7 | 多 session 并发 AskUQ | 灵动岛同时显示两套问题，互不干扰 |

## Known Risks

### R1: 多 hook 行为未文档化（v1 阻塞，Spike #2B 缓解）

CC 对多个 PreToolUse hook 同时返回 `updatedInput` 的处理未文档化。Vibe Island 用户尤其受影响——他们的 hook 也在拦 AskUQ。

**v1 缓解**：Spike #2B 决定。可能需要 `HookInstaller` 加一段：检测到 Vibe Island PreToolUse 入口时 NSLog 警告（不主动卸载对方）。

### R2: 单选误触

紧凑选项排列下手贱点错的概率非零。v1 不做二次确认（保持快捷感）。

**未来缓解**（如使用反馈差）：
- 第一次 tap 高亮 + 0.5s 防误触窗口
- 二次 tap 才提交
- 单选改成 radio + Submit 模式

### R3: Fallback JSON 形状假设

Spike #2A 完成前，60s fallback 的 stdout 形状尚未敲定。Spec 里所有相关代码用占位符 `<spike-2A-shape>`。

### R4: AskUQ 之外的 ExitPlanMode 等同类工具

CC 文档把 `ExitPlanMode` 与 `AskUserQuestion` 归为一类（都涉及用户决策）。本 spec 不处理 ExitPlanMode，但实现时把 `requiresBlockingResponse` 写得 extension 化，方便后续扩展。

## 迁移 / 兼容

- `~/.claude/settings.json` 无字段变更，HookInstaller 不动
- 已安装 ZackEyes 的用户升级到包含本特性的版本：行为自动改变，无需用户操作
- 旧 bridge 二进制（无 AskUQ 阻塞）配合新 app：bridge 还是 fire-and-forget，AskUQ 走旧的 PermissionRequest 只读路径——降级体验，无功能损坏
- 新 bridge 配合旧 app：旧 app 不识别 PreToolUse 阻塞事件 → SocketServer 立即关 fd → bridge POLLHUP → 走 fallback → 终端 UI。降级正确

## 实施顺序（实现时参考，正式 plan 由 writing-plans 产出）

1. ✅ Spike #2A: 验证 fallback JSON 形状
2. ✅ Spike #2B: 验证多 hook 共存
3. `Shared/EventProtocol.swift`: 新增 `PreToolUseHookResponse` + `BridgeResponse` enum + tests
4. `BridgeLib/SocketClient.swift`: POLLHUP 监听 + tests
5. `Bridge/main.swift`: 新增 PreToolUse + AskUQ 分支
6. `AppLib/Socket/SocketServer.swift`: `requiresBlockingResponse` 分流 + PermissionRequest+AskUQ shortcut
7. `AppLib/Session/SessionStore.swift`: responder 类型变更 + `submitAskUQAnswer` + tests
8. `AppLib/Notch/NotchExpandedView.swift`: 可点击选项 + 多选 Submit + 100ms 收回
9. 删除现有 PermissionRequest-AskUQ 只读预览的 dead code（如有）
10. Manual integration 全跑通
11. 文档：CHANGELOG entry + ARCHITECTURE.md 更新（PreToolUse 阻塞分支）
