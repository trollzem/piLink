# CLAUDE.md — project context for future sessions

This file exists to hand state and rationale to future Claude sessions working
on this repo. Read it before anything else.

## One-sentence project summary

Turn a Raspberry Pi Zero 2 W into a 4th display for an M4 Mac mini over a
single USB cable, bypassing the Mac GPU's 3-display hardware limit via software
virtual display + H.264 streaming + HW decode on the Pi.

## Architecture (final, shipping)

```
Mac (sender)
  CGVirtualDisplay (private CoreGraphics API)
    → ScreenCaptureKit SCStream
    → FrameTicker (re-emits latest frame at steady fps)
    → VideoToolbox H.264 (Main/CAVLC, real-time, PrioritizeEncodingSpeedOverQuality)
    → Annex-B framing + RFC 6184 RTP packetization
    → NWConnection UDP → 192.168.69.2:5001

USB (CDC-ECM gadget, libcomposite; NOT g_ether RNDIS — macOS hates RNDIS)

Pi (receiver — pidisplay, custom C, pi/receiver/pidisplay.c)
  udpsrc → RTP depay (handles FU-A fragmentation)
    → V4L2 M2M HW decoder (bcm2835-codec, /dev/video10)
    → DMA-BUF (EXPBUF)
    → DRM overlay plane via drmModeSetPlane (legacy API — atomic commits
      return EBUSY on VC4 when fbcon owns the primary)
    → HDMI
```

- Pi CPU for pixels: ~0% (everything's VideoCore).
- End-to-end latency: ~40-80 ms perceived.
- Auto-idle: pidisplay puts HDMI into DPMS off after 3 s of no frames; first
  incoming frame flips DPMS back on. Handles Mac sleep/wake transparently.

## What we tried that didn't work (don't rehash)

1. **fbdev output** (ffmpeg `-f fbdev`): yuv420p → bgra has no NEON path; one
   A53 core per ~30 ms of conversion at 1080p. Unusable. **Replaced with KMS
   DRM overlay plane.**
2. **`g_ether` default RNDIS**: macOS enumerates but won't route traffic. Zero
   packets to Pi despite kernel claiming link up. **Switched to pure CDC-ECM
   via libcomposite in `pi/boot/firstrun.sh`.**
3. **TCP transport**: HOL-blocks on any loss + buffers aggressively, adds
   50-100 ms. **Replaced with RTP/UDP + FU-A fragmentation.**
4. **3-plane YU12 on DRM**: `atomic commit: No space left` from VC4. **Forced
   decoder output to NV12 via S_FMT.**
5. **DRM atomic commit to overlay**: `Device or resource busy` because fbcon
   still holds primary. **Use `drmModeSetPlane` legacy API instead.**
6. **Plan D — custom USB bulk endpoint (FunctionFS + libusb)**: composite
   gadget works, 31.7 MB/s throughput demoed, but the Pi kernel hangs under
   sustained FFS-read + V4L2 + DRM load. Two kernel panics cost us ~an hour.
   Theoretical win was 1-3 ms. **Abandoned; preserved on branch
   `plan-d-usb-bulk`.**

## Files you'll likely touch

- `mac/Sources/PiDisplaySender/main.swift` — top-level wiring, tuning knobs,
  sleep/wake handling.
- `mac/Sources/PiDisplaySender/Encoder.swift` — VT session setup. Critical
  tuning: CAVLC (cheaper to HW-decode on Pi than CABAC), no max_ref_frames on
  H.264 (all-IDR bug on Apple Silicon), `PrioritizeEncodingSpeedOverQuality`.
- `mac/Sources/PiDisplaySender/RTPStreamer.swift` — RFC 6184 packetizer.
- `pi/receiver/pidisplay.c` — single-file receiver. Sections marked by
  comments: depay / decoder / display / main loop. ~800 LOC.

## Tuning knobs (main.swift)

```swift
let width = 1920           // 1080p — Pi Zero 2 W Level 4.2 cap
let height = 1080          // ditto
let fps = 60               // Pi handles 60 fine
let bitrate = 12_000_000   // 12 Mbps; USB 2.0 has plenty of headroom
let keyframeInterval = 120 // 2 s at 60 fps
```

Pi Zero 2 W HW decoder HARD ceiling is 1080p60 H.264 Level 4.2. Anything
higher → decoder refuses the stream. Pi 4/5 would go up from there; same code
should work unchanged if the UDC is dwc2 and `bcm2835-codec` equivalents exist.

## Build / deploy

```bash
# Mac side
cd mac && swift build
./.build/debug/PiDisplaySender              # run
./install_launchagent.sh                    # auto-start on login (.app bundle)

# Pi side (first-time, run on Pi)
cd pi && sudo ./setup_pi.sh                 # installs libdrm-dev, builds pidisplay,
                                            # installs services, re-enables KMS, reboots
```

## Live Pi state (as shipped)

- `display-receiver.service` → `/usr/local/sbin/display-receiver.sh` →
  `/usr/local/sbin/pidisplay`. Auto-starts on boot.
- `latency-echo.service` on tcp/5002 for sender-side RTT probing.
- `usb-gadget.service` creates the CDC-ECM gadget, assigns 192.168.69.2.
- `getty@tty1` is masked so console doesn't race pidisplay for the HDMI.
- `vc4-kms-v3d` is enabled (required for DRM plane output).

## Mac permissions (these bite every new session)

- **Screen Recording** must be granted to the `.app` bundle (not the raw
  binary). TCC identity is bundle-id based. Bundle id:
  `com.hazemeissa.pidisplay`.
- If Screen Recording is silently denied:
  `tccutil reset ScreenCapture com.hazemeissa.pidisplay`, then re-launch via
  `open /path/to/PiDisplaySender.app`.

## Git branches

- `main` — shipping. `gh repo sync` it.
- `plan-d-usb-bulk` — abandoned USB bulk endpoint attempt. Don't delete; has
  working FunctionFS setup worth the next person's time if they want 1-3 ms
  more latency and a kernel-debug mood.

## Debugging first-aid

- Pi unreachable on `192.168.69.2` — check WiFi fallback (`pidisplay.local`
  via mDNS). SSH works there (credentials: `pi` / `gameboy`).
- Dirty-unmount + "filesystem still has errors": **never** yank USB while Pi
  is doing writes. `ssh pi@192.168.69.2 'sudo poweroff'` first.
- Mac `en*` lost its 192.168.69.1 IP after sleep/reconnect:
  `sudo networksetup -setmanual "Pi Display Gadget" 192.168.69.1 255.255.255.0`.
- pidisplay shows `in>0 out=0` — V4L2 decoder refused the stream. Usually
  profile/level mismatch. Check `profile` in Encoder.swift.
- Sender shows `capture=0 fps` but `sender=60 fps` — SCStream has no content
  change events, FrameTicker is doing its job re-emitting the last frame.
  That's fine.

## Known quirks, not bugs

- First-boot sequence is *two* reboots (firstrun.sh + actual boot). Monitor
  shows kernel log frozen between them; not hung.
- After Mac sleep, the virtual display's `displayID` sometimes changes —
  main.swift retries `SCShareableContent` for 10 s on wake which handles it.
- `pidisplay` stats line uses millisecond-precision monotonic clock and
  reports period drift — expected; don't panic if it's ±50 ms off nominal.
