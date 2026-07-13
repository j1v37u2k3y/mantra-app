#!/usr/bin/env bash
# =============================================================================
# Mantra Health Setup — installs the sync-divergence monitor on the kiosk
#
# Companion to scripts/setup-mantra-sync.sh. Where that wires the deploy IN,
# this wires the watchdog ON TOP so a broken deploy can't sit silent (the
# 2026-06-17 failure: sync down for hours, every dashboard green). Installs:
#
#   1. /usr/local/bin/mantra-health           (the check + ntfy alert logic)
#      /usr/local/bin/mantra-notify-update    (positive "new mantras landed" ping)
#   2. mantra-health.service  (oneshot)        the scheduled check
#      mantra-health.timer    (every ~6h)      runs it, Persistent=true
#   3. mantra-health-alert.service (oneshot)    the instant path
#   4. mantra-sync drop-ins (non-destructive — the sync unit itself is untouched):
#      10-onfailure.conf      OnFailure=mantra-health-alert.service (failed sync → alert)
#      20-notify-update.conf  ExecStartPost + EnvironmentFile       (changed mantras.json → ping)
#
# Run on the Pi via SSH (NTFY_TOPIC is required — it's the whole alert channel):
#   chmod +x scripts/setup-mantra-health.sh
#   sudo NTFY_TOPIC=mantra-pi-7h3k9x ./scripts/setup-mantra-health.sh
#
# Pick a long, unguessable topic: anyone who knows it can read AND send your
# alerts. Subscribe on your phone with the ntfy app (https://ntfy.sh/app) to the
# same topic. The check cadence (every 6h) is how often we LOOK; the alert
# threshold (drift > 26h) is how long real drift must persist — that split is
# what keeps a normal daily sync gap from false-alarming. See mantra-health.sh.
#
# Environment variable overrides:
#   NTFY_TOPIC           - REQUIRED. ntfy.sh topic to publish alerts to.
#   NTFY_SERVER          - ntfy base URL (default: https://ntfy.sh)
#   DATA_DIR             - the Pi's data-repo clone (default: ~<user>/mantra)
#   BRANCH               - branch the deploy tracks (default: main)
#   SYNC_UNIT            - sync service to watch (default: mantra-sync.service)
#   DRIFT_THRESHOLD_SEC  - persist-before-alert for soft drift (default: 93600 = 26h)
#   RE_ALERT_SEC         - re-alert throttle while broken (default: 86400 = 1/day)
#   HEALTH_ON_CALENDAR   - systemd OnCalendar for the check (default: every 6h at :15)
#   STATE_DIR            - state markers dir (default: ~<user>/.local/state/mantra-health)
#   SKIP_TEST_PING       - set to 1 to skip the end-of-setup phone ping
# =============================================================================
set -euo pipefail

NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
BRANCH="${BRANCH:-main}"
SYNC_UNIT="${SYNC_UNIT:-mantra-sync.service}"
DRIFT_THRESHOLD_SEC="${DRIFT_THRESHOLD_SEC:-93600}"
RE_ALERT_SEC="${RE_ALERT_SEC:-86400}"
# 00:15, 06:15, 12:15, 18:15 — offset past the 00:00 sync (+ its RandomizedDelaySec)
# so a healthy midnight deploy has settled before the first check looks.
HEALTH_ON_CALENDAR="${HEALTH_ON_CALENDAR:-*-*-* 00/6:15:00}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "Run with sudo: sudo NTFY_TOPIC=... ./scripts/setup-mantra-health.sh"
[[ -z "${NTFY_TOPIC}" ]] && err "NTFY_TOPIC is required (the alert channel). e.g. sudo NTFY_TOPIC=mantra-pi-7h3k9x ./scripts/setup-mantra-health.sh"

REAL_USER="${SUDO_USER:-pi}"
REAL_HOME=$(eval echo "~${REAL_USER}")
DATA_DIR="${DATA_DIR:-${REAL_HOME}/mantra}"
STATE_DIR="${STATE_DIR:-${REAL_HOME}/.local/state/mantra-health}"
CONFIG_DIR="${REAL_HOME}/.config/mantra"
HEALTH_ENV="${CONFIG_DIR}/health.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_SRC="${SCRIPT_DIR}/mantra-health.sh"
HEALTH_BIN="/usr/local/bin/mantra-health"
NOTIFY_SRC="${SCRIPT_DIR}/mantra-notify-update.sh"
NOTIFY_BIN="/usr/local/bin/mantra-notify-update"

[[ -f "${HEALTH_SRC}" ]] || err "Expected ${HEALTH_SRC} next to this installer, not found"
[[ -f "${NOTIFY_SRC}" ]] || err "Expected ${NOTIFY_SRC} next to this installer, not found"

echo ""
echo "==========================================="
echo "  Mantra Health — sync-divergence monitor"
echo "==========================================="
echo ""
info "User:        ${REAL_USER}"
info "Data dir:    ${DATA_DIR} (${BRANCH})"
info "Watching:    ${SYNC_UNIT}"
info "Alerts:      ${NTFY_SERVER}/${NTFY_TOPIC}"
info "Check every: ${HEALTH_ON_CALENDAR}"
info "Alert after: drift persists > $(( DRIFT_THRESHOLD_SEC / 3600 ))h"
echo ""

# =============================================================================
# 1. Install the check script
# =============================================================================
install -m 0755 "${HEALTH_SRC}" "${HEALTH_BIN}"
log "Installed ${HEALTH_BIN}"
install -m 0755 "${NOTIFY_SRC}" "${NOTIFY_BIN}"
log "Installed ${NOTIFY_BIN}"

# =============================================================================
# 2. Write the config EnvironmentFile (600 — NTFY_TOPIC is a capability)
# =============================================================================
sudo -u "${REAL_USER}" mkdir -p "${CONFIG_DIR}" "${STATE_DIR}"
cat > "${HEALTH_ENV}" << EOF
# mantra-health config — written by setup-mantra-health.sh. Mode 600.
# The topic is a secret: anyone with it can read AND send your alerts.
NTFY_SERVER=${NTFY_SERVER}
NTFY_TOPIC=${NTFY_TOPIC}
DATA_DIR=${DATA_DIR}
BRANCH=${BRANCH}
SYNC_UNIT=${SYNC_UNIT}
DRIFT_THRESHOLD_SEC=${DRIFT_THRESHOLD_SEC}
RE_ALERT_SEC=${RE_ALERT_SEC}
STATE_DIR=${STATE_DIR}
EOF
chown "${REAL_USER}:${REAL_USER}" "${HEALTH_ENV}"
chmod 600 "${HEALTH_ENV}"
log "Wrote ${HEALTH_ENV} (mode 600, owner ${REAL_USER})"

# =============================================================================
# 3. Install the check service + timer + the OnFailure alert service
# =============================================================================
info "Writing /etc/systemd/system/mantra-health.service..."
cat > /etc/systemd/system/mantra-health.service << EOF
[Unit]
Description=Mantra kiosk sync-divergence check (alerts via ntfy on drift)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${REAL_USER}
EnvironmentFile=${HEALTH_ENV}
ExecStart=${HEALTH_BIN}
EOF

info "Writing /etc/systemd/system/mantra-health.timer..."
cat > /etc/systemd/system/mantra-health.timer << EOF
[Unit]
Description=Periodic mantra kiosk sync-divergence check

[Timer]
OnCalendar=${HEALTH_ON_CALENDAR}
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
EOF

info "Writing /etc/systemd/system/mantra-health-alert.service..."
cat > /etc/systemd/system/mantra-health-alert.service << EOF
[Unit]
Description=Mantra kiosk instant alert (OnFailure target for ${SYNC_UNIT})

[Service]
Type=oneshot
User=${REAL_USER}
EnvironmentFile=${HEALTH_ENV}
ExecStart=${HEALTH_BIN} --onfailure
EOF

# =============================================================================
# 4. Wire the instant path: mantra-sync OnFailure -> the alert service
#    Drop-in, not a rewrite — leaves setup-mantra-sync.sh's unit untouched.
# =============================================================================
if systemctl cat "${SYNC_UNIT}" >/dev/null 2>&1; then
    DROPIN_DIR="/etc/systemd/system/${SYNC_UNIT}.d"
    mkdir -p "${DROPIN_DIR}"
    cat > "${DROPIN_DIR}/10-onfailure.conf" << EOF
[Unit]
OnFailure=mantra-health-alert.service
EOF
    log "Wired ${SYNC_UNIT} OnFailure -> mantra-health-alert.service (drop-in)"

    # Positive path: after a successful sync, ping if mantras.json actually changed.
    # EnvironmentFile is additive here so the ExecStartPost inherits NTFY_TOPIC / DATA_DIR /
    # STATE_DIR from health.env — the sync unit itself has NO EnvironmentFile. Both the
    # ExecStartPost `-` and the EnvironmentFile `-` keep a notify hiccup (or a missing
    # health.env) from failing the sync and falsely tripping the OnFailure alert above.
    cat > "${DROPIN_DIR}/20-notify-update.conf" << EOF
[Service]
EnvironmentFile=-${HEALTH_ENV}
ExecStartPost=-${NOTIFY_BIN}
EOF
    log "Wired ${SYNC_UNIT} ExecStartPost -> ${NOTIFY_BIN} (drop-in)"

    # Seed the marker to the current blob so the first REAL change after install pings,
    # rather than the install-time state being mistaken for a change on the next sync.
    sudo -u "${REAL_USER}" \
        DATA_DIR="${DATA_DIR}" STATE_DIR="${STATE_DIR}" BRANCH="${BRANCH}" \
        "${NOTIFY_BIN}" --seed || warn "notify marker seed skipped (data repo not ready yet)"
else
    warn "${SYNC_UNIT} not found — skipping OnFailure + notify wiring. Run setup-mantra-sync.sh first."
fi

# =============================================================================
# 5. Enable the timer + run one check now
# =============================================================================
systemctl daemon-reload
systemctl enable --now mantra-health.timer
log "mantra-health.timer enabled (${HEALTH_ON_CALENDAR})"

info "Running an initial check..."
systemctl start mantra-health.service || true
systemctl --no-pager status mantra-health.service || true

# =============================================================================
# 6. Prove the channel end-to-end (so the operator sees it land on their phone)
# =============================================================================
if [[ "${SKIP_TEST_PING:-0}" != "1" ]]; then
    info "Sending a test push so you can confirm your phone is subscribed..."
    sudo -u "${REAL_USER}" \
        NTFY_SERVER="${NTFY_SERVER}" NTFY_TOPIC="${NTFY_TOPIC}" \
        "${HEALTH_BIN}" --test || warn "Test ping failed — check NTFY_TOPIC / network"
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo "==========================================="
echo "  Mantra Health configured"
echo "==========================================="
echo ""
log "Subscribe on your phone:  ntfy app -> add topic '${NTFY_TOPIC}'"
log "Instant path:             a failed ${SYNC_UNIT} pushes immediately"
log "Catch-all:                every 6h; alerts if drift persists > $(( DRIFT_THRESHOLD_SEC / 3600 ))h"
log "Update ping:              a changed mantras.json on sync pushes a 'new mantras live' note"
echo ""
info "Useful commands:"
echo "  systemctl list-timers mantra-health        # next scheduled check"
echo "  systemctl start mantra-health              # check right now"
echo "  journalctl -u mantra-health                # check history"
echo "  ${HEALTH_BIN} --test                       # re-send a test push (as ${REAL_USER}, with env set)"
echo ""