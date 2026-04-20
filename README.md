# piLink

Turn a Raspberry Pi Zero 2 W into a 4th display for an M4 Mac mini — over a
single USB cable, no DisplayLink driver, no WiFi in the data path. Bypasses
the Mac GPU's 3-display hardware limit with a software virtual display,
VideoToolbox H.264 encode, and zero-copy hardware decode on the Pi.

- **Resolution**: up to 1080p60 (Pi Zero 2 W VideoCore IV ceiling).
- **Latency**: ~40-80 ms end-to-end perceived.
- **Pi CPU for pixels**: essentially 0% (VideoCore does everything).
- **Auto-idle**: Pi drops HDMI signal when the Mac's other displays sleep,
  restores it on wake. Monitor actually enters standby (backlight off).

## Quick start (one command, once you have an SD card ready)

On the Mac:

```bash
curl -fsSL https://raw.githubusercontent.com/trollzem/piLink/main/install.sh | bash
```

Read the output — it tells you exactly what's next. The only manual step is
granting Screen Recording permission in System Settings (once).

## Hardware

- Apple Silicon Mac (tested on M4 mini, macOS Sequoia 15.x / 26).
- Raspberry Pi Zero 2 W.
- A micro-SD card (8 GB+).
- A **data-capable** micro-USB cable (the Pi draws power and data from the
  same cable).
- A mini-HDMI cable + monitor.

## Full setup from scratch

This is the detailed walkthrough the quick-start one-liner skips through.
Skip to the **troubleshooting** section below if something goes wrong.

### 0. Before you start

- On the Mac, install the Xcode Command Line Tools if you haven't:
  ```bash
  xcode-select --install
  ```
- Install Homebrew: https://brew.sh

### 1. Clone the repo

```bash
git clone https://github.com/trollzem/piLink.git ~/piLink
cd ~/piLink
```

### 2. Flash the SD card

1. Open **Raspberry Pi Imager**.
2. Choose **Raspberry Pi OS Lite (64-bit)** (Bookworm). **Not** the full
   desktop image.
3. In the advanced settings (gear icon): leave defaults — our script overrides
   what matters.
4. Flash to the SD card. When it ejects, **reinsert** it so `/Volumes/bootfs`
   is mounted on the Mac.
5. From the Mac, run:
   ```bash
   ./pi/prepare_sd.sh "<your 2.4 GHz WiFi SSID>" "<WiFi password>"
   ```
   This patches `/Volumes/bootfs` to:
   - Enable SSH
   - Create user `pi` / password `gameboy`
   - Turn on USB gadget mode (`dtoverlay=dwc2`, `modules-load=dwc2`)
   - Drop `firstrun.sh` on the SD card that, on first boot, configures:
     - CDC-ECM USB gadget at 192.168.69.2/24
     - NetworkManager WiFi profile for the SSID you provided
     - Hostname `pidisplay`
     - Self-deletes, reboots
6. The script ejects the SD card when done. **Pull it out of the Mac.**

> **Why 2.4 GHz WiFi?** Pi Zero 2 W only has a 2.4 GHz radio. 5 GHz won't
> associate.

### 3. Boot the Pi

1. Put the SD card in the Pi.
2. Plug the Pi into the Mac using the **middle** micro-USB port on the Pi
   (the data port). The outer port is PWR IN only — if you use that by
   mistake the Mac will never see the Pi.
3. Wait ~90 seconds. The Pi first-boots, runs `firstrun.sh`, reboots once,
   and comes up fully.
4. In another terminal, run:
   ```bash
   ping 192.168.69.2
   ```
   You should get replies in ~0.5 ms. If not → troubleshooting below.

### 4. Install the Pi receiver

Still on the Mac:

```bash
scp -r pi pi@192.168.69.2:~/       # password: gameboy
ssh pi@192.168.69.2 'cd pi && sudo ./setup_pi.sh'
```

`setup_pi.sh`:
- apt-installs `libdrm-dev`, `build-essential`, `python3`, and optionally the
  GStreamer plugins (as a fallback receiver — not used by default).
- Builds `pidisplay` (the custom C receiver).
- Installs `/usr/local/sbin/pidisplay` + systemd units.
- Re-enables `vc4-kms-v3d` in `/boot/firmware/config.txt` (required for DRM
  output).
- Masks `getty@tty1` so the console doesn't race for the HDMI framebuffer.
- Reboots.

After reboot (~30 s), `ping 192.168.69.2` should return immediately, the Pi's
HDMI monitor should be dark (no signal → DPMS standby), and the
`display-receiver.service` is active and listening on UDP 5001.

### 5. Mac-side network

```bash
cd mac
./setup_mac.sh
```

Assigns `192.168.69.1/24` persistently to the `Pi Display Gadget` network
service. Requires `sudo`.

### 6. Build the sender and install auto-start

```bash
./install_launchagent.sh
```

This:
- Builds a release binary.
- Wraps it in `PiDisplaySender.app` with bundle id
  `com.hazemeissa.pidisplay`.
- Ad-hoc codesigns the bundle.
- Installs `~/Library/LaunchAgents/com.hazemeissa.pidisplay.plist`.
- Starts it.

### 7. Grant Screen Recording permission

This is the one step that **cannot** be automated — macOS Transparency,
Consent & Control (TCC) accepts this permission only via System Settings.

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
```

You should see **PiDisplaySender** in the list. Toggle it on.

If it's **not** in the list:
1. Click the `+` button.
2. Press **`⌘⇧G`** and paste:
   ```
   /Users/<you>/piLink/mac/PiDisplaySender.app
   ```
3. Select the app → **Open** → toggle it on.

Then restart the agent:

```bash
launchctl kickstart -k gui/$(id -u)/com.hazemeissa.pidisplay
```

Tail the log to confirm success:

```bash
tail -f ~/Library/Logs/pidisplay/err.log
```

You want to see lines like:

```
virtual display created, displayID=8
rtp sender ready -> 192.168.69.2:5001
capture started (attempt 1)
sender: 60.0 fps, 1622 kbps
```

Your Pi's HDMI monitor lights up at this point.

## Using it

The Pi monitor behaves like any other display:
- **System Settings → Displays** shows a new "Pi Display" entry — arrange
  it relative to your other monitors.
- Drag windows to it, put full-screen apps on it.
- It **auto-sleeps** when your other displays sleep (HDMI signal drops after
  3 s of idle → monitor enters DPMS standby, backlight off).
- It **auto-wakes** when your displays wake.
- The sender **auto-starts on login** via LaunchAgent.

## Pipeline

```
Mac (sender)                                         Pi (receiver)
────────────────────────────────────────             ────────────────────────────────────────
CGVirtualDisplay (1920×1080)                         CDC-ECM usb0 (192.168.69.2)
  └── ScreenCaptureKit SCStream                              │
      └── FrameTicker (60 Hz synthetic cadence)              │
          └── VideoToolbox H.264                              │
              (Main/CAVLC, real-time,                         │
               PrioritizeEncodingSpeedOverQuality,            │
               no B-frames, 2 s GOP)                          │
              └── RTP packetizer (RFC 6184, FU-A)             │
                  └── NWConnection UDP ──────USB──────────────┤
                                                              │
                                         pidisplay (custom C, ~800 LOC)
                                         ├── udpsrc → RTP depay
                                         ├── V4L2 M2M HW decode (bcm2835-codec, /dev/video10)
                                         ├── EXPBUF → DMA-BUF
                                         ├── drmModeAddFB2 → drmModeSetPlane
                                         └── idle > 3 s → DPMS off
```

## Repo layout

```
mac/
├── Package.swift
├── setup_mac.sh                        persistent 192.168.69.1/24
├── install_launchagent.sh              build + wrap .app + register w/ launchd
├── monitor.sh                          live Pi CPU/fps over SSH
├── Sources/
│   ├── PiDisplayBridge/                Obj-C decls for private
│   │   └── include/PiDisplayBridge.h   CGVirtualDisplay* APIs
│   └── PiDisplaySender/
│       ├── main.swift                  wiring + stats + sleep/wake
│       ├── VirtualDisplay.swift        CGVirtualDisplay wrapper
│       ├── Capture.swift               SCStream → CMSampleBuffer
│       ├── FrameTicker.swift           forces steady fps output
│       ├── Encoder.swift               VTCompressionSession
│       ├── AnnexBConverter.swift       AVCC → Annex-B (unused; kept for future)
│       ├── RTPStreamer.swift           RFC 6184 RTP packetizer
│       └── LatencyProbe.swift          side-channel TCP echo RTT
pi/
├── prepare_sd.sh                       run on Mac before first Pi boot
├── setup_pi.sh                         run on Pi after first boot
├── receiver/
│   ├── pidisplay.c                     ~800-LOC custom C receiver
│   └── Makefile
├── rootfs/
│   ├── display-receiver.sh             systemd wrapper → runs pidisplay
│   ├── display-receiver-gstreamer.sh   fallback GStreamer receiver
│   ├── display-receiver.service        systemd unit
│   ├── latency-echo.py                 tcp/5002 echo helper
│   └── latency-echo.service
└── boot/
    └── firstrun.sh                     installed on SD; runs once at first boot
install.sh                              one-command Mac-side installer
CLAUDE.md                               context for future LLM sessions
```

## Tuning

Edit `mac/Sources/PiDisplaySender/main.swift`:

```swift
let width = 1920           // 1080p — Pi Zero 2 W HW ceiling (Level 4.2)
let height = 1080
let fps = 60
let bitrate = 12_000_000   // 12 Mbps; USB 2.0 has plenty of headroom
let keyframeInterval = 120 // 2 s at 60 fps
```

Then `cd mac && ./install_launchagent.sh` to rebuild + reload the agent.

### Going above 1080p60

Pi Zero 2 W cannot — 1080p60 H.264 Level 4.2 is a silicon hard limit. The
decoder will reject higher-level streams. A Pi 4 or Pi 5 would handle 1440p60
or 2160p30 with the same code unchanged.

## Troubleshooting

### Pi not appearing on the Mac at all

- Confirm you plugged into the **middle** micro-USB port on the Pi, not PWR IN.
- Watch the USB bus:
  ```bash
  ioreg -p IOUSB -l -w 0 | grep -iE "Pi Display|Raspberry|Linux"
  ```
  You want to see "Pi Display Gadget" with vendor "Raspberry Pi".
- If it enumerates as "RNDIS_Ethernet Gadget" — you're running the wrong
  firstrun (ancient `g_ether` version). `firstrun.sh` should have replaced
  that with CDC-ECM via libcomposite.

### Pi enumerates but ping to 192.168.69.2 fails

- Mac side: `ifconfig | grep -A2 "Pi Display"` to find the interface name
  (usually `en10-en20`). Re-run `mac/setup_mac.sh`.
- Pi side: SSH over WiFi (`ssh pi@pidisplay.local`), check `ip addr show usb0`.

### "The user declined TCCs" in the log

macOS silently denied Screen Recording. Fix:

```bash
tccutil reset ScreenCapture com.hazemeissa.pidisplay
sudo tccutil reset ScreenCapture com.hazemeissa.pidisplay
open /Users/<you>/piLink/mac/PiDisplaySender.app
# When the dialog appears, approve. If no dialog, open Settings:
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
# Add PiDisplaySender.app via the + button, toggle on.
launchctl kickstart -k gui/$(id -u)/com.hazemeissa.pidisplay
```

### Pi monitor shows "no signal" forever

- Check `ssh pi@192.168.69.2 'systemctl is-active display-receiver'` — should
  be `active`.
- Watch `sudo journalctl -u display-receiver -f` on the Pi — look for
  `source change -> reconfigure capture` as proof the decoder is seeing the
  stream. If no such line → sender isn't reaching the Pi.
- Check the Mac log: `tail -f ~/Library/Logs/pidisplay/err.log`. If
  `capture=0.0 fps` persistently but `sender: 60 fps` — SCStream is getting
  frames but content never changes. Move the cursor on the virtual display.

### High latency

All tuning is documented in `CLAUDE.md` under "What we tried that didn't
work". Current defaults reflect our best-known-good config. Going below ~40 ms
requires different hardware.

## What didn't work (preserved for history)

See `CLAUDE.md` for the full list. Short version:
- ffmpeg `-f fbdev` on the Pi (software colour conversion too slow)
- `g_ether` RNDIS default (macOS can't route through it)
- TCP transport (HOL blocking + buffering)
- DRM atomic commit to overlay plane (VC4 returns EBUSY under fbcon)
- Custom USB bulk endpoint via FunctionFS (kernel hangs; Plan D branch
  preserved for anyone who wants to finish it)

## License

MIT.
