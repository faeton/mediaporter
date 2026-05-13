import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

const LOCALES = ['en', 'ru', 'zh', 'ko'];

function localePathPrefix(locale) {
  return locale === 'en' ? '' : `/${locale}`;
}

function alternatesFor(pathname) {
  // pathname is full URL — derive base path (strip /ru, /zh, /ko prefix)
  try {
    const u = new URL(pathname);
    const parts = u.pathname.split('/').filter(Boolean);
    const base = (parts[0] === 'ru' || parts[0] === 'zh' || parts[0] === 'ko')
      ? '/' + parts.slice(1).join('/')
      : u.pathname;
    const normalized = base === '' ? '/' : base;
    const out = {};
    for (const l of LOCALES) {
      const prefix = localePathPrefix(l);
      const href = `https://porter.md${prefix}${normalized === '/' ? '' : normalized}` || 'https://porter.md/';
      out[l === 'zh' ? 'zh-CN' : l] = href === 'https://porter.md' ? 'https://porter.md/' : href;
    }
    return out;
  } catch {
    return undefined;
  }
}

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
      lastmod: new Date(),
    }),
  ],
});
