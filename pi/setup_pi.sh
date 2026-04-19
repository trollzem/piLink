#!/bin/bash
# Run this **on the Pi** after a fresh Pi OS Lite 64-bit (Bookworm) boot.
# It installs gstreamer, deploys the receiver + latency echo services, and
# re-enables KMS so the HW video pipeline works.
#
# Pre-requisites (done by `prepare_sd.sh` on the Mac before first boot):
#   - userconf.txt with the pi:gameboy credentials
#   - `ssh` marker file
#   - cmdline.txt with `modules-load=dwc2` + firstrun hook
#   - config.txt with `dtoverlay=dwc2`
#   - firstrun.sh drops usb-gadget setup, NM profiles, and reboots
#
# After this script finishes + reboot:
#   - Pi presents as CDC-ECM USB gadget at 192.168.69.2
#   - Display receiver listens for RTP/H.264 on udp/5001
#   - Latency echo listens on tcp/5002
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="${HERE}/rootfs"

need_root() { if [ "$(id -u)" -ne 0 ]; then exec sudo -E "$0" "$@"; fi }
need_root "$@"

echo "=== apt: gstreamer + helpers ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    python3

echo "=== re-enable vc4-kms-v3d (required for DRM output) ==="
python3 - <<PY
import re
p = "/boot/firmware/config.txt"
s = open(p).read()
s = re.sub(r"^# dtoverlay=vc4-kms-v3d.*$", "dtoverlay=vc4-kms-v3d", s, flags=re.M)
s = re.sub(r"^# max_framebuffers=2.*$",    "max_framebuffers=2",    s, flags=re.M)
s = re.sub(r"^# disable_fw_kms_setup=1.*$","disable_fw_kms_setup=1",s, flags=re.M)
# Drop any prior legacy-fb tuning we no longer need.
s = re.sub(r"\n# ---- BEGIN display tuning ----.*?# ---- END display tuning ----\n", "\n", s, flags=re.S)
open(p, "w").write(s)
PY

echo "=== install receiver + echo units ==="
install -d -m 0755 /usr/local/sbin
install -m 0755 "${ROOTFS}/display-receiver.sh" /usr/local/sbin/
install -m 0755 "${ROOTFS}/latency-echo.py"     /usr/local/sbin/
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
