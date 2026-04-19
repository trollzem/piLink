#!/bin/bash
# Zero-copy HW pipeline on Raspberry Pi Zero 2 W:
#   UDP RTP → rtpjitterbuffer → rtph264depay → h264parse → v4l2h264dec (HW)
#   → kmssink (HW YUV overlay plane on the HDMI output, scaled by the ISP)
#
# Pi CPU for pixels: effectively 0%. All the work is the VideoCore.
set -u

# Unbind fbcon so console text doesn't paint over the video plane.
for vtcon in /sys/class/vtconsole/vtcon*/name; do
    if grep -q "frame buffer" "$vtcon" 2>/dev/null; then
        echo 0 > "$(dirname "$vtcon")/bind" 2>/dev/null || true
    fi
done
for tty in /dev/tty1 /dev/tty2; do
    [ -w "$tty" ] && setterm -cursor off -blank 0 -powerdown 0 -clear all --term linux > "$tty" 2>/dev/null || true
done

exec gst-launch-1.0 -e \
    udpsrc port=5001 buffer-size=2097152 \
        caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96" ! \
    rtpjitterbuffer latency=5 drop-on-latency=true mode=none ! \
    rtph264depay ! \
    h264parse config-interval=-1 ! \
    queue max-size-buffers=1 max-size-bytes=0 max-size-time=0 leaky=downstream ! \
    v4l2h264dec capture-io-mode=dmabuf ! \
    queue max-size-buffers=1 max-size-bytes=0 max-size-time=0 leaky=downstream ! \
    kmssink sync=false can-scale=true qos=false
