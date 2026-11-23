import Foundation
import Network
import CryptoKit

/// The foreground app listens on loopback for USB connections from the Mac.
/// Each local HTTP connection uses one authenticated USB socket.
final class USBTransport {
    var onReady: ((URL) -> Void)?
    var onState: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    private(set) var localURL: URL?
    private let queue = DispatchQueue(label: "stream.usb.transport", qos: .userInteractive)
    private var deviceListener: NWListener?
    private var localListener: NWListener?
    private var token = ""
    private var generation = UUID()
    private var idle: [NWConnection] = []
    private var pending: [NWConnection] = []
    private var authenticating: [ObjectIdentifier: NWConnection] = [:]
    private var pipes: [UUID: USBPipe] = [:]
    private var readyReported = false
    private var stopping = true

    enum Failure: Error, LocalizedError {
        case invalidToken
        var errorDescription: String? { "USB 会话令牌无效，请重新配对。" }
    }

    func start(token: String, devicePort: UInt16 = 49372) throws {
        guard (16...256).contains(token.utf8.count), token.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { throw Failure.invalidToken }
        let remote = try NWListener(using: Self.parameters(port: devicePort))
        let local = try NWListener(using: Self.parameters(port: 0))
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            self.stopping = false; self.token = token
            self.deviceListener = remote; self.localListener = local
            let current = self.generation
            remote.newConnectionHandler = { [weak self] in self?.acceptUSB($0, current: current) }
            local.newConnectionHandler = { [weak self] in self?.acceptLocal($0, current: current) }
            remote.stateUpdateHandler = { [weak self] state in
                guard let self, current == self.generation else { return }
                if case .failed = state { self.failed("USB 监听失败") }
            }
            local.stateUpdateHandler = { [weak self] state in
                guard let self, current == self.generation else { return }
                switch state {
                case .ready:
                    guard let port = local.port else { return }
                    self.localURL = URL(string: "http://127.0.0.1:\(port.rawValue)")
                    self.reportReady()
                case .failed: self.failed("USB 本机通道不可用")
                default: break
                }
            }
            remote.start(queue: self.queue); local.start(queue: self.queue)
            self.state("USB 等待 Mac 连接")
        }
    }

    // Callers may immediately drop their last reference after stop(). Retain the
    // transport until its serialized cleanup has actually run.
    func stop() { queue.async { self.stopOnQueue() } }

    private static func parameters(port: UInt16) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2; tcp.keepaliveInterval = 1; tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func acceptUSB(_ connection: NWConnection, current: UUID) {
        guard current == generation, !stopping,
              authenticating.count + idle.count + pipes.count < 12 else { connection.cancel(); return }
        let identity = ObjectIdentifier(connection)
        authenticating[identity] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.generation == current else { return }
            switch state {
            case .ready:
                self.challenge(connection, current: current)
            case .failed, .cancelled: self.removeIdle(connection, current: current)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 4) { [weak self, weak connection] in
            guard let self, let connection, current == self.generation,
                  self.authenticating[identity] != nil else { return }
            self.authenticating.removeValue(forKey: identity); connection.cancel()
        }
    }

    private func challenge(_ connection: NWConnection, current: UUID) {
        let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let hex = nonce.map { String(format: "%02x", $0) }.joined()
        let key = SymmetricKey(data: Data(token.utf8))
        let proof = HMAC<SHA256>.authenticationCode(for: Data("GSUSB1:".utf8) + nonce, using: key)
        let expected = Data(("AUTH " + proof.map { String(format: "%02x", $0) }.joined() + "\n").utf8)
        connection.send(content: Data("GSUSB1 \(hex)\n".utf8), completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, current == self.generation else { return }
            guard error == nil else { connection.cancel(); return }
            self.readAuth(connection, expected: expected, current: current)
        })
    }

    private func readAuth(_ connection: NWConnection, expected: Data, current: UUID) {
        connection.receive(minimumIncompleteLength: expected.count, maximumLength: expected.count) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, current == self.generation else { return }
            guard error == nil, !complete, let data, Self.constantTimeEqual(data, expected) else {
                self.authenticating.removeValue(forKey: ObjectIdentifier(connection)); connection.cancel(); return
            }
            connection.send(content: Data("OK\n".utf8), completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection, current == self.generation else { return }
                self.authenticating.removeValue(forKey: ObjectIdentifier(connection))
                guard error == nil else { connection.cancel(); return }
                self.idle.append(connection)
                self.watchIdle(connection, current: current)
                self.reportReady(); self.pair()
            })
        }
    }

    // Keep a receive outstanding even for idle slots: unplug/EOF must not leave
    // apparently ready sockets in the pool. Once assigned, transfer that first
    // receive to the pipe instead of starting a concurrent receive.
    private func watchIdle(_ connection: NWConnection, current: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, current == self.generation else { return }
            if let pipe = self.pipes.values.first(where: { $0.remote === connection }) {
                pipe.firstRemoteReceive(data: data, complete: complete, error: error)
            } else {
                self.removeIdle(connection, current: current)
                connection.cancel()
            }
        }
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }

    private func acceptLocal(_ connection: NWConnection, current: UUID) {
        guard current == generation, !stopping, pending.count < 8, readyReported else { connection.cancel(); return }
        pending.append(connection)
        connection.start(queue: queue)
        pair()
        queue.asyncAfter(deadline: .now() + 3) { [weak self, weak connection] in
            guard let self, let connection, current == self.generation,
                  let index = self.pending.firstIndex(where: { $0 === connection }) else { return }
            self.pending.remove(at: index); connection.cancel()
        }
    }

    private func pair() {
        while !idle.isEmpty && !pending.isEmpty {
            let local = pending.removeFirst(), remote = idle.removeFirst()
            let id = UUID(), current = generation
            let pipe = USBPipe(local: local, remote: remote) { [weak self] failed in
                guard let self, current == self.generation else { return }
                self.pipes.removeValue(forKey: id)
                // Any failed active tunnel invalidates the controller lease locally.
                // Existing host watchdog and native stream close release remotely.
                if failed { self.failed("USB 连接已中断") }
            }
            pipes[id] = pipe
            pipe.start()
        }
    }

    private func removeIdle(_ connection: NWConnection, current: UUID) {
        authenticating.removeValue(forKey: ObjectIdentifier(connection))
        idle.removeAll { $0 === connection }
        guard readyReported, !stopping else { return }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, current == self.generation, self.readyReported,
                  self.idle.isEmpty, self.pipes.isEmpty else { return }
            self.failed("USB 连接已断开")
        }
    }

    private func reportReady() {
        guard !readyReported, idle.count >= 2, let url = localURL else { return }
        readyReported = true
        state("USB 数据通道已连接")
        DispatchQueue.main.async { [weak self] in self?.onReady?(url) }
    }

    private func state(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onState?(message) }
    }

    private func failed(_ message: String) {
        guard !stopping else { return }
        stopOnQueue(); state(message)
        DispatchQueue.main.async { [weak self] in self?.onDisconnect?() }
    }

    private func stopOnQueue() {
        stopping = true; generation = UUID(); readyReported = false; localURL = nil; token = ""
        deviceListener?.cancel(); deviceListener = nil
        localListener?.cancel(); localListener = nil
        for connection in idle + pending + Array(authenticating.values) { connection.cancel() }
        idle.removeAll(); pending.removeAll(); authenticating.removeAll()
        // Detach the collection before cancellation. cancel() marks each pipe
        // finished and does not invoke completion; any queued callback is also
        // invalidated by the generation change above.
        let closingPipes = Array(pipes.values)
        pipes.removeAll()
        for pipe in closingPipes { pipe.cancel() }
    }
}

private final class USBPipe {
    let local: NWConnection
    let remote: NWConnection
    let completion: (Bool) -> Void
    private var finished = false
    init(local: NWConnection, remote: NWConnection, completion: @escaping (Bool) -> Void) {
        self.local = local; self.remote = remote; self.completion = completion
    }
    func start() {
        for connection in [local, remote] {
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.finish(failed: true) }
            }
        }
        pump(from: local, to: remote)
        // The remote already has exactly one receive armed by watchIdle.
    }
    func firstRemoteReceive(data: Data?, complete: Bool, error: NWError?) {
        received(data: data, complete: complete, error: error, from: remote, to: local)
    }
    func cancel() {
        finished = true; local.cancel(); remote.cancel()
    }
    private func finish(failed: Bool) {
        guard !finished else { return }
        finished = true; local.cancel(); remote.cancel(); completion(failed)
    }
    private func end(_ destination: NWConnection) {
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true,
                         completion: .contentProcessed { [weak self] error in
            self?.finish(failed: error != nil)
        })
    }
    private func pump(from source: NWConnection, to destination: NWConnection) {
        guard !finished else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            self?.received(data: data, complete: complete, error: error, from: source, to: destination)
        }
    }
    private func received(data: Data?, complete: Bool, error: NWError?, from source: NWConnection, to destination: NWConnection) {
        guard !finished else { return }
        guard error == nil else { finish(failed: true); return }
        if let data, !data.isEmpty {
            destination.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.finished else { return }
                if error != nil { self.finish(failed: true) }
                else if complete { self.end(destination) }
                else { self.pump(from: source, to: destination) }
            })
        } else {
            if complete { end(destination) }
            else { pump(from: source, to: destination) }
        }
    }
}
