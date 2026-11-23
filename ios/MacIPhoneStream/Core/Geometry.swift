import Foundation
import CoreGraphics

struct FloatingMenuPosition {
    enum Edge { case left, right }
    var edge: Edge = .right
    var verticalFraction: CGFloat = 0
}

struct VideoGeometry {
    // A visual design size for this app, not a measurement of the hardware cutout.
    static let floatingMenuVisualDiameter: CGFloat = 37
    static let floatingMenuHitDiameter: CGFloat = 44

    static func floatingSettingsFrame(bounds: CGRect, safeArea: CGRect, source: CGRect,
                                      preferredSize: CGSize = CGSize(width: 320, height: 240)) -> CGRect {
        let safe = bounds.intersection(safeArea)
        guard !safe.isNull, safe.width > 0, safe.height > 0 else { return .zero }
        let inset = min(8, min(safe.width, safe.height) / 4)
        let available = safe.insetBy(dx: inset, dy: inset)
        let size = CGSize(width: min(preferredSize.width, available.width), height: min(preferredSize.height, available.height))
        let left = source.midX < bounds.midX
        return CGRect(x: left ? available.minX : available.maxX - size.width,
                      y: min(available.maxY - size.height, max(available.minY, source.midY - size.height / 2)),
                      width: size.width, height: size.height)
    }

    static func floatingMenuVisualFrame(in bounds: CGRect) -> CGRect {
        let side = max(0, min(floatingMenuVisualDiameter, min(bounds.width, bounds.height)))
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }
    static func floatingMenuContains(_ point: CGPoint, in bounds: CGRect) -> Bool {
        guard bounds.contains(point) else { return false }
        let radius = min(bounds.width, bounds.height) / 2
        let dx = point.x - bounds.midX, dy = point.y - bounds.midY
        return dx * dx + dy * dy <= radius * radius
    }
    /// Preserve vertical system safety, while using the larger horizontal inset on both sides.
    static func symmetricSafeBounds(bounds: CGRect, systemSafeArea: CGRect) -> CGRect {
        let left = max(0, systemSafeArea.minX - bounds.minX)
        let right = max(0, bounds.maxX - systemSafeArea.maxX)
        let horizontal = min(bounds.width / 2, max(left, right))
        return CGRect(x: bounds.minX + horizontal, y: systemSafeArea.minY,
                      width: max(0, bounds.width - horizontal * 2), height: max(0, systemSafeArea.height))
    }
    /// Horizontal docking follows the screen edge, independently of the game's safe bounds.
    private static func menuTravel(bounds: CGRect, safeArea: CGRect) -> (centers: CGRect, side: CGFloat) {
        let side = max(0, min(floatingMenuHitDiameter, min(bounds.width, safeArea.height)))
        let yInset = min(safeArea.height / 2, side / 2 + 6)
        return (CGRect(x: bounds.minX + side / 2, y: safeArea.minY + yInset,
                       width: max(0, bounds.width - side), height: max(0, safeArea.height - yInset * 2)), side)
    }
    private static func menuDockY(_ y: CGFloat, edge: FloatingMenuPosition.Edge,
                                  bounds: CGRect, safeArea: CGRect) -> CGFloat {
        let (travel, side) = menuTravel(bounds: bounds, safeArea: safeArea)
        let clamped = min(travel.maxY, max(travel.minY, y))
        let sideInset = edge == .left ? safeArea.minX - bounds.minX : bounds.maxX - safeArea.maxX
        guard bounds.width > bounds.height, sideInset > 0 else { return clamped }
        // UIKit gives side insets, not the cutout's exact rectangle. Conservatively keep the
        // entire circle in the outer vertical quarters on inset edges, clear of the middle.
        let upperLimit = bounds.minY + bounds.height * 0.25 - side / 2
        let lowerLimit = bounds.minY + bounds.height * 0.75 + side / 2
        guard upperLimit >= travel.minY, lowerLimit <= travel.maxY,
              clamped > upperLimit, clamped < lowerLimit else { return clamped }
        return clamped - upperLimit <= lowerLimit - clamped ? upperLimit : lowerLimit
    }
    static func floatingMenuFrame(bounds: CGRect, safeArea: CGRect, position: FloatingMenuPosition) -> CGRect {
        let travel = menuTravel(bounds: bounds, safeArea: safeArea).centers
        let y = menuDockY(travel.minY + travel.height * min(1, max(0, position.verticalFraction)),
                         edge: position.edge, bounds: bounds, safeArea: safeArea)
        return floatingMenuFrame(bounds: bounds, safeArea: safeArea, center: CGPoint(
            x: position.edge == .left ? travel.minX : travel.maxX,
            y: y))
    }
    static func floatingMenuFrame(bounds: CGRect, safeArea: CGRect, center: CGPoint) -> CGRect {
        let (travel, side) = menuTravel(bounds: bounds, safeArea: safeArea)
        return CGRect(x: min(travel.maxX, max(travel.minX, center.x)) - side / 2,
                      y: min(travel.maxY, max(travel.minY, center.y)) - side / 2,
                      width: side, height: side)
    }
    static func floatingMenuPosition(bounds: CGRect, safeArea: CGRect, center: CGPoint) -> FloatingMenuPosition {
        let travel = menuTravel(bounds: bounds, safeArea: safeArea).centers
        let edge: FloatingMenuPosition.Edge = center.x < travel.midX ? .left : .right
        let y = menuDockY(center.y, edge: edge, bounds: bounds, safeArea: safeArea)
        return FloatingMenuPosition(edge: edge,
            verticalFraction: travel.height > 0 ? (y - travel.minY) / travel.height : 0)
    }
    static func aspectMatches(client: CGSize, screen: CGSize) -> Bool {
        guard client.width > 0, client.height > 0, screen.width > 0, screen.height > 0 else { return false }
        return abs((client.width / client.height) / (screen.width / screen.height) - 1) <= 0.01
    }
    static func evenPixelCanvas(points: CGSize, nativeScale: CGFloat) -> CGSize {
        guard points.width > 0, points.height > 0, nativeScale.isFinite, nativeScale > 0 else { return .zero }
        return CGSize(width: max(2, floor(points.width * nativeScale / 2) * 2),
                      height: max(2, floor(points.height * nativeScale / 2) * 2))
    }
    static func aspectFit(video: CGSize, bounds: CGRect) -> CGRect {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / video.width, bounds.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    static func croppedPresentation(video: CGSize, bounds: CGRect, clientRect: CGRect) -> (viewport: CGRect, layer: CGRect) {
        guard clientRect.width > 0, clientRect.height > 0 else { return (.zero, .zero) }
        let viewport = aspectFit(video: CGSize(width: video.width * clientRect.width, height: video.height * clientRect.height), bounds: bounds)
        let full = CGSize(width: viewport.width / clientRect.width, height: viewport.height / clientRect.height)
        return (viewport, CGRect(x: -clientRect.minX * full.width, y: -clientRect.minY * full.height, width: full.width, height: full.height))
    }
    static func map(_ point: CGPoint, videoRect: CGRect, clientRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), clamp: Bool) -> CGPoint? {
        guard videoRect.width > 0, videoRect.height > 0, clientRect.width > 0, clientRect.height > 0 else { return nil }
        let active = CGRect(x: videoRect.minX + clientRect.minX * videoRect.width,
                            y: videoRect.minY + clientRect.minY * videoRect.height,
                            width: videoRect.width * clientRect.width, height: videoRect.height * clientRect.height)
        guard clamp || (point.x >= active.minX && point.x <= active.maxX && point.y >= active.minY && point.y <= active.maxY) else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - active.minX) / active.width)),
                       y: min(1, max(0, (point.y - active.minY) / active.height)))
    }
}

struct TouchContact: Codable, Equatable {
    let id: UInt32
    var phase: Int
    var x: Double
    var y: Double
}

struct FrameQueue {
    static let capacity = 32
    private(set) var frames: [[TouchContact]] = []
    mutating func append(_ contacts: [TouchContact]) -> Bool {
        let sorted = contacts.sorted { $0.id < $1.id }
        if !sorted.isEmpty, sorted.allSatisfy({ $0.phase == 2 }), let last = frames.last,
           last.allSatisfy({ $0.phase == 2 }), last.map(\.id) == sorted.map(\.id) {
            frames[frames.count - 1] = sorted
            return true
        }
        guard frames.count < Self.capacity else { return false }
        frames.append(sorted)
        return true
    }
    mutating func pop() -> [TouchContact]? { frames.isEmpty ? nil : frames.removeFirst() }
    mutating func releaseAll() { frames = [[]] }
    mutating func clear() { frames.removeAll() }
}
