#!/bin/bash
# Shows live diagnostics while sender is running in another terminal.

ssh pi@192.168.69.2 '
echo "---- Pi live stats ----"
for i in $(seq 1 60); do
    PID=$(pgrep -f "ffmpeg.*fbdev" | head -1)
    if [ -z "$PID" ]; then
        printf "%2ds  ffmpeg not running\n" "$i"; sleep 1; continue
    fi
    # Total system CPU, ffmpeg CPU, connection state, recent ffmpeg stats
    SYSCPU=$(top -b -n 1 2>/dev/null | awk "/%Cpu/ {printf \"%.0f\", 100-\$8}")
    FFCPU=$(top -b -n 1 -p "$PID" 2>/dev/null | tail -1 | awk "{print \$9}")
    TEMP=$(vcgencmd measure_temp | cut -d= -f2)
    CONN=$(sudo ss -tn state established "( sport = :5001 )" 2>/dev/null | tail -n +2 | wc -l)
    FPS=$(sudo journalctl -u display-receiver -n 3 --no-pager -q 2>/dev/null | grep -oE "fps=[ ]*[0-9.]+" | tail -1 | grep -oE "[0-9.]+")
    [ -z "$FPS" ] && FPS="-"
    printf "%2ds  sysCPU=%3s%%  ffmpegCPU=%5s%%  conns=%s  fps=%-6s  %s\n" \
        "$i" "$SYSCPU" "$FFCPU" "$CONN" "$FPS" "$TEMP"
    sleep 1
done
'
