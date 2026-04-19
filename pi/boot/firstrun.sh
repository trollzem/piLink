#!/bin/bash
# First-boot setup: runs exactly once after a fresh Pi OS flash, installed by
# `prepare_sd.sh` on the Mac side. It wires up USB-gadget mode, the display
# receiver, the latency echo helper, and sets a hostname. Self-deletes after
# success and reboots.
set +e
exec > >(tee -a /boot/firmware/firstrun.log) 2>&1
echo "=== firstrun.sh $(date) ==="

CURRENT_HOSTNAME=$(tr -d ' \t\n\r' < /etc/hostname)
echo "pidisplay" > /etc/hostname
sed -i "s/127\.0\.1\.1.*${CURRENT_HOSTNAME}/127.0.1.1\tpidisplay/g" /etc/hosts

# --- USB CDC-ECM gadget setup script ------------------------------------
install -d -m 0755 /usr/local/sbin
cat > /usr/local/sbin/usb-gadget-setup.sh <<'SCRIPT_EOF'
#!/bin/bash
set -e
if ! mountpoint -q /sys/kernel/config; then
    mount -t configfs none /sys/kernel/config
fi
modprobe libcomposite

GADGET_DIR=/sys/kernel/config/usb_gadget/pidisplay
if ! [ -d "$GADGET_DIR" ] || ! [ -s "$GADGET_DIR/UDC" ]; then
    rm -rf "$GADGET_DIR" 2>/dev/null || true
    mkdir -p "$GADGET_DIR"
    cd "$GADGET_DIR"
    echo 0x1d6b > idVendor
    echo 0x0104 > idProduct
    echo 0x0100 > bcdDevice
    echo 0x0200 > bcdUSB
    mkdir -p strings/0x409
    echo "0000000000000001" > strings/0x409/serialnumber
    echo "Raspberry Pi"     > strings/0x409/manufacturer
    echo "Pi Display Gadget" > strings/0x409/product
    mkdir -p configs/c.1/strings/0x409
    echo "CDC ECM" > configs/c.1/strings/0x409/configuration
    echo 250 > configs/c.1/MaxPower
    mkdir -p functions/ecm.usb0
    echo "02:00:00:00:00:01" > functions/ecm.usb0/host_addr
    echo "02:00:00:00:00:02" > functions/ecm.usb0/dev_addr
    ln -s functions/ecm.usb0 configs/c.1/
    UDC=$(ls /sys/class/udc | head -n1)
    [ -n "$UDC" ] && echo "$UDC" > UDC
fi

# Wait for the usb0 netdev the ECM function creates, then set static IP.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e /sys/class/net/usb0 ] && break
    sleep 1
done
if [ -e /sys/class/net/usb0 ]; then
    ip link set usb0 up
    ip addr flush dev usb0 2>/dev/null || true
    ip addr add 192.168.69.2/24 dev usb0
fi
exit 0
SCRIPT_EOF
chmod +x /usr/local/sbin/usb-gadget-setup.sh

cat > /etc/systemd/system/usb-gadget.service <<'UNIT_EOF'
[Unit]
Description=USB CDC-ECM gadget setup
Wants=sys-kernel-config.mount
After=sys-kernel-config.mount local-fs.target
Before=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/usb-gadget-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF

# NetworkManager must not touch usb0 (we assign its IP ourselves)
install -d -m 0755 /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-unmanaged-usb0.conf <<'NMC_EOF'
[keyfile]
unmanaged-devices=interface-name:usb0
NMC_EOF

# --- WiFi setup (optional, for install + debugging) ----------------------
install -d -m 0755 /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/__WIFI_NAME__.nmconnection <<'WIFI_EOF'
[connection]
id=__WIFI_NAME__
type=wifi
interface-name=wlan0
autoconnect=true

[wifi]
mode=infrastructure
ssid=__WIFI_NAME__

[wifi-security]
key-mgmt=wpa-psk
psk=__WIFI_PASSWORD__

[ipv4]
method=auto

[ipv6]
method=auto
WIFI_EOF
chmod 600 /etc/NetworkManager/system-connections/__WIFI_NAME__.nmconnection
chown root:root /etc/NetworkManager/system-connections/__WIFI_NAME__.nmconnection
raspi-config nonint do_wifi_country __WIFI_COUNTRY__ 2>/dev/null || echo "country=__WIFI_COUNTRY__" > /etc/wpa_supplicant/wpa_supplicant.conf
rfkill unblock wifi 2>/dev/null || true

# --- Finish: enable services, strip first-run hooks, self-delete, reboot ---
systemctl daemon-reload
systemctl enable usb-gadget.service

sed -i 's| systemd.run=/boot/firmware/firstrun.sh||g'      /boot/firmware/cmdline.txt
sed -i 's| systemd.run_success_action=reboot||g'           /boot/firmware/cmdline.txt
sed -i 's| systemd.unit=kernel-command-line.target||g'     /boot/firmware/cmdline.txt
rm -f /boot/firmware/firstrun.sh

sync
echo "=== firstrun.sh done $(date) ==="
exit 0
