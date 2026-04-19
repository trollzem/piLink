import Foundation
import CoreMedia
import CoreVideo

/// Pumps frames into the encoder at a steady rate regardless of whether
/// ScreenCaptureKit is currently delivering new ones. The latest captured
/// image buffer is re-encoded on each tick with a monotonic PTS so VT
/// treats each tick as a new frame (emits tiny P-frames for unchanged pixels).
final class FrameTicker {
    private let queue = DispatchQueue(label: "pidisplay.ticker", qos: .userInteractive)
    private let fps: Int
    private var timer: DispatchSourceTimer?
    private var latest: CVImageBuffer?
    private var tick: Int64 = 0

    var onFrame: ((CVImageBuffer, CMTime, CMTime) -> Void)?

    init(fps: Int) { self.fps = fps }

    func submit(_ sb: CMSampleBuffer) {
        guard let ib = CMSampleBufferGetImageBuffer(sb) else { return }
        queue.async { [weak self] in self?.latest = ib }
    }

    func start() {
        let interval: DispatchTimeInterval = .nanoseconds(1_000_000_000 / fps)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .nanoseconds(500_000))
        t.setEventHandler { [weak self] in
            guard let self = self, let ib = self.latest else { return }
            let pts = CMTime(value: self.tick, timescale: CMTimeScale(self.fps))
            let dur = CMTime(value: 1, timescale: CMTimeScale(self.fps))
            self.tick &+= 1
            self.onFrame?(ib, pts, dur)
        }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }
}
