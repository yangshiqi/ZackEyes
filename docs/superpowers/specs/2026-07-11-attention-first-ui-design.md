# Attention-First UI Design

## Goal

Make ZackEyes answer three questions within one glance: which agent needs the user, which sessions are running, and where to click next.

## Low-Cost Slice

### Session list

Group the existing urgency-sorted sessions into:

- `Needs You`: pending permission/question, surfaced error, or waiting state.
- `Running`: working sessions without an attention condition.
- `Recent`: idle and stopped sessions, collapsed by default.

Each non-empty section shows its count. Needs You and Running stay expanded. Recent is user-toggleable and starts collapsed each time the full view is mounted.

### Session card hierarchy

Promote `SessionInfo.displayName` (project directory) to the primary card title. Keep Agent, permission risk, and elapsed time in the title row. Show prompt/context as supporting text. Buddy name remains visible as quiet personality metadata beside the avatar rather than acting as the session identity.

### Compact attention

Replace decorative working pulse with a static status mark. Errors take red priority, pending user actions take amber priority, and counts appear when more than one item needs attention. Quota text remains stable.

### Settings copy

- `Compact display` becomes `Preferred quota source` because the selected agent falls back when it has no quota data.
- `Time progress` becomes `Window elapsed`.
- `Today's usage` becomes `Today's consumption`.

Keep the existing text segmented control for Off / Icon / Overlap, per product decision.

### Reduced motion

Buddy animations automatically stop when macOS Reduce Motion is enabled. Static state styling remains visible, so accessibility never removes status meaning.

## Deferred For Re-Evaluation

- Live compact previews in General and Appearance: decide whether previews use illustrative sample data or real usage before implementation.
- A global semantic color system: inventory every status/agent/quota/risk color first to avoid partial, conflicting migration.
- Explicit `Full / Status only / Off` motion preference: requires new persistence, live propagation, and animation lifecycle tests.

## Non-Goals

- No Bridge, socket, hook, session lifecycle, quota calculation, or notification behavior changes.
- No new session persistence, history, search, pinning, or muting.
