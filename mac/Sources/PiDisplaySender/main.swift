import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit  // NSWorkspace for screen sleep/wake notifications

// Config
let width = 1920
let height = 1080
let fps = 60
let bitrate = 12_000_000
let keyframeInterval = 120
let piHost = "192.168.69.2"
let piPort: UInt16 = 5001

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("fatal: \(message)\n".utf8))
    exit(code)
}

// Create the virtual display
let virtualDisplay: VirtualDisplay
do {
    virtualDisplay = try VirtualDisplay(width: width, height: height, refreshRate: Double(fps))
    FileHandle.standardError.write(
        Data("virtual display created, displayID=\(virtualDisplay.displayID)\n".utf8))
} catch {
    fail("creating virtual display: \(error)")
}

// Set up the encoder + streamer pipeline
let encoder = Encoder(width: width, height: height)
let streamer = RTPStreamer(host: piHost, port: piPort)

do {
    try encoder.start(bitrate: bitrate, fps: fps, maxKeyframeInterval: keyframeInterval)
} catch {
    fail("starting encoder: \(error)")
}

var encodedCount = 0
var bytesSent = 0
var lastReport = Date()
let statsQueue = DispatchQueue(label: "pidisplay.stats")
encoder.onCompressedSample = { sb in
    statsQueue.async {
        encodedCount += 1
        if let db = CMSampleBufferGetDataBuffer(sb) {
            bytesSent += CMBlockBufferGetDataLength(db)
        }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastReport)
        if elapsed >= 1.0 {
            let fps = Double(encodedCount) / elapsed
            let kbps = Double(bytesSent) / elapsed * 8 / 1000
            FileHandle.standardError.write(
                Data(String(format: "sender: %.1f fps, %.0f kbps\n", fps, kbps).utf8))
            encodedCount = 0
            bytesSent = 0
            lastReport = now
        }
    }
    streamer.send(sb)
}

streamer.start()

let probe = LatencyProbe(host: piHost, port: 5002)
probe.start()

// Periodic stats: sender fps, bitrate, encode latency, probe RTT.
let statsTimer = DispatchSource.makeTimerSource(queue: statsQueue)
statsTimer.schedule(deadline: .now() + 2, repeating: 2.0)
statsTimer.setEventHandler {
    var line = "stats: "
    if let cap = capture.drainCaptureRate() {
        line += String(format: "capture=%.1f fps ", cap)
    }
    if let enc = encoder.drainEncodeLatency() {
        line += String(format: "encode=%.1f/%.1f/%.1f ms (n=%d) ",
                       enc.min, enc.avg, enc.max, enc.samples)
    }
    if let pr = probe.snapshot() {
        line += String(format: "rtt=%.1f/%.1f/%.1f ms (n=%d)",
                       pr.min, pr.avg, pr.max, pr.samples)
    }
    line += "\n"
    FileHandle.standardError.write(Data(line.utf8))
}
statsTimer.resume()

// Start capture against the newly-created virtual display.
// SCStream is event-driven; wrap it in a steady-rate ticker so we always emit
// frames to the encoder at `fps` Hz (duplicates cheap via P-frames).
let ticker = FrameTicker(fps: fps)
ticker.onFrame = { ib, pts, dur in encoder.encode(imageBuffer: ib, pts: pts, duration: dur) }
ticker.start()

let capture = Capture()
capture.onFrame = { frame in
    ticker.submit(frame)
}

// ScreenCaptureKit needs a moment for the freshly-created virtual display to
// appear in SCShareableContent. Retry briefly.
Task {
    var lastError: Error?
    for attempt in 1...40 {
        do {
            try await capture.start(
                displayID: virtualDisplay.displayID,
                width: width, height: height, fps: fps
            )
            FileHandle.standardError.write(Data("capture started (attempt \(attempt))\n".utf8))
            return
        } catch {
            lastError = error
            if attempt == 1 || attempt % 4 == 0 {
                FileHandle.standardError.write(
                    Data("capture attempt \(attempt) failed: \(error)\n".utf8))
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
    fail("capture did not start after 20s: \(lastError.map(String.init(describing:)) ?? "unknown")")
}

// Clean shutdown on SIGINT/SIGTERM
let sigSource1 = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigSource2 = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
for src in [sigSource1, sigSource2] {
    src.setEventHandler {
        FileHandle.standardError.write(Data("shutting down\n".utf8))
        Task {
            await capture.stop()
            encoder.stop()
            streamer.stop()
            exit(0)
        }
    }
    src.resume()
}

// Sleep/wake with the rest of the system's displays. When the Mac's own
// monitors go to sleep, we stop the capture+encode pipeline (so ScreenCaptureKit
// doesn't spin on a sleeping display) and send the Pi's monitor a blank frame.
// On wake, we restart capture.
let workspaceNC = NSWorkspace.shared.notificationCenter
workspaceNC.addObserver(
    forName: NSWorkspace.screensDidSleepNotification,
    object: nil, queue: .main
) { _ in
    FileHandle.standardError.write(Data("screens sleeping — pausing\n".utf8))
    Task { await capture.stop() }
    ticker.stop()
    // Force an immediate IDR of a black frame so the Pi monitor clears.
    // (Omitted — the overlay plane keeps the last frame until wake; acceptable.)
}
workspaceNC.addObserver(
    forName: NSWorkspace.screensDidWakeNotification,
    object: nil, queue: .main
) { _ in
    FileHandle.standardError.write(Data("screens woke — resuming\n".utf8))
    ticker.start()
    Task {
        // Give SCShareableContent a beat to re-inventory after wake.
        try? await Task.sleep(nanoseconds: 500_000_000)
        for attempt in 1...20 {
            do {
                try await capture.start(
                    displayID: virtualDisplay.displayID,
                    width: width, height: height, fps: fps)
                FileHandle.standardError.write(
                    Data("capture resumed (attempt \(attempt))\n".utf8))
                return
            } catch {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        FileHandle.standardError.write(Data("capture failed to resume\n".utf8))
    }
}

FileHandle.standardError.write(Data("streaming to \(piHost):\(piPort). Ctrl+C to stop.\n".utf8))
dispatchMain()
