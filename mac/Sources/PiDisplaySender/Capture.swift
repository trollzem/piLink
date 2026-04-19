import Foundation
import ScreenCaptureKit
import CoreMedia

final class Capture: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "pidisplay.capture", qos: .userInteractive)
    private var captureCount = 0
    private var lastCaptureReport = Date()
    private let captureLock = NSLock()

    var onFrame: ((CMSampleBuffer) -> Void)?

    func drainCaptureRate() -> Double? {
        captureLock.lock(); defer { captureLock.unlock() }
        let elapsed = Date().timeIntervalSince(lastCaptureReport)
        guard elapsed >= 0.5 else { return nil }
        let rate = Double(captureCount) / elapsed
        captureCount = 0
        lastCaptureReport = Date()
        return rate
    }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        let content = try await SCShareableContent.current
        guard let target = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(
                domain: "Capture", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "virtual display \(displayID) not visible to ScreenCaptureKit"]
            )
        }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 3
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.capturesAudio = false

        let filter = SCContentFilter(display: target, excludingWindows: [])

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // SCStreamOutput
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Filter out non-frame status messages (idle frames are delivered with no imageBuffer)
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue else {
            return
        }

        captureLock.lock(); captureCount += 1; captureLock.unlock()
        onFrame?(sampleBuffer)
    }

    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("capture stopped: \(error)\n".utf8))
    }
}
