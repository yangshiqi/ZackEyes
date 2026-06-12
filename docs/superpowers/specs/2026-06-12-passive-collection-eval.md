# #83 被动优先采集评估 — 哪些状态可纯被动获取 / 哪些必须 hook

> 验收标准第 1 条的产出。来源:abtop 哲学(只有 rate-limit 需要可选 hook,其余纯被动)。
> 结论先行:**Claude 侧"基本会话列表"可完全被动获取,缺口只在"启动后新会话的持续发现"——本切片用周期重扫描补上;实时状态机/审批/配额必须 hook,kqueue tailer 推迟到有实际痛点。**

## 状态矩阵

| 状态 | 纯被动可得? | 来源 | 现状 |
|------|------------|------|------|
| 会话列表(id/cwd/transcriptPath) | ✅ | `~/.claude/projects/*.jsonl` 文件名 + 行内 `cwd` | `SessionScanner`(启动一次,8h 窗口) |
| lastUserPrompt / lastAssistantMessage | ✅ | transcript 末尾 64KB,`type:"user"/"assistant"` 文本块 | `SessionScanner` |
| 任务列表(TaskCreate/TaskUpdate) | ✅ | assistant `tool_use` 块 + user `tool_result` 关联 | `TaskExtractor`(导入时) |
| 工具调用(名称/输入) | ✅(事后) | assistant `tool_use` 块 | 已被 TaskExtractor 用;非实时 |
| 活/死判定 | ✅ | `ps`/`lsof`(`runningClaudeCwds`) | `LivenessFilter` + 60s sweep |
| **启动后新会话的发现** | ✅(本切片) | 同 SessionScanner,周期重跑 | **缺口:scan 只在启动跑一次 → 本切片接入 60s sweep** |
| 实时 working/idle 状态机 | ⚠️ 理论可(tail user/assistant 行边界) | 需 kqueue tailer(仿 CodexJsonlTailer ~600 行) | **推迟**(见下) |
| isToolRunning / currentToolName 实时 | ⚠️ 同上 | 同上 | 推迟 |
| 权限审批(PermissionRequest/AskUQ) | ❌ 不可能 | 交互必须双向 hook | hook 主路径,护城河,不动 |
| 5h/7d rate-limits | ❌ | 仅 statusLine hook 携带 | hook-only |
| 模型名 / cost / context 使用率 | ❌(Claude 侧) | statusLine hook 的 `model`/`cost`/`context_window` | hook-only(transcript 不含或未解析) |
| 每消息时间戳 | ❌(当前解析器) | transcript 行未解析时间字段 | 不需要 |

## 决策:周期重扫描 now,kqueue tailer 推迟

**做**(本切片):把 `SessionScanner`(claude-only)接进既有 60s sweep 节拍 —— 复用同一张
`runningClaudeCwds` 活性过滤逻辑,新增/更新的 detected 会话 ≤60s 可见。配合
`importDetectedSessions` 的「未变化跳过」守卫(mtime 未动即跳过,不重跑 TaskExtractor、
不重建会话、不碰 codex tailer 已增量写入的字段)。hook 未安装时:启动扫描给出存量,
周期重扫描给出增量,sweep 给出剔除 —— 基本会话列表完整闭环。

**不做**(推迟,理由):ClaudeJsonlTailer(仿 CodexJsonlTailer 的 kqueue 实时 tail)能把
状态机做到准实时,但 (1) ~600 行新组件,(2) Codex tailer 存在是因为「先于 hooks 安装的
TUI 永远不 fire hook」这个**已发生的痛点**;Claude 侧 hook 由 app 启动时自动安装 + #38
的 Repair 兜底,缺 hook 是异常态而非常态,(3) 60s 粒度对"兜底可见性"足够。
依据 CLAUDE.md:「我可能会需要」不是理由。若未来出现真实抱怨(hook 安装失败率数据、
用户反馈状态滞后),按本评估升级到 tailer 即可——CodexJsonlTailer 是现成模板。

## 不变量影响

- 不变量 #7(LivenessFilter cwd 检测 claude-only):重扫描只喂 claude 会话进过滤器,
  codex 项在 scan 后即被滤除,tailer 路径不受扰动。✅
- 周期路径与启动路径的 ps-失败语义**故意不同**:启动时 `ps` 失败 → 全量导入(宁可短暂
  tombstone 不可漏活会话);周期路径 `ps` 失败 → 本 tick 跳过导入(否则会复活 sweep
  刚剔除的死会话,卡片闪烁)。
- 被动读零写入:scanner/extractor 只读 transcript;不写任何用户文件。✅
