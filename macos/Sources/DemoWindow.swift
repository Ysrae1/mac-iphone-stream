import AppKit
import AVFoundation

struct PhoneContact: Decodable {
    let id: UInt32
    let phase: Int
    let x: Double
    let y: Double
}

@MainActor
final class DemoWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    var didClose: (() -> Void)?
    private let canvas = DemoCanvas()
    private var player: AVAudioPlayer?
    private var clock: Timer?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.delegate = self
        window.title = "串流触控测试"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 280)
        window.contentView = canvas
        window.center()

        let tone = NSButton(title: "播放测试音", target: self, action: #selector(playTone))
        tone.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(tone)
        NSLayoutConstraint.activate([
            tone.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -24),
            tone.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 44),
        ])
    }

    var captureTarget: StreamWindow? {
        guard let id = UInt32(exactly: window.windowNumber), id > 0, window.isVisible else { return nil }
        return StreamWindow(id: id, pid: ProcessInfo.processInfo.processIdentifier,
                            application: "Mac iPhone Stream", title: window.title, onScreen: true)
    }

    func open() {
        window.makeKeyAndOrderFront(nil)
        guard clock == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window.isVisible, !self.window.isMiniaturized else { return }
                self.canvas.updateClock()
            }
        }
    }

    func apply(_ contacts: [PhoneContact]) {
        canvas.apply(contacts)
    }

    func windowWillClose(_ notification: Notification) {
        canvas.apply([])
        player?.stop()
        clock?.invalidate()
        clock = nil
        didClose?()
    }

    @objc private func playTone() {
        let rate = 48_000
        let count = rate / 2
        let length = UInt32(count * 2)
        var wave = Data()
        func append<T: FixedWidthInteger>(_ integer: T) {
            var value = integer.littleEndian
            Swift.withUnsafeBytes(of: &value) { wave.append(contentsOf: $0) }
        }
        wave.append(Data("RIFF".utf8))
        append(length + 36)
        wave.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))
        append(UInt16(16))
        wave.append(Data("data".utf8))
        append(length)
        for i in 0..<count {
            let fraction = Double(i) / Double(count)
            let gain = min(1, fraction * 20, (1 - fraction) * 8)
            let sample = sin(2 * .pi * 523.25 * Double(i) / Double(rate)) * 5_000 * gain
            append(Int16(sample))
        }
        player?.stop()
        player = try? AVAudioPlayer(data: wave)
        player?.play()
    }
}

@MainActor
private final class DemoCanvas: NSView {
    private var active: [UInt32: PhoneContact] = [:]
    private var time = Date()
    private let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func apply(_ contacts: [PhoneContact]) {
        if contacts.isEmpty {
            guard !active.isEmpty else { return }
            active.removeAll(keepingCapacity: true)
        } else {
            for touch in contacts {
                if touch.phase == 3 { active.removeValue(forKey: touch.id) }
                if touch.phase == 1 || touch.phase == 2 { active[touch.id] = touch }
            }
        }
        needsDisplay = true
    }

    func updateClock() {
        time = Date()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSColor(srgbRed: 0.045, green: 0.09, blue: 0.13, alpha: 1)
        background.setFill()
        bounds.fill()

        NSColor.white.withAlphaComponent(0.08).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 1
        for index in 1..<8 {
            let fraction = CGFloat(index) / 8
            let x = bounds.width * fraction
            let y = bounds.height * fraction
            grid.move(to: NSPoint(x: x, y: 0))
            grid.line(to: NSPoint(x: x, y: bounds.height))
            grid.move(to: NSPoint(x: 0, y: y))
            grid.line(to: NSPoint(x: bounds.width, y: y))
        }
        grid.stroke()

        text("串流触控测试", at: NSPoint(x: 24, y: 42), size: 22, weight: .semibold)
        text("在 iPhone 画面上落下并移动手指。", at: NSPoint(x: 25, y: 76), size: 13, alpha: 0.74)
        text("活跃触点  \(active.count)", at: NSPoint(x: 25, y: bounds.height - 36),
             size: 14, weight: .medium, alpha: 0.82)
        let timestamp = clockFormatter.string(from: time) as NSString
        let clockFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let clockText: [NSAttributedString.Key: Any] = [
            .font: clockFont, .foregroundColor: NSColor.white.withAlphaComponent(0.76)
        ]
        timestamp.draw(at: NSPoint(x: bounds.width - 25 - timestamp.size(withAttributes: clockText).width,
                                   y: bounds.height - 36), withAttributes: clockText)

        for touch in active.values.sorted(by: { $0.id < $1.id }) {
            let x = bounds.width * min(1, max(0, touch.x))
            let y = bounds.height * min(1, max(0, touch.y))
            let hue = CGFloat((UInt64(touch.id) * 41 + 156) % 360) / 360
            let color = NSColor(hue: hue, saturation: 0.68, brightness: 0.97, alpha: 1)
            let marker = NSBezierPath(ovalIn: NSRect(x: x - 17, y: y - 17, width: 34, height: 34))
            color.withAlphaComponent(0.33).setFill()
            marker.fill()
            color.setStroke()
            marker.lineWidth = 2
            marker.stroke()
            let label = String(touch.id)
            let labelX = min(max(x + 22, 10), bounds.width - 91)
            let labelY = min(max(y - 8, 15), bounds.height - 24)
            text(label, at: NSPoint(x: labelX, y: labelY), size: 13, weight: .semibold)
        }
    }

    private func text(_ value: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular,
                      alpha: CGFloat = 1) {
        (value as NSString).draw(at: point, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha)
        ])
    }
}
