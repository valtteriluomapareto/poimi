# Poimi Website

The marketing website for **Poimi** — an iOS 26 app for hand-picking a year of photos into one
album. Built with **Astro** (plain CSS, no framework) and published to **GitHub Pages** by the
`deploy-website.yml` workflow. Design lives in the Paper "Website" page; content + decisions in
GitHub issue #227.

## Local development

Run all commands from `website/`. Use **Node 22.12+** (CI pins Node 22).

```bash
npm install
npm run dev
```

| Command            | Purpose                                               |
| :----------------- | :---------------------------------------------------- |
| `npm run dev`      | Start the local dev server                            |
| `npm run build`    | Build the static site into `dist/`                    |
| `npm run preview`  | Preview the production build locally                  |
| `npm run check`    | `astro check` (type + template diagnostics)           |
| `npm run validate` | The same gate CI runs (`astro check` + `astro build`) |
| `npm run format`   | Format with Prettier                                  |

## Layout

- `src/pages/` — `index.astro` (landing) + `privacy` / `terms` / `support` / `404`.
- `src/components/` — one component per landing section (Hero → Footer) + `mocks/`.
- `src/layouts/MarketingLayout.astro` — the shared `<head>` (SEO / OpenGraph / JSON-LD) + skip link.
- `src/styles/site.css` — design tokens (light) + base + shared classes.
- `src/consts.ts` — outbound links + the `IS_APP_STORE_LIVE` launch gate.
- `src/assets/` — real app screenshots (via `astro:assets`); `public/` — favicon, og-image, robots.

## Configuration

`astro.config.mjs` sets `site` + `base` (`/<repo>`, derived from `GITHUB_REPOSITORY` so a rename
needs no code change; local builds use a hardcoded fallback — update it if the repo is renamed).

## Deploy

Push to `main` touching `website/**` → `deploy-website.yml` builds and publishes to GitHub Pages at
`https://valtteriluomapareto.github.io/poimi`. **One-time setup:** repo Settings → Pages → Source =
"GitHub Actions" (before the first deploy).
