# Mantra

A minimal, meditative web app that serves a random personal mantra on each visit. Dark aesthetic, typography-forward,
single-purpose. Runs as a full-stack Express app locally and as a static site on GitHub Pages.

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

Add, remove, or rewrite lines in `src/data/mantras.json`. In dev, restart the server to pick up changes (the bundled
file is read once at startup). The client bundles this file for its static fallback, so rebuild with `npm run build` if
you're deploying.

For a **private, machine-local** list — and to push edits to a kiosk **automatically, with no restart** — use the
personal override file instead. See [Personal Mantras & Hands-Off Deploy](#personal-mantras--hands-off-deploy).

Supported formats:

```json
[
  "A plain mantra with no subtitle",
  "Title phrase — supporting context or descriptor",
  "**Bold Title** — supporting context"
]
```

A bare hyphen inside a plain string (e.g. `co-located services`) does **not** split into a subtitle — use an em/en dash
or bold markers for that.

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
├── scripts/
│   ├── setup-pi-display.sh      — Raspberry Pi kiosk provisioning (display + Chromium autostart)
│   └── setup-mantra-sync.sh     — Hands-off deploy: data-repo git-sync timer + symlink
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

| Method | Path                 | Response                                                       |
|--------|----------------------|----------------------------------------------------------------|
| GET    | `/api/mantra`        | `{ "mantra": string, "index": number, "total": number }`       |
| GET    | `/api/mantra/:index` | Same shape, or `404 {"error":"Invalid index"}` if out of range |

## GitHub Pages Deployment

The `pages.yml` workflow publishes `dist/` to GitHub Pages on every push to `main`. One-time repo setup:

1. Repo **Settings → Pages → Build and deployment → Source: GitHub Actions**.
2. Push to `main`. The workflow builds with `VITE_BASE=/<repo-name>/` and deploys.
3. Visit `https://<user>.github.io/<repo-name>/`.

When the client can't reach `/api/mantra` (which is the case on GitHub Pages), it transparently falls back to the
bundled `src/data/mantras.json` and picks client-side. Same UX, no backend required.

## Personal Mantras & Hands-Off Deploy

Beyond the bundled `src/data/mantras.json`, the Express server merges a **personal override file** at
`~/.config/mantra/mantras.json` (path overridable via `MANTRA_FILE`). Same flat-JSON-array format, appended after the
bundled list. This file is **server-only** — it never reaches the GitHub Pages build, so personal mantras stay private.

**Hot-reload:** `server.js` watches the override file with `fs.watchFile` (5s stat-poll) and re-reads it on
change — **no restart needed**. Stat-poll rather than `fs.watch` on purpose: the auto-sync below replaces the
file via atomic rename *through a symlink*, which makes an inode-based watcher go stale.

### Raspberry Pi kiosk

`scripts/setup-pi-display.sh` provisions a Raspberry Pi 4 + 3.5" XPT2046 (480×320) display as a kiosk — SPI/`piscreen`
overlay, Node + app build, a `mantra-app.service` systemd unit, and labwc/openbox autostart files that launch Chromium
full-screen against `http://localhost:5174`:

```bash
sudo ./scripts/setup-pi-display.sh
```

### Hands-off deploy (auto-sync)

`scripts/setup-mantra-sync.sh` makes editing your mantras **deploy itself** — no SSH, no restart. The personal list
lives in a **separate data repo** (a plain `mantras.json`; default `j1v37u2k3y/mantra`, override with `DATA_REPO`). On
the Pi the installer:

1. Clones the data repo to `~/mantra`.
2. Symlinks `~/.config/mantra/mantras.json` → `~/mantra/mantras.json` (any existing real file is backed up).
3. Installs `mantra-sync.service` (`oneshot`: `git fetch --prune` then `git reset --hard origin/main` — remote is the
   source of truth) + `mantra-sync.timer` (`OnCalendar=daily`, override with `SYNC_ON_CALENDAR`).

```bash
sudo ./scripts/setup-mantra-sync.sh
```

The full loop, zero restarts:

```
push to the data repo  →  daily timer: git fetch + reset --hard  →  symlinked
mantras.json changes   →  server fs.watchFile fires (~5s)         →  display updates
```

**Private data repo:** pass a fine-grained GitHub PAT so the headless timer can fetch it. The token is stored mode-600
at `~/.config/mantra/git-credentials` (never committed) and wired via `credential.helper=store`:

```bash
sudo MANTRA_GIT_TOKEN=github_pat_xxx ./scripts/setup-mantra-sync.sh
```

> ⚠️ The PAT must be **fine-grained** with **Contents: Read-only** on the data repo. A token with only the
> default *Metadata* permission authenticates but `git fetch` returns `403 "Write access to repository not
> granted"` — add **Contents: Read** to fix it.

### Drift monitor (mantra-health)

The hot-reload loop above is silent when it *works* — and was also silent when it **broke**: a sync can fail for hours
(corrupted clone, network, expired PAT) while `mantra-app.service` and `mantra-sync.timer` both still report `active`,
so the display goes stale with nothing to flag it. `scripts/setup-mantra-health.sh` installs a watchdog that pushes to
your phone via [ntfy.sh](https://ntfy.sh) when the deploy is no longer current:

```bash
sudo NTFY_TOPIC=mantra-pi-7h3k9x ./scripts/setup-mantra-health.sh
```

Two complementary signals:

- **Instant path** — a systemd drop-in adds `OnFailure=mantra-health-alert.service` to `mantra-sync.service`, so a
  failed sync pushes the *moment* it happens.
- **Catch-all** — `mantra-health.timer` (every ~6h) fetches and compares local `HEAD` vs `origin/main` and checks
  `systemctl is-failed mantra-sync.service`. A hard fault (failed unit, corrupt/missing clone, fetch error) alerts
  immediately; plain drift only alerts once it **persists past `DRIFT_THRESHOLD_SEC`** (default **26h** — above a normal
  daily sync gap, so a routine push→deploy delay never false-alarms). Re-alerts are throttled to once/day, and a
  recovery sends an all-clear.

Pick a long, unguessable `NTFY_TOPIC` — it's the alert channel (anyone who knows it can read and send your alerts) — and
subscribe to it in the ntfy phone app. Config is written mode-600 to `~/.config/mantra/health.env`; the check itself is
**observe-only** (it never resets or pulls — that stays the daily sync's job). The installer ends with a test push so
you can confirm your phone is subscribed.

**Testing by hand — go through systemd, not a bare command.** `mantra-health` reads `NTFY_TOPIC` from systemd's
`EnvironmentFile`, so running it straight from a shell (`mantra-health --onfailure`) finds no topic and safely no-ops
with `NTFY_TOPIC unset — would alert…` instead of pushing. To actually send a test, run it as a unit —
`sudo systemctl start mantra-health-alert.service` (instant path) or `sudo systemctl start mantra-health.service`
(scheduled check) — or source the env first: `set -a; . ~/.config/mantra/health.env; set +a; mantra-health --test`.
Confirm delivery independent of your phone by opening `https://ntfy.sh/<your-topic>` in a browser — sent messages show
in the topic history.

## Releases (semantic-release)

On every push to `main`, `release.yml` runs [semantic-release](https://semantic-release.gitbook.io/). Commit messages
drive the version bump:

| Commit prefix                                                 | Bump  | Example                                    |
|---------------------------------------------------------------|-------|--------------------------------------------|
| `fix:`                                                        | patch | `fix: handle empty mantras.json`           |
| `feat:`                                                       | minor | `feat: add auto-rotate control`            |
| `feat!:` or `BREAKING CHANGE:` footer                         | major | `feat!: drop support for the /v1 endpoint` |
| `chore:` / `docs:` / `test:` / `refactor:` / `ci:` / `build:` | —     | no release                                 |

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