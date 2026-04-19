import Foundation
import VideoToolbox
import CoreMedia

enum EncoderError: Error {
    case sessionCreationFailed(OSStatus)
    case propertySetFailed(String, OSStatus)
    case prepareFailed(OSStatus)
}

final class Encoder {
    private var session: VTCompressionSession?
    private let width: Int
    private let height: Int

    var onCompressedSample: ((CMSampleBuffer) -> Void)?
    /// Latest encode latency observations, in milliseconds.
    private(set) var encodeLatencyMs: [Double] = []
    private let latencyLock = NSLock()

    func drainEncodeLatency() -> (min: Double, avg: Double, max: Double, samples: Int)? {
        latencyLock.lock(); defer { latencyLock.unlock() }
        guard !encodeLatencyMs.isEmpty else { return nil }
        let mn = encodeLatencyMs.min()!, mx = encodeLatencyMs.max()!
        let avg = encodeLatencyMs.reduce(0, +) / Double(encodeLatencyMs.count)
        let n = encodeLatencyMs.count
        encodeLatencyMs.removeAll(keepingCapacity: true)
        return (mn, avg, mx, n)
    }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    func start(bitrate: Int, fps: Int, maxKeyframeInterval: Int) throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session = session else {
            throw EncoderError.sessionCreationFailed(status)
        }

        let setter: (CFString, CFTypeRef) throws -> Void = { key, value in
            let s = VTSessionSetProperty(session, key: key, value: value)
            if s != noErr {
                throw EncoderError.propertySetFailed(key as String, s)
            }
        }

        try setter(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        // Main profile compresses better than Baseline at the same bitrate; no B-frames needed.
        try setter(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        try setter(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        // CAVLC is ~20% lighter to decode than CABAC on the Pi's software decoder;
        // Main profile with CAVLC still beats Baseline's compression.
        try setter(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CAVLC)
        try setter(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        try setter(kVTCompressionPropertyKey_MaxKeyFrameInterval, maxKeyframeInterval as CFNumber)
        try setter(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                   (Double(maxKeyframeInterval) / Double(fps)) as CFNumber)
        try setter(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        try setter(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse)
        // macOS 14+: tell VT to pick the fastest encoding path over best quality.
        // Lumen sets this via ffmpeg's `prio_speed=1` — maps to this key.
        if #available(macOS 14.0, *) {
            let speedKey = "PrioritizeEncodingSpeedOverQuality" as CFString
            _ = VTSessionSetProperty(session, key: speedKey, value: kCFBooleanTrue)
        }
        // Allow ~1s of bitrate in bursts before throttling
        let dataRateLimits = [bitrate / 8, 1] as CFArray
        try setter(kVTCompressionPropertyKey_DataRateLimits, dataRateLimits)

        let prep = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prep == noErr else {
            throw EncoderError.prepareFailed(prep)
        }

        self.session = session
    }

    func encode(imageBuffer: CVImageBuffer, pts: CMTime, duration: CMTime) {
        guard let session = session else { return }
        let submittedAt = Date()
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, compressed in
            guard let self = self, status == noErr, let compressed = compressed else { return }
            let elapsed = Date().timeIntervalSince(submittedAt) * 1000.0
            self.latencyLock.lock()
            self.encodeLatencyMs.append(elapsed)
            if self.encodeLatencyMs.count > 240 { self.encodeLatencyMs.removeFirst(120) }
            self.latencyLock.unlock()
            self.onCompressedSample?(compressed)
        }
    }

    func stop() {
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }
}
