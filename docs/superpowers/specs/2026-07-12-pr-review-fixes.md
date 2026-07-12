# PR Review Fixes

## Goal

Close confirmed correctness, coverage, discoverability, and accessibility gaps from the unified settings and quota-presentation review while retaining the product decisions already recorded in the feature specs.

## In Scope

- Preserve simulated-notch expansion, recap, and scroll state across compact/full transitions without leaving hidden infinite animations active.
- Make all legacy ConfigStore mutation entry points abort when an existing config cannot be decoded.
- Give session grouping, compact attention, and list sorting one AppLib-owned attention policy.
- Verify Settings runtime notifications, expose Quit from Settings, and avoid constructing Settings state before first use.
- Add missing pure geometry coverage and remove stale/dead branches.
- Give menu-bar pressure a non-color channel and Buddy avatars a static reduced-motion state cue.
- Name neutral state colors and quota/context pressure thresholds centrally.
- Append a short session id only when visible project titles collide.
- Auto-expand Recent when it is the only non-empty session section.
- Keep Settings floating only while active, then demote it behind other applications.

## Explicitly Retained

- Project directory remains the primary session-card title; prompt and Buddy metadata provide secondary disambiguation.
- Compact quota chips continue coloring from raw quota pressure regardless of Used/Left presentation.

## Verification

- Focused unit tests cover corruption safety, notification posts, attention ordering, endpoint geometry, pressure presentation, and reduced-motion policy.
- `swift build`, `swift test`, and `make app` all pass.
