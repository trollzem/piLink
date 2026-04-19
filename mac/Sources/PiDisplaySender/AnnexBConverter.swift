import Foundation
import CoreMedia

/// Converts VideoToolbox AVCC-format H.264 sample buffers into Annex-B byte streams
/// that ffmpeg expects when fed over `-f h264`.
enum AnnexBConverter {
    private static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    static func convert(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var out = Data()

        // On keyframes, emit SPS/PPS as Annex-B before the IDR slice so ffmpeg can
        // decode even when the receiver joins mid-stream.
        if isKeyframe(sampleBuffer),
           let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            for ps in h264ParameterSets(from: formatDesc) {
                out.append(startCode, count: startCode.count)
                out.append(ps)
            }
        }

        var totalLength = 0
        var dataPtr: UnsafeMutablePointer<CChar>?
        let s = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPtr
        )
        guard s == noErr, let dataPtr = dataPtr else { return nil }

        let base = UnsafeRawPointer(dataPtr)
        var offset = 0
        while offset + 4 <= totalLength {
            let lenBE = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            let naluLength = Int(UInt32(bigEndian: lenBE))
            offset += 4
            guard naluLength > 0, offset + naluLength <= totalLength else { break }
            out.append(startCode, count: startCode.count)
            out.append(base.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
                       count: naluLength)
            offset += naluLength
        }

        return out
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        // Keyframe iff NotSync is absent or false
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }

    private static func h264ParameterSets(from formatDesc: CMFormatDescription) -> [Data] {
        var count: Int = 0
        // Probe count
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil
        )
        var out: [Data] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size: Int = 0
            let s = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: i,
                parameterSetPointerOut: &ptr,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            if s == noErr, let ptr = ptr, size > 0 {
                out.append(Data(bytes: ptr, count: size))
            }
        }
        return out
    }
}
