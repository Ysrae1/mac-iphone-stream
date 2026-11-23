import AppKit
import Combine
import Darwin
import Foundation

struct PendingPair: Decodable, Identifiable {
    let id: String
    let name: String
    let code: String

    enum CodingKeys: String, CodingKey {
        case id = "pair_id"
        case name, code
    }
}

struct TrustedPhone: Decodable, Identifiable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "device_id"
        case name
    }
}

struct HostStatus: Decodable {
    var serviceError: String?
    var windowID: UInt32?
    var stream = "idle"
    var connectionURL: String?
    var invitation: String?
    var pairingOpen = false
    var pending: [PendingPair] = []
    var devices: [TrustedPhone] = []
    var usb = "idle"

    enum CodingKeys: String, CodingKey {
        case serviceError = "service_error"
        case windowID = "window_id"
        case connectionURL = "connection_url"
        case pairingOpen = "pairing_open"
        case stream, invitation, pending, devices, usb
    }
}

private struct HostReply: Decodable {
    let id: Int
    let ok: Bool
    let status: HostStatus?
    let error: String?
}

private struct HostEvent: Decodable {
    let event: String
    let contacts: [PhoneContact]
}

@MainActor
final class HostModel: ObservableObject {
    @Published private(set) var windows: [StreamWindow] = []
    @Published private(set) var status = HostStatus()
    @Published private(set) var probing = false
    @Published private(set) var permissionRequired = false
    @Published private(set) var captureError: String?
    @Published private(set) var message: String?
    @Published private(set) var serviceRunning = false
    @Published private(set) var working = false

    private let demo = DemoWindow()
    private var demoID: UInt32?
    private var process: Process?
    private var input: FileHandle?
    private var poll: Timer?
    private var nextID = 0
    private var requests: [Int: String] = [:]
    private var quitting: (() -> Void)?

    var demoSelected: Bool { demoID != nil && demoID == status.windowID }
    var visibleWindows: [StreamWindow] {
        guard let target = demo.captureTarget, !windows.contains(where: { $0.id == target.id }) else { return windows }
        return [target] + windows
    }

    init() {
        demo.didClose = { [weak self] in self?.closedDemo() }
    }

    func begin() {
        signal(SIGPIPE, SIG_IGN)
        launch()
        refreshWindows()
    }

    func launch() {
        guard process == nil, !working else { return }
        working = true
        message = nil
        Task {
            let python = await Task.detached(priority: .utility) {
                Self.pythonExecutable()
            }.value
            working = false
            launchService(python)
        }
    }

    private func launchService(_ python: URL?) {
        guard let python,
              let service = Bundle.main.url(forResource: "main", withExtension: "py", subdirectory: "host") else {
            message = "找不到主机服务。请安装 Python 3.11 或更新版本，再从源码构建 App。"
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let state = home.appendingPathComponent("Library/Application Support/Mac-iPhone-Stream", isDirectory: true)
        let child = Process()
        let childInput = Pipe()
        let childOutput = Pipe()
        child.executableURL = python
        child.arguments = ["-B", "-E", "-s", service.path, "--state-dir", state.path, "--capture", CaptureTool.executable.path]
        child.standardInput = childInput
        child.standardOutput = childOutput
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
        } catch {
            message = "主机服务未能启动。请核对 Python 版本后重试。"
            return
        }
        process = child
        input = childInput.fileHandleForWriting
        serviceRunning = true
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.requests.isEmpty, self.quitting == nil else { return }
                self.send("status")
            }
        }
        let reader = childOutput.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data()
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if line.count <= 65_536 {
                        DispatchQueue.main.async { [weak self] in self?.receive(line, from: child) }
                    }
                }
                if buffer.count > 65_536 { buffer.removeAll() }
            }
            DispatchQueue.main.async { [weak self] in self?.ended(child) }
        }
        send("status")
    }

    func refreshWindows(requestPermission: Bool = false) {
        guard !probing else { return }
        probing = true
        captureError = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    if requestPermission { try CaptureTool.requestPermission() }
                    return try CaptureTool.list()
                }
            }.value
            probing = false
            switch result {
            case .success(let items):
                permissionRequired = false
                let hostPID = ProcessInfo.processInfo.processIdentifier
                windows = items.filter { $0.pid != hostPID || $0.id == demoID }
                if let selected = status.windowID, !visibleWindows.contains(where: { $0.id == selected }) {
                    send("select", ["window_id": NSNull()])
                }
            case .failure(CaptureTool.Failure.permission):
                permissionRequired = true
                windows = []
            case .failure:
                captureError = "无法列出窗口。请重试窗口扫描。"
            }
        }
    }

    func choose(_ id: UInt32) {
        message = nil
        guard id != 0 else {
            send("select", ["window_id": NSNull()])
            return
        }
        guard let target = visibleWindows.first(where: { $0.id == id }) else {
            message = "该窗口已关闭，请重新选择。"
            return
        }
        send("select", ["window_id": target.id, "window_pid": target.pid, "demo": target.id == demoID])
    }

    func openDemo() {
        demo.open()
        if let target = demo.captureTarget {
            demoID = target.id
            choose(target.id)
        }
        refreshWindows()
    }

    private func closedDemo() {
        if let id = demoID {
            demoID = nil
            windows.removeAll { $0.id == id }
            if status.windowID == id || requests.values.contains("select") { send("select", ["window_id": NSNull()]) }
        }
    }

    func action(_ command: String, _ arguments: [String: Any] = [:]) {
        message = nil
        send(command, arguments)
    }

    func quit(_ reply: @escaping () -> Void) {
        guard let child = process else { reply(); return }
        guard quitting == nil else { return }
        quitting = reply
        poll?.invalidate()
        send("quit")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard self?.process === child, child.isRunning else { return }
            child.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.process === child else { return }
            self.ended(child)
        }
    }

    private func send(_ command: String, _ arguments: [String: Any] = [:]) {
        guard let input else { return }
        nextID += 1
        var payload = arguments
        payload["id"] = nextID
        payload["command"] = command
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        requests[nextID] = command
        if command != "status" { working = true }
        do {
            try input.write(contentsOf: data + Data([10]))
        } catch {
            requests.removeValue(forKey: nextID)
            working = requests.values.contains { $0 != "status" }
            if quitting == nil { message = "主机服务已断开。" }
        }
    }

    private func receive(_ data: Data, from child: Process) {
        guard process === child else { return }
        let decoder = JSONDecoder()
        if let reply = try? decoder.decode(HostReply.self, from: data) {
            guard let command = requests.removeValue(forKey: reply.id) else { return }
            working = requests.values.contains { $0 != "status" }
            if let next = reply.status {
                if next.stream == "idle" || next.windowID != status.windowID { demo.apply([]) }
                status = next
            }
            if !reply.ok && command != "status" {
                message = Self.message(for: reply.error)
            }
        } else if let event = try? decoder.decode(HostEvent.self, from: data), event.event == "touch" {
            if demoSelected || event.contacts.isEmpty { demo.apply(event.contacts) }
        }
    }

    private func ended(_ child: Process) {
        guard process === child else { return }
        input = nil
        process = nil
        serviceRunning = false
        working = false
        poll?.invalidate()
        poll = nil
        requests.removeAll()
        demo.apply([])
        status = HostStatus()
        if let done = quitting {
            quitting = nil
            done()
        } else {
            message = "主机服务已退出，可以重新启动。"
        }
    }

    private nonisolated static func pythonExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["MAC_IPHONE_STREAM_PYTHON"] {
            guard override.hasPrefix("/") else { return nil }
            let candidate = URL(fileURLWithPath: override)
            return supportedPython(candidate) ? candidate : nil
        }
        let path = environment["PATH", default: ""].split(separator: ":").map(String.init)
        let directories = path + ["/opt/homebrew/bin", "/usr/local/bin"]
        var checked: Set<String> = []
        for directory in directories where directory.hasPrefix("/") && !checked.contains(directory) {
            checked.insert(directory)
            for name in ["python3", "python3.14", "python3.13", "python3.12", "python3.11"] {
                // Avoid invoking the macOS command-line-tools installation stub.
                guard directory != "/usr/bin" else { continue }
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if supportedPython(candidate) { return candidate }
            }
        }
        return nil
    }

    private nonisolated static func supportedPython(_ candidate: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else { return false }
        let process = Process()
        process.executableURL = candidate
        process.arguments = ["-I", "-B", "-c", "import sys; sys.exit(sys.version_info < (3, 11))"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()
        return process.terminationStatus == 0
    }

    private static func message(for error: String?) -> String {
        switch error {
        case "select_window_first", "invalid_window": return "请先选择要串流的窗口。"
        case "window_unavailable", "capture_failed", "capture_helper_missing": return "所选窗口无法采集，请检查录屏权限并重新选择。"
        case "code_mismatch", "pair_not_pending": return "配对码已过期或不匹配，请重新配对。"
        default: return "主机未能执行该操作。请检查窗口、连接和权限后重试。"
        }
    }
}
