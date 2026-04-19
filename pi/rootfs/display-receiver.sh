#!/bin/bash
# Launches the `pidisplay` custom C receiver on the Pi.
#   UDP/RTP H.264 (RFC 6184) → V4L2 M2M HW decode (bcm2835-codec)
#   → DMA-BUF → DRM overlay plane on HDMI.
# All pixel movement is in-kernel; userspace cost is tiny.
set -u

# Detach fbcon from the KMS framebuffer so console paint doesn't race our
# overlay plane.
for vtcon in /sys/class/vtconsole/vtcon*/name; do
    if grep -q "frame buffer" "$vtcon" 2>/dev/null; then
        echo 0 > "$(dirname "$vtcon")/bind" 2>/dev/null || true
    fi
done
for tty in /dev/tty1 /dev/tty2; do
    [ -w "$tty" ] && setterm -cursor off -blank 0 -powerdown 0 -clear all --term linux > "$tty" 2>/dev/null || true
done

exec /usr/local/sbin/pidisplay
