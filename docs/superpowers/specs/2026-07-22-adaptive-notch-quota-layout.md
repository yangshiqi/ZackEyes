# Adaptive Notch Quota Layout

## Goal

Fix #180 and #194 together so the compact physical-notch exclusion region stays centered while every quota surface renders only the windows the selected agent actually exposes.

## Problem

`NotchCompactView` currently centers one asymmetric fixed-size row containing the status icon, 5h chip, notch-width spacer, and 7d chip. The physical notch is centered on the screen, but the spacer drifts when the left and right content widths differ.

Codex can now emit only a 7-day rate-limit window. The ingestion layer classifies that payload correctly, but compact and expanded views still render hard-coded 5h and 7d slots. An absent 5h window is therefore presented as missing data and remains the compact headline.

## Design

### Physical-notch geometry

- Replace the asymmetric centered HStack with a two-sided layout whose exclusion region is always centered in its own bounds.
- Size both sides from the larger measured side, right-align the leading content and left-align the trailing content around the exclusion region.
- Keep a per-side safety margin around the runtime `notchWidth`.
- Extract the geometry calculation as a pure value so asymmetric content and multiple notch widths can be unit tested.

### Quota-window presentation

- Add a pure presentation model that derives ordered visible windows from 5h/7d values.
- Preserve the order 5h then 7d when both are available.
- A single 7d window becomes the compact primary chip; do not render `5h —`.
- Expanded physical and simulated surfaces render the union of windows that are meaningful for the active agent(s).
- Attach the gear to the first visible row. If no window is visible, render one empty/limit state row that retains the gear.
- Use freshness to distinguish `no quota data` from a fresh reading with `no active quota windows`.
- Keep limit-only Codex state visible even when no percentage window is present.

## Compatibility

- Runtime screen metrics remain the source of physical-notch width; no Mac model table is introduced.
- Claude dual-window behavior remains unchanged.
- Older or future Codex dual-window payloads automatically render both rows.
- Progress direction, reset countdowns, ETA, colors, time overlays, update badge, mouse behavior, and panel activation policy remain unchanged.

## Verification

- Pure tests cover dual, 5h-only, 7d-only, and no-window presentation.
- Geometry tests prove the exclusion region stays centered and neither side intersects it for asymmetric content and multiple notch widths.
- Focused AppLib tests, full `swift test`, `swift build`, and `make app` pass.
