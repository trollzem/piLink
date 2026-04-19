#!/bin/bash
# Run this **on the Pi** after a fresh Pi OS Lite 64-bit (Bookworm) boot.
# Builds the custom `pidisplay` C receiver, installs systemd services, and
# re-enables KMS so the HW video pipeline (V4L2 M2M decode -> DRM plane) works.
#
# Prerequisites (run `pi/prepare_sd.sh` on the Mac first, before first boot):
#   - ssh enabled, user pi/gameboy
#   - USB gadget (CDC-ECM) configured via firstrun.sh
#   - Optional WiFi profile for over-the-air setup
#
# After this script + reboot:
#   - Pi presents as CDC-ECM gadget at 192.168.69.2 on the Mac's USB
#   - /usr/local/sbin/pidisplay listens for RTP/H.264 on UDP 5001 and paints
#     decoded frames to the HDMI output via DRM overlay (zero-copy).
#   - Latency echo server on TCP 5002.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="${HERE}/rootfs"
RECEIVER="${HERE}/receiver"

need_root() { if [ "$(id -u)" -ne 0 ]; then exec sudo -E "$0" "$@"; fi }
need_root "$@"

echo "=== apt: build deps + runtime ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential libdrm-dev python3
# Gstreamer is used only if you prefer the fallback receiver; safe to skip.
apt-get install -y -qq gstreamer1.0-tools gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad 2>/dev/null || true

echo "=== build pidisplay ==="
make -C "${RECEIVER}" clean all
install -d -m 0755 /usr/local/sbin
install -m 0755 "${RECEIVER}/pidisplay" /usr/local/sbin/
install -m 0755 "${ROOTFS}/display-receiver.sh"            /usr/local/sbin/
install -m 0755 "${ROOTFS}/display-receiver-gstreamer.sh"  /usr/local/sbin/
install -m 0755 "${ROOTFS}/latency-echo.py"                /usr/local/sbin/

echo "=== re-enable vc4-kms-v3d (required for DRM plane output) ==="
python3 - <<'PY'
import re
p = "/boot/firmware/config.txt"
s = open(p).read()
s = re.sub(r"^# dtoverlay=vc4-kms-v3d.*$", "dtoverlay=vc4-kms-v3d", s, flags=re.M)
s = re.sub(r"^# max_framebuffers=2.*$",    "max_framebuffers=2",    s, flags=re.M)
s = re.sub(r"^# disable_fw_kms_setup=1.*$","disable_fw_kms_setup=1",s, flags=re.M)
# Drop any stale legacy-fb tuning we no longer need.
s = re.sub(r"\n# ---- BEGIN display tuning ----.*?# ---- END display tuning ----\n", "\n", s, flags=re.S)
open(p, "w").write(s)
PY

echo "=== install systemd units ==="
install -m 0644 "${ROOTFS}/display-receiver.service" /etc/systemd/system/
install -m 0644 "${ROOTFS}/latency-echo.service"     /etc/systemd/system/
systemctl daemon-reload
systemctl enable display-receiver.service latency-echo.service

echo "=== mask getty@tty1 (console must not own the framebuffer) ==="
systemctl disable getty@tty1.service 2>/dev/null || true
systemctl mask    getty@tty1.service

echo "=== done. rebooting in 3s ==="
sleep 3
systemctl reboot
