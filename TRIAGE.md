# Triage: ZackEyes

**Source:** `VULN-FINDINGS.json` (28 raw findings) · **Target:** `/Users/ysq/Work/lab/ZackEyes`

## How this was triaged

The automated `/triage` run hit the monthly Claude spend limit mid-pass, so this
was done **manually in-session, no subagents**. I directly re-read the source for
the load-bearing findings — **F-001, F-002, F-003, F-004, F-010** — plus a
tree-wide grep confirming **zero** code-signature primitives
(`codesign`/`SecStaticCode`/`SecCode`). The remaining findings were triaged by
analyzing the scanner's cited code locations and its (notably well-calibrated)
self-assessments, **not** re-opened line-by-line. Findings I did **not**
independently re-verify and that would most benefit from a fresh-eyes pass are
flagged **⚠ re-verify** below — chiefly the two cross-uid claims (T-5, T-7).

**Environment calibration:** ZackEyes is a **local, single-user, unsandboxed
macOS app with no remote listener.** Per `THREAT_MODEL.md`, a **same-uid** process
(e.g. a compromised dependency in a project the user runs an agent in) **is in
scope** — so same-uid findings are not dismissed — but their impact is bounded by
"the attacker already runs as you." The only true cross-privilege boundaries here
are **cross-uid** (multi-user host) and the **update/supply-chain** channel. That
calibration is why several scanner-HIGH items land at MEDIUM after triage.

## Result

| | count |
|---|---|
| Raw findings | 28 |
| **Confirmed (canonical, after clustering)** | **11** |
| Folded into a canonical finding | 13 |
| Downgraded / rejected | 4 |

Post-triage severity: **2 HIGH · 7 MEDIUM · 2 LOW** (scanner had 9 HIGH — most
drop to MEDIUM because access-level caps impact at availability or same-uid).

## Confirmed findings (ranked by real exploitability)

| # | id | finding | sev | conf | verdict |
|---|----|---------|-----|------|---------|
| 1 | **T-1** | Same-uid **code-execution persistence** via unprotected `~/.zackeyes` launcher chain (no signature check, default perms) — *folds F-010/F-011/F-012/F-014* | **HIGH** | 9 | true positive |
| 2 | **T-4** | **Update opened with no in-app signature/checksum** + server-controlled download host — *folds F-013/F-018/F-019/F-022/F-025/F-027* | **HIGH** | 8 | true positive (gated on T2) |
| 3 | **T-5** | **Cross-uid socket squat** — bridge doesn't authenticate the server peer on world-writable `/tmp` — *folds F-006/F-021* | MED | 6 | true positive ⚠ re-verify |
| 4 | **T-3** | **OSC-2 terminal-escape injection** via raw cwd basename (both writers) — *folds F-004/F-005/F-023* | MED | 8 | true positive |
| 5 | **T-8** | **Integer-overflow crash-loop** via crafted token counts (F-003) | MED | 8 | true positive |
| 6 | **T-2** | **Uncapped reads** bypass the 256MB cap (recurring-path DoS) — *folds F-001/F-002/F-017/F-020* | MED | 8 | true positive |
| 7 | **T-6** | **Spool replay has no event allowlist** → session/permission-badge spoofing (F-016) | MED | 6 | true positive |
| 8 | **T-7** | **Spool writes raw prompts world-readable** (0644 in 0755 dir) (F-007) | MED | 6 | true positive ⚠ re-verify |
| 9 | **T-10** | **Notification UI spoofing** — unsanitized title + weak body sanitizer (F-008) | LOW | 6 | true positive |
| 10 | **T-9** | **Unbounded kqueue tailer buffer** on newline-free line — *folds F-009/F-026* | LOW | 6 | true positive |
| 11 | **T-11** | `lsof` missing `--` end-of-options guard (F-015) | LOW | 5 | true positive |

### What changed vs. the raw 28

- **No false-positive HIGHs survived as HIGH.** The two genuine HIGHs are T-1
  (concrete persistence primitive) and T-4 (update RCE gap, but **gated** on a
  T2 release/token compromise). F-001/F-002/F-004/F-005/F-006 were scanner-HIGH
  and triage to **MEDIUM** — all real, but their impact for a local app is
  availability (DoS), same-uid, or a contrived/multi-user precondition.
- **Four clusters collapsed:** the launcher chain (4→T-1), the update channel
  (6→T-4), the uncapped reads (4→T-2), the OSC writers (3→T-3).
- **Four findings dropped from the vuln list:**
  - **F-023** (C1/ST sanitizer) — not credible: UTF-8 encoding emits U+009C as
    `0xC2 0x9C`, never an 8-bit C1 control on a UTF-8 terminal. Defense-in-depth
    note only.
  - **F-024** (statusline-mux quoting) — **no boundary crossed**: every input is
    same-uid/operator-controlled and the attacker already has write to the exec'd
    script. Hygiene, not a vuln.
  - **F-026** (tailer truncation offset) — robustness/correctness bug, not a
    security primitive (folded into T-9 as a fix).
  - **F-028** — the scanner's own **negative coverage note** confirming the
    bridge stdin path is safe. Not a finding.

## Top of the list, in plain terms

**T-1 is the one to fix first.** It's the only finding that turns the in-scope
same-uid threat into something *worse* than what the attacker started with:
a one-shot write to `~/.zackeyes/.app-path` (or the launcher body, or a planted
mdfind-indexed bundle) becomes **persistent code execution that re-fires on every
agent hook**, wired into Claude/Codex, with zero signature check anywhere in the
tree. It's also the cheapest fix: `0700`/`0600` perms + a `codesign -R` check
before `exec`.

**T-4 is the highest-impact but precondition-gated.** No in-app integrity check
means a compromised release (or stolen publish token) → RCE on every client —
but that's the T2 supply-chain compromise the threat model already flags. Fix it
because it's the missing floor under T2, not because it's exploitable alone.

**Everything else is a sanitization/cap discipline story.** T-2, T-3, T-8, T-9,
T-10 all reduce to two cheap, high-leverage habits the codebase already half-does:
*cap + symlink-skip every untrusted read* and *strip control chars at one shared
boundary for every sink*. The 256MB cap and `sanitizePrompt` exist — they were
just applied to one path each and the siblings were missed.

## Recommended fix themes (class-level, maps to THREAT_MODEL §8)

| theme | covers | effort | TM |
|-------|--------|--------|----|
| Lock down `~/.zackeyes` (0700 dirs, 0600 marker/files) + verify bundle signature before exec | T-1, T-6, T-7 | M | T3, T6 |
| In-app integrity verification of the update artifact + reconstruct URL + reject foreign redirects | T-4 | M | T2 |
| Centralize untrusted-text sanitization at one boundary (C0/C1/DEL + bidi) for every sink | T-3, T-10 | S | T5 |
| Size-cap + symlink-skip every untrusted read; clamp integer accumulation; cap tailer buffer; finite socket timeout | T-2, T-8, T-9, T-5 | S | T7 |
| Move the socket to a per-user 0700 dir + client-side peer auth | T-5 | M | T1 |

---
*Static triage of static candidates — not execution-verified. The `⚠ re-verify`
items (T-5, T-7) and the analysis-only verdicts should be re-checked with fresh
reads before acting; the directly-verified set (T-1, T-2 F-001/F-002, T-3 F-004,
T-8 F-003) is code-confirmed.*
