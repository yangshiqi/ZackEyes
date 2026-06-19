# Vulnerability Findings — ZackEyes

- **Target:** `/Users/ysq/Work/lab/ZackEyes`
- **Scanned:** 2026-06-19 (static source review, no execution)
- **Scope:** 72 Swift source files across 7 focus areas derived from `THREAT_MODEL.md` (sections 3 & 4)
- **Totals:** 28 findings — 9 HIGH, 10 MEDIUM, 9 LOW (5 low-confidence, <0.4)

These are **static candidates**, not execution-verified. Sorted by confidence
(desc), then severity. Prior fixes (aba2176 socket-auth + caps; cf61a5d/4754dba
sanitizePrompt) were verified against current code; findings are residual gaps,
sibling sinks, or new issues.

## Focus areas

1. Socket/IPC authorization (EP1/2/3, T1) — SocketServer, SessionStore, EventProtocol/AnyCodable, PendingEventReplayer
2. Bridge CLI input handling (EP4, T1/T7) — Bridge/main, SocketClient, PendingEventQueue, TTYUtil
3. Untrusted-text injection sinks (EP5/11, T5) — NotchExpandedView, AppDelegate.handleEvent, TerminalTitleWriter, NotificationManager, sanitizePrompt
4. Software-update integrity (EP9/10, T2) — UpdateChecker, UpdateDownloader
5. Launcher/helper resolution & hook install (EP8, T3) — HookInstaller, CodexHookInstaller, HookRepair, HookHealth, IntegrationUninstaller
6. Transcript/cache readers & missing-timeouts (EP5/6, T6/T7) — SessionScanner, CodexJsonlTailer, TaskExtractor, UsageTracker, PricingStore, ConfigStore
7. Terminal AX / Apple Events actuation (EP7, T4) — TerminalLocator

## Summary table

| id | sev | conf | category | file:line | title |
|---|---|---|---|---|---|
| F-001 | HIGH | 0.9 | unbounded-read | UsageTracker.swift:511 | Codex daily-token scan reads each rollout fully (uncapped, 30s recurring) |
| F-002 | HIGH | 0.8 | unbounded-read | TaskExtractor.swift:18 | TaskExtractor reads entire transcript uncapped — bypasses 256MB cap |
| F-003 | MED | 0.8 | integer-overflow | UsageTracker.swift:630 | Crafted token-count fields cause a Swift Int overflow trap (crash-loop) |
| F-004 | HIGH | 0.8 | terminal-escape-injection | TerminalTitleWriter.swift:51 | cwd basename embedded raw into OSC-2 title — sibling sink fix missed |
| F-005 | HIGH | 0.8 | terminal-escape-injection | TerminalLocator.swift:284 | Second OSC-2 writer also embeds raw cwd basename into tty escape |
| F-006 | HIGH | 0.7 | auth-bypass | SocketClient.swift:19 | Bridge connects to /tmp socket with no peer auth; reply = agent decision |
| F-007 | MED | 0.7 | information-disclosure | PendingEventQueue.swift:42 | Spool writes raw hook JSON (prompts/cwd) world-readable, no chmod |
| F-008 | MED | 0.7 | notification-spoofing | NotificationManager.swift:98 | Notification title unsanitized; body sanitizer strips no control/bidi chars |
| F-009 | MED | 0.7 | denial-of-service | CodexJsonlTailer.swift:251 | Tailer pendingBuffer grows unbounded on a newline-free line |
| F-010 | HIGH | 0.6 | code-execution | HookInstaller.swift:259 | Launcher execs bundle from writable .app-path marker, no signature check |
| F-011 | HIGH | 0.6 | insecure-permissions | HookInstaller.swift:235 | Directly-exec'd launcher/dir/marker created with default perms (no 0700/0600) |
| F-012 | HIGH | 0.6 | code-execution | HookInstaller.swift:269 | Launcher execs first mdfind result by bundle id, no signature check |
| F-013 | HIGH | 0.6 | insecure-update | UpdateChecker.swift:99 | DMG download URL taken verbatim from release JSON — any host |
| F-014 | LOW | 0.6 | code-execution | HookHealth.swift:172 | Health check trusts writable marker by path-equality, masks poisoning |
| F-015 | LOW | 0.6 | argument-injection | TerminalLocator.swift:266 | Untrusted transcript_path to `lsof -t` without `--` guard |
| F-016 | MED | 0.6 | auth-bypass | PendingEventReplayer.swift:35 | Spool replay has no event-type allowlist — spoofs session state |
| F-017 | MED | 0.5 | deserialization | PendingEventReplayer.swift:43 | Spool replay reads unbounded size into recursive AnyCodable decode |
| F-018 | MED | 0.5 | path-traversal | UpdateDownloader.swift:41 | Download filename from server URL last component (cache-hit open) |
| F-019 | MED | 0.5 | toctou | UpdateDownloader.swift:63 | DMG written to predictable tmp then opened — same-uid swap/cache-poison |
| F-020 | LOW | 0.5 | unbounded-read | PricingStore.swift:49 | Pricing/usage cache readers uncapped Data(contentsOf:) |
| F-021 | LOW | 0.5 | denial-of-service | SocketClient.swift:101 | No wall-clock timeout on blocking PermissionRequest read |
| F-022 | MED | 0.4 | ssrf | UpdateDownloader.swift:52 | Default URLSession follows cross-origin redirects on DMG download |
| F-023 | LOW | 0.4 | terminal-escape-injection | TerminalTitleWriter.swift:19 | OSC sanitizer doesn't strip C1 controls / ST (UTF-8 neuters it) |
| F-024 | MED | 0.3 | command-injection | HookInstaller.swift:353 | statusline-mux interpolates settings.json command raw/unquoted |
| F-025 | LOW | 0.3 | insecure-update | UpdateDownloader.swift:52 | No download size cap / per-download timeout on DMG fetch |
| F-026 | LOW | 0.3 | denial-of-service | CodexJsonlTailer.swift:614 | Tailer offset never reset on in-place truncation — silent stall |
| F-027 | LOW | 0.2 | insecure-update | UpdateChecker.swift:128 | Version parser accepts unbounded components — forced-update lever |
| F-028 | LOW | 0.2 | input-handling | Bridge/main.swift:22 | Bridge stdin single read — safe (coverage note, not a vuln) |

---

### F-001 — Codex daily-token scan reads each rollout fully via uncapped String(contentsOf:) (HIGH, conf 0.9)

`UsageTracker.swift:511` (`unbounded-read`)

scanCodexDailyTokens reads each codex rollout in the 7-day window fully: `else if let text = try? String(contentsOf: file, encoding: .utf8)` (line 511), then split on `\n`. No fileSize ceiling, no symlink guard — though the function already fetches `.fileSizeKey` for its cache key (lines 500-502). The aba2176 256MB cap (`maxTranscriptBytes` line 559 + `shouldScanTranscript` line 612, which also blocks symlinks) was applied only to the Claude `computeSnapshot` path; the structurally-identical codex path got neither. `refresh()` runs every 30s; an actively-grown rollout changes size each tick, defeating the `(mtime,size)` cache, so it is re-read whole every 30s. Author was aware (the cap comment cites "a multi-GB read on every 30s refresh") but fixed only one path.

**Exploit:** a same-uid process writes a 5GB rollout with recent mtime into `~/.codex/sessions/...`; every 30s the scan reads the whole 5GB into memory.

**Fix:** gate on the already-fetched size and skip symlinks (apply `shouldScanTranscript` here); tail-read append-only tallies.

### F-002 — TaskExtractor reads the entire transcript JSONL with uncapped Data(contentsOf:) (HIGH, conf 0.8)

`TaskExtractor.swift:18` (`unbounded-read`)

`extractTasks` reads the whole file with `Data(contentsOf:)` (line 18) then `String(data:)` + split — no size ceiling, no symlink check. aba2176's 256MB+symlink cap landed only in UsageTracker; this sibling reader was untouched (SessionScanner/CodexJsonlTailer use bounded 64KiB/1MiB reads — TaskExtractor is the lone whole-file reader). Reached on every `PostToolUse` of a `Task*` tool with the hook-supplied `transcriptPath` (SessionStore.swift:287-291), and per imported session (SessionStore.swift:679-680), re-fed on the mtime-gated rescan. Transcript content is LLM/tool output a malicious repo can bloat, or a same-uid process can plant a multi-GB jsonl.

**Exploit:** ~4GB appended to the active jsonl → next `Task*` PostToolUse `Data(contentsOf:)`-reads it all on the main session-handling path, spiking RSS; repeats per Task PostToolUse.

**Fix:** stat first, skip symlinks/over-cap files, bounded tail read (as `parseClaudeSession.readTail` already does).

### F-003 — Crafted token-count fields cause a Swift Int overflow trap (MEDIUM, conf 0.8)

`UsageTracker.swift:630` (`integer-overflow`)

Token fields parse from untrusted JSON into `Int` (`usage[...] as? Int`, lines 689-692; JSONSerialization yields Int up to Int.max) and are summed with trapping `+`/`+=`: `total = r.input + r.output + r.cacheRead + r.cacheCreate` (line 630), `tokens7d += total` (631). Swift aborts on signed overflow (deterministic SIGTRAP). Same shape in DailyUsage.swift:72,154-156. A transcript line with `"input_tokens":9223372036854775807,"output_tokens":1` traps on the first record. computeSnapshot runs on the 30s cycle, so the crash recurs every tick and relaunch — persistently disabling the security/usage UI.

**Fix:** clamp/reject absurd token magnitudes at parse time; use `addingReportingOverflow`/saturating accumulation in the folds.

### F-004 — cwd basename embedded raw into OSC-2 tab-title write (HIGH, conf 0.8)

`TerminalTitleWriter.swift:51` (`terminal-escape-injection`)

The prompt portion of the OSC-2 title is sanitized (strips ESC/BEL), but `basename = (cwd as NSString).lastPathComponent` (line 51) is interpolated raw at lines 56/59. writeIfPossible builds `ESC ]2; <title> BEL` (line 65) and writes to another process's tty (103-108). `cwd` comes straight from hook JSON (Bridge/main.swift:87-88), unvalidated. macOS dir names allow any byte but `/` and NUL — a basename carrying attacker-chosen BEL/ESC terminates the title early and injects follow-on escapes (OSC 52 clipboard, cursor moves, etc.). Same class the prompt fix closed, via a different field on the identical sink.

**Exploit:** a repo whose working dir basename is `proj\x07\x1b]52;c;<payload>\x07`; any hook fire emits the injected escape to the terminal, no prompt content needed.

**Fix:** sanitize the basename (both here and TerminalLocator:284), or sanitize the whole composed title once before the tty write; also strip C1 + ST.

### F-005 — Second OSC-2 writer (TerminalLocator.writeSessionTitle) also embeds raw cwd basename (HIGH, conf 0.8)

`TerminalLocator.swift:284` (`terminal-escape-injection`)

App-side OSC-2 writer (used by activateDetectedSessions:377, activateCodexSession:901, NotchViewModel:104). sessionTitle sanitizes the prompt (line 286) but interpolates the cwd basename raw (line 284); writeSessionTitle builds the OSC string (line 302) and writes to the tty (304-307). cwd comes from scanned transcript metadata read verbatim by SessionScanner (`cwd` field, lines 114-115 / codex :262), no path validation. The detected-session path auto-runs after the import scan (AppDelegate:320) and periodic sweep (:511) — no user click.

**Fix:** sanitize the basename in sessionTitle; ideally collapse both OSC builders into one sanitizing helper.

### F-006 — Bridge connects to /tmp/zackeyes.sock with no peer auth; reply becomes the agent's decision (HIGH, conf 0.7)

`SocketClient.swift:19` (`auth-bypass`)

The bridge connects to world-writable `/tmp/zackeyes.sock` (main.swift:94) and does NOT authenticate the listening peer — the server's getpeereid protects the app from rogue clients, not the bridge from a rogue server. For a PermissionRequest the bridge writes the socket reply verbatim to stdout (main.swift:119-122) with no shape validation; Claude Code obeys it as the decision. `/tmp` is sticky/world-writable: when the app isn't running, another local USER can bind the path first; the startup `unlink` can't remove a foreign-uid sticky file (EPERM), so the squatter persists. No wall-clock timeout (poll(-1)) — the squatter can also hang the agent. Cross-uid boundary, beyond the accepted same-uid trust.

**Exploit:** on a multi-user host, attacker B `nc -lU /tmp/zackeyes.sock` before A launches; A's PermissionRequest leaks to B and B replies `allow` (or never replies, hanging A).

**Fix:** per-user 0700 socket dir; bridge-side getpeereid; validate/parse the reply; finite timeout.

### F-007 — Pending-event spool writes raw hook JSON with default permissions in a world-traversable dir (MEDIUM, conf 0.7)

`PendingEventQueue.swift:42` (`information-disclosure`)

When the socket is down the bridge spools raw hook JSON to `~/.zackeyes/pending/*.json`. The dir is created with no `attributes:` (lines 42-44) and files written with `.atomic` and no mode (line 49) — umask-governed 0755/0644. Payload includes the user prompt (UserPromptSubmit), cwd, transcript_path. Verified: home is 0755 (world-traversable, not 0700), so cross-uid read of `~victim/.zackeyes/pending/*.json` is reachable. The socket node is deliberately 0o600 (SocketServer:90) — the spool persisting the same content gets no equivalent hardening. (T6.)

**Fix:** create the dir 0o700 and files 0o600; consider not persisting raw prompt content.

### F-008 — Notification title bypasses sanitization; body sanitizer strips no control/bidi chars (MEDIUM, conf 0.7)

`NotificationManager.swift:98` (`notification-spoofing`)

(1) The title is raw-interpolated (lines 98,133) with `projectName` = cwd basename (attacker-influenceable) — no sanitizer. (2) The body's `sanitizePrompt` (lines 186-199) is a weaker, same-named function: it only trims/drops-XML/truncates and strips NO control/bidi/C1 chars, so ESC/BEL/U+202E/zero-width pass into `content.body` (sourced from last user/assistant message). Notification Center is plain-text (no escape execution), so the real impact is UI spoofing via bidi/RTL-override misrepresenting which project/agent fired; the tap handler then activates the attacker-chosen sessionId (AppDelegate:217-226).

**Fix:** strip C0/C1/DEL + bidi/format chars from both title and body; rename the colliding function; centralize sanitization.

### F-009 — kqueue tailer's pendingBuffer grows without bound on a newline-free line (MEDIUM, conf 0.7)

`CodexJsonlTailer.swift:251` (`denial-of-service`)

parseTaskLifecycleEvents does `combined = pending + chunk`, splits on `\n`, carries the trailing partial in `pendingBuffer` (line 461) across write events with no cap. If a writer appends large bytes with no `\n`, every chunk yields no complete line and the whole content accumulates in `pending` (`pending + chunk` each write → ~GB, O(n²) recopy). Head reads are bounded (1MiB/1.1MiB); only the tail buffer is unbounded.

**Exploit:** a same-uid process appends an 800MB newline-free line to the tailed rollout; pendingBuffer grows to hundreds of MB/GB.

**Fix:** cap pendingBuffer (drop/skip past a few-MB ceiling); per-chunk read cap.

### F-010 — Launcher execs app bundle from same-uid-writable .app-path marker, no signature check (HIGH, conf 0.6)

`HookInstaller.swift:259` (`code-execution`)

The generated `/bin/sh` launcher (run every hook fire) reads `~/.zackeyes/.app-path` and execs the named bundle's bridge with only an `[-x]` check (line 253), then `exec` (256). Zero codesign/SecStaticCode anywhere in the tree. The marker is written default-perms (line 278) in a default-perms dir (235). Any same-uid process repoints the marker to an attacker bundle → next hook event execs attacker code as the user; line 255 pins the path. Code-confirmed instantiation of documented-unmitigated T3.

**Fix:** verify the resolved bundle's code signature before exec; lock marker/dir to 0600/0700 and reject writable inputs; bake the install path in at deploy time.

### F-011 — Directly-exec'd launcher, bin dir, and marker created with default permissions (HIGH, conf 0.6)

`HookInstaller.swift:235` (`insecure-permissions`)

`~/.zackeyes/bin` created with `attributes: nil` (235-239) → ~0755; scripts set to 0o755 (381-383); marker written with no mode (278-282). Only the socket (0o600) is hardened in the subsystem. The launcher is directly exec'd every hook fire (wired as the command, line 421). Distinct from F-010: overwriting the launcher **script body** replaces the executed code with any payload, no `[-x]`/bundle constraint.

**Fix:** create dir/bin 0700, launcher 0700, marker 0600 explicitly; verify ownership/non-group-writable each deploy/health pass.

### F-012 — Launcher execs first mdfind result by bundle id, no signature check (HIGH, conf 0.6)

`HookInstaller.swift:269` (`code-execution`)

Fallback: `mdfind 'kMDItemCFBundleIdentifier == "app.zackeyes.macos"' | head -n1` → try_app → exec, same no-validation flow as F-010. The bundle id is public; a same-uid attacker plants a matching bundle in a Spotlight-indexed location to win the lookup. Narrower than F-010 (marker + fixed paths must miss — achievable by emptying the same-uid marker or after the app moves).

**Fix:** verify code signature / DR of the candidate before exec; constrain to a path policy; exit on failure.

### F-013 — DMG download URL taken verbatim from release JSON — any host (HIGH, conf 0.6)

`UpdateChecker.swift:99` (`insecure-update`)

`dmgURL = first .dmg asset's browserDownloadURL` (line 99), taken verbatim from the release JSON with no host/scheme allowlist, flows to `URLSession.download` → `NSWorkspace.open` (UpdateDownloader:52,65). Concrete amplifier on T2: a compromised release can point the download at any host (need not be GitHub). With quarantine stripped + ad-hoc signing, the opened DMG hits no Gatekeeper gate.

**Fix:** require https + a host allowlist, or reconstruct the URL from known repo/tag/asset; ultimately verify DMG signature/checksum before open.

### F-014 — Health check trusts the writable marker by path-equality, masking poisoning (LOW, conf 0.6)

`HookHealth.swift:172` (`code-execution`)

checkLauncherResolution reads the writable `.app-path` marker and reports "healthy" if the resolved bundle path-equals the running bundle (resolvingSymlinksInPath) — no signature/permission check, read-only. A poisoned marker arranged to satisfy the equality (symlink games) reports healthy, suppressing the UI tripwire for F-010/F-011. No new primitive; detection-evasion tail.

**Fix:** verify marker/dir ownership+mode and the resolved bundle's signature; surface a "writable/unsigned resolution source" warning.

### F-015 — Untrusted transcript_path to `lsof -t` without `--` guard (LOW, conf 0.6)

`TerminalLocator.swift:266` (`argument-injection`)

`runWithTimeout("/usr/sbin/lsof", args: ["-t", file])` (266) where `file` = the untrusted `transcript_path` event field (EventProtocol:166,190 → SessionInfo → lsofPids). No `--` guard, so a leading `-` (e.g. `-i`) is parsed as an lsof option. argv-array (no shell) → not command injection; lsof is read-only → impact limited to mis-resolved/failed PID lookup.

**Fix:** `args: ["-t", "--", file]`; reject non-absolute transcriptPath before subprocess use.

### F-016 — Spool replay has no event-type allowlist — spoofs session state (MEDIUM, conf 0.6)

`PendingEventReplayer.swift:35` (`auth-bypass`)

The write side restricts spooling to `replayableEvents`; the read side (replayAll, 35-49) enforces no such filter and replays ANY decodable event through the same handler the authenticated socket uses. Reachable spoofs: fake session row (SessionStart), fabricated error banner (Stop + crafted last_assistant_message), forged `.yolo` risk badge (permission_mode `bypassPermissions`) or cleared real badge. Verified caveat: a replayed PermissionRequest cannot auto-approve (responder==nil → early return :550-553) — impact is security-surface spoofing, not a tool grant.

**Fix:** enforce the replayableEvents allowlist on read; never let replayed events mutate permissionRisk; 0700 spool dir.

### F-017 — Spool replay reads unbounded size into recursive AnyCodable decode (MEDIUM, conf 0.5)

`PendingEventReplayer.swift:43` (`deserialization`)

replayAll does `Data(contentsOf:)` (43) with no cap then decodes BridgeEvent (44); the live socket caps at 64KiB (SocketServer:148) but the spool was left uncapped by aba2176. AnyCodable recurses per nested element (EventProtocol:48,50); replay runs on @MainActor at startup. The clean crash is a large flat allocation from a same-uid writer (the deep-nesting stack-exhaustion variant is likely trapped by Foundation's parser depth limit first).

**Fix:** size-cap the spool read (64KiB); add a JSON nesting-depth cap in AnyCodable.

### F-018 — Download filename from server URL last component (MEDIUM, conf 0.5)

`UpdateDownloader.swift:41` (`path-traversal`)

`temporaryDirectory.appendingPathComponent(url.lastPathComponent)` (41-42) with the attacker-controlled URL; remove+move (62-63) and a cache-hit open (44-48, opens an existing path with no download/verification). Arbitrary-file overwrite is largely neutered (lastPathComponent is a single component; `..` names a directory). The residual real angle is the cache-hit branch opening a same-uid-pre-planted file in tmp.

**Fix:** fixed app-private filename in a restricted dir; assert dest stays inside the intended dir.

### F-019 — DMG written to predictable tmp then opened — same-uid swap/cache-poison (MEDIUM, conf 0.5)

`UpdateDownloader.swift:63` (`toctou`)

Predictable tmp path (filename = public asset name), window between moveItem (63) and NSWorkspace.open (65); cache-hit fast path opens with no check. No checksum/signature compare anywhere (grep). A same-uid process swaps the file in the window, or pre-seeds the cache path so the next install opens planted bytes with no download.

**Fix:** per-download mkdtemp 0700 dir; verify checksum/signature immediately before open; don't reuse cache path without re-verifying.

### F-020 — Pricing/usage cache readers uncapped Data(contentsOf:) (LOW, conf 0.5)

`PricingStore.swift:49` (`unbounded-read`)

`Data(contentsOf:)` on `~/.zackeyes/pricing-cache.json` (49) and usage-cache.json (UsageTracker:222), no size cap, then decode. Same-uid-writable caches; smaller blast radius (one-shot startup). A planted multi-GB cache spikes memory at launch.

**Fix:** stat + small ceiling (~1MB) before reading; apply to usage-cache.json and config.json.

### F-021 — No wall-clock timeout on the blocking PermissionRequest read (LOW, conf 0.5)

`SocketClient.swift:101` (`denial-of-service`)

`timeoutSeconds:0` → `poll(-1)` infinite wait (main.swift:119). A peer that accept()s but never replies (wedged app, or a squatter per F-006) blocks the agent's permission prompt with no ceiling; only SIGINT recovers. Intentional design but single-user availability-only.

**Fix:** finite ceiling that fails open to CC's own prompt; keep POLLHUP early-wake.

### F-022 — Default URLSession follows cross-origin redirects on the DMG download (MEDIUM, conf 0.4)

`UpdateDownloader.swift:52` (`ssrf`)

`URLSession.shared.download` with no redirect delegate (grep: none) follows cross-origin 30x silently; the 2xx guard checks only the final response. Compounds F-013. Note: legit GitHub delivery DOES redirect to a CDN, so the fix is an allowlist, not blanket disabling — partly defense-in-depth, and "SSRF" is a loose label here.

**Fix:** non-shared session with a willPerformHTTPRedirection delegate enforcing a host allowlist; validate the final host.

### F-023 — OSC sanitizer doesn't strip C1 controls / 2-byte ST (LOW, conf 0.4)

`TerminalTitleWriter.swift:19` (`terminal-escape-injection`)

Both sanitizers drop `<0x20`/`0x7F` (removing bare ESC/BEL) but not C1 (0x80-0x9F incl. U+009C ST). However the title is written via `.data(using:.utf8)` (line 100), so U+009C becomes `0xC2 0x9C` — a UTF-8 terminal treats it as a character, not an 8-bit ST. Exploit needs a legacy non-UTF-8 terminal (target Ghostty is UTF-8-only). Defense-in-depth completeness note.

**Fix:** also strip 0x80-0x9F; prefer an allowlist (covers bidi overrides too).

### F-024 — statusline-mux interpolates settings.json command raw/unquoted (MEDIUM, conf 0.3)

`HookInstaller.swift:353` (`command-injection`)

`displayCommand = "printf ... | \(originalCommand)"` (351-354) bakes the third-party statusLine.command raw into the exec'd mux script. But both sources (settings.json command, `.statusline-original` marker) are same-uid/operator-controlled, and statusLine.command IS a shell command string by design; an attacker who can write either already has same-uid write to the exec'd script. A quoting defect, not a privilege-crossing injection.

**Fix:** persist as argv/base64 and invoke via fixed `sh -c` after provenance check; lock `.statusline-original` 0600.

### F-025 — No download size cap / per-download timeout on the DMG fetch (LOW, conf 0.3)

`UpdateDownloader.swift:52` (`insecure-update`)

Shared session, no timeoutIntervalForResource/byte cap (checker sets 15s; downloader nothing). With an attacker host (F-013) + silent redirects (F-022), an unbounded stream fills disk or wedges `.downloading`. Availability-only corollary of the malicious-host primitive.

**Fix:** dedicated session with resource timeout + max-size enforcement.

### F-026 — Tailer offset never reset on in-place truncation — silent stall (LOW, conf 0.3)

`CodexJsonlTailer.swift:614` (`denial-of-service`)

`endSize > offset` guard (613-617) with no shrinkage detection/inode re-stat; in-place truncation (not caught by .delete/.rename, 572-575) makes the watcher permanently silent, and regrowth past the stale offset resumes mid-record feeding garbage into pendingBuffer (compounds F-009). Same-uid attacker; correctness/availability degradation, not corruption.

**Fix:** on `endSize < offset` reset offset + clear pendingBuffer (or re-attach); fstat identity per event.

### F-027 — Version parser accepts unbounded components — forced-update lever (LOW, conf 0.2)

`UpdateChecker.swift:128` (`insecure-update`)

parseVersion fails closed on non-numeric (safe), strict-greater (no downgrade), but `Int($0)` has no magnitude/count cap, so `v9999999999.0.0` always reads as newer — forcing the update prompt. Requires the same release compromise (T2) that already sets the malicious DMG, and the attacker could just bump the version legitimately. No independent exploitability.

**Fix:** cap component count/magnitude; treat version compare as advisory only, with an independent integrity gate.

### F-028 — Bridge stdin single read — safe (coverage note) (LOW, conf 0.2)

`Bridge/main.swift:22` (`input-handling`)

`availableData` (line 22) is a single bounded read — no memory blowup. Oversized payloads truncate, the JSON parse fails, and the bridge `exit(0)` silently; the never-nonzero-exit invariant holds on every path. No crafted input found that traps/exits non-zero. A PermissionRequest drop fails to CC's own prompt (safe default). Documented as a negative/coverage note — not a vulnerability.

**Fix (optional):** loop to EOF with an explicit byte cap to remove the silent-truncation footgun.

---

**Next step:** `> /triage /Users/ysq/Work/lab/ZackEyes/VULN-FINDINGS.json --repo /Users/ysq/Work/lab/ZackEyes`

These are static candidates, not verified. For execution-verified crashes use `vuln-pipeline run <target>` (not applicable to this Swift/macOS target).
