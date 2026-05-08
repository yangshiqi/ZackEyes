# AI Mogul Theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `BuddyTheme.silicon` ("AI 大佬") with 34 mogul names, 29 real-quote taglines, and 6 voice-clip sounds, closing [#18](https://github.com/yangshiqi/ZackEyes/issues/18).

**Architecture:** Pure additive change to `Sources/AppLib/Notch/Buddy.swift` (one new enum case + four switch branches + two `static let` arrays). Sound mp3 files dropped into `Resources/` are auto-bundled by `Makefile`'s `cp Resources/*.mp3` step. No UI code changes — `StatusBarMenu` and `GearMenuTarget` already iterate `BuddyTheme.allCases`. New test file `Tests/AppLibTests/BuddyThemeTests.swift` for the silicon-specific assertions.

**Tech Stack:** Swift 6, swift-testing (`@Test` / `#expect`), XCTest (`XCTAssert*`) where existing code uses it. macOS 14+. Foundation only (no third-party deps).

**Spec:** [`docs/superpowers/specs/2026-05-08-ai-mogul-theme-design.md`](../specs/2026-05-08-ai-mogul-theme-design.md)

---

## Pre-flight

- [ ] **Verify clean working tree**

```bash
cd /Users/ysq/Work/lab/ccisland
git status
```

Expected: `working tree clean` on `master`. If not, stash or commit before starting.

- [ ] **Verify baseline tests pass**

```bash
swift test 2>&1 | tail -5
```

Expected: `Test Suite 'All tests' passed`. If anything is broken before our changes, stop and investigate.

---

## Task 1: Scaffold `silicon` enum case + displayName

Goal: Get the enum case to exist with correct displayName so subsequent tests can target it. We use empty arrays + a single placeholder sound entry as scaffolding — they'll be filled in tasks 2–4.

**Files:**
- Create: `Tests/AppLibTests/BuddyThemeTests.swift`
- Modify: `Sources/AppLib/Notch/Buddy.swift`

- [ ] **Step 1: Write the failing test**

Create new file `Tests/AppLibTests/BuddyThemeTests.swift`:

```swift
import XCTest
@testable import AppLib

final class BuddyThemeTests: XCTestCase {

    func testSiliconCaseExists() {
        XCTAssertTrue(BuddyTheme.allCases.contains(.silicon))
    }

    func testSiliconDisplayName() {
        XCTAssertEqual(BuddyTheme.silicon.displayName, "AI 大佬")
    }

    func testAllCasesCount() {
        XCTAssertEqual(BuddyTheme.allCases.count, 3)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
swift test --filter BuddyThemeTests 2>&1 | tail -15
```

Expected: compile error — `type 'BuddyTheme' has no member 'silicon'`.

- [ ] **Step 3: Add `case silicon` to enum + displayName + scaffold the four switch branches**

In `Sources/AppLib/Notch/Buddy.swift`, modify the enum (replace the entire enum head + first three computed properties; keep arrays intact):

Replace:
```swift
public enum BuddyTheme: String, Codable, CaseIterable, Sendable {
    case rock
    case f1

    public var displayName: String {
        switch self {
        case .rock: return "Rock Legends"
        case .f1:   return "F1 2026"
        }
    }
```

With:
```swift
public enum BuddyTheme: String, Codable, CaseIterable, Sendable {
    case rock
    case f1
    case silicon

    public var displayName: String {
        switch self {
        case .rock:    return "Rock Legends"
        case .f1:      return "F1 2026"
        case .silicon: return "AI 大佬"
        }
    }
```

Then in `availableSounds`, add a scaffold case (the real sounds come in Task 4):

Replace:
```swift
        case .f1: return [
            ("Box Box 📻",           "box-box"),
            ("Get In There! 🏆",     "get-in-there"),
            ("FOR WHAT?! 😤",        "for-what"),
            ("Simply Lovely 😌",     "simply-lovely"),
            ("Super Max 🎵",         "super-max"),
            ("Team Radio 📡",        "team-radio"),
            ("F1 Radio 🏎️",          "f1-radio"),
            ("None 🔇",              "none"),
        ]
        }
    }
```

With:
```swift
        case .f1: return [
            ("Box Box 📻",           "box-box"),
            ("Get In There! 🏆",     "get-in-there"),
            ("FOR WHAT?! 😤",        "for-what"),
            ("Simply Lovely 😌",     "simply-lovely"),
            ("Super Max 🎵",         "super-max"),
            ("Team Radio 📡",        "team-radio"),
            ("F1 Radio 🏎️",          "f1-radio"),
            ("None 🔇",              "none"),
        ]
        case .silicon: return [
            ("None 🔇", "none"),
        ]
        }
    }
```

Then in `names` switch:

Replace:
```swift
    var names: [String] {
        switch self {
        case .rock: return Self.rockNames
        case .f1:   return Self.f1Names
        }
    }
```

With:
```swift
    var names: [String] {
        switch self {
        case .rock:    return Self.rockNames
        case .f1:      return Self.f1Names
        case .silicon: return Self.siliconNames
        }
    }
```

Then in `taglines` switch:

Replace:
```swift
    var taglines: [String] {
        switch self {
        case .rock: return Self.rockTaglines
        case .f1:   return Self.f1Taglines
        }
    }
```

With:
```swift
    var taglines: [String] {
        switch self {
        case .rock:    return Self.rockTaglines
        case .f1:      return Self.f1Taglines
        case .silicon: return Self.siliconTaglines
        }
    }
```

Finally, add two empty arrays inside the enum, immediately after the `f1Taglines` array's closing `]` and *before* the enum's closing `}`. Do **not** add another `}` — the enum closer already exists. The arrays are temporary; they get filled in Tasks 2 and 3:

```swift

    // MARK: - Silicon Valley AI moguls theme

    private static let siliconNames: [String] = []

    private static let siliconTaglines: [String] = []
```

(The next line in the file should be the enum's existing `}`.)

- [ ] **Step 4: Run tests to verify pass**

```bash
swift test --filter BuddyThemeTests 2>&1 | tail -10
```

Expected: `Test Suite 'BuddyThemeTests' passed` with 3 tests succeeded.

Also run full test suite to verify no regressions:

```bash
swift test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Notch/Buddy.swift Tests/AppLibTests/BuddyThemeTests.swift
git commit -m "$(cat <<'EOF'
feat(buddy): scaffold silicon theme enum case

Wires the silicon BuddyTheme case into displayName, names, taglines,
and availableSounds switches with empty/placeholder data. Real
content lands in follow-up commits (#18).
EOF
)"
```

---

## Task 2: Populate silicon names (34 entries)

**Files:**
- Modify: `Tests/AppLibTests/BuddyThemeTests.swift`
- Modify: `Sources/AppLib/Notch/Buddy.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/AppLibTests/BuddyThemeTests.swift` inside the `BuddyThemeTests` class (just before the closing `}`):

```swift
    func testSiliconNamesCount() {
        XCTAssertEqual(BuddyTheme.silicon.names.count, 34)
    }

    func testSiliconNamesIncludeKnownMoguls() {
        let names = BuddyTheme.silicon.names
        XCTAssertTrue(names.contains("🇺🇸 Sam from OpenAI"))
        XCTAssertTrue(names.contains("🇮🇹 Dario from Anthropic"))
        XCTAssertTrue(names.contains("🇹🇼 Jensen from Nvidia"))
        XCTAssertTrue(names.contains("🇨🇳 文锋 from DeepSeek"))
        XCTAssertTrue(names.contains("🇨🇳 植麟 from Moonshot"))
    }

    func testSiliconNamesNoJackMa() {
        // Jack Ma was intentionally excluded per spec.
        let names = BuddyTheme.silicon.names
        XCTAssertFalse(names.contains(where: { $0.contains("Jack from Alibaba") }))
    }
```

- [ ] **Step 2: Run tests to verify failure**

```bash
swift test --filter BuddyThemeTests 2>&1 | tail -15
```

Expected: 2 tests fail (`testSiliconNamesCount` expects 34 but got 0; `testSiliconNamesIncludeKnownMoguls` fails the first assertion). `testSiliconNamesNoJackMa` already passes (empty array).

- [ ] **Step 3: Fill in `siliconNames` array**

In `Sources/AppLib/Notch/Buddy.swift`, replace:

```swift
    private static let siliconNames: [String] = []
```

With:

```swift
    /// Silicon Valley + China AI moguls (34 total). Format: "{flag} {first-name} from {Org}".
    private static let siliconNames: [String] = [
        // Silicon Valley / Global (22)
        "🇺🇸 Sam from OpenAI",
        "🇺🇸 Greg from OpenAI",
        "🇮🇱 Ilya from SSI",
        "🇦🇱 Mira from Thinking Machines",
        "🇮🇹 Dario from Anthropic",
        "🇮🇹 Daniela from Anthropic",
        "🇬🇧 Demis from DeepMind",
        "🇹🇼 Jensen from Nvidia",
        "🇿🇦 Elon from xAI",
        "🇺🇸 Zuck from Meta",
        "🇮🇳 Sundar from Google",
        "🇮🇳 Satya from Microsoft",
        "🇨🇦 Geoff from Toronto",
        "🇫🇷 Yann from Meta",
        "🇨🇦 Yoshua from Mila",
        "🇸🇰 Andrej from Eureka",
        "🇨🇳 Fei-Fei from Stanford",
        "🇬🇧 Andrew from DeepLearning.AI",
        "🇮🇳 Aravind from Perplexity",
        "🇫🇷 Arthur from Mistral",
        "🇬🇧 Mustafa from MS AI",
        "🇮🇱 Noam from Character",
        // China (12)
        "🇨🇳 文锋 from DeepSeek",
        "🇨🇳 植麟 from Moonshot",
        "🇨🇳 Kai-Fu from 01.AI",
        "🇨🇳 小川 from Baichuan",
        "🇨🇳 一鸣 from ByteDance",
        "🇨🇳 兴兴 from Unitree",
        "🇨🇳 Robin from Baidu",
        "🇨🇳 Pony from Tencent",
        "🇨🇳 Ren from Huawei",
        "🇨🇳 鸿祎 from 360",
        "🇨🇳 慧文 from Light Year",
        "🇨🇳 扬清 from Lepton",
    ]
```

- [ ] **Step 4: Run tests to verify pass**

```bash
swift test --filter BuddyThemeTests 2>&1 | tail -10
```

Expected: all tests in `BuddyThemeTests` pass (now 6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Notch/Buddy.swift Tests/AppLibTests/BuddyThemeTests.swift
git commit -m "$(cat <<'EOF'
feat(buddy): add 34 silicon-theme mogul names

22 Silicon Valley + 12 China AI moguls per spec, "{flag} {name} from
{Org}" format matching f1 theme convention.
EOF
)"
```

---

## Task 3: Populate silicon taglines (29 entries)

**Files:**
- Modify: `Tests/AppLibTests/BuddyThemeTests.swift`
- Modify: `Sources/AppLib/Notch/Buddy.swift`

- [ ] **Step 1: Write the failing test**

Append to `BuddyThemeTests` class:

```swift
    func testSiliconTaglinesCount() {
        XCTAssertEqual(BuddyTheme.silicon.taglines.count, 29)
    }

    func testSiliconTaglinesIncludeKnownMemes() {
        let taglines = BuddyTheme.silicon.taglines
        XCTAssertTrue(taglines.contains("AGI is coming"))
        XCTAssertTrue(taglines.contains("Race to the top"))
        XCTAssertTrue(taglines.contains("The bitter lesson"))
        XCTAssertTrue(taglines.contains("源神，启动！"))
        XCTAssertTrue(taglines.contains("把成本打下来"))
    }

    func testSiliconTaglinesNo996() {
        // 996 是福报 was dropped along with Jack Ma per spec.
        XCTAssertFalse(BuddyTheme.silicon.taglines.contains("996 是福报"))
    }
```

- [ ] **Step 2: Run tests to verify failure**

```bash
swift test --filter BuddyThemeTests 2>&1 | tail -15
```

Expected: 2 new tests fail (count + meme assertions); `testSiliconTaglinesNo996` already passes (empty array).

- [ ] **Step 3: Fill in `siliconTaglines` array**

In `Sources/AppLib/Notch/Buddy.swift`, replace:

```swift
    private static let siliconTaglines: [String] = []
```

With:

```swift
    /// Real AI-industry quotes, memes, and shibboleths (29 total).
    private static let siliconTaglines: [String] = [
        "AGI is coming",
        "We need more compute",
        "Just scale it",
        "Stochastic parrot",
        "The bitter lesson",
        "Attention is all you need",
        "The more you buy, the more you save",
        "Software is eating the world",
        "It's just matmul",
        "Move fast and break things",
        "e/acc — accelerate or die",
        "What's your p(doom)?",
        "Vibes-based eval",
        "The model is the product",
        "We are so back",
        "It's so over",
        "Scaling laws don't lie",
        "Just one more epoch bro",
        "Backprop through everything",
        "Race to the top",
        "Powerful AI",
        "Genius in a datacenter",
        "源神，启动！",
        "把成本打下来",
        "All in 大模型",
        "拥抱变化",
        "卷死他们",
        "幻觉是特性不是 bug",
        "百模大战",
    ]
```

- [ ] **Step 4: Run tests to verify pass**

```bash
swift test --filter BuddyThemeTests 2>&1 | tail -10
```

Expected: all `BuddyThemeTests` pass (now 9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Notch/Buddy.swift Tests/AppLibTests/BuddyThemeTests.swift
git commit -m "$(cat <<'EOF'
feat(buddy): add 29 silicon-theme taglines

Real AI-industry quotes and memes mixing English and Chinese. Three
Dario phrases overlap with the (forthcoming) sound pool, mirroring f1
theme's design.
EOF
)"
```

---

## Task 4: Populate silicon `availableSounds` (6 sounds + None)

Goal: Replace the placeholder `availableSounds` entry with the full 7-entry list. Filenames here name the *intended* clips. Whether they come from Path A (real voice) or Path B (sci-fi fallback) is decided in Task 5 per slot, possibly renaming files at that point.

**Files:**
- Modify: `Tests/AppLibTests/BuddyThemeTests.swift`
- Modify: `Sources/AppLib/Notch/Buddy.swift`

- [ ] **Step 1: Write the failing test**

Append to `BuddyThemeTests` class:

```swift
    func testSiliconSoundsCount() {
        // 6 sound options + None sentinel.
        XCTAssertEqual(BuddyTheme.silicon.availableSounds.count, 7)
    }

    func testSiliconHasNoneSentinel() {
        let files = BuddyTheme.silicon.availableSounds.map(\.file)
        XCTAssertTrue(files.contains("none"))
    }

    func testSiliconDefaultSound() {
        XCTAssertEqual(BuddyTheme.silicon.defaultSoundFile, "agi-altman")
    }

    func testSiliconSoundFilenamesUnique() {
        let files = BuddyTheme.silicon.availableSounds.map(\.file)
        XCTAssertEqual(files.count, Set(files).count, "duplicate sound filenames")
    }

    func testSiliconCodableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(BuddyTheme.silicon)
        let decoded = try JSONDecoder().decode(BuddyTheme.self, from: encoded)
        XCTAssertEqual(decoded, .silicon)
    }

    func testBuddyAssignmentIsDeterministic() {
        let a = Buddy.from(sessionId: "fixed-session-id", theme: .silicon)
        let b = Buddy.from(sessionId: "fixed-session-id", theme: .silicon)
        XCTAssertEqual(a.name, b.name)
        XCTAssertEqual(a.tagline, b.tagline)
        XCTAssertTrue(BuddyTheme.silicon.names.contains(a.name))
        XCTAssertTrue(BuddyTheme.silicon.taglines.contains(a.tagline))
    }
```

- [ ] **Step 2: Run tests to verify failure**

```bash
swift test --filter BuddyThemeTests 2>&1 | tail -15
```

Expected: `testSiliconSoundsCount` fails (got 1, expected 7); `testSiliconDefaultSound` fails (got "none", expected "agi-altman"). The other new tests (`testSiliconHasNoneSentinel`, `testSiliconSoundFilenamesUnique`, `testSiliconCodableRoundTrip`, `testBuddyAssignmentIsDeterministic`) already pass — silicon's String rawValue Codable is automatic, and `Buddy.from` is unchanged.

- [ ] **Step 3: Replace placeholder `availableSounds` entry with full list**

In `Sources/AppLib/Notch/Buddy.swift`, replace:

```swift
        case .silicon: return [
            ("None 🔇", "none"),
        ]
```

With:

```swift
        case .silicon: return [
            ("AGI 🚀",            "agi-altman"),
            ("More Compute 💰",   "more-compute-jensen"),
            ("So Back 🔥",        "so-back"),
            ("Just Tokens 🎯",    "tokens-karpathy"),
            ("Race to the Top 🏁", "race-to-the-top-dario"),
            ("Move Fast ⚡",      "move-fast-zuck"),
            ("None 🔇",           "none"),
        ]
```

- [ ] **Step 4: Run tests to verify pass**

```bash
swift test --filter BuddyThemeTests 2>&1 | tail -10
```

Expected: all `BuddyThemeTests` pass (15 tests).

- [ ] **Step 5: Verify full test suite still passes**

```bash
swift test 2>&1 | tail -5
```

Expected: all tests pass — including `ConfigStoreTests` (which exercises theme round-trip via `f1`, but `silicon` should round-trip identically since `BuddyTheme` is a `String` rawValue Codable).

- [ ] **Step 6: Commit**

```bash
git add Sources/AppLib/Notch/Buddy.swift Tests/AppLibTests/BuddyThemeTests.swift
git commit -m "$(cat <<'EOF'
feat(buddy): add silicon-theme sound pool (6 + None)

Filenames declared here; mp3 files land in next commit. Default is
agi-altman (Sam Altman saying "AGI"). Sound list spans Sam, Jensen,
generic 'so back' meme, Karpathy, Dario (Anthropic), and Zuck.
EOF
)"
```

---

## Task 5: Source and add 6 mp3 files to `Resources/`

This task is **manual / out-of-band** — you cannot generate audio from code. The plan documents acceptance criteria and per-slot fallback strategy.

**Files:**
- Create: `Resources/agi-altman.mp3`
- Create: `Resources/more-compute-jensen.mp3`
- Create: `Resources/so-back.mp3`
- Create: `Resources/tokens-karpathy.mp3`
- Create: `Resources/race-to-the-top-dario.mp3`
- Create: `Resources/move-fast-zuck.mp3`

For each filename, follow Path A first (clip from public interview/keynote). If clean 1–2 second extract is impossible within ~30 minutes of effort, fall back to Path B per the spec (sci-fi effect, CC0 source).

- [ ] **Step 1: For each of the 6 filenames, source a clip**

Per spec table — sources:

| Filename | Path A source | Path B fallback (CC0) |
|----------|---------------|----------------------|
| `agi-altman.mp3` | Sam Altman saying "AGI" — pick from any 2024–2025 podcast (Lex Fridman, All-In, Hard Fork) | `gpt-bell.mp3` (ChatGPT response chime — freesound.org CC0) |
| `more-compute-jensen.mp3` | Jensen at GTC 2024/2025 keynote saying "more compute" or just "compute" | `tpu-whoosh.mp3` (datacenter fan whoosh — freesound.org CC0) |
| `so-back.mp3` | Any AI Twitter/podcast clip "we are so back" — multiple speakers; pick clearest | `jarvis-startup.mp3` (Iron Man UI startup-style synth, original or CC0) |
| `tokens-karpathy.mp3` | Karpathy "Let's build GPT" / "micrograd" video saying "tokens" or "just tokens" | `terminal-bell.mp3` (`\a` beep — generate via `printf '\a' > foo.aiff` or freesound CC0) |
| `race-to-the-top-dario.mp3` | Dario Amodei interview saying "race to the top" — Lex Fridman, Hard Fork, or Anthropic blog audio | `hal-chime.mp3` (HAL 9000-style chime — freesound CC0) |
| `move-fast-zuck.mp3` | Zuck early Meta era saying "move fast" — Senate hearing or F8 keynote | `r2d2-beep.mp3` (short R2D2-style beep — freesound CC0) |

Tools you can use:
- `yt-dlp <url> --extract-audio --audio-format mp3` — pull podcast audio
- `ffmpeg -i input.mp3 -ss 00:12:34.5 -t 1.5 -acodec mp3 output.mp3` — extract a 1.5-second slice starting at 12:34.5
- Any DAW (Logic, GarageBand, Audacity) for fine trimming + normalization

Per-clip acceptance:
- Duration: 1.0–2.0 seconds
- Loudness roughly matched to existing files (use `ffmpeg -i Resources/f1-radio.mp3 -af volumedetect -f null /dev/null` as reference; aim for similar mean_volume)
- File size: < 60 KB
- No background noise drowning the phrase

If a Path A clip cannot be sourced cleanly, swap to its Path B fallback. **Update `Sources/AppLib/Notch/Buddy.swift` `availableSounds` to match the actual filename used** (e.g., if `agi-altman` is impossible, change `"agi-altman"` to `"gpt-bell"` and `"AGI 🚀"` to `"GPT Bell 🔔"`).

> **Test update if slot 1 falls back:** the default sound is whichever entry sits at `availableSounds[0]`. If slot 1 falls back from `agi-altman` to its Path B equivalent, also update the assertion in `testSiliconDefaultSound` (`Tests/AppLibTests/BuddyThemeTests.swift`) to match the new filename. Stage all three changes (mp3 file, `Buddy.swift`, test) in the same commit so name-content-test stay in sync.

- [ ] **Step 2: Verify each file lands at the correct path with correct extension**

```bash
ls -lh Resources/agi-altman.mp3 Resources/more-compute-jensen.mp3 Resources/so-back.mp3 \
       Resources/tokens-karpathy.mp3 Resources/race-to-the-top-dario.mp3 \
       Resources/move-fast-zuck.mp3 2>&1
```

Expected: 6 files present, each under 60 KB. (If any slot fell back, that filename will differ — adjust the `ls` command accordingly.)

- [ ] **Step 3: Verify each file plays via `afplay`**

```bash
for f in Resources/agi-altman.mp3 Resources/more-compute-jensen.mp3 Resources/so-back.mp3 \
         Resources/tokens-karpathy.mp3 Resources/race-to-the-top-dario.mp3 \
         Resources/move-fast-zuck.mp3; do
    echo "Playing $f"
    afplay "$f"
done
```

Expected: each file plays cleanly, 1–2 seconds each, audible content matching its filename.

- [ ] **Step 4: Build the .app bundle and verify mp3s land in Resources**

```bash
make app
ls .build/ZackEyes.app/Contents/Resources/*.mp3 | wc -l
```

Expected: count includes the 6 new files plus the 11 existing ones (rock + f1 sounds) = **17** total. If fewer, the `cp Resources/*.mp3` step skipped something.

- [ ] **Step 5: Commit**

```bash
git add Resources/*.mp3
git commit -m "$(cat <<'EOF'
feat(buddy): add silicon-theme sound clips

Six 1-2s mp3 files for the AI 大佬 theme. Document per-slot Path A
(real voice) vs Path B (sci-fi fallback) decisions in PR description.
EOF
)"
```

In the eventual PR description for this branch, list per slot which path was used and link the source URL for each Path A clip.

---

## Task 6: End-to-end smoke test

Manual verification in the running .app. Documents what passing looks like.

- [ ] **Step 1: Quit any running ZackEyes**

```bash
osascript -e 'tell application "ZackEyes" to quit' 2>/dev/null || pkill -f ZackEyes || true
```

- [ ] **Step 2: Build and launch**

```bash
make run
```

Expected: app launches, menu bar icon appears.

- [ ] **Step 3: Open the gear menu and switch to AI 大佬**

Click the menu bar icon → click the gear icon → hover "Theme" → confirm three options visible: "Rock Legends", "F1 2026", "AI 大佬". Click "AI 大佬".

Expected: theme submenu shows checkmark next to "AI 大佬". Sound submenu (under the same theme menu) now lists 6 silicon sounds + None.

- [ ] **Step 4: Preview each sound**

For each silicon sound entry in the menu, click it. After each click:

Expected: the clip plays once. Selected entry gets a checkmark.

- [ ] **Step 5: Verify a buddy is rendered**

Trigger a session (start a Claude Code conversation in any tracked directory). Open the notch panel (default `Cmd+Shift+Z`).

Expected: session card shows a buddy name from the silicon pool (e.g., "🇺🇸 Sam from OpenAI") with a silicon tagline (e.g., "AGI is coming"). Avatar icon will look like a rock-theme pixel art (templates fall back) — this is acceptable per spec, an avatar follow-up is out of scope.

- [ ] **Step 6: Verify config persistence**

Quit the app. Reopen.

```bash
osascript -e 'tell application "ZackEyes" to quit'
sleep 1
cat ~/.zackeyes/config.json | python3 -m json.tool | grep -A1 theme
make run
```

Expected: config file shows `"theme": "silicon"`. After relaunching, the gear menu still shows AI 大佬 selected.

- [ ] **Step 7: Verify rock and f1 still work (regression check)**

In the gear menu, switch to Rock Legends → verify rock buddy + sound options. Switch to F1 2026 → same check. Switch back to AI 大佬.

Expected: all three themes function identically; switching is fluent; existing personas still appear.

- [ ] **Step 8: No commit needed for smoke test**

This task produces no code changes. If smoke testing surfaces any issue, file it as a follow-up task and update this plan.

---

## Done Criteria

- All `BuddyThemeTests` pass (15 tests).
- Full `swift test` suite green.
- Six new mp3 files present in `Resources/` and bundled into `.build/ZackEyes.app/Contents/Resources/`.
- Manual smoke test (Task 6) passes for all 8 steps.
- `~/.zackeyes/config.json` round-trips `silicon` correctly.
- Issue [#18](https://github.com/yangshiqi/ZackEyes/issues/18) closeable.

## Out of Scope (Follow-ups, Not This PR)

- Silicon-themed pixel-art avatars (currently falls back to rock templates in `PixelAvatar.swift`). If desired, file as a separate issue: 8 new 8x8 templates (CPU chip, neural net node, brain, robot head, terminal cursor, GPU, datacenter rack, transformer block) + 8 new palette colors (Anthropic orange, OpenAI green, Nvidia green, etc.).
- User-customizable name lists.
- Per-buddy sounds (sounds remain theme-wide).

## Execution Notes

- **TDD discipline**: every code-bearing task writes the test first, runs it to see it fail, then implements. Don't reorder.
- **Don't batch the four switch branches together with the data arrays.** Task 1 introduces the case + scaffold so subsequent tasks have a stable target. This is the cheapest path for a subagent reading tasks out of order.
- **Per-slot fallback in Task 5**: when a Path A clip can't be found, update both the filename in `Buddy.swift` `availableSounds` AND rename the mp3, in the same commit, so name and contents stay in sync.
