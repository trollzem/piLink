#!/bin/bash
# Run this **on the Mac** with a freshly flashed Raspberry Pi OS Lite 64-bit
# (Bookworm) SD card mounted under /Volumes/bootfs. Prepares bootfs so the Pi
# comes up headless with:
#   - SSH enabled
#   - user `pi` / password `gameboy`
#   - USB gadget mode (dwc2) via firstrun.sh
#   - WiFi connection (for `setup_pi.sh` over SSH)
#
# After this, pop the SD into the Pi, boot, wait ~90s for two boot cycles,
# SSH in via WiFi and run setup_pi.sh.
#
# Usage:
#   ./prepare_sd.sh <WIFI_SSID> <WIFI_PSK> [<WIFI_COUNTRY=US>]
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 <WIFI_SSID> <WIFI_PSK> [<WIFI_COUNTRY=US>]" >&2
    exit 1
fi

SSID="$1"
PSK="$2"
COUNTRY="${3:-US}"
BOOT=/Volumes/bootfs

[ -d "$BOOT" ] || { echo "error: $BOOT not mounted. Flash the SD and reinsert." >&2; exit 1; }
[ -f "$BOOT/cmdline.txt" ] || { echo "error: $BOOT/cmdline.txt not found. Wrong partition?" >&2; exit 1; }

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

echo "=== writing ssh marker ==="
touch "$BOOT/ssh"

echo "=== writing userconf.txt (pi : gameboy) ==="
HASH='$6$Z7gKrIxOMyQOX2Hm$evcq.YHHECqKBrtuJH406YE16u/eqOwoA7nAYJhJP55MM0uMdvtiGEdyhLcLpkau.jhvp2DTkT6iZL2SL7Z0N1'
printf 'pi:%s\n' "$HASH" > "$BOOT/userconf.txt"

echo "=== patching cmdline.txt: add modules-load=dwc2 + firstrun hook ==="
python3 - "$BOOT/cmdline.txt" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read().rstrip("\n")
if "modules-load=dwc2" not in s:
    s = s.replace("rootwait", "rootwait modules-load=dwc2", 1)
for tok in (
    "systemd.run=/boot/firmware/firstrun.sh",
    "systemd.run_success_action=reboot",
    "systemd.unit=kernel-command-line.target",
):
    if tok not in s:
        s += " " + tok
open(p, "w").write(s + "\n")
PY

echo "=== patching config.txt: dtoverlay=dwc2 under [all] ==="
python3 - "$BOOT/config.txt" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
if "# PIDISPLAY: dwc2 overlay" not in s:
    # Ensure an [all] section exists; add overlay line under it.
    if re.search(r"^\[all\]\s*$", s, flags=re.M) is None:
        s += "\n[all]\n"
    s = re.sub(r"^\[all\]\s*$", "[all]\n# PIDISPLAY: dwc2 overlay\ndtoverlay=dwc2", s, count=1, flags=re.M)
open(p, "w").write(s)
PY

echo "=== writing firstrun.sh ==="
sed -e "s|__WIFI_NAME__|${SSID}|g" \
    -e "s|__WIFI_PASSWORD__|${PSK}|g" \
    -e "s|__WIFI_COUNTRY__|${COUNTRY}|g" \
    "$HERE/boot/firstrun.sh" > "$BOOT/firstrun.sh"
chmod +x "$BOOT/firstrun.sh"

echo "=== ejecting ==="
diskutil eject "$BOOT" || echo "(eject failed — do it manually)"

cat <<'EONEXT'

Next steps:
  1. Put the SD card into the Pi.
  2. Plug the Pi into the Mac's *middle* micro-USB port (the data port).
  3. Wait ~90 seconds for two boot cycles (first one does firstrun + reboots).
  4. Find the Pi's WiFi IP (check your router, or `ping -c1 pidisplay.local`).
  5. Copy this project onto the Pi and run setup_pi.sh:
         scp -r pi/ pi@<wifi-ip>:
         ssh pi@<wifi-ip> 'cd pi && ./setup_pi.sh'
  6. After it reboots: `ssh pi@192.168.69.2` should work over USB-ethernet.
  7. On the Mac side, run setup_mac.sh (in the mac/ dir).
EONEXT
