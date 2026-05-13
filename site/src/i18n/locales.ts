export type Locale = "en" | "ru" | "zh" | "ko";

export const LOCALES: Locale[] = ["en", "ru", "zh", "ko"];
export const DEFAULT_LOCALE: Locale = "en";

export const HTML_LANG: Record<Locale, string> = {
  en: "en",
  ru: "ru",
  zh: "zh-CN",
  ko: "ko",
};

export const OG_LOCALE: Record<Locale, string> = {
  en: "en_US",
  ru: "ru_RU",
  zh: "zh_CN",
  ko: "ko_KR",
};

export const LOCALE_LABEL: Record<Locale, string> = {
  en: "English",
  ru: "Русский",
  zh: "中文",
  ko: "한국어",
};

/** Prefix a path with the locale (en lives at root). */
export function localizePath(locale: Locale, path: string): string {
  const p = path.startsWith("/") ? path : `/${path}`;
  if (locale === "en") return p === "/" ? "/" : p;
  return p === "/" ? `/${locale}` : `/${locale}${p}`;
}

/** Derive the current locale from a pathname. */
export function localeFromPath(pathname: string): Locale {
  const seg = pathname.split("/").filter(Boolean)[0];
  if (seg === "ru" || seg === "zh" || seg === "ko") return seg;
  return "en";
}

/** Strip the locale prefix to get the "base" path (always starts with /). */
export function stripLocale(pathname: string): string {
  const seg = pathname.split("/").filter(Boolean);
  if (seg[0] === "ru" || seg[0] === "zh" || seg[0] === "ko") {
    const rest = "/" + seg.slice(1).join("/");
    return rest === "/" ? "/" : rest;
  }
  return pathname.replace(/\/$/, "") || "/";
}

/** Hreflang alternates for a given base path (without locale prefix). */
export function alternates(basePath: string, siteOrigin = "https://porter.md") {
  return LOCALES.map((l) => ({
    hreflang: HTML_LANG[l],
    href: siteOrigin + localizePath(l, basePath),
  }));
}

export type Strings = {
  /** Document */
  htmlTitle: string;
  metaDescription: string;
  /** Nav */
  navChangelog: string;
  navSupport: string;
  navPrivacy: string;
  navGuides: string;
  navSetup: string;
  /** Hero */
  heroEyebrow: string;
  heroTitleLead: string;
  heroTitleAccent: string;
  heroTitleMuted: string;
  heroLede: string; // may contain <strong>
  ctaDownload: string;
  ctaSource: string;
  heroRequires: string;
  heroOneLiner: string;
  /** Features */
  featuresHeading: string;
  featuresLede: string; // may contain link placeholder {changelog}
  features: { tag: string; title: string; body: string }[];
  /** How */
  howEyebrow: string;
  howHeading: string;
  howLede: string;
  howSteps: { n: string; title: string; body: string }[];
  /** Anime callout (links to guide) */
  animeCalloutEyebrow: string;
  animeCalloutTitle: string;
  animeCalloutBody: string;
  animeCalloutCtaIphone: string;
  animeCalloutCtaIpad: string;
  /** More guides section */
  moreGuidesEyebrow: string;
  moreGuidesHeading: string;
  moreGuides: { tag: string; title: string; body: string; href: string; ctaSoon?: boolean }[];
  moreGuidesCtaSoon: string;
  /** FAQ */
  faqEyebrow: string;
  faqHeading: string;
  faq: { q: string; a: string }[];
  /** Download */
  downloadEyebrow: string;
  downloadTitle: string;
  downloadBody: string;
  downloadCta: string;
  downloadEmailPlaceholder: string;
  downloadNote: string;
  /** Setup callout on homepage */
  setupCalloutEyebrow: string;
  setupCalloutTitle: string;
  setupCalloutBody: string;
  setupCalloutCta: string;
  /** Setup page */
  setupPageTitle: string;
  setupPageDescription: string;
  setupHeading: string;
  setupLede: string;
  setupIntroBullets: string[];
  setupBuildsTag: string;
  setupBuildsTitle: string;
  setupBuildsBody: string;
  setupBuilds: { title: string; body: string }[];
  setupTmdbTag: string;
  setupTmdbTitle: string;
  setupTmdbWhat: string;
  setupTmdbSteps: string[];
  setupTmdbFree: string;
  setupTmdbCta: string;
  setupOsTag: string;
  setupOsTitle: string;
  setupOsWhat: string;
  setupOsSteps: string[];
  setupOsFree: string;
  setupOsCta: string;
  setupApplyHeading: string;
  setupApplyBody: string;
  /** Footer */
  footerProduct: string;
  footerHelp: string;
  footerFeatures: string;
  footerTagline: string;
  footerRights: string;
};

const en: Strings = {
  htmlTitle: "MediaPorter — Sync video, anime, and movies to the iPhone & iPad TV app",
  metaDescription:
    "Native macOS app that transcodes and syncs video, anime, and movies straight into the iPhone and iPad TV app. No iCloud. No iTunes. No data collection. Open source.",
  navChangelog: "Changelog",
  navSupport: "Support",
  navPrivacy: "Privacy",
  navGuides: "Guides",
  navSetup: "Setup",
  heroEyebrow: "## porter.md",
  heroTitleLead: "Media,",
  heroTitleAccent: "ported.",
  heroTitleMuted: "Deep on your devices.",
  heroLede:
    'A native macOS app that transcodes and syncs your video library straight into the built-in iOS/iPadOS <strong>TV app</strong>. No iCloud round-trip. No browser uploader. No "watch on the laptop" workaround.',
  ctaDownload: "Download for macOS",
  ctaSource: "View source",
  heroRequires: "# Requires macOS 14+ · iOS / iPadOS 15+",
  heroOneLiner:
    "drag ~/Movies/Anime → \"iPad Pro\"  # → 24 episodes, posters, sort order, audio switcher fixed",
  featuresHeading: "Built for the way the TV app actually works.",
  featuresLede:
    "Every feature here exists because we found a specific way the iPad TV app fails when fed arbitrary video. See {changelog} for the full trail.",
  features: [
    {
      tag: "transcode",
      title: "Smart, not stubborn",
      body: "Only re-encodes what your device can't play. HEVC stays HEVC. AAC and EAC3 pass through. AC3 → AAC because the iPad TV app silently drops AC3 from its audio switcher.",
    },
    {
      tag: "metadata",
      title: "Posters, seasons, sort titles",
      body: "Pulls metadata from TMDb, writes the full TV-app field set (sort titles, episode_sort_id, artwork via Airlock). Episodes group correctly. No \"0.\" prefix bug.",
    },
    {
      tag: "anime",
      title: "Anime-aware",
      body: "Detects sequential episodes, handles burned-in episode numbers, deduplicates against what's already on the device. Works with fan-subbed releases.",
    },
    {
      tag: "sync",
      title: "Pipelined sync, not 30-minute waits",
      body: "Files appear in the TV app as they finish uploading — not after a long \"finalizing\" wall. Mid-sync disk-space checks. Cmd-Q guard while syncing.",
    },
    {
      tag: "native",
      title: "Native macOS",
      body: "Built in Swift. Dark by default. Quits cleanly. Sits in the dock, not in your menu bar — unless you ask.",
    },
    {
      tag: "private",
      title: "No telemetry. None.",
      body: "We don't collect data. Not anonymous, not aggregated, not \"for product improvement.\" The app talks to your device, and to TMDb for posters. That's it.",
    },
  ],
  howEyebrow: "## how",
  howHeading: "One drop. Three phases.",
  howLede:
    "MediaPorter watches your library, plans what to do, and shows you the receipts before a single byte moves. You stay in control.",
  howSteps: [
    {
      n: "01",
      title: "Analyze",
      body: "Probe codecs, audio tracks, subtitles. Match titles to TMDb. Detect anime episode numbers. Skip files already on the device.",
    },
    {
      n: "02",
      title: "Plan",
      body: "Per file: keep as-is, remux, or transcode. Audio: pass-through or convert. Disk space check. You approve before anything runs.",
    },
    {
      n: "03",
      title: "Port",
      body: "Transcode in parallel. Upload to the device over USB or Wi-Fi. Register each file with the TV app as it lands — not after a 30-minute wait.",
    },
  ],
  animeCalloutEyebrow: "## guides",
  animeCalloutTitle: "How to put anime on iPhone and iPad",
  animeCalloutBody:
    "Step-by-step: get any anime release — single episodes, full seasons, fan subs — into the native TV app, with correct episode numbers, posters, and subtitles. No jailbreak.",
  animeCalloutCtaIphone: "Read the guide →",
  animeCalloutCtaIpad: "Read the guide →",
  moreGuidesEyebrow: "## more guides",
  moreGuidesHeading: "Pick a starting point",
  moreGuidesCtaSoon: "Coming soon",
  moreGuides: [
    {
      tag: "anime",
      title: "Anime on iPhone & iPad",
      body: "Drag a folder of .mkv files — single episodes, full seasons, fan subs — into MediaPorter. Watch each episode appear in the TV app with the right poster, season, and episode number as the upload completes. Dual audio is preserved; AC-3 is converted to AAC so the iPad TV app's audio switcher actually shows your tracks.",
      href: "/guides/anime-on-iphone-and-ipad",
    },
    {
      tag: "movies",
      title: "Movies without iTunes",
      body: "Drop a movies folder. MediaPorter probes each file, looks up the right TMDb poster, decides per-file whether to remux or re-encode, and shows you the plan before anything runs. Movies land in Library → Movies on the device.",
      href: "/#features",
      ctaSoon: true,
    },
    {
      tag: "tv",
      title: "TV shows with correct order",
      body: "S01E01 — S05E22 in a single drop. Sort titles and episode_sort_id are filled correctly, so episodes line up by season instead of alphabetically. No \"0. Show Name\" drift at the top of the list.",
      href: "/#features",
      ctaSoon: true,
    },
    {
      tag: "audio",
      title: "Fix missing audio tracks on iPad",
      body: "If your file has multiple audio tracks but the iPad TV app's audio switcher only shows one, AC-3 is the culprit. MediaPorter converts AC-3 to AAC and sets disposition correctly so every track is selectable. Walks you through the fix step-by-step.",
      href: "/#faq",
      ctaSoon: true,
    },
    {
      tag: "4k",
      title: "4K HEVC without re-encoding",
      body: "MediaPorter detects HEVC and remuxes in place — no quality loss, no waiting on ffmpeg. Files that need rewrapping for the TV app (.m4v container, hvc1 tag) get handled automatically.",
      href: "/#features",
      ctaSoon: true,
    },
    {
      tag: "subs",
      title: "Subtitles that actually show up",
      body: "SRT, ASS/SSA, mov_text, and PGS soft subs are remuxed into the output when the TV app can render them. Where the TV app can't (heavy ASS styling), MediaPorter degrades gracefully to plain text instead of silently dropping the track.",
      href: "/#faq",
      ctaSoon: true,
    },
  ],
  faqEyebrow: "## faq",
  faqHeading: "Frequently asked questions",
  faq: [
    {
      q: "How do I put anime on my iPhone or iPad?",
      a: "Install MediaPorter on a Mac, plug in (or pair over Wi-Fi) the iPhone or iPad, drag your anime folder into the app, and click sync. Episodes appear inside the built-in TV app under Library → TV Shows, with posters and correct episode order. Works with .mkv, .mp4, .m4v, .avi, subtitled or dubbed releases.",
    },
    {
      q: "Does this work without iTunes or iCloud?",
      a: "Yes. MediaPorter talks directly to the device using Apple's on-device sync protocol (ATC). Nothing is uploaded to iCloud. iTunes / Apple Music is not involved.",
    },
    {
      q: "Can I sync movies and TV shows too?",
      a: "Yes. MediaPorter detects movies vs. TV shows vs. anime automatically. Movies land under Library → Movies; series and anime land under TV Shows with seasons and episode numbers.",
    },
    {
      q: "Will it transcode my whole library?",
      a: "Only what your device can't already play. HEVC video is kept as-is. AAC and E-AC-3 audio pass through. AC-3 (Dolby Digital) is converted to AAC because the iPad TV app silently hides AC-3 tracks from the audio switcher.",
    },
    {
      q: "Does it support .mkv files?",
      a: "Yes. MKV with H.264, HEVC, AAC, AC-3, E-AC-3, or DTS is handled. Video is remuxed without re-encoding when possible; audio is converted only when the TV app would otherwise fail to play it.",
    },
    {
      q: "Will subtitles come across?",
      a: "Soft subtitles (SRT, ASS/SSA, mov_text, PGS) are remuxed into the output file when the TV app can render them. Burned-in subtitles stay in the picture.",
    },
    {
      q: "Do I need to jailbreak my iPhone or iPad?",
      a: "No. MediaPorter uses public Apple sync protocols on a stock device. macOS 14+, iOS / iPadOS 15+.",
    },
    {
      q: "Does MediaPorter collect telemetry?",
      a: "No analytics inside the app. No crash beacons, no usage stats. The macOS app talks only to your device and to TMDb (for posters).",
    },
    {
      q: "Do I need API keys to use MediaPorter?",
      a: "MediaPorter uses two free third-party services — TMDb for posters and metadata, and OpenSubtitles for downloading missing-language subtitles. Both require your own free account (5 minutes, no credit card). Bundling shared keys in the app isn't viable: they'd get extracted from the binary and rate-limited within days. See the Setup page for step-by-step instructions. Skipping them still works — you'll just get fallback posters and only the subtitles already inside your files.",
    },
  ],
  downloadEyebrow: "## download",
  downloadTitle: "Get MediaPorter.",
  downloadBody:
    "The macOS app is in private beta while we await Apple Developer Program approval. Drop your email and we'll send a signed build the day notarization lands.",
  downloadCta: "Notify me",
  downloadEmailPlaceholder: "you@example.com",
  downloadNote: "# No tracking pixel. The form posts a plain mailto: — your client opens.",
  setupCalloutEyebrow: "## setup",
  setupCalloutTitle: "You'll need two free API keys.",
  setupCalloutBody:
    "MediaPorter doesn't ship with bundled API keys — they'd get extracted from the binary and rate-limited for everyone within days. Instead, you grab your own free keys from TMDb (posters and metadata) and OpenSubtitles (subtitles). Five minutes, no credit card.",
  setupCalloutCta: "Open setup guide →",
  setupPageTitle: "Setup — API keys for MediaPorter",
  setupPageDescription:
    "How to get the free TMDb and OpenSubtitles API keys that MediaPorter uses for posters, metadata, and subtitles.",
  setupHeading: "Two free API keys, five minutes.",
  setupLede:
    "MediaPorter uses two third-party services to enrich your library: TMDb for posters and show metadata, and OpenSubtitles for downloading missing-language subtitles. Both are free for personal use and need only an account.",
  setupIntroBullets: [
    "Why your own keys: a single shared key bundled in the app would get extracted from the binary in minutes, then rate-limited or revoked — breaking the app for everyone. Per-user keys keep MediaPorter working long-term.",
    "What if you skip them: the app still syncs your files. TMDb missing → generated fallback posters and minimal metadata. OpenSubtitles missing → only the subtitles already embedded in your files are used.",
    "Privacy: keys stay on your Mac. MediaPorter talks directly to TMDb and OpenSubtitles from your machine — nothing routes through us.",
  ],
  setupBuildsTag: "builds",
  setupBuildsTitle: "Choose the right download build.",
  setupBuildsBody:
    "MediaPorter is distributed in two macOS builds. The app behavior is the same; the difference is how ffmpeg is provided for files that need remuxing or audio conversion.",
  setupBuilds: [
    {
      title: "Bundled ffmpeg",
      body: "Includes ffmpeg inside the app bundle. This is the simplest option and does not require Homebrew or any command-line setup.",
    },
    {
      title: "System ffmpeg",
      body: "Smaller download. Install ffmpeg yourself, for example with `brew install ffmpeg`, or make any compatible ffmpeg binary available in your PATH.",
    },
  ],
  setupTmdbTag: "tmdb",
  setupTmdbTitle: "TMDb — posters & metadata",
  setupTmdbWhat:
    "Used during Analyze to identify movies, TV shows, and anime, then fetch posters and the full TV-app field set (seasons, episode numbers, sort titles). Without it, you get a generated fallback poster and the filename as the title.",
  setupTmdbSteps: [
    "Sign up at themoviedb.org — free, no credit card. A username and email is all it asks.",
    "Open your account → Settings → API.",
    "Click \"Request an API key\" → \"Developer.\" Use type: \"Personal,\" tick the terms.",
    "Copy the v3 auth API key (a long hex string).",
    "In MediaPorter: Settings (⌘,) → Metadata → paste the key → Save.",
  ],
  setupTmdbFree:
    "The free TMDb tier is essentially uncapped for personal use — there's no daily download limit you'll hit syncing a library, even a large one.",
  setupTmdbCta: "Get a TMDb API key →",
  setupOsTag: "opensubtitles",
  setupOsTitle: "OpenSubtitles — multi-language subtitles",
  setupOsWhat:
    "Used during Analyze to find and download subtitle tracks in the languages you've configured (e.g. en, ru) when they're not already embedded in your file. The downloaded SRTs are remuxed into the output so they appear in the TV app's subtitle switcher.",
  setupOsSteps: [
    "Sign up at opensubtitles.com — free, no credit card.",
    "Go to opensubtitles.com/consumers and click \"New consumer.\" Give it any name (e.g. \"MediaPorter on my Mac\"). Copy the API key.",
    "In MediaPorter: Settings (⌘,) → Subtitles → paste the API key, your account username, your password, and the languages you want (e.g. en,ru) → Save.",
  ],
  setupOsFree:
    "Registered free accounts get 20 subtitle downloads per day — fine for a movie night or a few episodes, tight for binge-syncing a 24-episode season in one go. OpenSubtitles VIP (~$10/year) raises the limit substantially and is the right call if you sync large libraries.",
  setupOsCta: "Get an OpenSubtitles API key →",
  setupApplyHeading: "After you've pasted both keys",
  setupApplyBody:
    "Re-run Analyze on any folder you've already dropped — MediaPorter will fill in posters and subtitles for files it skipped before. Existing items in the TV app aren't touched; the upgrade only applies to new or re-analyzed files.",
  footerProduct: "Product",
  footerHelp: "Help",
  footerFeatures: "Features",
  footerTagline: "# Media, ported. Deep on your devices.",
  footerRights: "© {year} MediaPorter. All rights reserved.",
};

const ru: Strings = {
  htmlTitle: "MediaPorter — синхронизация аниме, фильмов и сериалов в приложение TV на iPhone и iPad",
  metaDescription:
    "Нативное macOS-приложение: перекодирует и заливает видео, аниме и фильмы прямо во встроенное приложение TV на iPhone и iPad. Без iCloud, без iTunes, без сбора данных. Открытый код.",
  navChangelog: "Изменения",
  navSupport: "Поддержка",
  navPrivacy: "Приватность",
  navGuides: "Гайды",
  navSetup: "Установка",
  heroEyebrow: "## porter.md",
  heroTitleLead: "Медиа,",
  heroTitleAccent: "доставлено.",
  heroTitleMuted: "Глубоко на ваших устройствах.",
  heroLede:
    'Нативное macOS-приложение, которое перекодирует и заливает вашу видеоколлекцию прямо во встроенное приложение <strong>TV</strong> на iOS/iPadOS. Без iCloud, без браузерных загрузчиков, без «смотри на ноутбуке».',
  ctaDownload: "Скачать для macOS",
  ctaSource: "Исходный код",
  heroRequires: "# macOS 14+ · iOS / iPadOS 15+",
  heroOneLiner:
    "перетащить ~/Movies/Anime → \"iPad Pro\"  # → 24 эпизода, постеры, порядок, аудио-переключатель в норме",
  featuresHeading: "Сделано под то, как TV-приложение реально работает.",
  featuresLede:
    "Каждая фича появилась потому, что мы нашли конкретный способ, которым TV-приложение iPad ломается на произвольном видео. Полная история — в {changelog}.",
  features: [
    {
      tag: "transcode",
      title: "Умно, без фанатизма",
      body: "Перекодирует только то, что устройство не сыграет. HEVC остаётся HEVC. AAC и EAC3 идут как есть. AC3 → AAC, потому что TV-приложение iPad молча выкидывает AC3 из переключателя аудио.",
    },
    {
      tag: "metadata",
      title: "Постеры, сезоны, сортировка",
      body: "Тянет метаданные с TMDb, заполняет весь набор полей TV-приложения (sort titles, episode_sort_id, обложки через Airlock). Эпизоды группируются. Без бага с префиксом «0.».",
    },
    {
      tag: "anime",
      title: "Понимает аниме",
      body: "Определяет последовательные эпизоды, обрабатывает прожжённые номера серий, не дублирует то, что уже на устройстве. Работает с фансабом.",
    },
    {
      tag: "sync",
      title: "Пайплайн, а не 30 минут ожидания",
      body: "Файлы появляются в TV-приложении по мере заливки, а не после долгого «финализирую». Проверка свободного места на лету. Защита от случайного Cmd-Q.",
    },
    {
      tag: "native",
      title: "Нативный macOS",
      body: "Swift. Тёмная тема по умолчанию. Закрывается чисто. Сидит в доке, а не в меню-баре — если только сами не попросите.",
    },
    {
      tag: "private",
      title: "Никакой телеметрии",
      body: "Мы не собираем данные. Ни анонимно, ни «агрегированно», ни «для улучшения продукта». Приложение общается только с устройством и с TMDb (за постерами).",
    },
  ],
  howEyebrow: "## как",
  howHeading: "Один drop. Три фазы.",
  howLede:
    "MediaPorter смотрит на библиотеку, планирует, что делать, и показывает «чек» до того, как уйдёт первый байт. Контроль — у вас.",
  howSteps: [
    {
      n: "01",
      title: "Анализ",
      body: "Зондируем кодеки, аудиодорожки, субтитры. Сопоставляем заголовки с TMDb. Определяем номера серий аниме. Пропускаем уже залитое.",
    },
    {
      n: "02",
      title: "План",
      body: "По каждому файлу: оставить, ремуксить или перекодировать. Аудио: pass-through или конверсия. Проверка места. Запускаем только после вашего OK.",
    },
    {
      n: "03",
      title: "Порт",
      body: "Перекодирование в параллель. Загрузка по USB или Wi-Fi. Регистрация в TV-приложении по мере прибытия — без 30-минутной финальной паузы.",
    },
  ],
  animeCalloutEyebrow: "## гайды",
  animeCalloutTitle: "Как залить аниме на iPhone и iPad",
  animeCalloutBody:
    "По шагам: как доставить любой релиз аниме — одиночные серии, целые сезоны, фансаб — во встроенное приложение TV, с правильными номерами серий, постерами и субтитрами. Без джейлбрейка.",
  animeCalloutCtaIphone: "Читать гайд →",
  animeCalloutCtaIpad: "Читать гайд →",
  moreGuidesEyebrow: "## ещё гайды",
  moreGuidesHeading: "С чего начать",
  moreGuidesCtaSoon: "Скоро",
  moreGuides: [
    {
      tag: "anime",
      title: "Аниме на iPhone и iPad",
      body: "Перетащите папку с .mkv — отдельные серии, целые сезоны, фансаб — в MediaPorter. Каждая серия появляется в TV-приложении с правильным постером, сезоном и номером по мере загрузки. Две аудиодорожки сохраняются; AC-3 конвертируется в AAC, чтобы переключатель аудио на iPad действительно показывал все треки.",
      href: "/guides/anime-on-iphone-and-ipad",
    },
    {
      tag: "movies",
      title: "Фильмы без iTunes",
      body: "Бросьте папку с фильмами. MediaPorter зондирует каждый файл, ищет постер в TMDb, решает по файлу — ремуксить или перекодировать, показывает план до запуска. Фильмы попадают в Library → Movies.",
      href: "/#features",
      ctaSoon: true,
    },
    {
      tag: "tv",
      title: "Сериалы с правильным порядком серий",
      body: "S01E01 — S05E22 одним drop'ом. Sort title и episode_sort_id заполнены корректно, серии выстраиваются по сезонам, а не по алфавиту. Без префикса «0. Show Name» вверху списка.",
      href: "/#features",
      ctaSoon: true,
    },
    {
      tag: "audio",
      title: "Чиним пропавшие аудиодорожки на iPad",
      body: "Если у файла несколько аудиодорожек, а в переключателе на iPad видна только одна — виноват AC-3. MediaPorter конвертирует AC-3 в AAC и расставляет disposition так, чтобы все треки были доступны. Пошаговое объяснение.",
      href: "/#faq",
      ctaSoon: true,
    },
    {
      tag: "4k",
      title: "4K HEVC без перекодирования",
      body: "MediaPorter определяет HEVC и ремуксит без потери качества — без ожидания ffmpeg. Если нужен .m4v-контейнер и тег hvc1 для TV-приложения, он сделает это сам.",
      href: "/#features",
      ctaSoon: true,
    },
    {
      tag: "subs",
      title: "Субтитры, которые действительно показываются",
      body: "SRT, ASS/SSA, mov_text и PGS-сабы ремуксятся в выход, если TV-приложение их умеет. Где не умеет (тяжёлый ASS-стиль), MediaPorter откатывается на обычный текст вместо того, чтобы молча выкинуть дорожку.",
      href: "/#faq",
      ctaSoon: true,
    },
  ],
  faqEyebrow: "## faq",
  faqHeading: "Частые вопросы",
  faq: [
    {
      q: "Как залить аниме на iPhone или iPad?",
      a: "Поставьте MediaPorter на Mac, подключите iPhone или iPad (по кабелю или по Wi-Fi), перетащите папку с аниме в окно приложения и нажмите Sync. Серии появятся во встроенном TV-приложении: Library → TV Shows, с постерами и правильным порядком эпизодов. Поддерживаются .mkv, .mp4, .m4v, .avi, релизы с озвучкой и сабами.",
    },
    {
      q: "Работает ли это без iTunes и iCloud?",
      a: "Да. MediaPorter общается с устройством напрямую через Apple ATC-протокол. В iCloud ничего не уезжает. iTunes / Apple Music не задействованы.",
    },
    {
      q: "А фильмы и сериалы тоже можно?",
      a: "Да. MediaPorter сам различает фильмы, сериалы и аниме. Фильмы попадают в Library → Movies; сериалы и аниме — в TV Shows с сезонами и нумерацией серий.",
    },
    {
      q: "Перекодирует ли он всю библиотеку?",
      a: "Только то, что устройство не сможет сыграть. HEVC остаётся как есть. AAC и E-AC-3 проходят без изменений. AC-3 (Dolby Digital) конвертируется в AAC, потому что TV-приложение iPad скрывает AC-3 в переключателе аудио.",
    },
    {
      q: "Поддерживает ли он .mkv?",
      a: "Да. MKV с H.264, HEVC, AAC, AC-3, E-AC-3 и DTS обрабатываются. Видео ремуксится без перекодирования там, где это возможно; аудио меняется только если иначе TV-приложение не сыграет.",
    },
    {
      q: "А субтитры?",
      a: "Софт-сабы (SRT, ASS/SSA, mov_text, PGS) ремуксятся в итоговый файл, если TV-приложение умеет их рисовать. Прожжённые субтитры остаются в картинке.",
    },
    {
      q: "Нужен ли джейлбрейк?",
      a: "Нет. MediaPorter работает на стоковом устройстве через публичные протоколы Apple. macOS 14+, iOS / iPadOS 15+.",
    },
    {
      q: "Собирает ли MediaPorter телеметрию?",
      a: "В приложении нет ни аналитики, ни крэш-репортов, ни статистики использования. macOS-приложение общается только с устройством и с TMDb (за постерами).",
    },
    {
      q: "Нужны ли API-ключи?",
      a: "MediaPorter использует два бесплатных сторонних сервиса — TMDb для постеров и метаданных и OpenSubtitles для загрузки субтитров на нужных языках. Оба требуют ваш собственный бесплатный аккаунт (5 минут, без банковской карты). Зашить общий ключ в приложение не вариант: его за пару дней выковыряют из бинарника и упрутся в rate limit — сломается у всех. На странице Установка есть пошаговая инструкция. Без ключей приложение тоже работает — просто будет фоллбэк-постер и только субтитры, уже встроенные в файл.",
    },
  ],
  downloadEyebrow: "## скачать",
  downloadTitle: "Получить MediaPorter.",
  downloadBody:
    "Приложение macOS в закрытой бете, ждём одобрения Apple Developer Program. Оставьте email — пришлём подписанный билд, как только пройдём нотаризацию.",
  downloadCta: "Сообщить мне",
  downloadEmailPlaceholder: "you@example.com",
  downloadNote: "# Никаких пикселей. Форма открывает обычный mailto: в вашем почтовом клиенте.",
  setupCalloutEyebrow: "## установка",
  setupCalloutTitle: "Понадобятся два бесплатных API-ключа.",
  setupCalloutBody:
    "В приложение не зашиты общие ключи — их за пару дней выковыряют из бинарника, упрутся в rate limit, и сломается у всех. Вместо этого вы получаете свои ключи: TMDb (постеры и метаданные) и OpenSubtitles (субтитры). Пять минут, без банковской карты.",
  setupCalloutCta: "Открыть инструкцию →",
  setupPageTitle: "Установка — API-ключи для MediaPorter",
  setupPageDescription:
    "Как получить бесплатные API-ключи TMDb и OpenSubtitles, которыми MediaPorter пользуется для постеров, метаданных и субтитров.",
  setupHeading: "Два бесплатных ключа за пять минут.",
  setupLede:
    "MediaPorter обогащает библиотеку через два сторонних сервиса: TMDb даёт постеры и метаданные сериалов и фильмов, OpenSubtitles — субтитры на тех языках, которых ещё нет в файле. Оба бесплатны для личного использования и требуют только аккаунта.",
  setupIntroBullets: [
    "Почему свои ключи: общий ключ, зашитый в приложение, за пару дней выковыривают из бинарника, после чего его блокируют по rate limit — и сервис ломается у всех. Личные ключи у каждого пользователя — единственный способ, чтобы MediaPorter работал долго.",
    "Если пропустить: приложение всё равно зальёт файлы на устройство. Без TMDb — будет сгенерированный фоллбэк-постер и минимум метаданных. Без OpenSubtitles — только субтитры, уже встроенные в файл.",
    "Приватность: ключи хранятся у вас на Mac. MediaPorter ходит в TMDb и OpenSubtitles напрямую с вашей машины — ничего не идёт через нас.",
  ],
  setupBuildsTag: "билды",
  setupBuildsTitle: "Выберите подходящую сборку.",
  setupBuildsBody:
    "MediaPorter распространяется в двух macOS-сборках. Поведение приложения одинаковое; отличается только то, откуда берётся ffmpeg для ремультиплексирования и конвертации аудио.",
  setupBuilds: [
    {
      title: "ffmpeg внутри приложения",
      body: "ffmpeg уже лежит в .app. Это самый простой вариант: Homebrew и настройка командной строки не нужны.",
    },
    {
      title: "Системный ffmpeg",
      body: "Скачивание меньше. Установите ffmpeg сами, например через `brew install ffmpeg`, или положите совместимый бинарник ffmpeg в PATH.",
    },
  ],
  setupTmdbTag: "tmdb",
  setupTmdbTitle: "TMDb — постеры и метаданные",
  setupTmdbWhat:
    "Используется на этапе Анализа, чтобы распознать фильмы, сериалы и аниме, подтянуть постеры и весь набор полей TV-приложения (сезоны, номера серий, сортировочные заголовки). Без ключа — сгенерированный фоллбэк-постер и имя файла как заголовок.",
  setupTmdbSteps: [
    "Зарегистрируйтесь на themoviedb.org — бесплатно, без банковской карты. Нужны логин и email.",
    "Откройте свой аккаунт → Settings → API.",
    "Нажмите «Request an API key» → «Developer». Тип: «Personal», примите условия.",
    "Скопируйте «API Key (v3 auth)» — длинная шестнадцатеричная строка.",
    "В MediaPorter: Settings (⌘,) → Metadata → вставьте ключ → Save.",
  ],
  setupTmdbFree:
    "Бесплатного тарифа TMDb для личного использования по сути хватает без ограничений — дневной лимит, в который можно упереться при синхронизации даже большой библиотеки, отсутствует.",
  setupTmdbCta: "Получить ключ TMDb →",
  setupOsTag: "opensubtitles",
  setupOsTitle: "OpenSubtitles — субтитры на нужных языках",
  setupOsWhat:
    "Используется на этапе Анализа, чтобы найти и скачать субтитры на настроенных языках (например, en, ru), если их ещё нет в файле. Скачанные SRT ремуксятся в итоговый файл и появляются в переключателе субтитров TV-приложения.",
  setupOsSteps: [
    "Зарегистрируйтесь на opensubtitles.com — бесплатно, без банковской карты.",
    "Зайдите на opensubtitles.com/consumers, нажмите «New consumer». Имя — любое (например, «MediaPorter on my Mac»). Скопируйте API-ключ.",
    "В MediaPorter: Settings (⌘,) → Subtitles → вставьте API-ключ, логин и пароль от opensubtitles.com и нужные языки (например, en,ru) → Save.",
  ],
  setupOsFree:
    "Зарегистрированный бесплатный аккаунт даёт 20 загрузок субтитров в сутки — нормально для фильма или нескольких серий, но впритык, если за раз заливать сезон из 24 эпизодов. Подписка OpenSubtitles VIP (~$10/год) поднимает лимит и оправдана, если у вас большая библиотека.",
  setupOsCta: "Получить ключ OpenSubtitles →",
  setupApplyHeading: "Когда оба ключа вставлены",
  setupApplyBody:
    "Запустите Анализ заново на уже добавленных папках — MediaPorter догрузит постеры и субтитры для файлов, которые пропустил раньше. То, что уже в TV-приложении, не трогается; обогащение применяется к новым и переанализированным файлам.",
  footerProduct: "Продукт",
  footerHelp: "Помощь",
  footerFeatures: "Возможности",
  footerTagline: "# Media, ported. Deep on your devices.",
  footerRights: "© {year} MediaPorter. Все права защищены.",
};

const zh: Strings = {
  htmlTitle: "MediaPorter — 把动漫、电影、剧集同步到 iPhone 和 iPad 的 TV 应用",
  metaDescription:
    "原生 macOS 应用：自动转码并把视频、动漫、电影直接同步到 iPhone 与 iPad 的内置 TV 应用。无需 iCloud，无需 iTunes，不收集任何数据。开源。",
  navChangelog: "更新日志",
  navSupport: "支持",
  navPrivacy: "隐私",
  navGuides: "教程",
  navSetup: "设置",
  heroEyebrow: "## porter.md",
  heroTitleLead: "媒体,",
  heroTitleAccent: "已就位.",
  heroTitleMuted: "深植于你的设备。",
  heroLede:
    "一款原生 macOS 应用，把你的视频库自动转码并直接同步到 iOS / iPadOS 的内置 <strong>TV 应用</strong>。不绕 iCloud，不用网页上传器，不再「只能在笔记本上看」。",
  ctaDownload: "下载 macOS 版",
  ctaSource: "查看源码",
  heroRequires: "# 需 macOS 14+ · iOS / iPadOS 15+",
  heroOneLiner:
    "拖拽 ~/Movies/Anime → \"iPad Pro\"  # → 24 集、海报、排序、音轨切换器全部就绪",
  featuresHeading: "围绕 TV 应用的真实行为打造。",
  featuresLede:
    "这里的每一个功能，都是因为我们发现 iPad 的 TV 应用在喂任意视频时会以某种特定方式翻车。完整记录见 {changelog}。",
  features: [
    {
      tag: "transcode",
      title: "聪明，不死板",
      body: "只转码设备播不了的部分。HEVC 保持 HEVC。AAC 与 EAC3 直通。AC3 → AAC，因为 iPad 的 TV 应用会悄悄把 AC3 从音轨切换器里删掉。",
    },
    {
      tag: "metadata",
      title: "海报、季、排序标题",
      body: "从 TMDb 拉取元数据，写满 TV 应用所需的全部字段（sort titles、episode_sort_id、Airlock 海报）。剧集正确分组，没有「0.」前缀 bug。",
    },
    {
      tag: "anime",
      title: "懂动漫",
      body: "识别连续集数，处理画面里烧入的集数，按设备已有内容去重。兼容粉丝字幕组的发布。",
    },
    {
      tag: "sync",
      title: "流水线同步，不再苦等 30 分钟",
      body: "文件上传完成的那一刻就出现在 TV 应用里——而不是在长长的「最后处理」之后。同步过程中实时检测磁盘空间。同步时拦截误关。",
    },
    {
      tag: "native",
      title: "原生 macOS",
      body: "Swift 打造。默认深色。正常退出。停在 Dock 里，不去抢菜单栏——除非你要求。",
    },
    {
      tag: "private",
      title: "零遥测",
      body: "不收集数据。不匿名、不汇总、不「为了改进产品」。应用只与你的设备和 TMDb（取海报用）通信。",
    },
  ],
  howEyebrow: "## 流程",
  howHeading: "一次拖拽，三个阶段。",
  howLede: "MediaPorter 观察你的库，规划要做的事，在第一字节流出前展示「清单」。控制权在你。",
  howSteps: [
    {
      n: "01",
      title: "分析",
      body: "探测编码、音轨、字幕。把片名匹配到 TMDb。识别动漫集数。跳过设备上已有的文件。",
    },
    {
      n: "02",
      title: "规划",
      body: "逐文件：保留、重封装或转码。音频：直通或转换。磁盘空间检查。你确认后才会开始。",
    },
    {
      n: "03",
      title: "投递",
      body: "并行转码。通过 USB 或 Wi-Fi 上传。每个文件到位时就注册到 TV 应用——不再等 30 分钟。",
    },
  ],
  animeCalloutEyebrow: "## 教程",
  animeCalloutTitle: "如何把动漫导入 iPhone 和 iPad",
  animeCalloutBody:
    "一步步教你：把任何动漫资源——单集、整季、字幕组发布——导入内置 TV 应用，集数、海报、字幕全部正确。无需越狱。",
  animeCalloutCtaIphone: "阅读教程 →",
  animeCalloutCtaIpad: "阅读教程 →",
  moreGuidesEyebrow: "## 更多教程",
  moreGuidesHeading: "从这里开始",
  moreGuidesCtaSoon: "即将上线",
  moreGuides: [
    {
      tag: "anime",
      title: "把动漫导入 iPhone 和 iPad",
      body: "把 .mkv 文件夹拖进 MediaPorter——单集、整季、字幕组发布。文件上传完成的瞬间，每一集都以正确的海报、季和集数出现在 TV 应用里。双音轨保留；AC-3 转成 AAC，iPad 的音轨切换器才能真正显示所有轨道。",
      href: "/guides/anime-on-iphone-and-ipad",
    },
    {
      tag: "movies",
      title: "无 iTunes 也能同步电影",
      body: "拖入电影文件夹。MediaPorter 探测每个文件，从 TMDb 取海报，逐文件决定重封装或重新编码，并在执行前展示完整计划。电影进入 Library → Movies。",
      href: "/#features",
      ctaSoon: true,
    },
    {
      tag: "tv",
      title: "剧集按正确顺序排列",
      body: "S01E01—S05E22 一次拖入。sort title 与 episode_sort_id 写入正确，剧集按季排序而不是按字母排序。没有「0. Show Name」漂浮在列表顶端。",
      href: "/#features",
      ctaSoon: true,
    },
    {
      tag: "audio",
      title: "修复 iPad 上消失的音轨",
      body: "如果文件有多条音轨，但 iPad 音轨切换器只显示一条，问题就是 AC-3。MediaPorter 把 AC-3 转成 AAC 并设置正确的 disposition，让每条轨道都可选。手把手讲清楚。",
      href: "/#faq",
      ctaSoon: true,
    },
    {
      tag: "4k",
      title: "4K HEVC 无需重新编码",
      body: "MediaPorter 识别 HEVC 后原地重封装——无质量损失，不用等 ffmpeg。TV 应用需要的 .m4v 容器与 hvc1 标记会自动处理。",
      href: "/#features",
      ctaSoon: true,
    },
    {
      tag: "subs",
      title: "真正能显示出来的字幕",
      body: "SRT、ASS/SSA、mov_text、PGS 软字幕在 TV 应用能渲染的范围内被重封装到输出文件。无法渲染时（重样式 ASS），MediaPorter 优雅降级为纯文本，而不是默默丢掉这条轨道。",
      href: "/#faq",
      ctaSoon: true,
    },
  ],
  faqEyebrow: "## faq",
  faqHeading: "常见问题",
  faq: [
    {
      q: "怎么把动漫导入 iPhone 或 iPad？",
      a: "在 Mac 上安装 MediaPorter，连接 iPhone 或 iPad（USB 或 Wi-Fi 配对），把动漫文件夹拖入应用，点击同步。剧集会出现在内置 TV 应用的 Library → TV Shows 下，带海报与正确集数。支持 .mkv、.mp4、.m4v、.avi，含字幕或配音版本均可。",
    },
    {
      q: "不用 iTunes 和 iCloud 也能用吗？",
      a: "可以。MediaPorter 通过 Apple 的设备同步协议（ATC）直接与设备通信。文件不会上传到 iCloud，也不依赖 iTunes / Apple Music。",
    },
    {
      q: "电影和剧集也能同步吗？",
      a: "可以。MediaPorter 会自动区分电影、剧集与动漫。电影进 Library → Movies；剧集和动漫进 TV Shows，按季和集数排好。",
    },
    {
      q: "它会把我整个库都转码一遍吗？",
      a: "只转码设备无法直接播放的部分。HEVC 视频原样保留。AAC 与 E-AC-3 音频直通。AC-3（杜比数字）会被转成 AAC，因为 iPad 的 TV 应用会把 AC-3 从音轨切换器里隐藏掉。",
    },
    {
      q: "支持 .mkv 吗？",
      a: "支持。包含 H.264、HEVC、AAC、AC-3、E-AC-3 或 DTS 的 MKV 都能处理。视频尽量重封装而不重新编码，音频只在必要时才转换。",
    },
    {
      q: "字幕能带过去吗？",
      a: "软字幕（SRT、ASS/SSA、mov_text、PGS）会被重封装到输出文件中，前提是 TV 应用能渲染。硬字幕本就在画面里。",
    },
    {
      q: "需要越狱吗？",
      a: "不需要。MediaPorter 在原版系统上通过 Apple 公开的同步协议工作。要求 macOS 14+，iOS / iPadOS 15+。",
    },
    {
      q: "MediaPorter 会收集遥测吗？",
      a: "应用内没有分析、没有崩溃信标、没有使用统计。macOS 应用只与你的设备和 TMDb（取海报）通信。",
    },
    {
      q: "需要 API 密钥吗？",
      a: "MediaPorter 使用两个免费的第三方服务 —— TMDb 用于海报与元数据，OpenSubtitles 用于下载缺失语言的字幕。两者都需要你自己的免费账号（5 分钟，无需信用卡）。把共享密钥打包进应用并不可行：很快会被从二进制中提取，进而触发限流。具体步骤见「设置」页面。不填密钥也能工作 —— 只是会得到回退海报，且仅使用文件中已内嵌的字幕。",
    },
  ],
  downloadEyebrow: "## 下载",
  downloadTitle: "获取 MediaPorter。",
  downloadBody:
    "macOS 应用正在私测，正在等待 Apple Developer Program 审核。留下邮箱，公证一通过我们就发送签名版本。",
  downloadCta: "通知我",
  downloadEmailPlaceholder: "you@example.com",
  downloadNote: "# 没有跟踪像素。表单只是普通的 mailto:，会打开你的邮件客户端。",
  setupCalloutEyebrow: "## 设置",
  setupCalloutTitle: "需要两个免费的 API 密钥。",
  setupCalloutBody:
    "MediaPorter 不内置共享密钥 —— 那样几天内就会被从二进制中提取并触发限流，所有人都会受影响。你需要自己申请：TMDb（海报与元数据）和 OpenSubtitles（字幕）。五分钟，无需信用卡。",
  setupCalloutCta: "查看设置指南 →",
  setupPageTitle: "设置 — MediaPorter 的 API 密钥",
  setupPageDescription:
    "如何申请 MediaPorter 用于海报、元数据和字幕的免费 TMDb 与 OpenSubtitles API 密钥。",
  setupHeading: "两个免费密钥，五分钟搞定。",
  setupLede:
    "MediaPorter 通过两个第三方服务来丰富你的媒体库：TMDb 提供海报与剧集/电影元数据，OpenSubtitles 提供文件中尚未内嵌的语言字幕。两者都对个人用途免费，只需注册账号。",
  setupIntroBullets: [
    "为什么用自己的密钥：把共享密钥打包进应用，几天内就会被从二进制中提取，紧接着触发限流或被吊销 —— 所有人都用不了。每个用户用自己的密钥，MediaPorter 才能长期可用。",
    "如果跳过：应用仍可同步文件。没有 TMDb —— 使用回退海报和最少元数据。没有 OpenSubtitles —— 只用文件中已内嵌的字幕。",
    "隐私：密钥保存在你的 Mac 上。MediaPorter 直接从你的电脑访问 TMDb 与 OpenSubtitles，不经过我们的服务器。",
  ],
  setupBuildsTag: "构建",
  setupBuildsTitle: "选择合适的下载版本。",
  setupBuildsBody:
    "MediaPorter 提供两个 macOS 构建。应用行为相同；区别只在于需要重封装或音频转换时 ffmpeg 从哪里来。",
  setupBuilds: [
    {
      title: "内置 ffmpeg",
      body: "ffmpeg 已包含在 app 包内。这是最简单的选择，不需要 Homebrew，也不需要命令行设置。",
    },
    {
      title: "系统 ffmpeg",
      body: "下载体积更小。请自行安装 ffmpeg，例如 `brew install ffmpeg`，或让任何兼容的 ffmpeg 二进制出现在 PATH 中。",
    },
  ],
  setupTmdbTag: "tmdb",
  setupTmdbTitle: "TMDb —— 海报与元数据",
  setupTmdbWhat:
    "在「分析」阶段用于识别电影、电视剧和动漫，并获取海报以及 TV 应用所需的完整字段集（季、集号、排序标题）。没有它 —— 只能得到生成的回退海报，标题就是文件名。",
  setupTmdbSteps: [
    "在 themoviedb.org 注册 —— 免费，无需信用卡。只需要用户名和邮箱。",
    "打开账号 → Settings → API。",
    "点击「Request an API key」→「Developer」。类型选「Personal」，勾选条款。",
    "复制「API Key (v3 auth)」—— 一串很长的十六进制字符。",
    "在 MediaPorter 中：Settings (⌘,) → Metadata → 粘贴密钥 → Save。",
  ],
  setupTmdbFree:
    "TMDb 免费档对个人用途几乎没有上限 —— 即使同步一个很大的库，也碰不到每日下载限制。",
  setupTmdbCta: "申请 TMDb API 密钥 →",
  setupOsTag: "opensubtitles",
  setupOsTitle: "OpenSubtitles —— 多语言字幕",
  setupOsWhat:
    "在「分析」阶段用于查找并下载你配置语言（例如 en, ru）的字幕，前提是文件中尚未内嵌。下载的 SRT 会被重新封装到输出文件中，从而在 TV 应用的字幕开关中出现。",
  setupOsSteps: [
    "在 opensubtitles.com 注册 —— 免费，无需信用卡。",
    "前往 opensubtitles.com/consumers 并点击「New consumer」。名字随便填（例如「MediaPorter on my Mac」）。复制 API 密钥。",
    "在 MediaPorter 中：Settings (⌘,) → Subtitles → 粘贴 API 密钥、opensubtitles.com 账号用户名、密码以及目标语言（例如 en,ru）→ Save。",
  ],
  setupOsFree:
    "已注册的免费账号每天可下载 20 个字幕 —— 看一部电影或几集很够用，但一次同步 24 集动漫一季就有点吃紧。OpenSubtitles VIP（约每年 $10）会显著提高上限，适合同步大型库。",
  setupOsCta: "申请 OpenSubtitles API 密钥 →",
  setupApplyHeading: "粘贴两个密钥后",
  setupApplyBody:
    "对已经拖进来的文件夹重新运行「分析」—— MediaPorter 会为之前跳过的文件补全海报与字幕。已在 TV 应用中的项目不会被改动；丰富只应用于新文件或重新分析的文件。",
  footerProduct: "产品",
  footerHelp: "帮助",
  footerFeatures: "功能",
  footerTagline: "# Media, ported. Deep on your devices.",
  footerRights: "© {year} MediaPorter. 保留所有权利。",
};

const ko: Strings = {
  htmlTitle: "MediaPorter — 애니메이션·영화·드라마를 iPhone과 iPad의 TV 앱으로 동기화",
  metaDescription:
    "네이티브 macOS 앱이 영상·애니메이션·영화를 iPhone과 iPad의 내장 TV 앱으로 자동 트랜스코드해 바로 옮깁니다. iCloud·iTunes·데이터 수집 없음. 오픈 소스.",
  navChangelog: "체인지로그",
  navSupport: "지원",
  navPrivacy: "개인정보",
  navGuides: "가이드",
  navSetup: "설정",
  heroEyebrow: "## porter.md",
  heroTitleLead: "미디어,",
  heroTitleAccent: "옮겨졌습니다.",
  heroTitleMuted: "기기 안 깊숙이.",
  heroLede:
    "비디오 라이브러리를 iOS / iPadOS의 내장 <strong>TV 앱</strong>으로 곧장 트랜스코드·동기화하는 네이티브 macOS 앱입니다. iCloud 우회 없음, 브라우저 업로더 없음, “노트북에서 봐야 하는” 불편 없음.",
  ctaDownload: "macOS용 다운로드",
  ctaSource: "소스 보기",
  heroRequires: "# macOS 14+ · iOS / iPadOS 15+ 필요",
  heroOneLiner:
    "끌어다 놓기 ~/Movies/Anime → \"iPad Pro\"  # → 24개 에피소드, 포스터, 정렬, 오디오 스위처까지 정상",
  featuresHeading: "TV 앱이 실제로 동작하는 방식에 맞춰 만들었습니다.",
  featuresLede:
    "이 페이지의 모든 기능은 iPad TV 앱이 임의의 비디오에서 정확히 어떻게 깨지는지 발견한 결과입니다. 전체 흐름은 {changelog} 참고.",
  features: [
    {
      tag: "transcode",
      title: "똑똑하게, 고집 없이",
      body: "기기가 재생 못 하는 부분만 다시 인코딩합니다. HEVC는 그대로. AAC·EAC3는 통과. AC3는 AAC로 — iPad TV 앱이 AC3 트랙을 오디오 스위처에서 조용히 숨기기 때문.",
    },
    {
      tag: "metadata",
      title: "포스터·시즌·정렬 타이틀",
      body: "TMDb에서 메타데이터를 가져와 TV 앱이 요구하는 필드 세트(sort titles, episode_sort_id, Airlock 아트워크)를 모두 채웁니다. 에피소드가 올바르게 묶이고 “0.” 접두사 버그 없음.",
    },
    {
      tag: "anime",
      title: "애니메이션 인식",
      body: "연속된 에피소드 번호를 감지하고, 화면에 박힌 번호도 처리하고, 기기에 이미 있는 파일은 중복 업로드하지 않습니다. 팬섭 릴리스에도 동작.",
    },
    {
      tag: "sync",
      title: "파이프라인 동기화, 30분 대기 없이",
      body: "파일이 업로드를 마치는 즉시 TV 앱에 등장합니다 — 길고 긴 “마무리 중” 화면 뒤가 아니라. 동기화 중 디스크 공간을 계속 확인. 동기화 중 Cmd-Q 방지.",
    },
    {
      tag: "native",
      title: "네이티브 macOS",
      body: "Swift로 작성. 기본 다크 모드. 깔끔하게 종료. 요청하지 않는 한 메뉴바가 아니라 Dock에 머뭅니다.",
    },
    {
      tag: "private",
      title: "텔레메트리 없음",
      body: "데이터를 수집하지 않습니다. 익명도, 집계도, “제품 개선용”도 없음. 앱은 기기와 TMDb(포스터용)만 통신합니다.",
    },
  ],
  howEyebrow: "## 절차",
  howHeading: "한 번 드롭. 세 단계.",
  howLede:
    "MediaPorter가 라이브러리를 살피고, 무엇을 할지 계획하고, 단 한 바이트가 움직이기 전에 영수증을 보여 줍니다. 결정권은 사용자.",
  howSteps: [
    {
      n: "01",
      title: "분석",
      body: "코덱·오디오 트랙·자막을 조사. 제목을 TMDb와 매칭. 애니메이션 에피소드 번호 감지. 기기에 이미 있는 파일은 스킵.",
    },
    {
      n: "02",
      title: "계획",
      body: "파일별로 그대로 둘지, 리먹스할지, 트랜스코드할지 결정. 오디오는 통과 또는 변환. 디스크 공간 확인. 사용자의 OK 후에만 진행.",
    },
    {
      n: "03",
      title: "전송",
      body: "병렬 트랜스코드. USB 또는 Wi-Fi로 업로드. 파일이 도착하는 즉시 TV 앱에 등록 — 마지막 30분 대기 없음.",
    },
  ],
  animeCalloutEyebrow: "## 가이드",
  animeCalloutTitle: "애니메이션을 iPhone과 iPad에 옮기는 법",
  animeCalloutBody:
    "단계별로 설명합니다. 단일 에피소드든, 시즌 전체든, 팬섭 릴리스든 — 내장 TV 앱에 정확한 에피소드 번호·포스터·자막과 함께 옮기는 법. 탈옥 필요 없음.",
  animeCalloutCtaIphone: "가이드 읽기 →",
  animeCalloutCtaIpad: "가이드 읽기 →",
  moreGuidesEyebrow: "## 더 많은 가이드",
  moreGuidesHeading: "어디서 시작할까",
  moreGuidesCtaSoon: "곧 공개",
  moreGuides: [
    {
      tag: "anime",
      title: "iPhone과 iPad에 애니메이션 옮기기",
      body: ".mkv 폴더를 MediaPorter에 드래그하세요 — 단일 에피소드든, 시즌 전체든, 팬섭이든. 업로드가 끝나는 순간 에피소드마다 올바른 포스터·시즌·번호로 TV 앱에 나타납니다. 듀얼 오디오는 유지되고, AC-3는 AAC로 변환해 iPad의 오디오 스위처가 실제로 모든 트랙을 보여 주도록 합니다.",
      href: "/guides/anime-on-iphone-and-ipad",
    },
    {
      tag: "movies",
      title: "iTunes 없이 영화 동기화",
      body: "영화 폴더를 드롭하세요. MediaPorter가 각 파일을 조사하고, TMDb 포스터를 찾고, 파일별로 리먹스할지 재인코딩할지 결정해 실행 전 플랜을 보여 줍니다. 영화는 라이브러리 → 영화로 들어갑니다.",
      href: "/#features",
      ctaSoon: true,
    },
    {
      tag: "tv",
      title: "올바른 순서로 정리되는 드라마",
      body: "S01E01부터 S05E22까지 한 번에 드롭. sort title과 episode_sort_id가 정확히 채워져 알파벳 순이 아니라 시즌·에피소드 순으로 정렬됩니다. 「0. Show Name」이 목록 상단을 떠도는 일도 없습니다.",
      href: "/#features",
      ctaSoon: true,
    },
    {
      tag: "audio",
      title: "iPad에서 사라진 오디오 트랙 고치기",
      body: "파일에 오디오 트랙이 여러 개인데 iPad 스위처에 하나만 보인다면 AC-3가 원인입니다. MediaPorter는 AC-3를 AAC로 변환하고 disposition을 올바르게 설정해 모든 트랙을 선택할 수 있게 만듭니다. 단계별로 안내합니다.",
      href: "/#faq",
      ctaSoon: true,
    },
    {
      tag: "4k",
      title: "재인코딩 없는 4K HEVC",
      body: "MediaPorter는 HEVC를 감지해 그대로 리먹스합니다 — 품질 손실 없음, ffmpeg 대기도 없음. TV 앱이 요구하는 .m4v 컨테이너와 hvc1 태그도 자동으로 처리합니다.",
      href: "/#features",
      ctaSoon: true,
    },
    {
      tag: "subs",
      title: "실제로 표시되는 자막",
      body: "SRT, ASS/SSA, mov_text, PGS 소프트 자막은 TV 앱이 렌더 가능한 범위에서 출력 파일에 리먹스됩니다. 렌더가 불가능한 경우(무거운 ASS 스타일) MediaPorter는 트랙을 조용히 버리지 않고 일반 텍스트로 우아하게 폴백합니다.",
      href: "/#faq",
      ctaSoon: true,
    },
  ],
  faqEyebrow: "## faq",
  faqHeading: "자주 묻는 질문",
  faq: [
    {
      q: "애니메이션을 iPhone이나 iPad에 어떻게 옮기나요?",
      a: "Mac에 MediaPorter를 설치하고, iPhone 또는 iPad를 USB로 연결하거나 Wi-Fi로 페어링한 뒤, 애니메이션 폴더를 앱에 드래그하고 동기화를 누릅니다. 에피소드가 내장 TV 앱의 라이브러리 → TV 프로그램에 포스터·정렬과 함께 나타납니다. .mkv, .mp4, .m4v, .avi, 자막·더빙 모두 지원합니다.",
    },
    {
      q: "iTunes나 iCloud 없이도 동작하나요?",
      a: "네. MediaPorter는 Apple의 디바이스 동기화 프로토콜(ATC)로 기기와 직접 통신합니다. 파일은 iCloud로 올라가지 않고, iTunes / Apple Music도 필요 없습니다.",
    },
    {
      q: "영화와 드라마도 동기화되나요?",
      a: "네. 영화·드라마·애니메이션을 자동으로 구분합니다. 영화는 라이브러리 → 영화로, 드라마와 애니메이션은 TV 프로그램으로 시즌과 에피소드 순서까지 정리되어 들어갑니다.",
    },
    {
      q: "라이브러리 전체를 트랜스코드하나요?",
      a: "기기가 재생할 수 없는 것만 변환합니다. HEVC 영상은 그대로. AAC와 E-AC-3 오디오는 통과. AC-3(돌비 디지털)는 AAC로 변환합니다 — iPad TV 앱이 AC-3 트랙을 오디오 스위처에서 숨기기 때문.",
    },
    {
      q: ".mkv도 지원하나요?",
      a: "네. H.264, HEVC, AAC, AC-3, E-AC-3, DTS가 들어 있는 MKV를 처리합니다. 가능하면 영상은 재인코딩 없이 리먹스하고, 오디오는 TV 앱이 재생 못 할 때만 변환합니다.",
    },
    {
      q: "자막은 같이 넘어가나요?",
      a: "소프트 자막(SRT, ASS/SSA, mov_text, PGS)은 TV 앱이 렌더 가능한 경우 출력 파일에 리먹스됩니다. 하드섭은 영상에 그대로 남습니다.",
    },
    {
      q: "탈옥이 필요하나요?",
      a: "아니요. MediaPorter는 정품 상태에서 Apple의 공개 동기화 프로토콜로 동작합니다. macOS 14+, iOS / iPadOS 15+.",
    },
    {
      q: "MediaPorter가 텔레메트리를 수집하나요?",
      a: "앱 내부에는 분석, 크래시 비콘, 사용 통계가 모두 없습니다. macOS 앱은 사용자의 기기와 TMDb(포스터용)와만 통신합니다.",
    },
    {
      q: "API 키가 필요한가요?",
      a: "MediaPorter는 두 가지 무료 외부 서비스를 사용합니다 — TMDb(포스터·메타데이터), OpenSubtitles(누락 언어 자막 다운로드). 둘 다 본인의 무료 계정이 필요합니다(5분, 신용카드 불필요). 공용 키를 앱에 내장하는 방식은 며칠 안에 바이너리에서 추출돼 속도 제한에 걸리므로 불가능합니다. 단계별 안내는 「설정」 페이지에 있습니다. 키 없이도 동작은 합니다 — 폴백 포스터와 파일에 이미 포함된 자막만 사용하게 됩니다.",
    },
  ],
  downloadEyebrow: "## 다운로드",
  downloadTitle: "MediaPorter 받기.",
  downloadBody:
    "macOS 앱은 Apple Developer Program 승인 대기 중이라 비공개 베타 단계입니다. 이메일을 남겨 주시면, 공증이 끝나는 날 서명된 빌드를 보내 드립니다.",
  downloadCta: "알려 주세요",
  downloadEmailPlaceholder: "you@example.com",
  downloadNote: "# 트래킹 픽셀 없음. 폼은 그냥 mailto: 링크 — 메일 클라이언트가 열립니다.",
  setupCalloutEyebrow: "## 설정",
  setupCalloutTitle: "무료 API 키 두 개가 필요합니다.",
  setupCalloutBody:
    "MediaPorter는 공용 API 키를 내장하지 않습니다 — 며칠 안에 바이너리에서 추출돼 속도 제한이 걸리고, 모두에게 영향이 갑니다. 대신 본인 키를 발급받으세요: TMDb(포스터·메타데이터)와 OpenSubtitles(자막). 5분, 신용카드 불필요.",
  setupCalloutCta: "설정 가이드 열기 →",
  setupPageTitle: "설정 — MediaPorter용 API 키",
  setupPageDescription:
    "MediaPorter가 포스터, 메타데이터, 자막에 사용하는 무료 TMDb 및 OpenSubtitles API 키를 발급받는 방법.",
  setupHeading: "무료 키 두 개, 5분이면 끝.",
  setupLede:
    "MediaPorter는 라이브러리를 풍부하게 하기 위해 두 가지 외부 서비스를 사용합니다: TMDb는 포스터와 작품 메타데이터, OpenSubtitles는 파일에 아직 포함되지 않은 언어의 자막을 제공합니다. 둘 다 개인 사용은 무료이며 계정만 있으면 됩니다.",
  setupIntroBullets: [
    "왜 본인 키가 필요한가: 공용 키를 앱에 내장하면 며칠 안에 바이너리에서 추출되고, 곧 속도 제한이나 차단으로 이어져 모두가 사용할 수 없게 됩니다. 사용자별 키만이 MediaPorter를 장기적으로 동작하게 하는 방법입니다.",
    "키 없이 사용한다면: 파일 동기화는 여전히 됩니다. TMDb 없음 — 생성된 폴백 포스터와 최소한의 메타데이터. OpenSubtitles 없음 — 파일에 이미 포함된 자막만 사용.",
    "개인정보: 키는 Mac에 보관됩니다. MediaPorter는 사용자 컴퓨터에서 직접 TMDb와 OpenSubtitles에 접속합니다 — 저희 서버를 거치지 않습니다.",
  ],
  setupBuildsTag: "빌드",
  setupBuildsTitle: "맞는 다운로드 빌드를 선택하세요.",
  setupBuildsBody:
    "MediaPorter는 두 가지 macOS 빌드로 배포됩니다. 앱 동작은 같고, 리먹스나 오디오 변환에 필요한 ffmpeg를 어디서 가져오는지만 다릅니다.",
  setupBuilds: [
    {
      title: "ffmpeg 포함 빌드",
      body: "ffmpeg가 앱 번들 안에 포함되어 있습니다. 가장 간단한 선택이며 Homebrew나 명령줄 설정이 필요 없습니다.",
    },
    {
      title: "시스템 ffmpeg 빌드",
      body: "다운로드 크기가 더 작습니다. `brew install ffmpeg` 등으로 직접 설치하거나, 호환되는 ffmpeg 바이너리가 PATH에 있도록 설정하세요.",
    },
  ],
  setupTmdbTag: "tmdb",
  setupTmdbTitle: "TMDb — 포스터·메타데이터",
  setupTmdbWhat:
    "분석 단계에서 영화, 드라마, 애니메이션을 식별하고 포스터 및 TV 앱이 사용하는 전체 필드 세트(시즌, 에피소드 번호, 정렬 제목)를 가져오는 데 사용됩니다. 키가 없으면 — 생성된 폴백 포스터와 파일명이 제목으로 사용됩니다.",
    setupTmdbSteps: [
    "themoviedb.org에 가입 — 무료, 신용카드 불필요. 사용자 이름과 이메일만 있으면 됩니다.",
    "계정 → Settings → API.",
    "「Request an API key」→「Developer」 클릭. 유형은 「Personal」, 약관 동의.",
    "「API Key (v3 auth)」 복사 — 긴 16진수 문자열.",
    "MediaPorter에서: Settings (⌘,) → Metadata → 키 붙여넣기 → Save.",
  ],
  setupTmdbFree:
    "TMDb 무료 등급은 개인 사용 기준 사실상 무제한입니다 — 대규모 라이브러리를 동기화해도 일일 다운로드 한도에 걸리지 않습니다.",
  setupTmdbCta: "TMDb API 키 발급받기 →",
  setupOsTag: "opensubtitles",
  setupOsTitle: "OpenSubtitles — 다국어 자막",
  setupOsWhat:
    "분석 단계에서 설정한 언어(예: en, ru)의 자막을 찾고 다운로드하는 데 사용됩니다 — 파일에 아직 포함되지 않은 경우에 한해. 다운로드된 SRT는 출력 파일에 재멀티플렉싱되어 TV 앱의 자막 스위처에 나타납니다.",
  setupOsSteps: [
    "opensubtitles.com에 가입 — 무료, 신용카드 불필요.",
    "opensubtitles.com/consumers로 가서 「New consumer」 클릭. 이름은 자유(예: 「MediaPorter on my Mac」). API 키 복사.",
    "MediaPorter에서: Settings (⌘,) → Subtitles → API 키, opensubtitles.com 계정 사용자명·비밀번호, 원하는 언어(예: en,ru) 입력 → Save.",
  ],
  setupOsFree:
    "등록된 무료 계정은 하루 20개의 자막 다운로드를 제공합니다 — 영화 한 편이나 몇 화 정도는 충분하지만, 24화짜리 한 시즌을 한 번에 동기화하기에는 빠듯합니다. OpenSubtitles VIP(연 약 $10)는 한도를 크게 늘려 주며, 대규모 라이브러리를 다룬다면 권장됩니다.",
  setupOsCta: "OpenSubtitles API 키 발급받기 →",
  setupApplyHeading: "두 키를 모두 입력한 후",
  setupApplyBody:
    "이미 드롭한 폴더에 「분석」을 다시 실행하세요 — MediaPorter가 이전에 건너뛴 파일들의 포스터와 자막을 채워 넣습니다. TV 앱에 이미 들어간 항목은 변경되지 않으며, 보강은 새 파일이나 다시 분석된 파일에만 적용됩니다.",
  footerProduct: "제품",
  footerHelp: "도움말",
  footerFeatures: "기능",
  footerTagline: "# Media, ported. Deep on your devices.",
  footerRights: "© {year} MediaPorter. 모든 권리 보유.",
};

export const STRINGS: Record<Locale, Strings> = { en, ru, zh, ko };

/* ============================================================
 * Anime guide strings (iPhone + iPad share the same content, the
 * page just changes the device noun.)
 * ============================================================ */

export type GuideStrings = {
  title: string;
  description: string;
  hero: { eyebrow: string; title: string; lede: string };
  toc: string;
  sections: { id: string; heading: string; body: string }[];
  steps: { name: string; text: string }[];
  callout: string;
  related: string;
};

const DEVICE_PHRASE: Record<Locale, string> = {
  en: "iPhone and iPad",
  ru: "iPhone и iPad",
  zh: "iPhone 和 iPad",
  ko: "iPhone과 iPad",
};

function buildGuide(locale: Locale): GuideStrings {
  const deviceName = DEVICE_PHRASE[locale];

  const tables: Record<Locale, GuideStrings> = {
    en: {
      title: `How to put anime on ${deviceName} — full guide (2026)`,
      description: `Step-by-step: transfer anime episodes, full seasons, and fan-subbed releases to the built-in TV app on ${deviceName}. Works with .mkv, .mp4, .avi, soft and hard subs, dual audio. No iTunes, no iCloud, no jailbreak.`,
      hero: {
        eyebrow: "## guides / anime",
        title: `How to put anime on ${deviceName}`,
        lede: `The honest, end-to-end version: get any anime release into the native TV app on your ${deviceName} — episodes in the right order, posters, correct audio track, subtitles. No jailbreak, no iCloud, no DRM dance.`,
      },
      toc: "On this page",
      sections: [
        {
          id: "why-tv-app",
          heading: "Why use the built-in TV app, not VLC / Infuse?",
          body: `Third-party players work, but the native TV app is offline by default, integrated with AirPlay and the Apple TV remote, remembers playback position across devices, and survives device resets. The catch is that Apple offers no consumer-grade way to load video into it. MediaPorter rebuilds that path for ${deviceName}.`,
        },
        {
          id: "what-you-need",
          heading: "What you need",
          body: `A Mac running macOS 14 or newer, an iPhone or iPad on iOS / iPadOS 15+, a USB cable (or first-time Wi-Fi pairing through Finder), and the anime files. Common formats — .mkv, .mp4, .m4v, .avi, .mov — all work. Containers with H.264, HEVC, AAC, AC-3, E-AC-3, or DTS audio are handled.`,
        },
        {
          id: "steps",
          heading: "Step-by-step",
          body: "Below is the exact flow. There is no setup screen with twelve toggles — the app reads your files, makes a plan, and shows the receipts.",
        },
        {
          id: "fan-subs",
          heading: "Fan-subbed and multi-audio releases",
          body: "Most anime releases ship as .mkv with dual audio (Japanese + English dub) and soft subs (ASS/SSA). MediaPorter keeps both audio tracks when the TV app can play them, converts AC-3 to AAC (the iPad TV app silently hides AC-3 from the audio switcher), and remuxes soft subtitles into the output file. ASS styling falls back to plain text where the TV app can't render karaoke effects.",
        },
        {
          id: "episode-numbers",
          heading: "Episode numbers and burned-in titles",
          body: `Releases like "[Group] Show Name - 07 [1080p].mkv" are detected as episode 7 of the named show. MediaPorter writes the full TV-app field set (sort title, episode_sort_id, season number) so the episode lands in the correct slot — not as "0. Show Name" at the top of the list, which is a long-standing bug when fields are partially filled. Burned-in episode numbers in the picture are left alone.`,
        },
        {
          id: "specials-ovas",
          heading: "Specials, OVAs, and movies",
          body: "Specials are mapped to season 0 by TMDb convention; OVAs and movies are routed to the Movies tab. If a release has no TMDb match (very recent or niche shows), MediaPorter falls back to the folder name and you can correct the metadata in the plan view before syncing.",
        },
        {
          id: "storage",
          heading: "Will it fill up my device?",
          body: `Yes if you let it. The app shows free space on the device and the projected size of the transcoded output before you sync. Files that are already in a TV-app-compatible codec are not re-encoded — they are remuxed in place, costing the same bytes. Re-encodes default to HEVC at a target bitrate appropriate for the ${deviceName} display. You can override per file.`,
        },
        {
          id: "compared",
          heading: "Compared to AirDrop, VLC, Infuse, and WALTR",
          body: "AirDrop dumps files into the Files app, not the TV app, and skips per-episode metadata. VLC and Infuse are great third-party players but live outside the native TV ecosystem (no AirPlay-from-lock-screen, no system Now Playing). Older sync tools targeted iTunes; iTunes is gone on modern macOS. MediaPorter is built specifically for the modern, post-iTunes path into the native TV app, with anime-aware metadata handling.",
        },
      ],
      steps: [
        { name: "Install MediaPorter", text: "Download the macOS app from porter.md and drag it to /Applications." },
        { name: `Connect your ${deviceName}`, text: `Plug in via USB the first time so macOS trusts the device. Wi-Fi sync works on subsequent runs.` },
        { name: "Drop your anime folder", text: "Drag the folder (or individual .mkv / .mp4 files) into the MediaPorter window." },
        { name: "Review the plan", text: "MediaPorter shows what will be kept as-is, remuxed, or transcoded, and which TMDb match was chosen for each episode. Correct any mismatches inline." },
        { name: "Sync", text: `Click Sync. Episodes appear inside the TV app on the ${deviceName} as each file finishes uploading. Posters and episode order are correct from the first arrival.` },
      ],
      callout: `Stuck or hit an edge case? The site collects fixes for the common ones (AC-3 audio, "0." prefix bug, mid-sync space) at the changelog page.`,
      related: "Related guides",
    },
    ru: {
      title: `Как залить аниме на ${deviceName} — полный гайд (2026)`,
      description: `Пошагово: как перенести серии аниме, целые сезоны и фансаб-релизы во встроенное TV-приложение на ${deviceName}. Поддерживает .mkv, .mp4, .avi, soft- и hard-sub, две аудиодорожки. Без iTunes, без iCloud, без джейлбрейка.`,
      hero: {
        eyebrow: "## гайды / аниме",
        title: `Как залить аниме на ${deviceName}`,
        lede: `Честная сквозная инструкция: как доставить любой релиз аниме в нативное TV-приложение на ${deviceName} — серии в правильном порядке, постеры, нужная аудиодорожка, субтитры. Без джейлбрейка, без iCloud, без танцев с DRM.`,
      },
      toc: "На этой странице",
      sections: [
        {
          id: "why-tv-app",
          heading: "Зачем встроенное TV-приложение, а не VLC / Infuse?",
          body: `Сторонние плееры работают, но нативное TV-приложение по умолчанию офлайн, дружит с AirPlay и пультом Apple TV, запоминает позицию между устройствами и переживает сбросы. Подвох в том, что Apple не даёт обычного способа загрузить туда видео. MediaPorter восстанавливает этот путь для ${deviceName}.`,
        },
        {
          id: "what-you-need",
          heading: "Что нужно",
          body: `Mac с macOS 14 или новее, ${deviceName} с iOS / iPadOS 15+, USB-кабель (или первичный коннект по Wi-Fi через Finder) и сами файлы. Распространённые форматы — .mkv, .mp4, .m4v, .avi, .mov — все работают. Контейнеры с H.264, HEVC, AAC, AC-3, E-AC-3 и DTS обрабатываются.`,
        },
        {
          id: "steps",
          heading: "По шагам",
          body: "Ниже — точный сценарий. Нет экрана настроек с двенадцатью переключателями: приложение читает файлы, строит план и показывает «чек».",
        },
        {
          id: "fan-subs",
          heading: "Фансаб и две аудиодорожки",
          body: "Большая часть аниме приходит в .mkv с двумя аудио (японский + английский даб) и soft-сабами (ASS/SSA). MediaPorter сохраняет обе дорожки, если TV-приложение умеет их играть, конвертирует AC-3 в AAC (TV-приложение iPad молча скрывает AC-3 в переключателе) и ремуксит мягкие субтитры в выходной файл. Сложное оформление ASS падает в обычный текст там, где TV-приложение не умеет караоке.",
        },
        {
          id: "episode-numbers",
          heading: "Номера серий и прожжённые заголовки",
          body: `Релиз вроде «[Group] Show Name - 07 [1080p].mkv» определяется как 7-я серия названного сериала. MediaPorter заполняет полный набор полей TV-приложения (sort title, episode_sort_id, номер сезона), чтобы серия попала в нужное место — а не «0. Show Name» вверху списка, это давний баг при частично заполненных полях. Прожжённые в картинку номера остаются как есть.`,
        },
        {
          id: "specials-ovas",
          heading: "Спешлы, OVA и фильмы",
          body: "Спешлы по конвенции TMDb идут в нулевой сезон; OVA и фильмы попадают на вкладку Movies. Если у релиза нет совпадения в TMDb (свежие или нишевые тайтлы), MediaPorter откатывается на имя папки, а вы можете поправить метаданные в плане до запуска.",
        },
        {
          id: "storage",
          heading: "Забьёт ли он мне устройство?",
          body: `Забьёт, если разрешить. Приложение показывает свободное место и прогноз размера выходных файлов до старта. Файлы, уже совместимые с TV-приложением, не перекодируются — только ремуксятся. Перекодирование по умолчанию — HEVC с битрейтом под экран ${deviceName}; можно переопределить по каждому файлу.`,
        },
        {
          id: "compared",
          heading: "Сравнение с AirDrop, VLC, Infuse",
          body: "AirDrop кидает файлы в Files, а не в TV, и не несёт метаданные. VLC и Infuse — отличные сторонние плееры, но живут вне нативной TV-экосистемы (нет AirPlay с локскрина, нет системного Now Playing). Старые инструменты синхронизации работали через iTunes; iTunes на современном macOS нет. MediaPorter сделан именно под современный путь в нативное TV-приложение, с пониманием аниме-метаданных.",
        },
      ],
      steps: [
        { name: "Установите MediaPorter", text: "Скачайте macOS-приложение с porter.md и перетащите в /Applications." },
        { name: `Подключите ${deviceName}`, text: `Первый раз — по USB, чтобы macOS доверяло устройству. Дальше работает по Wi-Fi.` },
        { name: "Перетащите папку с аниме", text: "Дропните папку (или отдельные .mkv / .mp4) в окно MediaPorter." },
        { name: "Проверьте план", text: "MediaPorter покажет, что оставит как есть, что ремуксит, что перекодирует, и какой матч в TMDb выбран для каждой серии. Можно поправить вручную." },
        { name: "Sync", text: `Жмите Sync. Серии появляются в TV-приложении на ${deviceName} по мере заливки. Постеры и порядок корректны с первого файла.` },
      ],
      callout: `Застряли или попали в граничный случай? Частые фиксы (AC-3, баг «0.», нехватка места) собраны в changelog.`,
      related: "Смежные гайды",
    },
    zh: {
      title: `如何把动漫导入 ${deviceName}——完整教程（2026）`,
      description: `逐步教程：把动漫单集、整季和字幕组发布导入 ${deviceName} 的内置 TV 应用。支持 .mkv、.mp4、.avi、软硬字幕、多音轨。无需 iTunes、iCloud、越狱。`,
      hero: {
        eyebrow: "## 教程 / 动漫",
        title: `如何把动漫导入 ${deviceName}`,
        lede: `这是完整、坦诚的版本：把任意动漫资源导入 ${deviceName} 的原生 TV 应用——集数正确、海报齐全、音轨与字幕都对。无需越狱，不绕 iCloud，不用对付 DRM。`,
      },
      toc: "本页内容",
      sections: [
        {
          id: "why-tv-app",
          heading: "为什么用内置 TV 应用，而不是 VLC / Infuse？",
          body: `第三方播放器也能用，但内置 TV 应用默认离线，原生支持 AirPlay 和 Apple TV 遥控器，能跨设备记住播放位置，系统重置后也在。麻烦在于 Apple 不提供面向用户的视频导入方式。MediaPorter 把这条路径为 ${deviceName} 重建出来。`,
        },
        {
          id: "what-you-need",
          heading: "你需要什么",
          body: `一台 macOS 14 或更高版本的 Mac，一台 iOS / iPadOS 15+ 的 ${deviceName}，一根 USB 线（或首次通过 Finder 进行 Wi-Fi 配对），以及动漫文件。常见格式 .mkv、.mp4、.m4v、.avi、.mov 都行；H.264、HEVC、AAC、AC-3、E-AC-3、DTS 也都能处理。`,
        },
        {
          id: "steps",
          heading: "逐步操作",
          body: "下面是完整流程。没有十几个开关的设置页——应用读你的文件、做计划、把「清单」给你看。",
        },
        {
          id: "fan-subs",
          heading: "字幕组与多音轨版本",
          body: "大多数动漫资源是双音轨（日语+英语配音）+ ASS/SSA 软字幕的 .mkv。MediaPorter 在 TV 应用能播的范围内保留两条音轨，把 AC-3 转成 AAC（iPad TV 应用会悄悄从音轨切换器里隐藏 AC-3），并把软字幕重封装到输出文件里。ASS 复杂样式在 TV 应用无法渲染卡拉 OK 效果时会退化成纯文本。",
        },
        {
          id: "episode-numbers",
          heading: "集数与画面里烧入的标题",
          body: `形如「[Group] Show Name - 07 [1080p].mkv」的文件会被识别为该剧的第 7 集。MediaPorter 写满 TV 应用所需的全部字段（sort title、episode_sort_id、season number），让它正确归位——而不是出现在列表顶端的「0. Show Name」（这是字段部分填充时的老 bug）。画面里烧入的集数保持原样。`,
        },
        {
          id: "specials-ovas",
          heading: "特别篇、OVA 与剧场版",
          body: "按 TMDb 惯例，特别篇归入第 0 季；OVA 和剧场版进入 Movies 标签。如果 TMDb 找不到匹配（非常新的或冷门作品），MediaPorter 会回退到使用文件夹名，你可在同步前的计划视图中手动修正元数据。",
        },
        {
          id: "storage",
          heading: "会把我的设备塞满吗？",
          body: `放任不管会的。应用在同步前会展示设备剩余空间和预计输出大小。已经兼容 TV 应用编码的文件不会重新编码——只是重封装，体积不变。需要重新编码的默认用 HEVC，目标码率按 ${deviceName} 屏幕优化；可以按文件覆盖设置。`,
        },
        {
          id: "compared",
          heading: "对比 AirDrop、VLC、Infuse、WALTR",
          body: "AirDrop 把文件丢进 Files 而不是 TV 应用，且没有逐集元数据。VLC 和 Infuse 是优秀的第三方播放器，但在原生 TV 生态之外（锁屏 AirPlay、系统正在播放都没有）。早期同步工具走 iTunes，现代 macOS 上 iTunes 已经不在。MediaPorter 专门为「后 iTunes 时代」进入原生 TV 应用而做，且懂动漫的元数据规则。",
        },
      ],
      steps: [
        { name: "安装 MediaPorter", text: "从 porter.md 下载 macOS 应用并拖入 /Applications。" },
        { name: `连接 ${deviceName}`, text: `第一次用 USB 连接，让 macOS 信任设备。之后可走 Wi-Fi。` },
        { name: "拖入动漫文件夹", text: "把文件夹（或单个 .mkv / .mp4）拖进 MediaPorter 窗口。" },
        { name: "查看计划", text: "MediaPorter 显示哪些保留、哪些重封装、哪些重新编码，以及每集匹配到的 TMDb 条目。可以现场修正。" },
        { name: "Sync", text: `点击 Sync。每个文件上传完成时立即出现在 ${deviceName} 的 TV 应用里。海报和集数从第一个文件就是对的。` },
      ],
      callout: `卡住或遇到边角情况？常见修复（AC-3、「0.」前缀 bug、同步中空间不足）都集中在 changelog 页。`,
      related: "相关教程",
    },
    ko: {
      title: `${deviceName}에 애니메이션 옮기는 법 — 풀 가이드 (2026)`,
      description: `단계별 안내: 애니메이션 단일 에피소드, 시즌 전체, 팬섭 릴리스를 ${deviceName}의 내장 TV 앱으로 옮기는 법. .mkv, .mp4, .avi, 소프트/하드 자막, 다중 오디오 트랙 지원. iTunes·iCloud·탈옥 불필요.`,
      hero: {
        eyebrow: "## 가이드 / 애니메이션",
        title: `${deviceName}에 애니메이션 옮기는 법`,
        lede: `정직한 전체 흐름: 모든 애니메이션 릴리스를 ${deviceName}의 네이티브 TV 앱으로 옮기기 — 순서가 맞는 에피소드, 포스터, 정확한 오디오 트랙, 자막까지. 탈옥 없음, iCloud 우회 없음, DRM 싸움 없음.`,
      },
      toc: "이 페이지의 내용",
      sections: [
        {
          id: "why-tv-app",
          heading: "왜 VLC / Infuse가 아니라 내장 TV 앱인가?",
          body: `서드파티 플레이어도 동작합니다. 하지만 내장 TV 앱은 기본 오프라인이고, AirPlay와 Apple TV 리모컨과 통합되며, 기기 간 재생 위치를 기억하고, 기기 초기화에서도 살아남습니다. 문제는 Apple이 사용자에게 비디오를 넣을 일반적인 방법을 제공하지 않는다는 점이고, MediaPorter가 ${deviceName}용으로 그 경로를 다시 만듭니다.`,
        },
        {
          id: "what-you-need",
          heading: "필요한 것",
          body: `macOS 14 이상이 설치된 Mac, iOS / iPadOS 15+ ${deviceName}, USB 케이블(또는 Finder를 통한 최초 Wi-Fi 페어링), 그리고 애니메이션 파일. 흔한 .mkv, .mp4, .m4v, .avi, .mov 모두 동작합니다. H.264, HEVC, AAC, AC-3, E-AC-3, DTS 컨테이너를 처리합니다.`,
        },
        {
          id: "steps",
          heading: "단계별",
          body: "아래가 정확한 흐름입니다. 토글 12개짜리 설정 화면 같은 건 없습니다 — 앱이 파일을 읽고, 계획을 세우고, 영수증을 보여 줍니다.",
        },
        {
          id: "fan-subs",
          heading: "팬섭 / 다중 오디오 릴리스",
          body: "애니메이션 릴리스 대부분은 일본어 + 영어 더빙의 두 오디오와 ASS/SSA 소프트 자막을 가진 .mkv입니다. MediaPorter는 TV 앱이 재생할 수 있는 한 두 오디오 트랙을 모두 유지하고, AC-3는 AAC로 변환하며(iPad TV 앱이 AC-3를 오디오 스위처에서 조용히 숨김), 소프트 자막을 출력 파일로 리먹스합니다. TV 앱이 가라오케 효과를 그릴 수 없을 때 ASS 복잡 스타일은 일반 텍스트로 폴백됩니다.",
        },
        {
          id: "episode-numbers",
          heading: "에피소드 번호와 화면에 박힌 제목",
          body: `「[Group] Show Name - 07 [1080p].mkv」 같은 파일은 해당 작품의 7화로 인식됩니다. MediaPorter는 TV 앱이 요구하는 필드 세트(sort title, episode_sort_id, season number)를 모두 기록해 에피소드가 올바른 자리에 들어가도록 합니다 — 필드가 부분만 채워졌을 때 발생하는 「0. Show Name」 상단 정렬 버그를 피합니다. 화면에 박힌 번호는 그대로 둡니다.`,
        },
        {
          id: "specials-ovas",
          heading: "스페셜, OVA, 극장판",
          body: "스페셜은 TMDb 관례에 따라 시즌 0으로 매핑되고, OVA와 극장판은 Movies 탭으로 라우팅됩니다. TMDb 매치가 없는 경우(최신작 또는 마이너 작품) MediaPorter는 폴더명으로 폴백하며, 동기화 전 플랜 뷰에서 메타데이터를 수정할 수 있습니다.",
        },
        {
          id: "storage",
          heading: "기기를 가득 채우지는 않나요?",
          body: `놔두면 그렇게 됩니다. 앱은 동기화 전 기기의 여유 공간과 변환 결과의 예상 크기를 보여 줍니다. 이미 TV 앱과 호환되는 코덱은 재인코딩하지 않고 리먹스만 하므로 용량이 동일합니다. 재인코딩은 기본 HEVC, ${deviceName} 디스플레이에 맞는 비트레이트로 진행되며, 파일별로 덮어쓸 수 있습니다.`,
        },
        {
          id: "compared",
          heading: "AirDrop, VLC, Infuse와의 비교",
          body: "AirDrop은 파일을 Files 앱으로 떨어뜨리지 TV 앱으로 넣지 않고, 에피소드별 메타데이터도 없습니다. VLC와 Infuse는 훌륭한 서드파티 플레이어지만 네이티브 TV 생태계 밖에 있습니다(잠금화면 AirPlay나 시스템 Now Playing 없음). 예전 동기화 도구들은 iTunes에 의존했는데, 최신 macOS에는 iTunes가 없습니다. MediaPorter는 포스트-iTunes 시대의 네이티브 TV 앱 경로를 위해, 그리고 애니메이션 메타데이터 처리를 위해 만들어졌습니다.",
        },
      ],
      steps: [
        { name: "MediaPorter 설치", text: "porter.md에서 macOS 앱을 받아 /Applications에 드래그하세요." },
        { name: `${deviceName} 연결`, text: `처음에는 USB로 연결해 macOS가 기기를 신뢰하게 합니다. 이후엔 Wi-Fi 동기화가 됩니다.` },
        { name: "애니메이션 폴더 드롭", text: "폴더(또는 개별 .mkv / .mp4 파일)를 MediaPorter 창에 끌어다 놓습니다." },
        { name: "플랜 확인", text: "MediaPorter가 무엇을 그대로 두고, 무엇을 리먹스하며, 무엇을 트랜스코드할지, 그리고 각 에피소드에 매칭된 TMDb 항목을 보여 줍니다. 불일치는 그 자리에서 수정." },
        { name: "Sync", text: `Sync를 누르세요. 각 파일이 업로드를 마치는 즉시 ${deviceName}의 TV 앱에 에피소드가 나타납니다. 포스터와 에피소드 순서는 첫 도착부터 맞습니다.` },
      ],
      callout: `막혔거나 경계 케이스를 만나셨다면, 흔한 수정(AC-3 오디오, 「0.」 접두사 버그, 동기화 중 공간 부족)은 체인지로그 페이지에 모여 있습니다.`,
      related: "관련 가이드",
    },
  };
  return tables[locale];
}

export function getGuide(locale: Locale): GuideStrings {
  return buildGuide(locale);
}
