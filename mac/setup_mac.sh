#!/bin/bash
# Configure the Mac side of the USB-ethernet link after the Pi boots with the
# CDC-ECM gadget up. Idempotent — safe to re-run.
#
# What this does:
#   1. Finds the network service whose hardware port is "Pi Display Gadget".
#   2. Sets a persistent static IP 192.168.69.1/24 on it (survives reboots
#      and cable reconnects, via macOS's Network Services database).
#   3. Pings the Pi to verify.
set -euo pipefail

EXPECTED_PORT="Pi Display Gadget"
MAC_IP="192.168.69.1"
PI_IP="192.168.69.2"
NETMASK="255.255.255.0"

need_sudo() {
    if ! sudo -n true 2>/dev/null; then
        echo "This script needs sudo (for networksetup)."
    fi
}
need_sudo

port_device=$(networksetup -listallhardwareports \
    | awk -v want="$EXPECTED_PORT" '/Hardware Port:/ {p=$0; sub(/Hardware Port: /,"",p)} /Device:/ {d=$2} p==want && d!="" {print d; exit}')

if [ -z "$port_device" ]; then
    echo "error: no network service named '$EXPECTED_PORT' found."
    echo "Is the Pi plugged in via USB and showing on the Mac?"
    echo "Run: networksetup -listallhardwareports  to inspect."
    exit 1
fi
echo "found: $EXPECTED_PORT on $port_device"

sudo networksetup -setmanual "$EXPECTED_PORT" "$MAC_IP" "$NETMASK"
echo "assigned $MAC_IP/$NETMASK to $EXPECTED_PORT"

echo "--- pinging Pi at $PI_IP ---"
if ping -c 3 -t 2 "$PI_IP"; then
    echo "ok. SSH:  ssh pi@$PI_IP"
else
    echo "warn: no ping reply yet. Possible causes:"
    echo "  - Pi still booting"
    echo "  - Pi's usb0 IP isn't 192.168.69.2 (check firstrun logs)"
    echo "  - macOS bound CDC-ECM before our static IP was set; try running again"
fi
