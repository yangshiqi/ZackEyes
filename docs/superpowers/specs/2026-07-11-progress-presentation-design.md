# Progress Presentation Design

## Goal

Let people choose whether ZackEyes presents quota windows as consumption or remaining capacity, while keeping the elapsed-window layer, text, fill direction, and overlap geometry in the same mental model.

## Preferences

Persist three independent display preferences in `~/.zackeyes/config.json`:

| Key | Values | Default |
|---|---|---|
| `progressMode` | `used`, `left` | `used` |
| `leftProgressDirection` | `leftToRight`, `rightToLeft` | `leftToRight` |
| `timeOverlayOpacity` | `0.0 ... 1.0`, tenth increments | `0.4` |

`leftProgressDirection` is retained while Used is selected but has no visual effect until Left is selected. The prerelease value remains accepted as an alias for `used`. Values loaded from edited or old config files are clamped to `0...1` and rounded to the nearest tenth.

## Settings

Add the following controls to Settings > General > Dynamic Island:

```text
Progress mode       [ Used | Left ]
Fill direction      [ -> | <- ]       (visible only for Left)
Window elapsed      [ Off | Icon | Overlap ]
Overlay transparency [----|------] 60% (visible only for Overlap)
```

The direction segments use SF Symbol arrows with accessibility labels and hover help. The opacity control is a native slider with `0...100`, `10`-point steps, and a fixed-width percentage value.

## Display Rules

| Mode | Displayed value | Header wording | Fill fraction | Fill anchor |
|---|---|---|---|---|
| Used | `usedPct` | `54% used` | `usedPct` | leading (left) |
| Left, LTR | `100 - usedPct` | `54% remaining` | `100 - usedPct` | leading (left) |
| Left, RTL | `100 - usedPct` | `54% remaining` | `100 - usedPct` | trailing (right) |

The compact pill keeps a dense `5h 54% Used` form with a small, low-emphasis Used/Left suffix. The number follows the selected mode. Expanded and split quota rows use the explicit `used` or `remaining` wording. A hard rate-limit state still says `limit`; it is never relabeled as remaining capacity.

Usage color continues to express quota pressure from the original `usedPct`, not from the draw direction. Thus 90% remaining is a long Activity-colored Left bar, while 10% remaining is a short Critical-colored Left bar. Menu-bar risk color, ETA, usage ingestion, Today consumption, and per-session context bars are not part of this preference.

## Time Presentation

Time follows the same presentation semantics:

| Mode | Time value | Time fraction | Fill anchor |
|---|---|---|---|
| Used | elapsed window time | elapsed fraction | leading (left) |
| Left, LTR | reset time remaining | `1 - elapsed` | leading (left) |
| Left, RTL | reset time remaining | `1 - elapsed` | trailing (right) |

Icon mode places the clock at the visible end of the time fill. In Left mode it therefore moves toward depletion, rather than continuing to imply elapsed consumption.

Overlap compares the two displayed fractions, not the raw used fractions. The time layer remains below when its displayed fill is longer, otherwise above. The time segment has a 1px border in the same light-gray token as the fill. Settings presents inverse transparency: 60% transparency is stored as 40% opacity. A zero opacity hides the fill and border; otherwise border opacity is `max(0, overlayOpacity - 0.15)`.

## Architecture

Introduce pure presentation helpers that convert the stored used percentage and elapsed fraction into:

- displayed numeric value and label role;
- fill fraction;
- leading or trailing anchor;
- time border opacity;
- overlap layer order.

`UsageProgressTrack` consumes this presentation state rather than hard-coding a leading used fill. `UsageTracker` remains the published owner of the three display preferences so physical notch and simulated notch update immediately. `ConfigStore` owns defensive persistence, and `SettingsViewModel` bridges the controls to the tracker.

## Verification

- Config default, round-trip, malformed-value, clamping, and preservation tests.
- Pure presentation tests for Used, Left LTR, and Left RTL, including 0%, 50%, and 100% boundaries.
- Time border-opacity and overlap-order tests for all presentation combinations.
- Text tests for expanded and split rows, including limit-reached priority.
- Native screenshots for Used, Left LTR, Left RTL, and Overlap opacity 0%, 40%, and 100%.

## Non-Goals

- No change to how Claude or Codex usage is collected, cached, or expired.
- No reversal of burn-rate or ETA calculation; they continue to predict quota exhaustion from consumption.
- No direction preference for per-session context bars or Today consumption.
