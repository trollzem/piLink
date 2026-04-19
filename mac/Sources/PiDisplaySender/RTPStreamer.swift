import Foundation
import Network
import CoreMedia

/// RFC 6184 H.264-over-RTP sender. Takes a VideoToolbox-produced
/// `CMSampleBuffer` (AVCC: length-prefixed NALs), splits it into NAL units,
/// and emits RTP packets over UDP. NALs larger than the MTU are fragmented
/// with FU-A. The M bit is set on the last packet of each access unit.
///
/// On keyframes we also emit SPS/PPS NALs from the format description so a
/// decoder that tunes in mid-stream can sync without waiting on an out-of-band
/// parameter set.
final class RTPStreamer {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "pidisplay.rtp", qos: .userInitiated)
    private var connection: NWConnection?
    private var isReady = false
    private var stopped = false

    private var sequenceNumber: UInt16 = UInt16.random(in: 0...UInt16.max)
    private let ssrc: UInt32 = UInt32.random(in: 1...UInt32.max)
    private let payloadType: UInt8 = 96

    /// Effective RTP payload budget per packet. USB-CDC MTU is 1500; minus
    /// IP (20) + UDP (8) + RTP (12) leaves 1460. Stay well below that.
    private let mtuPayloadLimit = 1400

    init(host: String, port: UInt16) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() { queue.async { [weak self] in self?.connect() } }

    func stop() {
        queue.async { [weak self] in
            self?.stopped = true
            self?.connection?.cancel()
        }
    }

    private func connect() {
        guard !stopped else { return }
        let udp = NWProtocolUDP.Options()
        let params = NWParameters(dtls: nil, udp: udp)
        let conn = NWConnection(host: host, port: port, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                FileHandle.standardError.write(Data("rtp sender ready -> \(self.host):\(self.port)\n".utf8))
                self.isReady = true
            case .failed(let error), .waiting(let error):
                FileHandle.standardError.write(Data("rtp sender \(state): \(error)\n".utf8))
                self.isReady = false
                if case .failed = state {
                    conn.cancel()
                    self.queue.asyncAfter(deadline: .now() + 1) { self.connect() }
                }
            case .cancelled:
                self.isReady = false
                if !self.stopped {
                    self.queue.asyncAfter(deadline: .now() + 1) { self.connect() }
                }
            default: break
            }
        }
        connection = conn
        conn.start(queue: queue)
    }

    func send(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var nals: [Data] = []

        if isKeyframe(sampleBuffer),
           let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            nals.append(contentsOf: h264ParameterSets(from: fmt))
        }

        var totalLength = 0
        var dataPtr: UnsafeMutablePointer<CChar>?
        let s = CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength, dataPointerOut: &dataPtr
        )
        guard s == noErr, let dataPtr = dataPtr else { return }
        let base = UnsafeRawPointer(dataPtr)

        var off = 0
        while off + 4 <= totalLength {
            let lenBE = base.loadUnaligned(fromByteOffset: off, as: UInt32.self)
            let naluLength = Int(UInt32(bigEndian: lenBE))
            off += 4
            guard naluLength > 0, off + naluLength <= totalLength else { break }
            nals.append(Data(bytes: base.advanced(by: off), count: naluLength))
            off += naluLength
        }

        guard !nals.isEmpty else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let rtpTs = UInt32(truncatingIfNeeded: Int64((CMTimeGetSeconds(pts) * 90_000.0).rounded()))

        queue.async { [weak self] in
            guard let self = self, self.isReady, let conn = self.connection else { return }
            for (i, nal) in nals.enumerated() {
                let last = (i == nals.count - 1)
                self.emitNAL(nal, timestamp: rtpTs, markerOnLast: last, conn: conn)
            }
        }
    }

    private func emitNAL(_ nal: Data, timestamp: UInt32, markerOnLast: Bool, conn: NWConnection) {
        guard !nal.isEmpty else { return }
        if nal.count <= mtuPayloadLimit {
            var pkt = rtpHeader(marker: markerOnLast, timestamp: timestamp)
            pkt.append(nal)
            conn.send(content: pkt, completion: .idempotent)
            return
        }
        // FU-A fragmentation
        let hdr = nal[0]
        let forbidden = (hdr & 0x80) >> 7
        let nri = (hdr & 0x60) >> 5
        let nalType = hdr & 0x1F
        let fuIndicator: UInt8 = (forbidden << 7) | (nri << 5) | 28  // FU-A

        let payload = nal.suffix(from: 1)  // strip original NAL header byte
        let fragSize = mtuPayloadLimit - 2  // account for FU indicator + FU header
        var offset = 0
        let total = payload.count
        while offset < total {
            let thisLen = min(fragSize, total - offset)
            let isStart = offset == 0
            let isEnd = offset + thisLen >= total
            var fuHeader: UInt8 = nalType
            if isStart { fuHeader |= 0x80 }  // S
            if isEnd   { fuHeader |= 0x40 }  // E

            var pkt = rtpHeader(marker: markerOnLast && isEnd, timestamp: timestamp)
            pkt.append(fuIndicator)
            pkt.append(fuHeader)
            let lo = payload.index(payload.startIndex, offsetBy: offset)
            let hi = payload.index(lo, offsetBy: thisLen)
            pkt.append(Data(payload[lo..<hi]))
            conn.send(content: pkt, completion: .idempotent)
            offset += thisLen
        }
    }

    private func rtpHeader(marker: Bool, timestamp: UInt32) -> Data {
        let seq = sequenceNumber
        sequenceNumber = sequenceNumber &+ 1
        var d = Data(count: 12)
        d[0] = 0x80  // V=2
        d[1] = payloadType | (marker ? 0x80 : 0)
        d[2] = UInt8((seq >> 8) & 0xFF)
        d[3] = UInt8(seq & 0xFF)
        d[4] = UInt8((timestamp >> 24) & 0xFF)
        d[5] = UInt8((timestamp >> 16) & 0xFF)
        d[6] = UInt8((timestamp >> 8) & 0xFF)
        d[7] = UInt8(timestamp & 0xFF)
        d[8] = UInt8((ssrc >> 24) & 0xFF)
        d[9] = UInt8((ssrc >> 16) & 0xFF)
        d[10] = UInt8((ssrc >> 8) & 0xFF)
        d[11] = UInt8(ssrc & 0xFF)
        return d
    }

    private func isKeyframe(_ sb: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sb, createIfNecessary: false
        ) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }

    private func h264ParameterSets(from formatDesc: CMFormatDescription) -> [Data] {
        var count: Int = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        )
        var out: [Data] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size: Int = 0
            let s = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            if s == noErr, let ptr = ptr, size > 0 {
                out.append(Data(bytes: ptr, count: size))
            }
        }
        return out
    }
}
