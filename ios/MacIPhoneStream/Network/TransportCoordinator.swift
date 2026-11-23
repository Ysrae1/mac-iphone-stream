import Foundation

/// Owns the selected route. The session controller manages leases and touch recovery.
final class TransportCoordinator {
    enum Route: CaseIterable {
        case lan, usb

        var title: String {
            switch self {
            case .lan: return "局域网"
            case .usb: return "USB"
            }
        }
    }

    var onState: ((String) -> Void)?
    var onReady: ((Connection) -> Void)?
    var onFailure: ((String) -> Void)?

    private var epoch = UUID()
    private var usb: USBTransport?
    private var deadline: DispatchWorkItem?
    private var delivered = false

    func start(_ route: Route, connection: Connection) {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        if route == .lan {
            onReady?(connection)
            return
        }
        let current = epoch
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.delivered else { return }
            self.fail("未连接 USB 通道。请确认数据线、设备信任状态和 Mac 主机。", current: current)
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)

        let transport = USBTransport()
        usb = transport
        transport.onState = { [weak self] message in
            guard let self, self.epoch == current else { return }
            self.onState?(message)
        }
        transport.onReady = { [weak self] url in
            self?.deliverUSB(url, token: connection.token, current: current)
        }
        transport.onDisconnect = { [weak self] in
            self?.fail("USB 连接已中断，触点已释放。", current: current)
        }
        do { try transport.start(token: connection.token) }
        catch { fail(error.localizedDescription, current: current) }
    }

    func stop() {
        epoch = UUID()
        deadline?.cancel()
        deadline = nil
        usb?.stop()
        usb = nil
        delivered = false
    }

    private func deliverUSB(_ url: URL, token: String, current: UUID) {
        guard epoch == current, !delivered else { return }
        do {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw Connection.Invalid.address
            }
            components.fragment = "token=" + token
            let connection = try Connection(text: components.string ?? "")
            delivered = true
            deadline?.cancel()
            deadline = nil
            onReady?(connection)
        } catch {
            fail(error.localizedDescription, current: current)
        }
    }

    private func fail(_ message: String, current: UUID) {
        guard epoch == current else { return }
        stop()
        onFailure?(message)
    }
}
