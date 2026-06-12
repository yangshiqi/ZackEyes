# Passive Claude Rescan (#83) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Without hooks installed, Claude sessions started after app launch become visible within ≤60s — `SessionScanner` re-runs (claude-only) on the existing 60s sweep tick, liveness-filtered, with an unchanged-skip guard so re-imports are free and never clobber enriched sessions (GitHub issue #83).

**Architecture:** The companion evaluation (`docs/superpowers/specs/2026-06-12-passive-collection-eval.md`, committed with this branch) concluded: basic session list is fully passive-obtainable; the only gap is post-launch discovery (startup scan runs once). Slice = periodic claude-only rescan piggybacking the sweep timer + an unchanged-skip guard in `importDetectedSessions`. The kqueue ClaudeJsonlTailer is deliberately deferred (no felt pain; rationale in the eval doc). Codex untouched (its tailer owns that path; invariant #7 preserved).

**Branch:** `feat/83-passive-rescan` off `ea7fd99` (worktree `.claude/worktrees/feat-83-passive-rescan`, baseline 276 green).

**Key semantic decision (from eval):** the periodic path treats `runningClaudeCwds() == nil` (ps failure) as "skip this tick" — NOT the startup path's import-all fallback — because resurrecting just-pruned sessions on a ps hiccup would make cards flap.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/AppLib/Session/SessionStore.swift` | Modify | `importDetectedSessions`: unchanged-skip guard + `@discardableResult -> Int` |
| `Sources/ZackEyes/AppDelegate.swift` | Modify | `runPassiveClaudeRescan()` + sweep-timer wiring |
| `Tests/AppLibTests/SessionStoreTests.swift` | Modify | 3 new import-semantics tests |
| `ARCHITECTURE.md` | Modify | SessionScanner row + 双 agent 兼容点速查 row |
| `docs/superpowers/specs/2026-06-12-passive-collection-eval.md` | Commit | acceptance #1 deliverable (already written) |

---

### Task 1: importDetectedSessions — unchanged-skip + count

**Files:**
- Modify: `Sources/AppLib/Session/SessionStore.swift:650-674`
- Test: `Tests/AppLibTests/SessionStoreTests.swift` (append; read existing fixture style first — there are existing importDetectedSessions tests to mimic)

- [ ] **Step 1.1: failing tests** — append (adapt helper construction to the file's existing `SessionScanner.DetectedSession` fixtures; if a maker helper exists, reuse it):

```swift
    // MARK: - #83 periodic rescan import semantics

    @MainActor
    @Test func reimportSkipsUnchangedDetectedSession() {
        let store = SessionStore()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let d = SessionScanner.DetectedSession(
            id: "s1", cwd: "/tmp/p", lastModified: t,
            lastUserPrompt: "original prompt", lastAssistantMessage: nil,
            messageCount: 1, transcriptPath: "/tmp/none.jsonl", agent: .claude)
        #expect(store.importDetectedSessions([d]) == 1)

        // Enrich the stored session the way a tailer/hook-adjacent path
        // might; an unchanged re-import must NOT rebuild and lose this.
        store.sessions["s1"]?.lastAssistantMessage = "enriched"

        let count = store.importDetectedSessions([d])  // same lastModified
        #expect(count == 0)
        #expect(store.sessions["s1"]?.lastAssistantMessage == "enriched")
    }

    @MainActor
    @Test func reimportRefreshesWhenTranscriptMoved() {
        let store = SessionStore()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let d1 = SessionScanner.DetectedSession(
            id: "s1", cwd: "/tmp/p", lastModified: t,
            lastUserPrompt: "old", lastAssistantMessage: nil,
            messageCount: 1, transcriptPath: "/tmp/none.jsonl", agent: .claude)
        _ = store.importDetectedSessions([d1])

        let d2 = SessionScanner.DetectedSession(
            id: "s1", cwd: "/tmp/p", lastModified: t.addingTimeInterval(60),
            lastUserPrompt: "new prompt", lastAssistantMessage: "new reply",
            messageCount: 2, transcriptPath: "/tmp/none.jsonl", agent: .claude)
        let count = store.importDetectedSessions([d2])

        #expect(count == 1)
        #expect(store.sessions["s1"]?.lastUserPrompt == "new prompt")
        #expect(store.sessions["s1"]?.lastAssistantMessage == "new reply")
        #expect(store.sessions["s1"]?.lastActiveAt == t.addingTimeInterval(60))
    }

    @MainActor
    @Test func reimportNeverTouchesLiveSessions() {
        let store = SessionStore()
        store.handleEvent(BridgeEvent(
            bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/tmp/p"))
        store.upgradeToLive(sessionId: "s1")  // ensure .live regardless of default
        let d = SessionScanner.DetectedSession(
            id: "s1", cwd: "/tmp/p", lastModified: Date(),
            lastUserPrompt: "stale", lastAssistantMessage: nil,
            messageCount: 1, transcriptPath: "/tmp/none.jsonl", agent: .claude)

        #expect(store.importDetectedSessions([d]) == 0)
        #expect(store.sessions["s1"]?.lastUserPrompt != "stale")
    }
```

(NOTE: check `DetectedSession`'s actual memberwise init order/labels in `SessionScanner.swift` and `SessionStore.handleEvent`'s creation semantics — if `SessionStart` already creates `.live` sessions, drop the `upgradeToLive` line and note it. Adjust ONLY fixture mechanics, never the assertions' meaning.)

- [ ] **Step 1.2:** run filter → the first two FAIL (no return value → compile error first; after signature exists, behavior fails), third may pass already.

- [ ] **Step 1.3: implement** — replace `importDetectedSessions`:

```swift
    /// Import sessions discovered by SessionScanner. These are read-only and
    /// marked as `.detected` — user needs to restart them (or open a new
    /// thread, in Codex's case) for live tracking.
    ///
    /// Returns the number of sessions actually created/refreshed. The #83
    /// periodic rescan re-feeds known sessions every tick: when the
    /// transcript hasn't moved (`lastModified` matches `lastActiveAt`), the
    /// rebuild is skipped — no TaskExtractor re-parse, and enrichment
    /// written by other paths (codex tailer fields, recap fallbacks)
    /// survives.
    @discardableResult
    public func importDetectedSessions(_ detected: [SessionScanner.DetectedSession]) -> Int {
        var imported = 0
        for d in detected {
            // Don't overwrite live sessions if we already have them
            if sessions[d.id]?.source == .live { continue }
            // Unchanged-skip (#83): same transcript mtime ⇒ nothing new.
            if let existing = sessions[d.id], existing.source == .detected,
               existing.lastActiveAt == d.lastModified { continue }

            var session = SessionInfo(
                id: d.id,
                cwd: d.cwd,
                agent: d.agent,
                state: .idle,
                startedAt: d.lastModified
            )
            session.lastActiveAt = d.lastModified
            session.lastUserPrompt = d.lastUserPrompt
            session.lastAssistantMessage = d.lastAssistantMessage   // #43 recap fallback
            session.transcriptPath = d.transcriptPath
            // TaskExtractor only knows the Claude transcript schema. Codex
            // tasks would need their own extractor (deferred).
            if d.agent == .claude {
                session.tasks = TaskExtractor.extractTasks(fromTranscriptAt: d.transcriptPath)
            }
            session.source = .detected
            sessions[d.id] = session
            imported += 1
        }
        return imported
    }
```

- [ ] **Step 1.4:** `swift test 2>&1 | tail -3` → 279 pass (276 + 3).
- [ ] **Step 1.5: Commit** — `git add Sources/AppLib/Session/SessionStore.swift Tests/AppLibTests/SessionStoreTests.swift && git commit -m "feat(session): skip unchanged detected sessions on re-import"`

---

### Task 2: AppDelegate periodic rescan

**Files:**
- Modify: `Sources/ZackEyes/AppDelegate.swift` (timer block ~:301-303; new method near `runLivenessSweep` ~:372)

- [ ] **Step 2.1:** Update the sweep timer block:

```swift
        livenessSweepTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runLivenessSweep()
                self?.runPassiveClaudeRescan()
            }
        }
```
and extend the `// 7.` comment above it with: `Also re-scans Claude transcripts each tick (#83) so sessions started after launch surface even with no hooks installed.`

- [ ] **Step 2.2:** Add after `runLivenessSweep`'s closing brace:

```swift
    /// #83 — passive fallback discovery. The startup scan runs once, so
    /// without hooks a session started after launch would never appear.
    /// Each sweep tick re-scans Claude transcripts and imports new/updated
    /// detected sessions. Claude-only: codex has its own kqueue tailer with
    /// 30s rediscovery (invariant #7 — codex never enters the claude cwd
    /// liveness filter).
    private func runPassiveClaudeRescan() {
        Task.detached(priority: .utility) { [weak self] in
            let scanner = SessionScanner()
            let detected = scanner.scan(
                claudeRecencyMinutes: 480,   // same 8h window as startup
                codexRecencyMinutes: 0       // codex path skipped entirely
            ).filter { $0.agent == .claude }
            guard !detected.isEmpty else { return }

            // Unlike startup (ps failure ⇒ import-all fallback), the
            // periodic path requires a live cwd map: resurrecting sessions
            // the sweep just pruned, on a transient ps hiccup, would make
            // cards flap. Skip the tick instead — the next one retries.
            guard let cwdCounts = TerminalLocator.runningClaudeCwds() else { return }
            let live = LivenessFilter.filterLiveDetected(
                detected, cwdCounts: cwdCounts, codexCwdCounts: nil)
            guard !live.isEmpty else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                let imported = self.sessionStore.importDetectedSessions(live)
                if imported > 0 {
                    NSLog("ZackEyes: passive rescan imported %d claude sessions", imported)
                    // PID discovery + OSC2 titles only when something new landed.
                    self.activateDetectedSessions()
                }
            }
        }
    }
```

VERIFY first: does `scanner.scan(claudeRecencyMinutes:codexRecencyMinutes:)` tolerate `0` for codex (cutoff = now ⇒ zero codex files)? Read `SessionScanner.scan` — if `0` would misbehave (e.g. divide/edge), use `codexRecencyMinutes: 1` instead; the `.filter { $0.agent == .claude }` already guarantees correctness either way. Also confirm `LivenessFilter.filterLiveDetected(_:cwdCounts:codexCwdCounts:)` accepts `codexCwdCounts: nil` (it does — legacy pass-through semantics; we feed zero codex items anyway). Note what you found.

- [ ] **Step 2.3:** `swift build 2>&1 | tail -3` clean; `swift test 2>&1 | tail -3` → 279.
- [ ] **Step 2.4: Commit** — `git add Sources/ZackEyes/AppDelegate.swift && git commit -m "feat(session): periodic passive claude rescan on sweep tick (#83)"`

---

### Task 3: Docs

- [ ] **Step 3.1:** ARCHITECTURE.md:
  - `SessionScanner` row (Socket / Session 核心 table) — append to 职责: `；#83 起每 60s 随 sweep 重扫 Claude transcript（claude-only、活性过滤、未变化跳过），hook 缺失时启动后新会话 ≤60s 可见`.
  - 双 agent 兼容点速查 table — the `进程探测（liveness sweep）` row exists; ADD a new row after it: `| 无 hook 兜底发现 | 启动扫描 + 60s 周期重扫（SessionScanner） | CodexJsonlTailer kqueue 实时 + 30s rediscovery |`.
- [ ] **Step 3.2:** stage eval spec + plan: `git add docs/superpowers/specs/2026-06-12-passive-collection-eval.md docs/superpowers/plans/2026-06-12-passive-claude-rescan.md ARCHITECTURE.md`
- [ ] **Step 3.3:** full sweep `swift build && swift test && make app` tails green; commit `docs: passive-collection evaluation + rescan documentation (#83)`

---

### Task 4: Ship

- [ ] Final whole-branch review (range `ea7fd99..HEAD`).
- [ ] PR `feat(session): passive claude rescan fallback + collection evaluation (#83)`; body: eval matrix summary, the now-vs-deferred tailer decision, ps-failure semantic difference (startup vs periodic), acceptance mapping. `Closes #83`.
- [ ] Bot review → dispositions → squash-merge → tick #83 in #92 → memory → pull master.

---

## Self-Review Notes

- Acceptance [1] eval doc ✓ (specs/2026-06-12-passive-collection-eval.md); [2] hookless basic list incl. post-launch sessions ✓ (rescan ≤60s); [3] tests ✓ (3 import-semantics tests; rescan loop itself is AppDelegate-thin like the sweep, untested by project convention).
- Unchanged-skip equality uses `lastActiveAt == d.lastModified` — exact Date equality is safe because both sides originate from the same file-mtime value set at import time; any hook/tailer touch moves lastActiveAt to Date() ⇒ next rescan refreshes. Intentional.
- Risk: rescan + sweep both call ps/lsof per tick (2× subprocess/min) — accepted; merging the flows would entangle early-return semantics for a negligible saving.
