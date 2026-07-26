import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import { writeFile } from 'node:fs/promises';
import { APP_VERSION } from './src/i18n/locales';

// Cloudflare Pages _redirects, generated at build time so the /dl/* download
// aliases track APP_VERSION (single source in src/i18n/locales.ts) instead of
// needing a manual bump on every release.
const DL_BASE = `https://github.com/faeton/mediaporter/releases/download/v${APP_VERSION}`;
const REDIRECTS = `# GENERATED at build time from astro.config.mjs — edit there, not here.

# Old per-device anime guide URLs were merged into one canonical page on 2026-05-13.
# 301 to preserve any external links and pass PageRank.

/guides/anime-on-iphone        /guides/anime-on-iphone-and-ipad        301
/guides/anime-on-ipad          /guides/anime-on-iphone-and-ipad        301
/ru/guides/anime-on-iphone     /ru/guides/anime-on-iphone-and-ipad     301
/ru/guides/anime-on-ipad       /ru/guides/anime-on-iphone-and-ipad     301
/zh/guides/anime-on-iphone     /zh/guides/anime-on-iphone-and-ipad     301
/zh/guides/anime-on-ipad       /zh/guides/anime-on-iphone-and-ipad     301
/ko/guides/anime-on-iphone     /ko/guides/anime-on-iphone-and-ipad     301
/ko/guides/anime-on-ipad       /ko/guides/anime-on-iphone-and-ipad     301

# Short download aliases — always the current release (APP_VERSION).
# 302 (Found) so search engines don't cache the binary URL and we can repoint
# to a newer build without 301 cache pollution.
/dl/mac             ${DL_BASE}/MediaPorter-${APP_VERSION}-with-ffmpeg.dmg   302
/dl/mac-ffmpeg      ${DL_BASE}/MediaPorter-${APP_VERSION}-with-ffmpeg.dmg   302
/dl/mac-minimal     ${DL_BASE}/MediaPorter-${APP_VERSION}.dmg               302
/dl/releases        https://github.com/faeton/mediaporter/releases          302
`;

export default defineConfig({
  site: 'https://porter.md',
  output: 'static',
  trailingSlash: 'never',
  build: {
    assets: '_assets',
    format: 'file',
  },
  compressHTML: true,
  integrations: [
    sitemap({
      i18n: {
        defaultLocale: 'en',
        locales: { en: 'en', ru: 'ru', zh: 'zh-CN', ko: 'ko' },
      },
      changefreq: 'weekly',
      priority: 0.7,
    }),
    {
      name: 'generate-redirects',
      hooks: {
        'astro:build:done': async ({ dir }) => {
          await writeFile(new URL('_redirects', dir), REDIRECTS);
        },
      },
    },
  ],
});
