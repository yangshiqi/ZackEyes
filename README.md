# ZackEyes Website

Public website for ZackEyes, a macOS notch command center for Claude Code and Codex CLI.

## Stack

- Astro 5 static output
- Tailwind CSS v4 through the Vite plugin
- React 19 dependencies are available for future Astro islands
- Sitemap, robots, manifest, JSON-LD, Open Graph, Twitter cards, and `llms.txt`

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
