import Foundation
import Network

/// Maintains a TCP connection to an echo server on the Pi and measures
/// round-trip latency of small probes. Since the probe and the video stream
/// share the same USB-ethernet link, the probe RTT is a decent proxy for the
/// network-plus-kernel component of end-to-end video delay.
final class LatencyProbe {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "pidisplay.probe", qos: .utility)
    private var connection: NWConnection?
    private var isReady = false
    private var seq: UInt32 = 0
    private var pendingSent: [UInt32: Date] = [:]
    private var recentRTTs: [Double] = []   // ms, rolling window
    private var stopped = false

    init(host: String, port: UInt16) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() { queue.async { [weak self] in self?.connect() } }
    func stop()  { queue.async { [weak self] in self?.stopped = true; self?.connection?.cancel() } }

    /// Returns (min, avg, max) in ms for the current window, then resets it.
    func snapshot() -> (min: Double, avg: Double, max: Double, samples: Int)? {
        return queue.sync {
            guard !recentRTTs.isEmpty else { return nil }
            let minV = recentRTTs.min()!
            let maxV = recentRTTs.max()!
            let avgV = recentRTTs.reduce(0, +) / Double(recentRTTs.count)
            let n = recentRTTs.count
            recentRTTs.removeAll(keepingCapacity: true)
            return (minV, avgV, maxV, n)
        }
    }

    private func connect() {
        guard !stopped else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        let conn = NWConnection(host: host, port: port, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.isReady = true
                self.receive()
                self.scheduleProbe()
            case .failed, .cancelled:
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

    private func scheduleProbe() {
        guard !stopped, isReady, let conn = connection else { return }
        seq &+= 1
        let mySeq = seq
        var payload = Data(count: 8)
        payload.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: mySeq.bigEndian, toByteOffset: 0, as: UInt32.self)
            buf.storeBytes(of: UInt32(0).bigEndian, toByteOffset: 4, as: UInt32.self)
        }
        pendingSent[mySeq] = Date()
        conn.send(content: payload, completion: .idempotent)
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.scheduleProbe() }
    }

    private func receive() {
        guard !stopped, let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 8, maximumLength: 8) { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let data = data, data.count == 8 {
                let seq = data.withUnsafeBytes { buf -> UInt32 in
                    let raw = buf.load(as: UInt32.self)
                    return UInt32(bigEndian: raw)
                }
                if let sentAt = self.pendingSent.removeValue(forKey: seq) {
                    let rtt = Date().timeIntervalSince(sentAt) * 1000.0
                    self.recentRTTs.append(rtt)
                    if self.recentRTTs.count > 50 {
                        self.recentRTTs.removeFirst(self.recentRTTs.count - 50)
                    }
                }
            }
            if error == nil { self.receive() }
        }
    }
}
