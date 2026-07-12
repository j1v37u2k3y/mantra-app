#!/usr/bin/env bash
# =============================================================================
# Mantra Notify-Update — positive "new mantras landed" ntfy ping
#
# The good-news counterpart to mantra-health.sh. Where mantra-health alerts on
# PROBLEMS (sync failed, drift), this fires when the daily mantra-sync actually
# pulls a CHANGED mantras.json onto the kiosk — pushing a notification that
# names what was added AND removed. Silent on no-op syncs and on commits that
# don't touch mantras.json (it compares the file's git BLOB hash, not commits).
#
# Wired as `ExecStartPost=-/usr/local/bin/mantra-notify-update` on
# mantra-sync.service via a drop-in (installed by setup-mantra-health.sh). The
# leading `-` (and `EnvironmentFile=-…`) mean a notify hiccup NEVER fails the
# sync unit — which would otherwise falsely trip mantra-health's OnFailure alert.
#
# Observe-only: reads the git blob + a state marker and pushes. Never writes the
# working tree. Runs AFTER mantra-sync's fetch+reset, so HEAD is already at
# origin/BRANCH when the blob is read; the persisted marker carries the "before".
#
# Usage:
#   mantra-notify-update            # compare blob vs marker; ping if changed
#   mantra-notify-update --seed     # record the current blob, stay silent
#                                     (installer uses this so the first REAL
#                                     change after install pings, not the seed)
#
# Config — the SAME EnvironmentFile as mantra-health (~/.config/mantra/health.env):
#   NTFY_TOPIC   - REQUIRED to actually push (secret: read/send capability).
#   NTFY_SERVER  - ntfy base URL (default: https://ntfy.sh)
#   DATA_DIR     - the Pi's data-repo clone (default: ~/mantra)
#   BRANCH       - branch the deploy tracks (default: main)
#   STATE_DIR    - marker dir (default: ~/.local/state/mantra-health)
#   MANTRA_JSON  - data file, repo-relative (default: mantras.json)
# =============================================================================
set -euo pipefail

NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
DATA_DIR="${DATA_DIR:-${HOME}/mantra}"
BRANCH="${BRANCH:-main}"
STATE_DIR="${STATE_DIR:-${HOME}/.local/state/mantra-health}"
MANTRA_JSON="${MANTRA_JSON:-mantras.json}"

MARKER="${STATE_DIR}/last-notified-blob"
HOST_TAG="$(hostname 2>/dev/null || echo pi)"
MAX_LINES=10

mkdir -p "${STATE_DIR}"
log() { echo "[mantra-notify-update] $*"; }

# Blob hash of the data file at the current (already fetch+reset) HEAD.
blob="$(git -C "${DATA_DIR}" rev-parse "HEAD:${MANTRA_JSON}" 2>/dev/null || true)"
if [[ -z "${blob}" ]]; then
    log "cannot read ${MANTRA_JSON} blob in ${DATA_DIR} (missing / not a repo) — nothing to do"
    exit 0
fi

# --seed: record current state, no ping (installer path so the first real change pings).
if [[ "${1:-}" == "--seed" ]]; then
    echo "${blob}" > "${MARKER}"
    log "seeded marker at ${blob:0:12} (no ping)"
    exit 0
fi

# First run with no marker: seed silently rather than ping on a phantom "change".
if [[ ! -f "${MARKER}" ]]; then
    echo "${blob}" > "${MARKER}"
    log "no marker yet — seeded at ${blob:0:12}, staying silent"
    exit 0
fi

last="$(cat "${MARKER}" 2>/dev/null || echo "")"
if [[ "${blob}" == "${last}" ]]; then
    log "mantras.json unchanged (${blob:0:12}) — no ping"
    exit 0
fi

# --- changed: pull the added (+) / removed (-) mantra lines from the blob diff.
# Diff the two blob objects directly; strip the sign, indentation, and trailing
# comma so the body reads as clean mantra text. `|| true` keeps `set -e` happy
# when a side has zero matching lines.
changed_lines() {  # $1 = "+" or "-" — emits the changed mantra strings, quoted
    local sign="$1"
    git -C "${DATA_DIR}" diff --no-color "${last}" "${blob}" 2>/dev/null \
        | grep -E "^\\${sign}" \
        | grep -vE "^(\\+\\+\\+|---)" \
        | sed -E "s/^.//; s/^[[:space:]]*//; s/[[:space:]]*,?[[:space:]]*$//" \
        | grep -E '^"'                      # keep only JSON string entries; drop [ ] and blanks
}
added="$(changed_lines '+' || true)"
removed="$(changed_lines '-' || true)"
# Cancel lines present on BOTH sides — a mantra that merely shifted array position is
# line-diff noise, not a genuine add/remove. What survives is what actually changed.
only_in() {  # emit lines of $1 that are NOT exactly present in $2
    [[ -z "$1" ]] && return 0
    grep -vxF -f <(printf '%s\n' "$2") <<< "$1" || true
}
added_only="$(only_in "${added}" "${removed}")"
removed_only="$(only_in "${removed}" "${added}")"

count="$(python3 -c "import json;print(len(json.load(open('${DATA_DIR}/${MANTRA_JSON}'))))" 2>/dev/null || echo "")"

if [[ -n "${count}" ]]; then
    body="${count} mantras now live on ${HOST_TAG}."
else
    body="mantras.json updated on ${HOST_TAG}."
fi

append_block() {  # $1 = prefix ("+"/"-")  $2 = lines
    local prefix="$1" lines="$2" n shown
    [[ -z "${lines}" ]] && return 0
    n="$(printf '%s\n' "${lines}" | grep -c .)"
    shown="$(printf '%s\n' "${lines}" | head -n "${MAX_LINES}" | sed "s/^/${prefix} /")"
    body+=$'\n'"${shown}"
    if (( n > MAX_LINES )); then
        body+=$'\n'"…and $(( n - MAX_LINES )) more ${prefix}"
    fi
    return 0   # never leak the arithmetic test's exit status (set -e would kill us)
}
append_block "+" "${added_only}"
append_block "-" "${removed_only}"

# --- publish; advance the marker ONLY on a successful push (retry-friendly) ---
if [[ -z "${NTFY_TOPIC}" ]]; then
    log "NTFY_TOPIC unset — would ping: ${body//$'\n'/ | }"
    echo "${blob}" > "${MARKER}"   # no channel to deliver to; don't re-check forever
    exit 0
fi

if curl -fsS --max-time 15 \
        -H "Title: Mantra kiosk: mantras updated" \
        -H "Priority: default" \
        -H "Tags: sparkles,satellite" \
        --data-binary "${body}" \
        "${NTFY_SERVER}/${NTFY_TOPIC}" >/dev/null; then
    echo "${blob}" > "${MARKER}"
    log "pinged + marker advanced to ${blob:0:12}"
else
    log "ntfy publish to ${NTFY_SERVER} failed — marker held, will retry next sync"
fi

exit 0