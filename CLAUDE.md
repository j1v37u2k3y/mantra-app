# Mantra App — Agent Instructions

A small React + Express app that displays a random mantra from `src/data/mantras.json`. Single-purpose,
typography-forward, minimal UI. Deploys both as a full-stack Express app and as a static site on GitHub Pages.

## Architecture

- **`server.js`** — Express server on port `3174`. Loads `src/data/mantras.json` at startup AND merges a personal
  override file (`${MANTRA_FILE:-~/.config/mantra/mantras.json}`) that it **hot-reloads** via `watchFile` (see
  § Personal Mantras & Hands-Off Deploy). Exposes `GET /api/mantra` and `GET /api/mantra/:index`, and serves the Vite
  `dist/` build in production. Exports `app` so tests can hit it with supertest; only calls `.listen()` when run
  directly.
- **`src/App.tsx`** — Single-component React UI. Tries `/api/mantra` first, falls back to the bundled
  `src/data/mantras.json` when the API is unreachable (this is what makes the GitHub Pages build work without a
  backend).
- **`src/lib/parseMantra.ts`** — Pure parser extracted so it's unit-testable. `App.tsx` imports from here.
- **`src/data/mantras.json`** — Flat JSON array of strings. Single source of truth — imported by both the client
  bundle and `server.js`.
- **`vite.config.ts`** — Dev server on port `5174` with `/api` proxied to `http://localhost:3174`. Reads
  `VITE_BASE` from the environment so the GitHub Pages workflow can build with `/mantra-app/` as the base.
- **`tests/`** — Vitest suite. `parseMantra.test.ts` covers the parser, `server.test.ts` hits the Express app via
  supertest.

## Mantra Format

`parseMantra()` in `src/lib/parseMantra.ts` recognizes three formats:

1. `"Plain string"` — rendered as title only
2. `"Title — subtitle"` (em dash or en dash) — split into two lines
3. `"**Bold title** — subtitle"` — markdown-style bold title with subtitle (also accepts `-` as separator)

When adding new mantras, prefer format 2 or 3 so the UI has both a primary headline and a secondary line. Keep titles
short (under ~50 chars); subtitles can be longer. A bare hyphen inside a plain string (e.g. `co-located services`)
does NOT split — you need an em/en dash, or bold markers, to get a subtitle.

## Running

```bash
npm install
npm run dev        # Express (3174) + Vite (5174) in parallel via concurrently
npm run build      # Vite build → dist/
npm run preview    # Express serves dist/ + API on port 3174
npm run typecheck  # tsc --noEmit
npm test           # vitest run (parser + server tests)
npm run test:watch # vitest in watch mode
npm run ci         # typecheck + test + build, as CI runs it
```

## Target Resolutions

- Desktop/tablet: normal flow with large Playfair headline.
- **480x320 embedded display** — the layout is compact-first. Title font-size uses `clamp(1.1rem, 5vw, 3rem)`,
  subtitle uses `clamp(0.75rem, 2.6vw, 1.25rem)`, gaps shrink at `sm`, and the spacebar hint is hidden on small
  screens so the control row fits. If you edit `App.tsx`, verify the layout still fits inside a 480x320 viewport
  before shipping.

## Code Conventions

- **TypeScript strict mode** — no `any`, `resolveJsonModule` enabled for JSON imports.
- **React 19** with hooks, functional components only.
- **Tailwind** for styling — no CSS modules or styled-components; inline `style` only for keyframe animations.
- **ESM only** — `"type": "module"` in package.json; use `import` syntax everywhere including `server.js`.
- Keep `App.tsx` as the single UI component. If the app grows, split into `components/` — but don't over-abstract
  for a one-screen experience.

## Making Changes

### Adding a mantra

Edit `src/data/mantras.json` — the **bundled** list. In dev, restart the server so it picks up the change (this file
is read once at startup in `server.js`). The client also bundles it at build time for the static fallback — run
`npm run build` to refresh that.

To add a mantra to the **live Pi kiosk** instead, push to the personal data repo — it hot-reloads onto the display
with no restart. See § Personal Mantras & Hands-Off Deploy.

### Changing the mantra parser

`parseMantra()` lives in `src/lib/parseMantra.ts`. If you add a new format, update the matching test in
`tests/parseMantra.test.ts` AND the README's "Editing Mantras" section.

### Styling

The look is intentional: dark background (`#050507`), purple accent lines, Playfair Display for headlines,
JetBrains Mono for UI chrome. Avoid bright colors or heavy UI elements — this app is meant to feel quiet and
meditative. Keep the 480x320 constraint in mind for any layout change.

### Adding persistence / database

Not needed. `src/data/mantras.json` is the source of truth. If the list grows beyond ~100 entries, consider
reading it on each request instead of at startup so edits don't require restarts.

## Personal Mantras & Hands-Off Deploy (Raspberry Pi kiosk)

The production target is a **Raspberry Pi 4 + 3.5" 480x320 display** running Chromium in kiosk mode against the local
Express server. Two things beyond the bundled `src/data/mantras.json` make mantra updates hands-off.

### Personal override file + hot-reload

`server.js` merges a **personal override** at `${MANTRA_FILE:-~/.config/mantra/mantras.json}` (appended after the
bundled list) when it exists and parses as a JSON array. It's **server-only** — never in the GitHub Pages build, so
personal mantras stay private. The server **hot-reloads** it: `watchFile(LOCAL_MANTRAS_PATH, { interval: 5000 })`
re-reads on change, no restart.

- `watchFile` (stat-poll), NOT `fs.watch` (inode), is deliberate: the deploy swaps the file via atomic rename through a
  **symlink**, which makes an inode watcher go stale. Don't switch it to `fs.watch`.
- Hot-reload applies ONLY to the override file. The **bundled** `src/data/mantras.json` is still read once at startup.

### The two Pi installers (`scripts/`)

- **`setup-pi-display.sh`** — provisions the kiosk (SPI/`piscreen` overlay, Node + build, `mantra-app.service`,
  labwc/openbox autostart for Chromium). `--password-store=basic` is **load-bearing**: without it the GNOME keyring
  unlock prompt covers the 480x320 screen with an on-screen keyboard and the mantra never renders.
- **`setup-mantra-sync.sh`** — the hands-off deploy. The personal list lives in a **separate data repo** (default
  `j1v37u2k3y/mantra`, override `DATA_REPO`). On the Pi it clones the data repo to `~/mantra`, symlinks
  `~/.config/mantra/mantras.json` → that clone's `mantras.json`, and installs `mantra-sync.service` (`oneshot`:
  `git fetch --prune` + `git reset --hard origin/main` — remote is truth, never `git pull`) on a daily
  `mantra-sync.timer`.

**The loop, zero restarts:** push to the data repo → daily timer fetch/reset → symlinked file changes → `watchFile`
reloads → display updates.

### Private data repo (PAT)

The data repo is **private**, so the headless timer authenticates with a fine-grained GitHub PAT:
`sudo MANTRA_GIT_TOKEN=github_pat_xxx ./scripts/setup-mantra-sync.sh`. The installer writes it to git's default store
`~/.git-credentials` (mode 600) via `git credential approve` (non-destructive — won't clobber other hosts), and sets the
data repo's repo-local `credential.helper` to plain `store`.

- **PAT gotcha:** a fine-grained PAT needs **Contents: Read** on the data repo. Fresh tokens default to Metadata-only,
  which authenticates but makes `git fetch` 403 with `"Write access to repository not granted"` (GitHub's generic
  wording — fetch only needs *read*). Add Contents: Read.
- **Don't commit infra coordinates.** Committed files reference the Pi via a `mantra-pi` ssh alias only; the real
  host/user/IP live in the operator's local `~/.ssh/config`, never in the repo.

## Ports

| Service     | Port | Notes                                           |
|-------------|------|-------------------------------------------------|
| Express API | 3174 | Serves `/api/mantra` and static `dist/` in prod |
| Vite dev    | 5174 | Proxies `/api/*` → `3174` in dev                |

These ports are hardcoded. If you change them, update `server.js`, `vite.config.ts`, the README, and this file.

## CI / Release / Deploy

Three GitHub Actions workflows:

- **`.github/workflows/ci.yml`** — runs on every PR and push to `main`. Does `typecheck`, `test`, `build` (with
  `VITE_BASE=/<repo>/`), and a server smoke test (boot `server.js`, curl `/api/mantra`).
- **`.github/workflows/pages.yml`** — on push to `main`, builds the static bundle with `VITE_BASE=/<repo>/` and
  publishes to GitHub Pages via `actions/deploy-pages`. Requires Pages to be enabled in repo settings with "Source:
  GitHub Actions".
- **`.github/workflows/release.yml`** — on push to `main`, runs `semantic-release` (config in `.releaserc.json`).
  Uses conventional commits to decide the next SemVer bump, writes `CHANGELOG.md`, tags the release, and creates a
  GitHub release. Pushes a `chore(release): x.y.z [skip ci]` commit back to `main`.

None of these deploy the app to the **Raspberry Pi kiosk** — that's a Pi-side **pull** (the `mantra-sync.timer`), not a
cloud push. There's deliberately no hosted-runner CD reaching the Pi (a cloud runner can't reach a home-LAN device
without exposing it). See § Personal Mantras & Hands-Off Deploy.

### Conventional commits

Since `semantic-release` is driving version bumps, commit messages matter:

- `fix: ...` → patch bump
- `feat: ...` → minor bump
- `feat!: ...` or a `BREAKING CHANGE:` footer → major bump
- `chore:`, `docs:`, `test:`, `refactor:`, `ci:`, `build:` → no release

If you want to change how versioning is decided, edit `.releaserc.json`.

## Non-obvious Gotchas

- **`mantras.json` lives in `src/data/`**, not the repo root. Both `server.js` and the client import from there —
  that's intentional, so there's a single source of truth for both the API and the static fallback.
- **The leading-list-marker strip in `parseMantra`** requires whitespace after the `-` or `*` (`/^[-*]\s+/`). That
  prevents `**Bold**` from getting one of its stars stripped. Don't relax that regex without updating the tests.
- **`VITE_BASE`** defaults to `/` for local dev/preview so the Express server still serves assets correctly. Only
  the CI/Pages workflow sets it to `/mantra-app/`.
