# pidisplay — Raspberry Pi Zero 2 W as a 4th display for an M4 Mac mini

Adds a 4th display to a Mac mini that's already maxed out its GPU display
budget (3 external). A Pi Zero 2 W connects via a single USB cable to the Mac
and drives an HDMI monitor. The Mac creates a virtual display, encodes its
contents with VideoToolbox H.264, and streams RTP/UDP over USB-CDC-ECM to the
Pi, which hardware-decodes with its VideoCore IV and scans the result out to
HDMI via a DRM overlay plane.

No DisplayLink driver. No WiFi at runtime. One cable.

Measured on a Pi Zero 2 W + M4 Mac mini: steady 60 fps at 1080p, perceived
end-to-end latency under ~80 ms.

## Pipeline

```
  Mac                                                   Pi Zero 2 W
  ----------------------------------------------------  ----------------
  CGVirtualDisplay (1920x1080)                          CDC-ECM usb0
     └── ScreenCaptureKit (SCStream)                    192.168.69.2
         └── FrameTicker (60 Hz synthetic cadence)          │
             └── VideoToolbox H.264 (Main, CAVLC,            │
                   8–12 Mbps, real-time, prio_speed)         │
                 └── RTP/H.264 packetizer (RFC 6184)          │
                     └── NWConnection UDP ─────── USB ────────┤
                                                              │
                                         pidisplay (custom C)  
                                          UDP recv → RTP depay  
                                          → V4L2 M2M HW decode   
                                          → DMA-BUF              
                                          → DRM atomic SetPlane  
                                          → HDMI overlay         
```

## Repo layout

```
mac/
├── Package.swift                          Swift Package for the sender
├── Sources/
│   ├── PiDisplayBridge/                   Obj-C declarations for private
│   │   └── include/PiDisplayBridge.h      CGVirtualDisplay* APIs
│   └── PiDisplaySender/
│       ├── main.swift                     wiring + stats + signal handling
│       ├── VirtualDisplay.swift           CGVirtualDisplay wrapper
│       ├── Capture.swift                  SCStream → CMSampleBuffer
│       ├── FrameTicker.swift              forces steady 60 Hz output
│       ├── Encoder.swift                  VTCompressionSession
│       ├── AnnexBConverter.swift          AVCC → Annex-B NAL conversion
│       ├── RTPStreamer.swift              RFC 6184 H.264-over-RTP/UDP
│       ├── Streamer.swift                 legacy TCP streamer (unused)
│       └── LatencyProbe.swift             side-channel RTT measurement
├── setup_mac.sh                           one-shot static IP on en*
└── monitor.sh                             live Pi CPU/fps over SSH
pi/
├── prepare_sd.sh                          run on Mac before first Pi boot
├── setup_pi.sh                            run on Pi after first boot
├── receiver/
│   ├── pidisplay.c                        custom C receiver (preferred)
│   └── Makefile
├── rootfs/                                files installed to Pi rootfs
│   ├── display-receiver.sh                runs pidisplay
│   ├── display-receiver-gstreamer.sh      fallback GStreamer receiver
│   ├── display-receiver.service           systemd unit
│   ├── latency-echo.py                    tcp/5002 echo for RTT probing
│   └── latency-echo.service
└── boot/
    └── firstrun.sh                        laid onto SD by prepare_sd.sh
```

## First-time setup from scratch

### 1. Flash the SD card

1. Flash **Raspberry Pi OS Lite 64-bit (Bookworm)** onto the SD card with
   Raspberry Pi Imager.
2. Reinsert the SD so `/Volumes/bootfs` mounts on the Mac.
3. Run `pi/prepare_sd.sh <SSID> <PSK>` — writes `ssh`, `userconf.txt`
   (`pi`/`gameboy`), patches `cmdline.txt` + `config.txt` for USB gadget
   mode, and drops `firstrun.sh` that completes first-boot.
4. Eject, put the card in the Pi.

### 2. First Pi boot

1. Plug the Pi into the Mac's **middle** micro-USB port (the data port, not
   the PWR IN port near the edge).
2. Wait ~90 s through two boot cycles. On boot 2 the Pi should come up as
   a CDC-ECM gadget at 192.168.69.2 and also connect to WiFi as a fallback.

### 3. Mac side

```bash
cd mac
./setup_mac.sh                 # sets en* to 192.168.69.1/24 persistently
```

Ping: `ping 192.168.69.2`. SSH: `ssh pi@192.168.69.2` (password: `gameboy`).

### 4. Install the receiver on the Pi

```bash
scp -r pi pi@192.168.69.2:~/
ssh pi@192.168.69.2 'cd pi && sudo ./setup_pi.sh'
```

Script reboots at the end. After reboot:
- `/usr/local/sbin/pidisplay` listens on UDP 5001.
- `latency-echo` listens on TCP 5002.
- `getty@tty1` is masked so the console doesn't race for the HDMI plane.

### 5. Grant the Mac sender Screen Recording permission

1. `cd mac && swift build`
2. `./.build/debug/PiDisplaySender` — macOS prompts for Screen Recording.
3. Approve in System Settings → Privacy & Security → Screen Recording for
   **your Terminal.app**, then quit and reopen Terminal.
4. Re-run. The Pi's HDMI monitor should show the new virtual display.

A "Pi Display" entry appears in System Settings → Displays and behaves like
any other monitor (drag windows, arrange, etc.).

## Running

```bash
# on the Mac, in mac/:
./.build/debug/PiDisplaySender
```

Stderr prints per-second stats:
```
sender: 60.0 fps, 1635 kbps
stats: capture=44.5 fps encode=5.5/6.5/12.4 ms (n=120) rtt=0.7/0.9/1.1 ms
```

- `sender`: frames actually encoded + sent. Held at 60 fps by `FrameTicker`.
- `capture`: raw SCStream delivery rate (event-driven, varies with content).
- `encode`: min/avg/max latency in the VT encoder callback.
- `rtt`: round-trip through the latency-echo on Pi — the network-plus-Pi-
  kernel component of perceived delay.

Ctrl-C cleanly shuts down.

## Tuning knobs

All in [`mac/Sources/PiDisplaySender/main.swift`](mac/Sources/PiDisplaySender/main.swift):

- `width`, `height`, `fps` — capture + encode target.
- `bitrate` — H.264 AverageBitRate.
- `keyframeInterval` — frames between IDRs (longer = more bits on P-frames).

Hardware ceiling on Pi Zero 2 W: **1080p60 H.264** (H.264 Level 4.2). It
will refuse anything higher at the decoder.

## What didn't work

- `fbdev` output on the Pi: software YUV→BGRA conversion saturated all four
  Cortex-A53 cores before we even reached 1080p60.
- RNDIS default of Linux `g_ether`: macOS enumerates but cannot send packets
  through. We switched to **pure CDC-ECM via `libcomposite`** for the gadget.
- USB bulk endpoint via FunctionFS (Plan D in git history, branch
  `plan-d-usb-bulk`): showed 31.7 MB/s throughput but hit a kernel race
  between FFS reads and V4L2/DRM under sustained load. Two kernel hangs,
  ~1–3 ms theoretical win. Not worth the complexity on this SoC.

## Rollback

Pi side: `sudo systemctl restart display-receiver` restores the receiver.
Re-run `setup_pi.sh` to re-deploy after any config drift.

Mac side: `git checkout main` in this repo. Everything in main is the
known-good state.
