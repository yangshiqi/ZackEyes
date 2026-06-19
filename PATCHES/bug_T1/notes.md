# Candidate patch — T-1: launcher chain code-execution

**File:** `Sources/AppLib/Hooks/HookInstaller.swift` (`deployLauncherScript`, `deployScript`)
**Finding:** TRIAGE T-1 (folds F-010/F-011/F-012/F-014) — same-uid code-execution
persistence via the unprotected `~/.zackeyes` launcher chain.

> ⚠️ **INERT — for human review only.** This diff was NOT applied to the source,
> NOT built, and NOT tested. The normal `/patch` verification ladder (apply →
> rebuild → re-attack) and the independent reviewer pass could not run (monthly
> spend limit). Treat every claim below as unverified until you build and test.

## What the diff changes

1. **`~/.zackeyes` and `~/.zackeyes/bin` created `0700`** (was umask-default,
   typically `0755`), and re-tightened with `setAttributes` in case they
   pre-existed loose.
2. **Launcher script written `0700`** (was `0755`) via a new `permissions:`
   parameter on `deployScript` (default stays `0755`, so the statusline-mux path
   is unchanged).
3. **`.app-path` marker written `0600`** (was default `0644`), mirroring the
   deliberate `0600` lock already on the socket node.
4. **Resolution order reordered**: the deploy-time-baked absolute path and the
   fixed `/Applications` paths are tried **before** the mutable marker. The
   marker becomes a fallback for the "app was relocated after install" case
   (still kept fresh by `HookHealth`).
5. **Commented-out signature gate** in `try_app()`, with instructions — see below.

## What it closes — and what it does NOT

**Closes (cross-uid):** items 1–3 remove the world-readable/writable surface, so
another *local user* can no longer read the spooled marker or write the launcher
dir. This is the real fix for the **cross-uid** slice and for **T-7**.

**Does NOT close (same-uid):** T-1's core threat is a **same-uid** attacker (a
compromised dependency running as you). That attacker **owns** these files and
can `chmod` them back and rewrite the marker regardless of `0700`/`0600`.
Item 4 (reorder) only **shrinks** the window — the attacker must now also
invalidate the baked path, or wait for a relocation, before the marker is
consulted. It does not eliminate it.

**The only thing that actually stops same-uid bundle substitution is the
signature gate (item 5), and that is blocked on finding T-4:** ZackEyes is
**ad-hoc signed**, so an attacker can ad-hoc sign an impostor bundle with the
same identifier and pass any local signature check. The gate is therefore left
**disabled** and only becomes meaningful once the app ships **Developer-ID
signed + notarized** (the T-4 fix). **T-1 and T-4 are coupled — neither is fully
fixed alone.**

## How to verify (when spend allows)

1. `git apply PATCHES/bug_T1/patch.diff` on a branch.
2. `make app` (or `swift build`) — confirm it compiles; `deployScript`'s new
   default-arg keeps existing call sites valid.
3. Run the app once; check perms landed:
   `stat -f '%Sp %Su' ~/.zackeyes ~/.zackeyes/bin ~/.zackeyes/bin/bridge ~/.zackeyes/.app-path`
   → expect `drwx------` / `-rwx------` / `-rw-------`, owner = you.
4. Confirm hooks still fire (trigger a Claude/Codex tool call; the notch should
   still receive events) — i.e. the reorder didn't break normal resolution.
5. Run `AppLibTests` (`HookInstaller`/`HookHealth` tests) — the reorder and the
   marker perms may need test updates; **expect some tests to need adjusting**,
   that's a signal not a failure.
6. Only after T-4 (Developer-ID + notarization) lands: enable the commented
   `codesign --verify` block and re-test that a *legit* signed build still
   resolves (no false-negative that silently disables hooks).

## Reviewer watch-items

- The reorder changes self-heal semantics if the app is moved AND none of the
  three fixed paths match AND `HookHealth` hasn't refreshed the marker yet.
  Confirm `HookHealth`'s repair cadence covers that gap.
- `createDirectory(attributes:)` sets the mode on the leaf; the explicit
  `setAttributes` calls cover the intermediate (`zackDir`) — confirm both end
  up `0700` on a machine where `~/.zackeyes` already existed at `0755`.
- The `0600` marker is rewritten by the launcher's `printf … > "$C"` on each
  successful resolve; shell `>` truncates in place and preserves the existing
  mode, so it stays `0600` after the first app-side write. Verify.
