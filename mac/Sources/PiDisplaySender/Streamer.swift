import Foundation
import Network

final class Streamer {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "pidisplay.streamer", qos: .userInitiated)
    private var connection: NWConnection?
    private var stopped = false
    private var isReady = false

    init(host: String, port: UInt16) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() {
        queue.async { [weak self] in self?.connect() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopped = true
            self?.connection?.cancel()
        }
    }

    /// Drop the caller's payload if the TCP buffer isn't ready so we never queue
    /// latency. Always better to skip a frame than to send stale ones.
    func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self = self, self.isReady, let connection = self.connection else { return }
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    FileHandle.standardError.write(Data("send error: \(error)\n".utf8))
                }
            })
        }
    }

    private func connect() {
        guard !stopped else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 3
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let conn = NWConnection(host: host, port: port, using: parameters)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                FileHandle.standardError.write(Data("streamer connected to \(self.host):\(self.port)\n".utf8))
                self.isReady = true
            case .failed(let error):
                FileHandle.standardError.write(Data("streamer failed: \(error); reconnecting in 1s\n".utf8))
                self.isReady = false
                conn.cancel()
                self.queue.asyncAfter(deadline: .now() + 1) { self.connect() }
            case .waiting(let error):
                FileHandle.standardError.write(Data("streamer waiting: \(error)\n".utf8))
                self.isReady = false
            case .cancelled:
                self.isReady = false
                if !self.stopped {
                    self.queue.asyncAfter(deadline: .now() + 1) { self.connect() }
                }
            default:
                break
            }
        }
        connection = conn
        conn.start(queue: queue)
    }
}
