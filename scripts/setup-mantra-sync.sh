#!/usr/bin/env bash
# =============================================================================
# Mantra Sync — daily git pull of the personal mantras list onto the kiosk
#
# Wires up the "elegant" deploy path so editing the j1v37u2k3y/mantra data repo
# reaches the Pi display on its own:
#
#   1. Clones (or updates) the mantra DATA repo on the Pi.
#   2. Symlinks ~/.config/mantra/mantras.json -> <data repo>/mantras.json, so a
#      pull updates the exact file the server reads. (Real file is backed up.)
#   3. Installs a systemd timer that does `git fetch && git reset --hard` daily.
#
# No service restart in the loop: server.js hot-reloads mantras.json via
# fs.watchFile, so the symlinked file changing is the whole deploy. (This setup
# does ONE restart at the end to catch the initial symlink swap.)
#
# Run on the Pi via SSH:
#   chmod +x scripts/setup-mantra-sync.sh
#   sudo ./scripts/setup-mantra-sync.sh
#
#   # private data repo (token never touches git, stored 600 on the Pi):
#   sudo MANTRA_GIT_TOKEN=github_pat_xxx ./scripts/setup-mantra-sync.sh
#
# Environment variable overrides:
#   DATA_DIR          - where the data repo lives (default: ~<user>/mantra)
#   DATA_REPO         - data repo URL (default: j1v37u2k3y/mantra)
#   BRANCH            - branch to track (default: main)
#   SYNC_ON_CALENDAR  - systemd OnCalendar expr (default: daily = 00:00)
#   APP_SERVICE       - app service to bump once at setup (default: mantra-app)
#   MANTRA_GIT_TOKEN  - PAT for a PRIVATE data repo; enables headless auth.
#                       Stored mode-600 at CRED_FILE, never committed. Use a
#                       fine-grained token: Contents=read-only on the data repo.
#   GIT_USERNAME      - username paired with the token (default: repo owner)
#   CRED_FILE         - token store path (default: ~<user>/.config/mantra/git-credentials)
# =============================================================================
set -euo pipefail

DATA_REPO="${DATA_REPO:-https://github.com/j1v37u2k3y/mantra.git}"
BRANCH="${BRANCH:-main}"
SYNC_ON_CALENDAR="${SYNC_ON_CALENDAR:-daily}"
APP_SERVICE="${APP_SERVICE:-mantra-app}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "Run with sudo: sudo ./scripts/setup-mantra-sync.sh"

REAL_USER="${SUDO_USER:-pi}"
REAL_HOME=$(eval echo "~${REAL_USER}")
DATA_DIR="${DATA_DIR:-${REAL_HOME}/mantra}"
CONFIG_DIR="${REAL_HOME}/.config/mantra"
CONFIG_FILE="${CONFIG_DIR}/mantras.json"
TARGET_FILE="${DATA_DIR}/mantras.json"
CRED_FILE="${CRED_FILE:-${CONFIG_DIR}/git-credentials}"
GIT_USERNAME="${GIT_USERNAME:-$(printf '%s' "${DATA_REPO}" | sed -E 's#.*github\.com[:/]([^/]+)/.*#\1#')}"
MANTRA_GIT_TOKEN="${MANTRA_GIT_TOKEN:-}"

GIT_BIN="$(command -v git || true)"

echo ""
echo "==========================================="
echo "  Mantra Sync — daily git deploy"
echo "==========================================="
echo ""
info "User:        ${REAL_USER}"
info "Data repo:   ${DATA_REPO} (${BRANCH})"
info "Data dir:    ${DATA_DIR}"
info "Config file: ${CONFIG_FILE} -> ${TARGET_FILE}"
info "Schedule:    ${SYNC_ON_CALENDAR}"
echo ""

# =============================================================================
# 1. Ensure git
# =============================================================================
if [[ -z "${GIT_BIN}" ]]; then
    info "Installing git..."
    apt -y install git
    GIT_BIN="$(command -v git)"
fi
log "git: ${GIT_BIN}"

# =============================================================================
# 2. Optional: store a PAT so the headless service can fetch a private repo
# =============================================================================
GIT_CRED_OPT=()
if [[ -n "${MANTRA_GIT_TOKEN}" ]]; then
    info "Storing git credentials for private repo access (user: ${GIT_USERNAME})..."
    sudo -u "${REAL_USER}" mkdir -p "${CONFIG_DIR}"
    sudo -u "${REAL_USER}" install -m 600 /dev/null "${CRED_FILE}"
    printf 'https://%s:%s@github.com\n' "${GIT_USERNAME}" "${MANTRA_GIT_TOKEN}" \
        | sudo -u "${REAL_USER}" tee "${CRED_FILE}" >/dev/null
    GIT_CRED_OPT=(-c "credential.helper=store --file=${CRED_FILE}")
    log "Credential file: ${CRED_FILE} (mode 600, owner ${REAL_USER})"
else
    warn "No MANTRA_GIT_TOKEN set — assuming a public repo or cached credentials."
fi

# =============================================================================
# 3. Clone or update the data repo (as the real user)
# =============================================================================
if [[ -d "${DATA_DIR}/.git" ]]; then
    info "Data repo exists, fetching + resetting to origin/${BRANCH}..."
    sudo -u "${REAL_USER}" "${GIT_BIN}" "${GIT_CRED_OPT[@]}" -C "${DATA_DIR}" fetch --prune origin
    sudo -u "${REAL_USER}" "${GIT_BIN}" -C "${DATA_DIR}" reset --hard "origin/${BRANCH}"
else
    info "Cloning data repo..."
    sudo -u "${REAL_USER}" "${GIT_BIN}" "${GIT_CRED_OPT[@]}" clone --branch "${BRANCH}" "${DATA_REPO}" "${DATA_DIR}"
fi
[[ -f "${TARGET_FILE}" ]] || err "Expected ${TARGET_FILE} after clone, not found"
# Persist the helper into the repo-local config so the headless timer fetch
# (plain `git fetch`, no -c) authenticates the same way.
if [[ -n "${MANTRA_GIT_TOKEN}" ]]; then
    sudo -u "${REAL_USER}" "${GIT_BIN}" -C "${DATA_DIR}" config credential.helper "store --file=${CRED_FILE}"
fi
ENTRIES="$(sudo -u "${REAL_USER}" python3 -c "import json;print(len(json.load(open('${TARGET_FILE}'))))" 2>/dev/null || echo '?')"
log "Data repo ready (${ENTRIES} entries)"

# =============================================================================
# 4. Symlink the config file at the repo's mantras.json (back up a real file)
# =============================================================================
sudo -u "${REAL_USER}" mkdir -p "${CONFIG_DIR}"
if [[ -L "${CONFIG_FILE}" ]]; then
    info "Config file is already a symlink; re-pointing it."
elif [[ -e "${CONFIG_FILE}" ]]; then
    BACKUP="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    mv "${CONFIG_FILE}" "${BACKUP}"
    chown "${REAL_USER}:${REAL_USER}" "${BACKUP}"
    warn "Backed up real mantras.json -> ${BACKUP}"
fi
sudo -u "${REAL_USER}" ln -sfn "${TARGET_FILE}" "${CONFIG_FILE}"
log "Symlinked ${CONFIG_FILE} -> ${TARGET_FILE}"

# =============================================================================
# 5. Install the sync service + timer
# =============================================================================
info "Writing /etc/systemd/system/mantra-sync.service..."
cat > /etc/systemd/system/mantra-sync.service << EOF
[Unit]
Description=Sync personal mantras from git (j1v37u2k3y/mantra)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${REAL_USER}
WorkingDirectory=${DATA_DIR}
# fetch must succeed before reset runs; a failed fetch fails the unit loudly
# (journalctl -u mantra-sync) rather than silently resetting to a stale ref.
ExecStart=${GIT_BIN} fetch --prune origin
ExecStart=${GIT_BIN} reset --hard origin/${BRANCH}
EOF

info "Writing /etc/systemd/system/mantra-sync.timer..."
cat > /etc/systemd/system/mantra-sync.timer << EOF
[Unit]
Description=Daily sync of personal mantras from git

[Timer]
OnCalendar=${SYNC_ON_CALENDAR}
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now mantra-sync.timer
log "mantra-sync.timer enabled (${SYNC_ON_CALENDAR})"

# =============================================================================
# 6. Run once now + bump the app once to catch the symlink swap
# =============================================================================
info "Running an initial sync..."
systemctl start mantra-sync.service
systemctl --no-pager status mantra-sync.service || true

if systemctl list-unit-files | grep -q "^${APP_SERVICE}.service"; then
    info "Restarting ${APP_SERVICE} once to pick up the new symlink..."
    systemctl restart "${APP_SERVICE}.service"
    log "${APP_SERVICE} restarted (subsequent syncs hot-reload — no restart needed)"
else
    warn "${APP_SERVICE}.service not found; skipping restart. Server hot-reload picks up changes if running."
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo "==========================================="
echo "  Mantra Sync configured"
echo "==========================================="
echo ""
log "Edit the list:   push to ${DATA_REPO} (${BRANCH})"
log "It lands:        within 24h via mantra-sync.timer, no restart"
echo ""
info "Useful commands:"
echo "  systemctl list-timers mantra-sync       # next scheduled run"
echo "  systemctl start mantra-sync             # sync right now"
echo "  journalctl -u mantra-sync               # sync history / failures"
echo "  journalctl -u ${APP_SERVICE} -f         # watch the hot-reload fire"
echo ""