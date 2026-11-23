import UIKit

final class TouchSurfaceView: UIView {
    var safeBounds = CGRect.zero { didSet { if safeBounds != oldValue { releaseAll() } } }
    var videoSize = CGSize.zero { didSet { if videoSize != oldValue { releaseAll() } } }
    var clientRect = CGRect(x: 0, y: 0, width: 1, height: 1) { didSet { if clientRect != oldValue { releaseAll() } } }
    var acceptsTouches = false { didSet { if !acceptsTouches { releaseAll() } } }
    var onFrame: (([TouchContact]) -> Void)?
    private var tracked: [ObjectIdentifier: TouchContact] = [:]
    private var nextID: UInt32 = 1
    private var lastBounds = CGRect.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "串流触控画面"
        accessibilityHint = "在画面内点按或多点触控"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds != lastBounds { releaseAll(); lastBounds = bounds }
    }
    func releaseAll() {
        guard !tracked.isEmpty else { return }
        tracked.removeAll()
        onFrame?([])
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsTouches else { return }
        var phases: [ObjectIdentifier: Int] = [:]
        for touch in touches where acceptsInputType(touch) {
            guard tracked.count < 10,
                  let point = map(touch, clamp: false) else { continue }
            let key = ObjectIdentifier(touch)
            if nextID == UInt32.max { releaseAll(); nextID = 1 }
            tracked[key] = TouchContact(id: nextID, phase: 1, x: point.x, y: point.y)
            nextID += 1
            phases[key] = 1
        }
        emit(phases)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsTouches else { return }
        var phases: [ObjectIdentifier: Int] = [:]
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard var contact = tracked[key], let point = map(touch, clamp: true) else { continue }
            contact.x = point.x; contact.y = point.y
            tracked[key] = contact; phases[key] = 2
        }
        emit(phases)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        var phases: [ObjectIdentifier: Int] = [:]
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard var contact = tracked[key] else { continue }
            if let point = map(touch, clamp: true) { contact.x = point.x; contact.y = point.y }
            tracked[key] = contact; phases[key] = 3
        }
        emit(phases)
        for key in phases.keys { tracked.removeValue(forKey: key) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { releaseAll() }
    private func acceptsInputType(_ touch: UITouch) -> Bool {
        #if targetEnvironment(macCatalyst)
        // Native Mac pointer path for desktop integration checks; never evidence of iPhone multi-touch.
        return touch.type == .direct || touch.type == .indirectPointer
        #else
        return touch.type == .direct
        #endif
    }
    private func map(_ touch: UITouch, clamp: Bool) -> CGPoint? {
        VideoGeometry.map(touch.location(in: self), videoRect: VideoGeometry.croppedPresentation(video: videoSize, bounds: safeBounds, clientRect: clientRect).viewport, clamp: clamp)
    }
    private func emit(_ phases: [ObjectIdentifier: Int]) {
        guard !phases.isEmpty else { return }
        let snapshot = tracked.map { key, value -> TouchContact in
            var contact = value; contact.phase = phases[key] ?? 2; return contact
        }.sorted { $0.id < $1.id }
        onFrame?(snapshot)
    }
}
