# 蜡笔小新主题 + F1 音效扩充

**日期**: 2026-07-25
**状态**: 已实现并合并（PR #196 → `62aedf3`），随下一个版本发布。
配音版本已于 2026-07-26 经用户人工试听确认为国语新版。

## 目标

1. 给现有 `f1` 主题补充几个有辨识度的车队电台音效
2. 新增第四个 `BuddyTheme`：蜡笔小新（台配国语），带角色名池、台词池、音效

## 背景

`BuddyTheme` 是一个自包含的枚举：一个 case 打包了 displayName、名字池、tagline 池、音效列表。
新增主题不需要动数据流或存储层——`ConfigStore` 存的是 theme 的 rawValue，
`NotificationManager.playThemeSound()` 只按当前主题校验音效文件归属。
`silicon` 主题（2026-05-08）已经验证过这条路径。

## 音效来源

沿用 `566b6f3`（F1 Verstappen 电台）和 `a386b9d`（silicon TTS）的做法：
真实片段 → yt-dlp 抓取 → whisper-cpp 转写定位台词边界 → ffmpeg 精确裁剪 →
`loudnorm=I=-16:TP=-1.5` 归一化，与现有 18 个音效响度一致（现有基准实测 -16.5 LUFS）。

取材经过两轮：第一轮 11 个候选，用户试听后留下 F1 的 3 个；小新那批因配音版本无法确认
整批作废（详见「音效」小节）。第二轮从新番片源重取，用户从中挑定 7 个。
本设计实现的是两轮筛选后最终留下的 10 个片段。

## 菜单文案一律英文

主题名与音效名会出现在设置面板的选择菜单里，统一用英文。
新主题 displayName 为 `Crayon Shin-chan`，音效名全英文；
既有的 `silicon` 主题 displayName 由「AI 大佬」改为 `AI Moguls` 以保持一致。
名字池与 tagline 池不受此约束——它们显示在刘海面板的会话卡片上，不是菜单，
且中文正是主题特征（`silicon` 已有此先例）。
契约测试 `testMenuLabelsAreEnglish` 用 `\p{Han}` 正则钉死这条规则。

## 变更一：F1 主题 +3 音效

`f1` 可播放音效从 7 个增加到 10 个（`availableSounds` 条目含 `None` 共 11 条）。
追加在 `f1-radio` 之后、`None` 之前，
保持既有条目顺序不变（默认音效仍是 `box-box`）。

| 显示名 | 文件 | 内容 | 时长 |
|---|---|---|---|
| Lights Out 🚦 | `lights-out` | "It's lights out and away we go" | 3.7s |
| GP2 Engine 😤 | `gp2-engine` | Alonso 2015 铃鹿 "GP2 engine, GP2! ARGH!" | 5.6s |
| It's Valtteri 🧊 | `james-its-valtteri` | Bottas "James, it's Valtteri." | 1.7s |

`lights-out` 已于本次会话中先行落地（用户单独指定），代码与测试已通过。

## 变更二：新主题 `shinchan`

### 枚举

```swift
case shinchan   // displayName: "Crayon Shin-chan"
```

### 音效（7 + None）

配音版本要求**国语新版**（2019 年之后接手的台配班底）。取材时无法靠听辨版本，
判定依据只能是片源标注：素材取自明确标注「蠟筆小新新番 第十季 / 第十一季」的两集
动感超人剧集（`5GuGqRNAnNs`、`6y3KrzLg2kc`），整集 whisper 转写后按词级时间戳定位切分。
最初一批取自 UP 主二次剪辑合集、版本无法确认，已整批作废。
成品已于 2026-07-26 经用户人工试听确认确为新版配音——即片源标注这条判定依据成立。

默认音效为 `xin-yay`（列表首项）——短、正向，契合「任务完成」的播放语境。

| 显示名 | 文件 | 内容 | 时长 |
|---|---|---|---|
| Awesome! 🎉 | `xin-yay` | 「太棒了」 | 1.2s |
| Eh-heh 😏 | `xin-eheh` | 小新招牌语气「嗨哩嗨哩」 | 1.3s |
| I'm Home 🏠 | `xin-im-home` | 「我回来了」「小新，有礼物哦」 | 2.7s |
| Are You Crazy?! 😳 | `xin-are-you-crazy` | 「妈妈，你是不是疯了」 | 1.7s |
| Cute Butt 🍑 | `xin-cute-butt` | 「可爱屁屁」 | 1.5s |
| Justice Wins ⚖️ | `xin-justice` | 「正义终究会获胜」 | 2.0s |
| Action Kamen 🦸 | `kamen-laugh` | 动感超人招牌笑声 | 3.2s |
| None 🔇 | `none` | 静音（保留字） | — |

正片音轨自带 BGM，不像专门制作的音效那样纯净——这是从剧集取材的固有代价，用户试听后仍选定了这批片段。

### 名字池（16 个）

格式沿用 `silicon` 的 "{名字} from {组织}"，不带国旗（单一国别，加旗子无信息量）。

野原家 5：新之助、美冴、广志、小葵、小白
向日葵班 4：风间、妮妮、正男、阿呆
双叶幼稚园 4：园长、吉永老师、松坂老师、上尾老师
春日部 3：娜娜子、动感超人、肥嘟嘟左卫门

### Tagline 池（20 条）

真实台配国语台词，与 `f1`（真实车队电台）、`silicon`（真实行业语录）的做法一致，
不写自造的开发者梗。

### 头像

复用 `rockTemplates`（`PixelAvatar` 里 `theme == .f1 ? f1Templates : rockTemplates`），
与 `silicon` 主题的处理一致——不为第四个主题新画一套像素模板。
`themeSwatch` 配色用红 + 黄（小新的红上衣 + 黄裤子）。

## 不做的事

- 不新增像素模板集（YAGNI，silicon 已确立复用先例）
- 不改存储层、不改音效播放逻辑——两者都是主题无关的
- 不做每主题独立记忆音效选择（切主题即重置为默认，是既有行为）

## 测试

`Tests/AppLibTests/BuddyThemeTests.swift` 沿用 silicon 的测试组结构：
case 存在性、displayName、`allCases.count` 3→4、名字/tagline 数量与关键条目、
音效数量与文件名唯一性、默认音效、Codable round-trip，
以及已有的「原有音效文件仍归属原主题」回归断言（F1 列表需同步更新）。

新增一条测试：所有主题声明的音效文件（除 `none`）在 `Resources/` 中都存在对应 mp3——
防止「代码里加了选项但忘了提交音频文件」这类静默失败（用户会选中一个永远不响的音效）。
