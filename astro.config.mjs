// @ts-check
import { defineConfig } from 'astro/config';

import sitemap from '@astrojs/sitemap';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  site: 'https://zackeyes.app',
  build: {
    format: 'file'
  },
  vite: {
    plugins: [tailwindcss()]
  },
  integrations: [sitemap()]
});
