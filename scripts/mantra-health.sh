#!/usr/bin/env bash
# =============================================================================
# Mantra Health — sync-divergence monitor for the kiosk
#
# Answers one question the dashboards couldn't on 2026-06-17: "is the mantras
# list this Pi is showing actually current?" On that day mantra-sync had been
# failing for HOURS (corrupted clone -> `fatal: bad object HEAD`) while both
# mantra-app.service and the timer still reported `active`. Nothing surfaced it.
# This turns that silent drift into an ntfy.sh push so it's caught in hours, not
# whenever a human next happens to SSH in.
#
# Observe-only: it NEVER writes the working tree (no reset/pull). The daily
# mantra-sync.service owns deploying; this only fetches + compares + alerts.
#
# Two failure classes, two cadences:
#   HARD  (sync unit failed, clone missing/corrupt, fetch fails)
#         -> alert immediately. This is the exact 2026-06-17 mode.
#   SOFT  (clone healthy, just behind origin)
#         -> normal between a push and the next daily sync. Only alert once it
#            has PERSISTED past DRIFT_THRESHOLD_SEC, so a routine daily gap never
#            false-alarms. (Threshold must exceed the sync period — see below.)
#
# Usage (normally invoked by systemd, not by hand):
#   mantra-health                # the scheduled check
#   mantra-health --onfailure    # OnFailure= target: sync just failed, alert now
#   mantra-health --test         # send a "setup OK" ping to prove the topic works
#
# Config comes from the environment (the installer writes an EnvironmentFile):
#   NTFY_TOPIC          - REQUIRED. ntfy.sh topic to publish to. Treat as a
#                         secret: anyone with it can read/send your alerts.
#   NTFY_SERVER         - ntfy base URL (default: https://ntfy.sh)
#   DATA_DIR            - the Pi's mantra data-repo clone (default: ~/mantra)
#   BRANCH              - branch the deploy tracks (default: main)
#   SYNC_UNIT           - the sync service to watch (default: mantra-sync.service)
#   DRIFT_THRESHOLD_SEC - how long SOFT drift must persist before alerting.
#                         MUST exceed the sync period or every normal push trips
#                         it: with a DAILY sync, legitimate drift can be ~24h, so
#                         the default is 26h (93600s), comfortably above a day +
#                         the timer's RandomizedDelaySec.
#   RE_ALERT_SEC        - while a problem persists, re-alert at most this often
#                         (default: 86400 = once/day) so the phone isn't nagged.
#   STATE_DIR           - where first-divergence / last-alert markers live
#                         (default: ~/.local/state/mantra-health)
# =============================================================================
set -euo pipefail

NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
DATA_DIR="${DATA_DIR:-${HOME}/mantra}"
BRANCH="${BRANCH:-main}"
SYNC_UNIT="${SYNC_UNIT:-mantra-sync.service}"
DRIFT_THRESHOLD_SEC="${DRIFT_THRESHOLD_SEC:-93600}"   # 26h — above a daily gap
RE_ALERT_SEC="${RE_ALERT_SEC:-86400}"                 # nag at most once/day
STATE_DIR="${STATE_DIR:-${HOME}/.local/state/mantra-health}"

FIRST_DIVERGENCE_FILE="${STATE_DIR}/first-divergence"
LAST_ALERT_FILE="${STATE_DIR}/last-alert"
HOST_TAG="$(hostname 2>/dev/null || echo pi)"
NOW="$(date +%s)"

mkdir -p "${STATE_DIR}"

# --- ntfy push --------------------------------------------------------------
# $1=title  $2=priority(default|high|urgent)  $3=tags(csv)  $4=body
publish() {
    local title="$1" priority="$2" tags="$3" body="$4"
    if [[ -z "${NTFY_TOPIC}" ]]; then
        echo "[mantra-health] NTFY_TOPIC unset — would alert: ${title} :: ${body}" >&2
        return 0
    fi
    curl -fsS --max-time 15 \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -H "Tags: ${tags}" \
        -d "${body}" \
        "${NTFY_SERVER}/${NTFY_TOPIC}" >/dev/null \
        || echo "[mantra-health] ntfy publish to ${NTFY_SERVER} failed" >&2
}

# Last few sync-unit journal lines, best-effort, for an actionable alert body.
sync_journal_tail() {
    journalctl -u "${SYNC_UNIT}" -n 4 --no-pager -o cat 2>/dev/null | tr '\n' ' ' || true
}

# Re-alert throttle: true if we may alert now (never alerted, or RE_ALERT_SEC elapsed).
may_alert() {
    [[ -f "${LAST_ALERT_FILE}" ]] || return 0
    local last; last="$(cat "${LAST_ALERT_FILE}" 2>/dev/null || echo 0)"
    (( NOW - last >= RE_ALERT_SEC ))
}

mark_alerted() { echo "${NOW}" > "${LAST_ALERT_FILE}"; }

# --- flag handling ----------------------------------------------------------
case "${1:-}" in
    --test)
        publish "Mantra kiosk: health monitor armed" default "white_check_mark,satellite" \
            "mantra-health is installed on ${HOST_TAG}. If sync ever drifts, this is where you'll hear about it."
        echo "[mantra-health] test ping sent to ${NTFY_SERVER}/${NTFY_TOPIC}"
        exit 0
        ;;
    --onfailure)
        # Instant path: mantra-sync.service just failed (OnFailure= target).
        # Bypass the throttle — an explicit unit failure is always worth a push.
        publish "Mantra kiosk: SYNC FAILED" urgent "rotating_light,satellite" \
            "${SYNC_UNIT} failed on ${HOST_TAG}. The display will go stale until it's fixed. Last log: $(sync_journal_tail)"
        mark_alerted
        echo "[mantra-health] OnFailure alert sent for ${SYNC_UNIT}"
        exit 0
        ;;
esac

# --- 1. classify state ------------------------------------------------------
hard_problem=""
soft_diverged=0
detail=""

if systemctl is-failed --quiet "${SYNC_UNIT}"; then
    hard_problem+="${SYNC_UNIT} is in a failed state. "
fi

if [[ ! -d "${DATA_DIR}/.git" ]]; then
    hard_problem+="${DATA_DIR} is not a git repo (clone missing or corrupted). "
elif ! git -C "${DATA_DIR}" fetch --quiet origin "${BRANCH}" 2>/dev/null; then
    hard_problem+="git fetch failed in ${DATA_DIR} (network, auth, or corrupted clone). "
else
    local_head="$(git -C "${DATA_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
    remote_head="$(git -C "${DATA_DIR}" rev-parse "origin/${BRANCH}" 2>/dev/null || echo unknown)"
    if [[ "${local_head}" != "${remote_head}" ]]; then
        soft_diverged=1
        detail="HEAD ${local_head:0:7} != origin/${BRANCH} ${remote_head:0:7}"
    fi
fi

# --- 2. act -----------------------------------------------------------------
if [[ -n "${hard_problem}" ]]; then
    # Keep the divergence clock running too, but a hard fault alerts now.
    [[ -f "${FIRST_DIVERGENCE_FILE}" ]] || echo "${NOW}" > "${FIRST_DIVERGENCE_FILE}"
    if may_alert; then
        publish "Mantra kiosk: sync UNHEALTHY" high "warning,satellite" \
            "On ${HOST_TAG}: ${hard_problem}Last log: $(sync_journal_tail)"
        mark_alerted
        echo "[mantra-health] HARD problem — alerted: ${hard_problem}"
    else
        echo "[mantra-health] HARD problem (within re-alert window, holding): ${hard_problem}"
    fi
    exit 0
fi

if (( soft_diverged )); then
    if [[ -f "${FIRST_DIVERGENCE_FILE}" ]]; then
        first="$(cat "${FIRST_DIVERGENCE_FILE}" 2>/dev/null || echo "${NOW}")"
    else
        first="${NOW}"; echo "${NOW}" > "${FIRST_DIVERGENCE_FILE}"
    fi
    age=$(( NOW - first ))
    if (( age >= DRIFT_THRESHOLD_SEC )) && may_alert; then
        hrs=$(( age / 3600 ))
        publish "Mantra kiosk: drift ${hrs}h" high "warning,satellite" \
            "On ${HOST_TAG}: deployed list behind origin for ${hrs}h. ${detail}. mantra-sync may be stuck (it shows active but isn't catching up)."
        mark_alerted
        echo "[mantra-health] SOFT drift ${age}s >= threshold — alerted. ${detail}"
    else
        echo "[mantra-health] SOFT drift ${age}s < ${DRIFT_THRESHOLD_SEC}s (or throttled) — normal daily gap, holding. ${detail}"
    fi
    exit 0
fi

# --- 3. healthy: clear clocks, and close the loop if we'd alerted -----------
if [[ -f "${LAST_ALERT_FILE}" ]]; then
    publish "Mantra kiosk: back in sync" default "white_check_mark,satellite" \
        "${HOST_TAG} caught up — HEAD == origin/${BRANCH}. Drift cleared."
    echo "[mantra-health] recovered — sent all-clear"
fi
rm -f "${FIRST_DIVERGENCE_FILE}" "${LAST_ALERT_FILE}"
echo "[mantra-health] healthy — HEAD == origin/${BRANCH}"