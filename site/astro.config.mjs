import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://porter.md',
  output: 'static',
  trailingSlash: 'never',
  build: {
    assets: '_assets',
  },
  compressHTML: true,
});
