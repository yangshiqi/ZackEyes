# AI Mogul Theme Design

## Goal

Add a third `BuddyTheme` — `silicon` ("AI 大佬") — alongside `rock` and `f1`. Each session is assigned a Silicon Valley or Chinese AI mogul as buddy with a real famous quote / meme as tagline, and notification sounds are short clips of those moguls' signature lines.

Closes [#18](https://github.com/yangshiqi/ZackEyes/issues/18).

## Scope

- One new enum case + name pool (34) + tagline pool (29) + sound pool (6 + None).
- Six new mp3 files in `Resources/`.
- No UI changes — `StatusBarMenu` and `GearMenuTarget` are data-driven over `BuddyTheme.allCases`.
- No config migration — existing users on `rock`/`f1` are unaffected.

Out of scope: per-buddy sounds (sounds are theme-wide, like `f1`); user-customizable name lists; non-MP3 audio formats.

## Theme Metadata

| Field | Value |
|-------|-------|
| `BuddyTheme` enum case | `silicon` |
| `displayName` | `"AI 大佬"` |
| Default sound | `agi-altman` (first in `availableSounds`) |

`silicon` is chosen for symmetry with `rock` / `f1` (short, lowercase, single-word). It evokes Silicon Valley while not excluding the Chinese half of the roster — both are part of the same AI mogul aesthetic.

## Name Pool (34)

Format follows `f1`: `{flag} {first-name} from {Org}`. For Chinese moguls, use given name in Chinese characters when more recognizable than English transliteration.

### Silicon Valley / Global (22)

```
🇺🇸 Sam from OpenAI
🇺🇸 Greg from OpenAI
🇮🇱 Ilya from SSI
🇦🇱 Mira from Thinking Machines
🇮🇹 Dario from Anthropic
🇮🇹 Daniela from Anthropic
🇬🇧 Demis from DeepMind
🇹🇼 Jensen from Nvidia
🇿🇦 Elon from xAI
🇺🇸 Zuck from Meta
🇮🇳 Sundar from Google
🇮🇳 Satya from Microsoft
🇨🇦 Geoff from Toronto
🇫🇷 Yann from Meta
🇨🇦 Yoshua from Mila
🇸🇰 Andrej from Eureka
🇨🇳 Fei-Fei from Stanford
🇬🇧 Andrew from DeepLearning.AI
🇮🇳 Aravind from Perplexity
🇫🇷 Arthur from Mistral
🇬🇧 Mustafa from MS AI
🇮🇱 Noam from Character
```

### China (12)

```
🇨🇳 文锋 from DeepSeek
🇨🇳 植麟 from Moonshot
🇨🇳 Kai-Fu from 01.AI
🇨🇳 小川 from Baichuan
🇨🇳 一鸣 from ByteDance
🇨🇳 兴兴 from Unitree
🇨🇳 Robin from Baidu
🇨🇳 Pony from Tencent
🇨🇳 Ren from Huawei
🇨🇳 鸿祎 from 360
🇨🇳 慧文 from Light Year
🇨🇳 扬清 from Lepton
```

## Tagline Pool (29)

Real AI-industry quotes, memes, and shibboleths. Mix English and Chinese.

```
AGI is coming
We need more compute
Just scale it
Stochastic parrot
The bitter lesson
Attention is all you need
The more you buy, the more you save
Software is eating the world
It's just matmul
Move fast and break things
e/acc — accelerate or die
What's your p(doom)?
Vibes-based eval
The model is the product
We are so back
It's so over
Scaling laws don't lie
Just one more epoch bro
Backprop through everything
Race to the top
Powerful AI
Genius in a datacenter
源神，启动！
把成本打下来
All in 大模型
拥抱变化
卷死他们
幻觉是特性不是 bug
百模大战
```

Three Dario Amodei phrases (`Race to the top`, `Powerful AI`, `Genius in a datacenter`) appear here — partial overlap with the sound pool is intentional and matches the `f1` design (sound `box-box` ↔ tagline `Box box, box box`).

## Sound Pool (6 + None)

Strategy: **Path A first** (real mogul voice clips). For each sound, source a clean 1–2 second clip from a public interview, podcast, or keynote. If a clean clip cannot be found within reasonable effort, **fall back to Path B** (sci-fi / AI-themed effect, CC0 source) for that one slot.

### Path A — primary (real voice clips)

| # | Display Name | Filename | Source | Notes |
|---|--------------|----------|--------|-------|
| 1 | "AGI" 🚀 | `agi-altman` | Sam Altman, any interview | Single word, easiest to extract cleanly |
| 2 | "More compute" 💰 | `more-compute-jensen` | Jensen Huang, GTC keynote | Two-word phrase |
| 3 | "We are so back" 🔥 | `so-back` | Generic AI Twitter/podcast meme | Multiple speakers; pick clearest |
| 4 | "It's just tokens" 🎯 | `tokens-karpathy` | Karpathy, "Let's build GPT" series | Educational video, clean audio |
| 5 | "Race to the top" 🏁 | `race-to-the-top-dario` | Dario Amodei, Anthropic core narrative | Strategic Anthropic phrase |
| 6 | "Move fast" ⚡ | `move-fast-zuck` | Zuck, early Meta era | Iconic two-word version |
| 7 | None 🔇 | `none` | — | Reserved silence sentinel |

### Path B — per-slot fallback

If Path A slot N is impossible, replace with one of these (CC0 / public-domain effect). Preserve the slot's display position; rename file accordingly:

```
hal-chime          — HAL 9000 console chime
gpt-bell           — ChatGPT response done bell
jarvis-startup     — JARVIS UI startup
r2d2-beep          — short R2D2 beep
tpu-whoosh         — datacenter fan whoosh
terminal-bell      — terminal \a beep
```

Implementation PR will list which Path A slots succeeded vs. fell back to Path B in the PR description, so this design doc remains the source of truth for *intent*, while the PR documents *reality*.

### File constraints

- Format: MP3 (matches existing `Resources/*.mp3`).
- Duration: 1–2 seconds (per issue #18 requirement).
- Loudness: roughly match existing files (`f1-radio.mp3` ≈ -16 LUFS as reference).
- File size: under 60 KB each (existing files range 18–90 KB).

## Buddy Assignment

Unchanged. `Buddy.from(sessionId:theme:)` already hashes session ID against `theme.names.count` and `theme.taglines.count`. Adding 34 names + 29 taglines into `BuddyTheme.silicon`'s arrays makes silicon work automatically, deterministically.

## Code Structure

### `Sources/AppLib/Notch/Buddy.swift`

- Add `case silicon` to `BuddyTheme` enum.
- Extend `displayName` switch: `case .silicon: return "AI 大佬"`.
- Extend `availableSounds` switch with the silicon sound list above.
- Extend `names` and `taglines` switches with `case .silicon: return Self.siliconNames` / `Self.siliconTaglines`.
- Add two new `private static let` arrays: `siliconNames`, `siliconTaglines`.

### `Resources/`

- Add: `agi-altman.mp3`, `more-compute-jensen.mp3`, `so-back.mp3`, `tokens-karpathy.mp3`, `race-to-the-top-dario.mp3`, `move-fast-zuck.mp3` (or Path B equivalents).
- `Package.swift` already has `.process("Resources")` rule on the App target — new mp3s are picked up automatically with no manifest edit.

### Files NOT modified

- `Sources/AppLib/MenuBar/StatusBarMenu.swift` — `themeSubmenuItem()` iterates `BuddyTheme.allCases` and `theme.availableSounds`. Data-driven.
- `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift` — `themeClicked()` / `soundClicked()` operate on the persisted theme + filename. No theme-specific branches.
- `Sources/AppLib/Config/ConfigStore.swift` — already stores theme as `BuddyTheme` raw value (`Codable`); `silicon` round-trips automatically.

## Tests

`Tests/SharedTests/` should add or update tests covering:

1. **Enum completeness** — `BuddyTheme.allCases.count == 3` and contains `.silicon`.
2. **Pool non-empty** — `BuddyTheme.silicon.names.count > 0`, `.taglines.count > 0`, `.availableSounds.count > 0`.
3. **Default sound exists** — `BuddyTheme.silicon.defaultSoundFile == "agi-altman"` (or whatever Path B fallback wins for slot 1).
4. **Round-trip** — encode `BuddyTheme.silicon` to JSON, decode, equal.
5. **Determinism** — `Buddy.from(sessionId: "fixed-id", theme: .silicon)` returns the same `(name, tagline)` across calls.

No need to test that every sound file exists at runtime — `GearMenuTarget` already tolerates missing files (logs and skips preview).

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Mogul voice clip copyright | Short clips (1–2s), used as UI sound effect, fall under fair use for personal/non-commercial use. App is currently distributed gratis. If a clip becomes legally questionable, swap to Path B. |
| Quote misattribution | Each Path A clip is sourced from a verifiable public interview / keynote. PR description lists source URLs. |
| Cultural insensitivity in name flags | Flags use birth-country or primary-association country, matching `f1`'s convention. Dario / Daniela use 🇮🇹 (Italian-American is a recognized identity). Andrej uses 🇸🇰 (Slovak — his birth country). Edge cases will be revisited if any user complains. |
| China names not understood by English speakers | Mixed format (some English first names like `Robin`, `Pony`, `Kai-Fu`; some Chinese characters like `文锋`, `植麟`) intentionally — the Chinese characters are the primary public identity for those founders. |

## Open Questions

None. All taste decisions resolved during brainstorming.

## Acceptance

- `BuddyTheme.silicon` selectable from gear menu under "Theme" submenu.
- Selecting silicon shows "AI 大佬" as the menu label.
- New session shows a buddy from the silicon pool with a silicon tagline.
- Sound submenu lists 6 silicon sounds + None.
- Selecting a sound previews it via `NSSound`.
- All `swift test` targets pass.
- No regressions: switching back to rock or f1 still works, and existing config files load without migration.
