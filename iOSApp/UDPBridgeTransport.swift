import Foundation
import Network

@MainActor
protocol BridgeTransporting: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onMessage: ((Data) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func open(host: String, port: UInt16)
    func send(_ data: Data)
    func close(afterSending stop: Data?)
}

/// Connected UDP restricts replies to the configured peer. This is not authentication.
@MainActor
final class UDPBridgeTransport: BridgeTransporting {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "simplecontroller.bridge", qos: .userInteractive)

    func open(host: String, port: UInt16) {
        close()
        guard let networkPort = NWEndpoint.Port(rawValue: port) else { return }
        let link = NWConnection(host: NWEndpoint.Host(host), port: networkPort, using: .udp)
        connection = link
        link.stateUpdateHandler = { [weak self, weak link] state in
            Task { @MainActor in
                guard let self, let link, self.connection === link else { return }
                switch state {
                case .ready:
                    self.onReady?()
                case .failed(let error):
                    self.onFailure?(error.localizedDescription)
                case .waiting(let error):
                    self.onFailure?(error.localizedDescription)
                default:
                    break
                }
            }
        }
        link.start(queue: queue)
        receive(on: link)
    }

    func send(_ data: Data) {
        guard let link = connection else { return }
        link.send(content: data, completion: .contentProcessed { [weak self, weak link] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, let link, self.connection === link else { return }
                self.onFailure?(error.localizedDescription)
            }
        })
    }

    /// Repeated stop is best effort; the bridge lease remains essential after radio loss.
    func close(afterSending stop: Data? = nil) {
        guard let old = connection else { return }
        connection = nil
        old.stateUpdateHandler = nil
        guard let stop else { old.cancel(); return }
        for _ in 0..<3 {
            old.send(content: stop, completion: .idempotent)
        }
        queue.asyncAfter(deadline: .now() + 0.2) { old.cancel() }
    }

    private func receive(on link: NWConnection) {
        link.receiveMessage { [weak self, weak link] data, _, _, error in
            Task { @MainActor in
                guard let self, let link, self.connection === link else { return }
                if let error {
                    self.onFailure?(error.localizedDescription)
                    return
                }
                if let data { self.onMessage?(data) }
                // A callback may have closed or replaced the connection.
                if self.connection === link { self.receive(on: link) }
            }
        }
    }
}
