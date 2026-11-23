import Foundation

struct StreamWindow: Decodable, Equatable, Identifiable {
    let id: UInt32
    let pid: Int32
    let application: String
    let title: String
    let onScreen: Bool

    var label: String {
        if application.isEmpty { return title.isEmpty ? "Window \(id)" : title }
        return title.isEmpty || title == application ? application : "\(application) · \(title)"
    }

    enum CodingKeys: String, CodingKey {
        case id = "window_id"
        case pid, application, title
        case onScreen = "on_screen"
    }
}

enum CaptureTool {
    enum Failure: Error {
        case permission
        case unavailable
    }

    static var executable: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/StreamCapture.app/Contents/MacOS/StreamCapture")
    }

    static func list() throws -> [StreamWindow] {
        let preflight = try run(["--preflight"])
        if preflight.status == 77 { throw Failure.permission }
        guard preflight.status == 0 else { throw Failure.unavailable }
        let result = try run(["--list-windows"])
        guard result.status == 0 else { throw Failure.unavailable }
        return try JSONDecoder().decode([StreamWindow].self, from: result.data)
            .filter { $0.pid > 0 && $0.onScreen && (!$0.title.isEmpty || !$0.application.isEmpty) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    static func requestPermission() throws {
        _ = try run(["--request-permission"])
    }

    private static func run(_ arguments: [String]) throws -> (status: Int32, data: Data) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        let limit: Double = arguments.first == "--request-permission" ? 120 : 15
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return (process.terminationStatus, data)
    }
}
