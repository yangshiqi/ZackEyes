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

## SEO And GEO Requirements

Every production change should preserve these surfaces:

- Canonical URL and meta description.
- Open Graph and Twitter card metadata.
- JSON-LD `Organization`, `WebSite`, and `SoftwareApplication` data.
- `robots.txt` and sitemap output.
- `site.webmanifest`, `icon.svg`, and `og-image.svg`.
- `llms.txt` and `llms-full.txt` for LLM-readable discovery.

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
- `src/layouts/SiteLayout.astro` - SEO, social, manifest, and structured data shell.
- `src/styles/global.css` - Tailwind entry and custom landing page CSS.
- `src/pages/llms.txt.ts` and `src/pages/llms-full.txt.ts` - LLM-readable GEO context.
- `public/robots.txt`, `public/site.webmanifest`, `public/icon.svg`, `public/og-image.svg` - crawler and sharing assets.
- `docs/website-design-plan.md` - design direction, page structure, and open decisions.
- `tests/` - source and production output contracts for SEO/GEO/performance.

## Design Direction

The current direction is immersive CSS 3D for the hero, kinetic typography for scroll narrative, and restrained glassmorphism for product UI surfaces. The homepage intentionally ships as static HTML/CSS with one inline script for the canvas background and scroll progress, avoiding generated client JavaScript bundles until a real interactive island is needed.
