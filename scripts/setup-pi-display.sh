#!/usr/bin/env bash
# =============================================================================
# Raspberry Pi 4 + 3.5" XPT2046 Display — Mantra App Kiosk Setup
# Based on: research/raspberry-pi-4-3.5inch-display-setup.md
#
# Run on the Pi via SSH:
#   chmod +x scripts/setup-pi-display.sh
#   sudo ./scripts/setup-pi-display.sh
#
# Environment variable overrides:
#   TOUCH_FIX        - "invxy" (default), "swapxy", or "none"
#   DISPLAY_ROTATE   - 0 (default), 90, 180, 270
#   APP_PORT         - Mantra app port (default: 3174)
#   NODE_VERSION     - Node.js major version (default: 20)
# =============================================================================
set -euo pipefail

TOUCH_FIX="${TOUCH_FIX:-invxy}"
DISPLAY_ROTATE="${DISPLAY_ROTATE:-0}"
APP_PORT="${APP_PORT:-5174}"
NODE_VERSION="${NODE_VERSION:-20}"
APP_DIR="/home/${SUDO_USER:-pi}/mantra-app"
KIOSK_URL="http://localhost:${APP_PORT}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "Run with sudo: sudo ./setup-pi-display.sh"

REAL_USER="${SUDO_USER:-pi}"
REAL_HOME=$(eval echo "~${REAL_USER}")

echo ""
echo "==========================================="
echo "  Mantra App — Pi Kiosk Setup"
echo "==========================================="
echo ""
info "User:           ${REAL_USER}"
info "App directory:  ${APP_DIR}"
info "Kiosk URL:      ${KIOSK_URL}"
info "Touch fix:      ${TOUCH_FIX}"
info "Rotation:       ${DISPLAY_ROTATE}"
echo ""

# =============================================================================
# 1. System Update
# =============================================================================
info "Updating system packages..."
apt update && apt -y full-upgrade
log "System updated"

# =============================================================================
# 2. Enable SPI (required for XPT2046 touch controller)
# =============================================================================
info "Enabling SPI interface..."
raspi-config nonint do_spi 0
log "SPI enabled"

# =============================================================================
# 3. Configure 3.5" Display Driver (dtoverlay method — Bookworm)
# =============================================================================
CONFIG_FILE="/boot/firmware/config.txt"
[[ ! -f "$CONFIG_FILE" ]] && CONFIG_FILE="/boot/config.txt"
[[ ! -f "$CONFIG_FILE" ]] && err "Could not find config.txt"

info "Configuring display driver in ${CONFIG_FILE}..."

OVERLAY_LINE="dtoverlay=piscreen,drm,speed=18000000"
case "${TOUCH_FIX}" in
    invxy)  OVERLAY_LINE="${OVERLAY_LINE},invx,invy" ;;
    swapxy) OVERLAY_LINE="${OVERLAY_LINE},swapxy" ;;
    none)   ;;
    *)      warn "Unknown TOUCH_FIX='${TOUCH_FIX}', skipping" ;;
esac
[[ "${DISPLAY_ROTATE}" != "0" ]] && OVERLAY_LINE="${OVERLAY_LINE},rotate=${DISPLAY_ROTATE}"

# Remove existing piscreen line if present
sed -i '/dtoverlay=piscreen/d' "$CONFIG_FILE"

echo "" >> "$CONFIG_FILE"
echo "# 3.5\" XPT2046 TFT Display" >> "$CONFIG_FILE"
echo "${OVERLAY_LINE}" >> "$CONFIG_FILE"
log "Display overlay: ${OVERLAY_LINE}"

# =============================================================================
# 4. Install Node.js
# =============================================================================
info "Installing Node.js ${NODE_VERSION}.x..."
if command -v node &>/dev/null; then
    CURRENT_NODE=$(node --version)
    info "Node.js already installed: ${CURRENT_NODE}"
    # Check if it's the right major version
    if [[ "${CURRENT_NODE}" != v${NODE_VERSION}.* ]]; then
        warn "Expected Node ${NODE_VERSION}.x, found ${CURRENT_NODE}. Reinstalling..."
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
        apt install -y nodejs
    fi
else
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
    apt install -y nodejs
fi
log "Node.js: $(node --version), npm: $(npm --version)"

# =============================================================================
# 5. Install Git & Clone Mantra App
# =============================================================================
apt -y install git
if [[ -d "${APP_DIR}" ]]; then
    info "Mantra app already exists at ${APP_DIR}, pulling latest..."
    sudo -u "${REAL_USER}" git -C "${APP_DIR}" pull || warn "Git pull failed, using existing code"
else
    info "Cloning mantra-app..."
    sudo -u "${REAL_USER}" git clone https://github.com/j1v37u2k3y/mantra-app.git "${APP_DIR}"
fi
log "Mantra app ready at ${APP_DIR}"

# =============================================================================
# 6. Install App Dependencies & Build
# =============================================================================
info "Installing npm dependencies and building..."
cd "${APP_DIR}"
sudo -u "${REAL_USER}" npm install
sudo -u "${REAL_USER}" npm run build
log "Mantra app built"

# =============================================================================
# 7. Create systemd Service for Mantra App
# =============================================================================
info "Creating systemd service..."
cat > /etc/systemd/system/mantra-app.service << EOF
[Unit]
Description=Mantra App Server
After=network.target

[Service]
Type=simple
User=${REAL_USER}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5
Environment=PORT=${APP_PORT}
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mantra-app.service
log "mantra-app.service created and enabled"

# =============================================================================
# 8. Install Kiosk Dependencies & Configure Autostart
# =============================================================================
info "Installing kiosk dependencies..."
apt -y install wtype
log "Kiosk dependencies installed"

AUTOSTART_DIR="${REAL_HOME}/.config/labwc"
AUTOSTART_FILE="${AUTOSTART_DIR}/autostart"
mkdir -p "${AUTOSTART_DIR}"

cat > "${AUTOSTART_FILE}" << EOF
# Disable screen blanking
xset -dpms
xset s noblank
xset s off

# Wait for mantra-app server to be ready
sleep 8

# Launch in kiosk mode
chromium ${KIOSK_URL} --kiosk --noerrdialogs --disable-infobars --no-first-run --enable-features=OverlayScrollbar --start-maximized --window-size=480,320 &
EOF

chown -R "${REAL_USER}:${REAL_USER}" "${AUTOSTART_DIR}"
log "Kiosk autostart configured"

# Openbox fallback for lite/minimal installs
if [[ -d /etc/xdg/openbox ]]; then
    cat > /etc/xdg/openbox/autostart << EOF
xset -dpms
xset s noblank
xset s off
sleep 8
chromium-browser --kiosk --noerrdialogs --disable-infobars --no-first-run --window-size=480,320 "${KIOSK_URL}" &
EOF
    log "Openbox fallback configured"
fi

# =============================================================================
# 9. Disable Screen Blanking System-Wide
# =============================================================================
info "Disabling screen blanking..."
if [[ -f /etc/default/console-setup ]]; then
    grep -q "BLANK_TIME=0" /etc/default/console-setup || echo "BLANK_TIME=0" >> /etc/default/console-setup
fi
systemctl mask screen-saver.service 2>/dev/null || true
log "Screen blanking disabled"

# =============================================================================
# Done
# =============================================================================
echo ""
echo "==========================================="
echo "  Setup Complete!"
echo "==========================================="
echo ""
log "Display:   ${OVERLAY_LINE}"
log "App:       ${APP_DIR} (port ${APP_PORT})"
log "Service:   mantra-app.service (auto-starts on boot)"
log "Kiosk:     Chromium -> ${KIOSK_URL}"
echo ""
info "Reboot to activate everything:"
echo "  sudo reboot"
echo ""
info "After reboot, useful commands:"
echo "  systemctl status mantra-app    # check app server"
echo "  journalctl -u mantra-app -f    # app server logs"
echo "  sudo systemctl restart mantra-app  # restart app"
echo ""
info "If touch is wrong, re-run with a different TOUCH_FIX:"
echo "  sudo TOUCH_FIX=swapxy ./scripts/setup-pi-display.sh"
echo "  sudo TOUCH_FIX=none   ./scripts/setup-pi-display.sh"
echo ""
warn "Reboot required! Run: sudo reboot"
