# Mantra

A minimal, meditative web app that serves a random personal mantra on each visit. Dark aesthetic, typography-forward, single-purpose. Runs as a full-stack Express app locally and as a static site on GitHub Pages.

![React](https://img.shields.io/badge/React-19-61dafb) ![Vite](https://img.shields.io/badge/Vite-6-646cff) ![Tailwind](https://img.shields.io/badge/Tailwind-3-38bdf8) ![Express](https://img.shields.io/badge/Express-4-000000) ![Tests](https://img.shields.io/badge/tests-vitest-6E9F18) ![Release](https://img.shields.io/badge/release-semantic--release-e10079)

## What It Does

- Fetches a random mantra from a curated list (`src/data/mantras.json`).
- Parses mantras with an optional `"Title — subtitle"` format into a title and a secondary line.
- Renders the result in a full-screen, minimalist layout with subtle fade-in animation.
- Works with or without the backend — on GitHub Pages (static) the bundled JSON is used as a fallback.
- Sized to fit tiny embedded displays (**480x320** and up).

## Quick Start

**Requirements:** Node.js 20+

```bash
npm install
npm run dev
```

Open http://localhost:5174

This runs two processes in parallel:
- **Express API** on port `3174` serving `GET /api/mantra`
- **Vite dev server** on port `5174` with an API proxy for `/api/*`

## Production Build

```bash
npm run build     # Vite build → dist/
npm run preview   # Express serves dist/ + API on port 3174
```

## Tests

Vitest covers the mantra parser and the Express API (via supertest).

```bash
npm test              # run once
npm run test:watch    # watch mode
npm run typecheck     # tsc --noEmit
npm run ci            # typecheck + test + build (the same thing CI runs)
```

## Editing Mantras

Add, remove, or rewrite lines in `src/data/mantras.json`. In dev, restart the server to pick up changes (the file is read once at startup). The client bundles this file for its static fallback, so rebuild with `npm run build` if you're deploying.

Supported formats:

```json
[
  "A plain mantra with no subtitle",
  "Title phrase — supporting context or descriptor",
  "**Bold Title** — supporting context"
]
```

A bare hyphen inside a plain string (e.g. `co-located services`) does **not** split into a subtitle — use an em/en dash or bold markers for that.

## Architecture

```
mantra-app/
├── server.js                    — Express API + static file server (port 3174, exports `app` for tests)
├── src/
│   ├── main.tsx                 — React root
│   ├── App.tsx                  — Full UI: fetch, parse, render, refresh, static fallback
│   ├── lib/parseMantra.ts       — Pure parser (unit-testable)
│   ├── data/mantras.json        — Curated mantra list (single source of truth)
│   └── index.css                — Tailwind entry
├── tests/
│   ├── parseMantra.test.ts      — Parser unit tests
│   └── server.test.ts           — API tests via supertest
├── .github/workflows/
│   ├── ci.yml                   — Typecheck + test + build + server smoke test
│   ├── pages.yml                — Build + deploy to GitHub Pages
│   └── release.yml              — semantic-release on push to main
├── .releaserc.json              — semantic-release config
├── vite.config.ts
├── vitest.config.ts
└── package.json
```

## API

| Method | Path                | Response                                                      |
|--------|---------------------|---------------------------------------------------------------|
| GET    | `/api/mantra`       | `{ "mantra": string, "index": number, "total": number }`      |
| GET    | `/api/mantra/:index`| Same shape, or `404 {"error":"Invalid index"}` if out of range |

## GitHub Pages Deployment

The `pages.yml` workflow publishes `dist/` to GitHub Pages on every push to `main`. One-time repo setup:

1. Repo **Settings → Pages → Build and deployment → Source: GitHub Actions**.
2. Push to `main`. The workflow builds with `VITE_BASE=/<repo-name>/` and deploys.
3. Visit `https://<user>.github.io/<repo-name>/`.

When the client can't reach `/api/mantra` (which is the case on GitHub Pages), it transparently falls back to the bundled `src/data/mantras.json` and picks client-side. Same UX, no backend required.

## Releases (semantic-release)

On every push to `main`, `release.yml` runs [semantic-release](https://semantic-release.gitbook.io/). Commit messages drive the version bump:

| Commit prefix            | Bump   | Example                                    |
|--------------------------|--------|--------------------------------------------|
| `fix:`                   | patch  | `fix: handle empty mantras.json`           |
| `feat:`                  | minor  | `feat: add auto-rotate control`            |
| `feat!:` or `BREAKING CHANGE:` footer | major  | `feat!: drop support for the /v1 endpoint` |
| `chore:` / `docs:` / `test:` / `refactor:` / `ci:` / `build:` | — | no release                                 |

semantic-release will:
1. Analyze commits since the last tag.
2. Bump `package.json` / `package-lock.json`.
3. Regenerate `CHANGELOG.md`.
4. Tag the release and create a GitHub release.
5. Push a `chore(release): x.y.z [skip ci]` commit back to `main`.

## Tech Stack

- **Frontend:** React 19, TypeScript (strict), Vite 6, Tailwind CSS 3
- **Backend:** Express 4 (Node.js ESM)
- **Tests:** Vitest + supertest
- **Release:** semantic-release (`@semantic-release/changelog`, `@semantic-release/git`, `@semantic-release/github`)
- **CI:** GitHub Actions
- **Fonts:** Playfair Display (serif headlines), JetBrains Mono (small caps UI)