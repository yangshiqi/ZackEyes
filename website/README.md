# ZackEyes Website

Public website for ZackEyes, a macOS notch command center for Claude Code and Codex CLI.

## Stack

- Astro 5 static site generation
- Tailwind CSS v4 through `@tailwindcss/vite`
- TypeScript with Astro strict config
- React 19 dependencies reserved for future Astro islands
- `@astrojs/sitemap` for static sitemap generation
- Node built-in test runner for source and production-output contracts

## Technical Architecture

The site is intentionally built as a static-first landing page:

- `src/pages/index.astro` renders the homepage to static HTML at build time.
- `src/components/SiteHeader.astro` owns the shared top navigation used by all public pages.
- `src/components/SiteFooter.astro` owns the shared footer links used by all public pages.
- `src/layouts/SiteLayout.astro` owns the document shell, metadata, canonical URL, social cards, manifest links, and JSON-LD structured data.
- `src/styles/global.css` contains the Tailwind v4 entry plus the custom visual system for the landing page.
- `public/` contains crawler and sharing assets that are copied directly into the production output.
- `src/pages/llms.txt.ts` and `src/pages/llms-full.txt.ts` expose LLM-readable product context for GEO and AI search surfaces.
- `tests/` validates the site contract and production output budget.

The homepage currently uses no React island and no generated client JavaScript bundle. The only browser script is the inline canvas/scroll-progress script in `src/pages/index.astro`. If React interactivity is added later, it should be isolated to small Astro islands and loaded only with an explicit `client:*` directive where needed.

## Runtime Requirements

- Node.js 20 or newer is recommended.
- pnpm 10.28.2 is the pinned package manager, declared in `package.json`.
- The production target must support static file hosting.
- The canonical production origin is currently `https://zackeyes.app`; update `astro.config.mjs`, `public/robots.txt`, and LLM text endpoints if the final domain changes.
- Latest public release: `https://github.com/yangshiqi/ZackEyes-release/releases/download/v0.8.0/ZackEyes-0.8.0.dmg`.
- DMG size: 3.5 MB.
- SHA256: `a44b445f675e3acb347d13ed70bbf7101b1618cc9781d561a6741c485fc4fa58`.
- Issues and feature requests: `https://github.com/yangshiqi/ZackEyes-release/issues`.
- Release metadata is centralised in [`src/lib/release.mjs`](src/lib/release.mjs); update that file on each release and every page + test will pick up the new values.
- `make release` in the ccisland repo triggers the [`bump-version`](.github/workflows/bump-version.yml) workflow here via `gh workflow run`, which rewrites `src/lib/release.mjs` with the new DMG metadata and opens a PR. The PR is intentionally not auto-merged so a changelog entry can be added by hand on the same branch.

## SEO And GEO Requirements

Every production change should preserve these surfaces:

- Canonical URL and meta description.
- Open Graph and Twitter card metadata.
- JSON-LD `Organization`, `WebSite`, and `SoftwareApplication` data.
- `robots.txt` and sitemap output.
- `site.webmanifest`, `icon.svg`, and `og-image.svg`.
- `llms.txt` and `llms-full.txt` for LLM-readable discovery.

## Public Pages

- `/` - product homepage, primary download CTA, FAQ, and download verification.
- `/docs` - install, uninstall, compatibility, and troubleshooting guide.
- `/download` - current DMG, compatibility, file size, SHA256, and install path.
- `/changelog` - public release notes and update history.
- `/roadmap` - product direction and planned focus areas.
- `/answers` - direct Q&A page for GEO and AI search.
- `/security` - local hook write boundaries, Unix socket bridge behavior, and safety model.
- `/privacy` - local-first privacy notes, network requests, analytics, and local data cleanup.
- `/llms.txt` and `/llms-full.txt` - crawler-readable product context.

When changing release metadata, update the homepage CTA, `/download`, `/docs`, `/changelog`, `/answers` if relevant, `llms.txt`, `llms-full.txt`, and this README. Keep the DMG size and SHA256 in sync with the public GitHub Release asset.

## Product Content Requirements

The public product story should mention more than agent visibility alone:

- Multiple themes for matching the notch panel to different desktop styles: Rock Legends, F1 2026, and AI moguls.
- Display modes for real MacBook notches, simulated Dynamic Island-style panels, menu bar use, and external displays.
- Claude Code and Codex CLI session state, approvals, task progress, completion, and usage pressure.
- terminal tab jump for iTerm2, Terminal.app, Ghostty, Warp, WezTerm, Kitty, Alacritty, VS Code, and Cursor.
- Per-session context window usage, model and cost metadata, custom global hotkey, update checker, and in-app DMG download.
- Local-first hook and Unix socket architecture, with identifiable `zackeyes` hook entries.
- Public download, verification, and feedback paths through GitHub Releases and GitHub Issues.

## Performance Requirements

The landing page should stay optimized for fast open and first render:

- Keep the homepage statically rendered by Astro.
- Avoid generated client JavaScript bundles unless a real interactive island requires one.
- Keep below-the-fold sections using render-friendly CSS such as `content-visibility`.
- Respect `prefers-reduced-motion`.
- Keep animations limited to transform, opacity, and low-cost canvas work.
- Run `pnpm test` after `pnpm build`; the output tests enforce no generated homepage JS bundle and static asset size budgets.

## Development

```bash
pnpm install
pnpm dev
```

Then visit:

```text
http://localhost:4321
```

## Verification

```bash
pnpm test
pnpm build
```

## Structure

- `src/pages/index.astro` - static homepage.
- `src/pages/docs.astro` - install, uninstall, compatibility, and troubleshooting content.
- `src/pages/download.astro` - current release download, verification, and install content.
- `src/pages/changelog.astro` - release history.
- `src/pages/roadmap.astro` - product roadmap.
- `src/pages/answers.astro` - direct answer content for GEO.
- `src/pages/security.astro` - local security and safety model.
- `src/pages/privacy.astro` - privacy notes.
- `src/components/SiteHeader.astro` - shared top navigation for every public page.
- `src/components/SiteFooter.astro` - shared footer for every public page.
- `src/layouts/SiteLayout.astro` - SEO, social, manifest, and structured data shell.
- `src/styles/global.css` - Tailwind entry and custom landing page CSS.
- `src/pages/llms.txt.ts` and `src/pages/llms-full.txt.ts` - LLM-readable GEO context.
- `public/robots.txt`, `public/site.webmanifest`, `public/icon.svg`, `public/og-image.svg` - crawler and sharing assets.
- `docs/website-design-plan.md` - design direction, page structure, and open decisions.
- `tests/` - source and production output contracts for SEO/GEO/performance.

## Design Direction

The current direction is immersive CSS 3D for the hero, kinetic typography for scroll narrative, and restrained glassmorphism for product UI surfaces. The homepage intentionally ships as static HTML/CSS with one inline script for the canvas background and scroll progress, avoiding generated client JavaScript bundles until a real interactive island is needed.

Logo source: `https://www.logosymbol.com/letter/letter-z-logo-design-with-arrow`. The source is published as CC0 by LogoSymbol; the site uses a ZackEyes-themed recolor in `public/logo-symbol.svg` and `public/icon.svg`.
