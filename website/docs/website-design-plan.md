# ZackEyes Website Design Plan

Issue: #50
Branch: `feat/website-homepage-50`

## Product Story

ZackEyes is a small command center for AI coding agents that lives in the MacBook notch. The website should make that spatial idea obvious before it explains implementation details.

Primary message:

> Your AI agents, in the notch.

Supporting message:

> ZackEyes keeps Claude Code and Codex CLI sessions, approvals, tasks, and usage pressure visible without pulling you out of your editor.

## Audience

- Developers already using Claude Code, Codex CLI, or both.
- MacBook users who understand the notch as available screen real estate.
- People who run long agent tasks and want less terminal checking.
- Indie/tooling users who care about native behavior and low friction.

The page should feel like a serious macOS utility with a memorable hardware-native hook. Avoid generic AI assistant visuals.

## Design Direction

Use a hybrid direction:

- **Immersive 3D** for the first-viewport product metaphor: a MacBook top edge with a live notch command center.
- **Kinetic typography** for scroll narrative: large text that changes scale, position, and opacity as the user scrolls.
- **Restrained glassmorphism** for product UI surfaces: panels, permission prompts, session cards.

Do not use neo-brutalism as the main language. Its roughness conflicts with the product promise: native, calm, focused, and reliable.

## Visual System

### Mood

Industrial, native, controlled. The site should feel like a tool that belongs near the system menu bar, not like a marketing SaaS page.

### Palette

- Base: near-black green-tinted background.
- Primary accent: electric green for live state, CTA, and Codex-adjacent activity.
- Secondary accent: cyan for Claude/session contrast and socket/data flow.
- Warning accent: amber for permission request moments.
- Text: warm off-white, muted grey-green secondary copy.

Avoid making the page a one-color neon green theme. Green should be the product signal, not the whole atmosphere.

### Typography

- Display: condensed, heavy, uppercase for the command-center feel.
- Body: clean macOS-adjacent sans serif.
- Mono: only for hook/socket/code snippets.

Large display text should be reserved for hero and kinetic narrative sections. Product detail sections should use tighter, more readable type.

### Shapes

- Notch silhouette as brand cue.
- UI panels: small radius, glass-like but not overly frosted.
- Cards: radius 8px or less unless representing the actual notch panel.
- Avoid decorative floating cards inside cards.

## Page Structure

### 1. Hero

Goal: communicate the product in one glance.

Content:

- Kicker: `macOS native agent panel`
- H1: `Your AI agents / in the notch.`
- Body: Claude Code + Codex CLI sessions, tasks, rate limits, and permission prompts.
- Primary CTA: download.
- Secondary CTA: see flow / GitHub.
- Visual: 3D MacBook top edge with expanded notch panel and permission prompt.

Design requirement:

- The product/object must be visible in the first viewport on desktop.
- On mobile, show copy first and let the 3D object continue below the fold.

### 2. Kinetic Narrative

Goal: turn the concept into a memorable scroll moment.

Current draft:

- `Less terminal hunting.`
- `More agent awareness.`
- `Always in sight.`

Possible stronger version:

- `Stop checking terminals.`
- `Watch your agents breathe.`
- `Answer from the notch.`

Implementation rule:

- Animate only transform and opacity.
- Scroll handler must be rAF-throttled.
- Respect `prefers-reduced-motion`.

### 3. Product Capabilities

Goal: make the page useful after the visual hook.

Cards:

- Session state at a glance.
- Permission prompts without context switching.
- Rate limits where they matter.

Potential additions:

- Dual agent support: Claude Code + Codex CLI in one panel.
- Silent failure behavior: hooks never break terminal workflow.
- Menu bar fallback / simulated notch for non-notch machines.

### 4. Technical Trust Section

Goal: reassure technical users that this is not fragile magic.

Show:

- Hook event enters bridge.
- Bridge sends event to Unix socket.
- App updates session store and notch UI.
- Controlled failures exit silently.

Tone:

- Concise and factual.
- Do not over-explain architecture on the homepage.

### 5. Final CTA

Goal: restate the product promise and provide action.

Current:

`Turn the notch into signal.`

Possible alternatives:

- `Keep agents in sight.`
- `Make the notch useful.`
- `A command center for coding agents.`

## Content Gaps

Need final decisions for:

- Download URL.
- GitHub visibility/repo URL once public.
- App screenshots or generated product renders.
- Whether the public name stays `ZackEyes` or gets a clearer tagline.

## Implementation Plan

1. Keep the current static HTML as visual prototype.
2. Replace placeholder CTA links with real targets.
3. Tighten hero copy and kinetic lines.
4. Add a real screenshot/video capture from the macOS app if available.
5. Split static prototype into production site structure only after direction is approved.
6. Add performance checks for canvas, scroll animation, and mobile layout.

## Performance Constraints

- No heavy 3D library for the first iteration.
- Canvas background stays decorative and low-cost.
- Prefer CSS transforms over layout-changing animation.
- Pause ambient animation when document is hidden.
- Honor reduced motion.
- Keep the page usable without JavaScript where possible.

## Open Design Questions

- Should the hero visual be stylized CSS 3D, real app screenshot, or hybrid?
- Should the page target developers in English only, or support Chinese copy too?
- Should the site become a single landing page, or include docs/install sections?
- Should the final production path live under `docs/website`, root `website/`, or a GitHub Pages-compatible folder?
