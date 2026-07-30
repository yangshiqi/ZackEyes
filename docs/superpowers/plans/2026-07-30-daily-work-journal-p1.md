# 每日工作日志 P1「本地管道」— 实施计划（#214）

- **Spec**: [`2026-07-29-daily-work-journal-design.md`](../specs/2026-07-29-daily-work-journal-design.md)
- **范围**: spec §11 的 **P1** —— Collector → Distiller → Sanitizer → Renderer → 本地原子落盘，外加 Bridge 的 `ZACKEYES_JOURNAL=1` 静默路径
- **目标版本**: v0.10.0
- **日期**: 2026-07-30

P1 结束时功能已可用（纯本地日志）。这也是「提炼质量到底行不行」最早的验证点 —— 如果 P1 产出的日报读起来是废话，P2/P3 的工程量就不该付。

## 1. §13 四个必答问题的回应

### Q0 跨厂商披露 — 已定：**全程按出处隔离**

原始 transcript 与提炼摘要**都不跨厂商**。Claude 会话只喂 `claude -p`，Codex 会话只喂 `codex exec`。

三个直接后果，都必须在实现里兑现：

1. **引擎按 slice 选，不是全局选。** spec §5.3「引擎选择（设置项，默认自动）」作废 —— 没有可选的余地了，出处即引擎。设置里保留的只剩「某一家没装时怎么办」（见 3）。
2. **reduce 也按厂商分。** 两份 partial DayNote，**由 Swift 合并**成一天一个文件。合并不经过 LLM，所以不构成披露 —— 这一点站得住，是因为 spec §4.2 已经规定项目分组这类结构事实归 Swift 所有。损失仅限于：同一项目上跨两家 agent 的工作会是两条并列叙述，而非一句融合。
3. **`--output-schema` 不再是「默认路径」的保障。** codex 侧仍有 provider 强制 schema，但 Claude 侧现在是**承重路径**而不是回退。Swift 侧的严格解析器因此从「兜底」升级为「与 codex 路径同等重要」，测试等级同步提高（见 §5）。

**opt-in 文案的净收益**：可以给出一句强得多的承诺 —— *「会话内容只会被送回写出它的那一家，不会跨厂商」*。这句进 website privacy 段（spec §9），P3 落地。

### Q1 reduce 跨项目串味 — 采「按项目分别 reduce」

与 Q0 复合后，reduce 的粒度是 **(厂商 × 项目)**。每个 `SessionSlice` 本就属于唯一 `projectKey`（spec §5.1），所以按项目喂给 reduce 时，模型**看不到**别的项目的内容 —— 串味不是被检测出来的，是结构上不可能发生。这满足 §13 对 Q1 的硬要求（「只验 `projectKey` 合法不算满足」）。

代价是 spawn 次数从 2 次变成 ~项目数×2。可接受：这是日终一次性任务，不在交互路径上；且单项目 reduce 的输入更小，超时风险反而更低。

**规模闸门**：单天参与 reduce 的 (厂商×项目) 组合上限 12。超出时按当天 token 降序取前 12，其余合并成一行「另有 N 个项目的零星改动」—— 这条与 spec §5.2「全天总长优先于每项目配额」的挤出规则用同一套排序，不引入第二套。

### Q2 `LESSONS.md` 冲突后静默丢弃 — **P2 落地，方案在此定死**

按 §13 要求：**不建持久化重试队列**（单用户桌面 app，为罕见冲突建一套带持久化的队列属过度工程）。改为：

- 409 重取重试 1 次；仍失败 → **写入 run 记录**（`~/.zackeyes/journal/.runs.jsonl`，字段 `lessonsPending: [date]`）
- 下次运行开始时先读 run 记录，把未落地的 lessons 一并 append

丢失因此**可见**（进诊断报告）且**会被重试**，但不需要额外的持久化基础设施 —— run 记录本来就要写。

### Q3 Markdown 结构性注入 — **渲染期强制转义**

不扩黑名单。`JournalRenderer` 对每个来自 LLM 的文本字段做转义，而非过滤：行首 `#` / `-` / `*` / `>` / 数字`.` 前加 `\`，`[` `]` `(` `)` 加 `\`，换行 → 空格（日志字段本就不该多行）。

转义放在 Renderer 而不是 Sanitizer，是因为二者职责不同：Sanitizer 判「这条内容能不能出现」，Renderer 判「怎么安全地放进 Markdown」。同一个字符（如 `-`）在前者是正常连字符、在后者是列表标记 —— 混在一层会导致要么误杀正常句子，要么漏掉结构注入。

## 2. 对 spec 的一处修改（✅ 已批准 2026-07-30）

**去掉 `DayNote.headline` 的 LLM 来源，改由 Swift 用事实合成。** spec §5.1 的 `headline` 字段与 §7 的「`headline` 被 Sanitizer 拒 → 整天不推」一并作废。

spec §5.1 定的是 `headline: String // 一句话概括今天；必填，被拒则整天不推`。Q0 定案后它出了问题：headline 天然跨厂商，而跨厂商的叙述合成正是我们刚禁掉的事。

三个理由支持改掉它：

1. 它是唯一一个**必然**跨厂商的 LLM 字段，留着就得为它单开一个例外。
2. 它更贴 §4.2 的既定规则 —— 「今天推进了 6 个项目、交付 3 项」这种话全部是我们已精确知道的事实，本就不该让 LLM 填。
3. 它消掉 spec §7 里「`headline` 被 Sanitizer 拒 → 整天不推」这条失败路径。一个纯事实拼装的字符串不会被 Sanitizer 拒。

**如果你不同意**，替代方案是：headline 由「当天 token 占比最高的那一家」的引擎生成，只吃该厂商自己的 partial note，文案上承认它只覆盖半天。我认为不值得，但这是你的产品判断。

## 3. 出处标签常开（✅ 已定 2026-07-30）

Q0 之前，缺哪个引擎都能用另一个顶。现在不能了：**没装 codex ⇒ 当天所有 Codex 会话不产出。**

处置：**每段叙述都带出处标签**，两家都装时也标。不是缺 CLI 时才出现的特例。

两个理由：

1. 它让「不跨厂商」这个承诺在**产物本身**里看得见 —— 用户不必相信我们的文案，翻一眼日报就能验证。
2. 它把「只装一个 CLI」这件事变成不需要额外解释的状态：所有段落都标着 codex，缺什么一目了然。

**刻意不为「未安装」再加一条提示行。** 未安装是用户自己知道的稳定状态，出处标签已经足够；而「装了但这次跑挂了」是意外，走 spec §7 的失败处理留痕 —— 原计划把这两种情况混成同一个 `skipped` 字段是多余的。

实现：`DayNote.projects` 的值从 `String` 改为 `[ProjectNarrative]`，每条带 `agent: AgentKind`。`agent` 由 Swift 在合并两份 partial 时填入，**不进 schema、不过 Sanitizer** —— 它是我们已知的事实，不是 LLM 的叙述（§4.2）。

## 4. 组件与落点

新增 `Sources/AppLib/Journal/`（AGENTS.md 提交 scope 表需加一行 `journal`）：

| 文件 | 职责 | 纯度 |
|------|------|------|
| `JournalCollector.swift` | transcript → `[SessionSlice]`，按本地日切片 + 按项目分组 | 注入 FS |
| `JournalDistiller.swift` | spawn agent CLI 做 (厂商×项目) map-reduce；**唯一** spawn 处 | 注入 Process |
| `JournalSanitizer.swift` | `DayNote` → 合规 `DayNote` 或拒绝 | **纯** |
| `JournalRenderer.swift` | `DayNote` → Markdown，含 Q3 转义 | **纯** |
| `JournalTypes.swift` | `SessionSlice` / `SliceNote` / `DayNote` / `Outcome` | — |

改动既有文件：

- `Sources/Bridge/main.swift` —— 开头读 `ZACKEYES_JOURNAL=1` 即静默 `exit(0)`（落在铁律 2 已有的静默失败路径上，约 5 行）
- `AGENTS.md` —— scope 表加 `journal`
- `ARCHITECTURE.md` —— 组件表加 5 行 + 目录树加 `Journal/`

### 复用（侦察已确认）

- `Shared/AtomicFileWriter.write(...)`（#209）→ 本地草稿落盘
- `SessionScanner.allDateDirs(under:)` / `extractCodexSessionId(fromFilename:)` → codex 路径布局
- `Diagnostics/Redactor` → Sanitizer 复用规则但**改语义**：诊断里是替换成 `<user>`，日志里是丢弃整条

### 侦察发现的两个坑（写进计划以免开工才撞上）

1. **`DailyUsage` 给不了 per-project token。** `buildDailyUsage` 按「天 × agent × model」聚合，项目维度已折掉。但 #116 的 per-file `FileTally` 缓存仍在，而 Claude 文件路径 `~/.claude/projects/<encoded-cwd>/` 编码了项目 —— Collector 按路径重新折一次即可，**不需要重解析**。
2. **`SessionScanner` 只读 tail**（`readTail(of:maxBytes:)`，为探测设计）。Collector 要整天全文，须另写读取，并自带体积上限（单 slice 喂给 LLM 的原文需截断，截断策略：保留首尾、丢中段，因为开头有意图、结尾有结论）。

## 5. 测试

| 层 | 覆盖点 |
|----|--------|
| `JournalSanitizer` | 密钥前缀 ×8、路径样式 ×6、驼峰（白名单内外）、URL/IP、中英混排、`#123` 放行；**假阳性专项**：一批正常中英文句子必须全部通过 |
| `JournalRenderer` | 三档快照；**Q3 对抗性专项**：构造含 `#` / `-` / `[]()` / 换行的模型输出，断言产物里不出现新标题、列表项、链接 |
| `JournalCollector` | 本地日界（含 codex UTC 目录 → 本地日转换）、项目分组、别名/排除、全文截断保留首尾 |
| `JournalDistiller` | 注入假 Process：超时 kill、解析失败重试、全失败不产出；**Q0 专项**：断言 Claude slice 永不出现在 codex 命令行、反之亦然；**Q1 专项**：断言喂给某项目 reduce 的输入不含其他项目内容 |
| 严格解析器 | Claude 侧无 `--output-schema`，故单独测：缺字段、多字段、类型错、外包 Markdown 代码块、前后有解释性文字 —— 全部须拒绝而非猜测 |

**端到端真跑**（spec §8 + memory「Verify upstream before release」的硬要求，P1 阶段就做）：真跑一次 `codex exec --output-schema` 和一次 `claude -p --no-session-persistence`，验证 ① 确实没落 transcript（扫目录确认）② 确实没触发 hook（事件轨迹里没有幻影事件）③ 输出确实符合 schema。合成重放只证明「收到后处理对」，不证明这套 flag 真的这么工作。

## 6. 任务顺序

按「先能验证、后堆功能」排，每步可独立编译 + 测试：

1. `JournalTypes` + `JournalSanitizer` + 全套测试 —— 唯一安全边界，先钉死，且不依赖任何其他部分
2. `JournalRenderer` + Q3 对抗性测试 —— 同样是纯函数，可与 1 并行验证
3. `Bridge` 的 `ZACKEYES_JOURNAL=1` 静默路径 —— 5 行，但必须在任何 spawn 之前就位，否则第一次真跑就会造出幻影卡片
4. `JournalCollector` + 测试 —— 到此为止不 spawn 任何进程
5. `JournalDistiller` + 注入假 Process 的测试
6. **端到端真跑**（§5 末）—— 第一次真正 spawn；此时 3 已就位，不会自污染
7. 手动触发入口（临时菜单项即可，正式 UI 在 P2）+ 本地落盘
8. `ARCHITECTURE.md` / `AGENTS.md` 同步

## 7. P1 完成判据

- 手动触发能在 `~/.zackeyes/journal/` 生成当天 Markdown
- 实机确认：无幻影会话卡片、无 transcript 落盘、`DailyUsage` 未被污染
- Sanitizer 假阳性专项与 Q3 对抗性专项全绿
- `swift test` 全绿

## 8. 明确不在 P1

Keychain、`GitHubPublisher`、`LESSONS.md`、正式设置 UI（→ P2）；`JournalScheduler`、配额闸门、run 记录、网站文案（→ P3）。

**run 记录分两段**：Q2 的重试要靠它，所以**基础的写入与读回落在 P2**（与 `GitHubPublisher` 同期）；P3 只加调度相关的部分（延后计数、跨日）与汇入诊断报告。原稿把它整块记在 P3，与 Q2 冲突 —— 那会让 P2 实现 lessons 重试时没有可依赖的持久状态。

**注**：仓库里目前**没有任何 Keychain / `SecItem` 代码**，P2 要从零写。Security 是系统框架，不破铁律 6。
