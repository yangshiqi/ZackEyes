# Time Progress Overlay Design

## Goal

Show how much of each 5-hour or 7-day quota window has elapsed on the existing usage bars, independently from quota consumption.

## Preference

Persist `timeProgressMode` in `~/.zackeyes/config.json` with three values:

- `off` (default): existing bars are unchanged.
- `icon`: a deep ochre clock sits at the elapsed-time position. It straddles the track vertically; the portion intersecting the track is hollow so the full symbol stays legible over every usage color.
- `overlap`: a translucent light-gray fill runs from the leading edge to the elapsed-time position. When elapsed time is longer than quota usage it renders below the usage fill; otherwise it renders above, including when both are equal. Settings presents transparency from 0% to 100% in 10% steps (default 60%), inversely mapped to the persisted opacity (default 40%). Its same-color 1px border is 15 percentage points less opaque, floored at 0%.

The setting appears in Settings > General > Dynamic Island as an `Off / Icon / Overlap` segmented picker and applies immediately.

## Time Calculation

Only `resetsAt` is supplied by Claude/Codex. Window duration is fixed by row:

- 5h: 18,000 seconds
- 7d: 604,800 seconds

For valid data:

```text
elapsed = clamp(1 - (resetsAt - now) / duration, 0, 1)
```

No reset date means no time overlay. The calculation lives in a pure helper and is tested at the start, midpoint, end, before-start, and after-reset boundaries.

## Rendering

Add one shared `UsageProgressTrack` SwiftUI view used by the physical-notch full bars and both simulated-notch bar layouts. It renders the neutral track, quota consumption, and optional time layer in a stable 5/6pt frame. A `TimelineView` refreshes the time layer every 30 seconds without requiring new hook data.

The bundled Rock, F1, and Silicon sound files and their original theme mappings remain unchanged. Exact filename-list tests guard this unrelated settings surface from regression.

The icon center is clamped by half its width at both ends, preventing clipping at 0% and 100%. The hollow band is produced inside the icon compositing group and never cuts the underlying quota bar.

## Scope

Included:
- Physical-notch 5h/7d bars.
- Simulated-notch single-agent 5h/7d bars.
- Simulated-notch split Claude/Codex 5h/7d bars.

Excluded:
- Per-session context bars.
- Today token composition/chart.
- Compact text-only notch views.

## Verification

- Config round-trip/default/preservation tests.
- Pure elapsed-time calculation tests.
- Settings view-model persistence and live tracker update test.
- Full build/test/app assembly.
- Native screenshots for Icon and Overlap modes.
