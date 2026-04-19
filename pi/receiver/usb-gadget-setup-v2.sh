#!/bin/bash
# Plan D: composite USB gadget with CDC-ECM (for SSH) + FunctionFS (for bulk).
# Does NOT bind UDC — ffs-init/pidisplay does that after writing descriptors.
set -e

if ! mountpoint -q /sys/kernel/config; then
    mount -t configfs none /sys/kernel/config
fi
modprobe libcomposite

GADGET=/sys/kernel/config/usb_gadget/pidisplay

# If already bound, unbind so we can rebuild cleanly.
if [ -f "$GADGET/UDC" ] && [ -s "$GADGET/UDC" ]; then
    echo "" > "$GADGET/UDC" 2>/dev/null || true
fi

# Tear down any previous composite.
if [ -d "$GADGET" ]; then
    find "$GADGET/configs" -maxdepth 2 -type l -exec rm -f {} \; 2>/dev/null || true
    for f in "$GADGET"/configs/*/strings/0x409; do [ -d "$f" ] && rmdir "$f"; done
    for f in "$GADGET"/configs/*; do [ -d "$f" ] && rmdir "$f"; done
    for f in "$GADGET"/functions/*; do [ -d "$f" ] && rmdir "$f"; done
    [ -d "$GADGET/strings/0x409" ] && rmdir "$GADGET/strings/0x409"
    rmdir "$GADGET" 2>/dev/null || true
fi

mkdir -p "$GADGET"
cd "$GADGET"

echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
echo "0000000000000001" > strings/0x409/serialnumber
echo "Raspberry Pi"     > strings/0x409/manufacturer
echo "Pi Display Gadget" > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
echo "CDC ECM + bulk" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower

# Function 1: CDC-ECM (for SSH + UDP fallback)
mkdir -p functions/ecm.usb0
echo "02:00:00:00:00:01" > functions/ecm.usb0/host_addr
echo "02:00:00:00:00:02" > functions/ecm.usb0/dev_addr
ln -s functions/ecm.usb0 configs/c.1/

# Function 2: FunctionFS for high-speed bulk transport
mkdir -p functions/ffs.pidisplay
ln -s functions/ffs.pidisplay configs/c.1/

# Mount functionfs so pidisplay/ffs-init can write descriptors.
mkdir -p /dev/ffs/pidisplay
if ! mountpoint -q /dev/ffs/pidisplay; then
    mount -t functionfs pidisplay /dev/ffs/pidisplay
fi

# Bring up usb0 (from ECM) with static IP so SSH works even if ffs-init hasn't
# written descriptors yet. UDC bind happens later — this just pre-configures
# the netdev that will appear when the gadget enumerates.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e /sys/class/net/usb0 ] && break
    sleep 1
done
if [ -e /sys/class/net/usb0 ]; then
    ip link set usb0 up 2>/dev/null || true
    ip addr flush dev usb0 2>/dev/null || true
    ip addr add 192.168.69.2/24 dev usb0 2>/dev/null || true
fi

echo "gadget created; awaiting FFS descriptors + UDC bind by pidisplay"
