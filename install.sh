#!/usr/bin/env bash
# piLink one-command installer (Mac side).
#
# Usage on the Mac:
#   curl -fsSL https://raw.githubusercontent.com/trollzem/piLink/main/install.sh | bash
#   (or) ./install.sh
#
# What it does, in order:
#   1. Clones/updates the piLink repo to ~/piLink (if not already there).
#   2. Installs Mac prerequisites via Homebrew (if needed).
#   3. Builds the Swift sender.
#   4. If the Pi is reachable at 192.168.69.2 — pushes pi/ and runs
#      `setup_pi.sh` over SSH (builds pidisplay, installs services, reboots).
#   5. Sets the persistent static IP on the Mac's USB ethernet interface.
#   6. Installs the LaunchAgent + .app bundle.
#
# Things this script can NOT do for you (TCC + SD-card restrictions):
#   - Flash the SD card itself — run `pi/prepare_sd.sh <SSID> <PSK>` for that.
#   - Grant Screen Recording permission — you'll do that once in System
#     Settings after the first run. The script tells you exactly what to do.
set -euo pipefail

REPO_URL="https://github.com/trollzem/piLink.git"
REPO_DIR="${HOME}/piLink"
PI_HOST="pi@192.168.69.2"
PI_HOST_WIFI="pi@pidisplay.local"

say()  { printf "\n\033[1;36m== %s\033[0m\n" "$*"; }
info() { printf "   %s\n" "$*"; }
warn() { printf "\033[1;33m!! %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m!! %s\033[0m\n" "$*"; exit 1; }

# -------- 1. clone/update --------
if [ -d "${REPO_DIR}/.git" ]; then
    say "updating existing clone at ${REPO_DIR}"
    git -C "${REPO_DIR}" pull --ff-only
else
    say "cloning ${REPO_URL} to ${REPO_DIR}"
    git clone "${REPO_URL}" "${REPO_DIR}"
fi
cd "${REPO_DIR}"

# -------- 2. brew prereqs --------
need_brew=()
command -v brew >/dev/null || die "Homebrew is required. Install from https://brew.sh first."
command -v swift >/dev/null || need_brew+=(swift)  # comes with Xcode CLT; unlikely missing
if [ ${#need_brew[@]} -gt 0 ]; then
    say "installing prerequisites: ${need_brew[*]}"
    brew install "${need_brew[@]}"
fi

# -------- 3. build Swift sender --------
say "building Mac sender (release)"
( cd mac && swift build -c release )

# -------- 4. Pi side --------
PI_REACHABLE=""
if ping -c 1 -W 1 -t 1 192.168.69.2 >/dev/null 2>&1; then
    PI_REACHABLE="${PI_HOST}"
elif ping -c 1 -W 1 -t 1 pidisplay.local >/dev/null 2>&1; then
    PI_REACHABLE="${PI_HOST_WIFI}"
fi

if [ -z "${PI_REACHABLE}" ]; then
    warn "Pi not reachable at 192.168.69.2 or pidisplay.local."
    warn "If you haven't flashed an SD card yet, flash one with Raspberry Pi"
    warn "OS Lite 64-bit (Bookworm) and run:"
    warn "    ./pi/prepare_sd.sh <WIFI_SSID> <WIFI_PSK>"
    warn "Then insert the card into the Pi, plug USB into the Mac's middle"
    warn "port, wait ~90 s, and re-run this script."
else
    say "Pi reachable as ${PI_REACHABLE} — pushing setup"
    rsync -az --delete pi/ "${PI_REACHABLE}:pi/"
    ssh "${PI_REACHABLE}" 'sudo bash -lc "cd pi && ./setup_pi.sh"' || warn "setup_pi.sh returned non-zero"
fi

# -------- 5. Mac network --------
say "setting persistent 192.168.69.1/24 on the Mac USB ethernet"
( cd mac && ./setup_mac.sh ) || warn "setup_mac.sh failed (Pi may not be enumerated yet)"

# -------- 6. LaunchAgent + .app --------
say "installing LaunchAgent + PiDisplaySender.app"
( cd mac && ./install_launchagent.sh )

say "done."
cat <<EOT

final step you must do once (macOS TCC):

  1. macOS may have already prompted for Screen Recording. If it hasn't:
     open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

  2. You should see "PiDisplaySender" in the list — toggle it on.
     If you don't see it, click + and add:
       ${REPO_DIR}/mac/PiDisplaySender.app

  3. Restart the agent so it picks up the permission:
     launchctl kickstart -k gui/\$(id -u)/com.hazemeissa.pidisplay

  4. Tail the log to confirm video is flowing:
     tail -f ~/Library/Logs/pidisplay/err.log

That's it — the Pi's HDMI monitor is now your 4th display, and the whole
thing auto-starts on login and idles to DPMS-off when your other displays
sleep.
EOT
