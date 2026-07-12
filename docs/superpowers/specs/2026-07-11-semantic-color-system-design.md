# Semantic Color System Design

## Goal

Give every functional color one stable meaning, make Overlap time progress distinct from quota pressure, and remove duplicated status RGB values across the app.

## Tokens

| Role | Value | Meaning |
|---|---|---|
| Activity | `#4FCBC3` | active work and healthy resource usage |
| Information | `#78A8D8` | neutral informational state |
| Time overlay | `#C9CDD3` | elapsed-window progress |
| Attention | `#F2B544` | waiting, stale data, and elevated quota pressure |
| Critical | `#F05A5A` | errors, destructive actions, and exhausted quota |
| Success | `#62C47A` | explicit successful completion or healthy integration |
| Idle | `#8E8E93` | inactive or resting session state |
| No data | `#FFFFFF` | unavailable quota signal, with component-owned opacity |
| Claude identity | `#C78CF2` | Claude category identity only |
| Codex identity | `#1AD98C` | Codex category identity only |

The existing deep ochre `#A16B24` remains a component token for the physical clock marker. It is an object treatment, not a warning state.

## Overlap Rendering

- Render elapsed time with light gray `#C9CDD3`; Settings presents 0%-100% transparency in 10% steps, defaulting to 60%, inverse to the persisted 40% opacity.
- Keep quota usage opaque and keep the existing dynamic layer order.
- Add a same-color 1px border 15 percentage points less opaque than the fill, floored at 0%.
- Use normal alpha compositing; do not use multiply or screen blending.
- Preserve fill length and border geometry so color is not the only differentiator.

## Migration Boundary

Migrate functional colors in Usage, Notch, SimulatedNotch, Settings, and MenuBar utility windows. Agent identity colors route through the shared tokens.

Do not migrate Buddy rock palettes, F1 team colors, or other illustrative/theme-owned colors. Those colors identify artwork rather than application state.

## Text

Usage percentage text follows the quota-pressure color. Reset countdowns remain secondary neutral text; they describe remaining time rather than the elapsed overlay.
