// @ts-check
import { defineConfig } from 'astro/config';

import sitemap from '@astrojs/sitemap';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  site: 'https://zackeyes.app',
  trailingSlash: 'never',
  build: {
    // 'directory' emits /foo/index.html which Vercel serves at /foo with no
    // redirect, AND tells @astrojs/sitemap to emit /foo URLs (not /foo.html)
    // so search engines crawl the canonical form directly.
    format: 'directory'
  },
  vite: {
    plugins: [tailwindcss()]
  },
  integrations: [sitemap()]
});
