import Foundation
import CoreGraphics

@main struct CoreTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: \(name)") }
        passed += 1
    }
    static func rejects(_ name: String, _ body: () throws -> Void) {
        do { try body(); fatalError("FAIL: expected rejection: \(name)") } catch { passed += 1 }
    }
    static func packet(_ kind: String = "GSV1", _ payload: Data = Data([0,0,0,1,0x65,0x88]), a: UInt32 = 1280, b: UInt32 = 720) -> Data {
        var data = Data(kind.utf8)
        for value in [UInt32(payload.count)] { var n = value.bigEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        var timestamp = UInt64(0x0102030405060708).bigEndian
        withUnsafeBytes(of: &timestamp) { data.append(contentsOf: $0) }
        for value in [a,b] { var n = value.bigEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        data.append(payload)
        return data
    }
    static func contact(_ id: UInt32, _ phase: Int = 2, _ x: Double = 0.5) -> TouchContact {
        TouchContact(id: id, phase: phase, x: x, y: 0.5)
    }
    static func main() throws {
        let wire = packet()
        var parser = StreamParser(), packets: [StreamPacket] = []
        for byte in wire { try parser.append(Data([byte])) { packets.append($0) } }
        check(packets.count == 1 && packets[0].payload == Data(wire.dropFirst(24)), "bytewise fragmentation")
        check(packets[0].timestampMicroseconds == 0x0102030405060708, "big-endian UInt64 timestamp")
        check(packets[0].a == 1280 && packets[0].b == 720, "big-endian dimensions")
        try parser.finish()
        check(parser.bufferedBytes == 0, "consumed payload not retained")
        let audio = packet("GSA1", Data(repeating: 0, count: 32), a: 48_000, b: 2)
        packets.removeAll()
        try parser.append(wire + audio + wire) { packets.append($0) }
        check(packets.map(\.kind) == [.video,.audio,.video], "multiple media frames in one callback")
        let heartbeat = packet("GSH1", Data([0]), a: 0, b: 0)
        packets.removeAll()
        for byte in heartbeat { try parser.append(Data([byte])) { packets.append($0) } }
        try parser.finish()
        check(packets == [StreamPacket(kind: .heartbeat, timestampMicroseconds: 0x0102030405060708,
                                       a: 0, b: 0, payload: Data([0]))], "split heartbeat preserves record framing")
        packets.removeAll()
        try parser.append(wire + heartbeat + audio) { packets.append($0) }
        check(packets.map(\.kind) == [.video, .heartbeat, .audio], "heartbeat interleaves with media")
        rejects("heartbeat payload byte") {
            var p = StreamParser()
            try p.append(packet("GSH1", Data([1]), a: 0, b: 0)) { _ in fatalError("invalid heartbeat emitted") }
        }
        rejects("heartbeat length checked before payload") {
            var p = StreamParser()
            try p.append(Data(packet("GSH1", Data([0, 0]), a: 0, b: 0).prefix(24))) { _ in }
        }
        rejects("heartbeat audio field") {
            var p = StreamParser()
            try p.append(packet("GSH1", Data([0]), a: 48_000, b: 0)) { _ in }
        }
        rejects("heartbeat secondary field") {
            var p = StreamParser()
            try p.append(packet("GSH1", Data([0]), a: 0, b: 2)) { _ in }
        }
        rejects("truncated heartbeat") {
            var p = StreamParser()
            try p.append(Data(heartbeat.dropLast())) { _ in }
            try p.finish()
        }
        for split in 0...wire.count {
            var partial = StreamParser(); var count = 0
            try partial.append(Data(wire.prefix(split))) { _ in count += 1 }
            try partial.append(Data(wire.dropFirst(split))) { _ in count += 1 }
            try partial.finish()
            guard count == 1 else { fatalError("FAIL: split \(split)") }
        }
        check(true, "every possible split boundary")
        rejects("unknown magic") { var p = StreamParser(); try p.append(packet("BAD1")) { _ in } }
        rejects("oversized payload rejected from header") {
            var p = StreamParser(), header = Data(wire.prefix(24)); header[4] = 0x7f
            try p.append(header) { _ in }
        }
        rejects("truncated stream") { var p = StreamParser(); try p.append(Data(wire.dropLast())) { _ in }; try p.finish() }
        rejects("zero dimension") { var p = StreamParser(); try p.append(packet(a: 0)) { _ in } }
        rejects("audio sample rate") { var p = StreamParser(); try p.append(packet("GSA1", Data(repeating: 0, count: 8), a: 44_100,b: 2)) { _ in } }
        rejects("audio incomplete stereo frame") { var p = StreamParser(); try p.append(packet("GSA1", Data(repeating: 0, count: 7), a: 48_000,b: 2)) { _ in } }
        rejects("zero payload") { var p = StreamParser(); try p.append(packet("GSV1", Data())) { _ in } }
        let nals = try AnnexB.units(Data([0,0,0,1,0x67,0x42,0,0,1,0x68,0x12,0,0,0,1,0x65,0x88]))
        check(nals == [Data([0x67,0x42]),Data([0x68,0x12]),Data([0x65,0x88])], "mixed Annex-B delimiters")
        check(AnnexB.avcc(nals).prefix(6) == Data([0,0,0,2,0x67,0x42]), "AVCC length prefix")
        rejects("NAL without start code") { _ = try AnnexB.units(Data([0x65,0x88])) }
        rejects("empty NAL") { _ = try AnnexB.units(Data([0,0,1,0,0,1,0x65])) }
        let landscape = VideoGeometry.aspectFit(video: CGSize(width: 1920, height: 1080), bounds: CGRect(x: 0,y: 0,width: 1000,height: 500))
        check(abs(landscape.width - 888.8888889) < 0.001 && landscape.minY == 0, "pillarbox geometry")
        check(VideoGeometry.map(CGPoint(x: 0,y: 250), videoRect: landscape, clamp: false) == nil, "black bar cannot begin touch")
        check(VideoGeometry.map(CGPoint(x: 500,y: 250), videoRect: landscape, clamp: false) == CGPoint(x: 0.5,y: 0.5), "video center maps exactly")
        check(VideoGeometry.map(CGPoint(x: -20,y: 600), videoRect: landscape, clamp: true) == CGPoint(x: 0,y: 1), "existing contact clamps outside edge")
        let portrait = VideoGeometry.aspectFit(video: CGSize(width: 1920,height: 1080), bounds: CGRect(x: 0,y: 0,width: 400,height: 800))
        check(portrait == CGRect(x: 0,y: 287.5,width: 400,height: 225), "portrait letterbox")
        let client = CGRect(x: 0,y: 0.1,width: 1,height: 0.9)
        check(VideoGeometry.map(CGPoint(x: 500,y: 25),videoRect: CGRect(x: 0,y: 0,width: 1000,height: 500),clientRect: client,clamp: false) == nil, "titlebar crop excluded")
        let cropped = VideoGeometry.croppedPresentation(video: CGSize(width: 1352, height: 934), bounds: CGRect(x: 0,y: 0,width: 1000,height: 600), clientRect: CGRect(x: 0,y: 28.0/467,width: 1,height: 439.0/467))
        check(abs(cropped.viewport.width / cropped.viewport.height - 1352.0/878) < 0.00001, "client crop preserves actual game aspect")
        check(abs(cropped.layer.minY + cropped.layer.height * 28.0/467) < 0.00001, "titlebar translated out of clipped viewport")
        check(VideoGeometry.map(CGPoint(x: cropped.viewport.midX,y: cropped.viewport.midY), videoRect: cropped.viewport, clamp: false) == CGPoint(x: 0.5,y: 0.5), "cropped presentation and touch share geometry")
        // Synthetic safe insets exercise both orientations; no model-specific dimensions are used by the app.
        let screenBounds = CGRect(x: 0,y: 0,width: 896,height: 414)
        let islandLeft = VideoGeometry.symmetricSafeBounds(bounds: screenBounds,systemSafeArea: CGRect(x: 58,y: 0,width: 818,height: 390))
        let islandRight = VideoGeometry.symmetricSafeBounds(bounds: screenBounds,systemSafeArea: CGRect(x: 20,y: 0,width: 818,height: 390))
        check(islandLeft == islandRight, "left and right island orientations yield identical conservative horizontal margins")
        check(islandLeft.minX == 58 && screenBounds.maxX - islandLeft.maxX == 58, "both margins use larger actual system inset")
        check(islandLeft.minY == 0 && islandLeft.maxY == 390, "symmetric horizontal safety preserves vertical home-indicator region")
        for safe in [islandLeft,islandRight] {
            let game = safe
            let fitted = VideoGeometry.croppedPresentation(video: CGSize(width: 1352,height: 934), bounds: game, clientRect: CGRect(x: 0,y: 28.0/467,width: 1,height: 439.0/467))
            check(safe.contains(fitted.viewport), "landscape crop entirely inside safe bounds")
            let menu = VideoGeometry.floatingMenuFrame(bounds: screenBounds, safeArea: safe, position: FloatingMenuPosition())
            check(menu.maxX == screenBounds.maxX && menu.minY == safe.minY + 6,
                  "floating menu defaults to actual upper-right screen edge independently of game safe bounds")
            check(VideoGeometry.map(CGPoint(x: safe.minX - 1,y: fitted.viewport.midY),videoRect: fitted.viewport,clamp: false) == nil, "notch-side margin rejects new touches")
            check(VideoGeometry.map(CGPoint(x: fitted.viewport.midX,y: fitted.viewport.midY),videoRect: fitted.viewport,clamp: false) == CGPoint(x: 0.5,y: 0.5), "safe offset and crop map game center")
        }
        check(VideoGeometry.aspectMatches(client: CGSize(width: 2556,height: 1179),screen: CGSize(width: 852,height: 393)), "full-screen option requires matching aspect")
        check(!VideoGeometry.aspectMatches(client: CGSize(width: 1352,height: 878),screen: CGSize(width: 852,height: 393)), "old window aspect cannot silently fill or crop screen")
        let leftSafe = CGRect(x: 58, y: 0, width: 818, height: 390)
        let rightSafe = CGRect(x: 20, y: 0, width: 818, height: 390)
        let dragged = VideoGeometry.floatingMenuFrame(bounds: screenBounds, safeArea: leftSafe, center: CGPoint(x: -100, y: 900))
        check(screenBounds.contains(dragged) && dragged.minX == screenBounds.minX && dragged.maxY == 384,
              "drag reaches real screen edge while retaining vertical home-indicator safety")
        let leftPosition = VideoGeometry.floatingMenuPosition(bounds: screenBounds, safeArea: leftSafe, center: CGPoint(x: dragged.midX, y: dragged.midY))
        check(leftPosition.edge == .left && leftPosition.verticalFraction == 1, "release selects nearest left edge and normalized height")
        let upperRight = FloatingMenuPosition(edge: .right, verticalFraction: 0.1)
        let menuBeforeFlip = VideoGeometry.floatingMenuFrame(bounds: screenBounds, safeArea: leftSafe, position: upperRight)
        let menuAfterFlip = VideoGeometry.floatingMenuFrame(bounds: screenBounds, safeArea: rightSafe, position: upperRight)
        check(menuBeforeFlip.maxX == screenBounds.maxX && menuAfterFlip.maxX == screenBounds.maxX,
              "landscape flip never shifts docked menu inward to horizontal safe inset")
        check(menuBeforeFlip.midY == menuAfterFlip.midY && screenBounds.contains(menuAfterFlip), "landscape flip preserves safe corner position")
        let rightPosition = VideoGeometry.floatingMenuPosition(bounds: screenBounds, safeArea: leftSafe, center: CGPoint(x: 700, y: 60))
        let snappedRight = VideoGeometry.floatingMenuFrame(bounds: screenBounds, safeArea: leftSafe, position: rightPosition)
        check(rightPosition.edge == .right && snappedRight.midY == 60 && snappedRight.maxX == screenBounds.maxX,
              "nearest-edge snap preserves an unobstructed release height")
        for safe in [leftSafe, rightSafe] {
            for x: CGFloat in [100, 700] {
                for y: CGFloat in [180, 240] {
                    let position = VideoGeometry.floatingMenuPosition(bounds: screenBounds, safeArea: safe, center: CGPoint(x: x, y: y))
                    let docked = VideoGeometry.floatingMenuFrame(bounds: screenBounds, safeArea: safe, position: position)
                    check(docked.minX == screenBounds.minX || docked.maxX == screenBounds.maxX,
                          "releasing a dragged menu never leaves it in the game center")
                    check(docked.maxY <= screenBounds.height * 0.25 || docked.minY >= screenBounds.height * 0.75,
                          "inset landscape edges keep the whole control clear of the central cutout band")
                }
            }
        }
        let portraitBounds = CGRect(x: 0, y: 0, width: 414, height: 896)
        let portraitSafe = CGRect(x: 0, y: 62, width: 414, height: 800)
        let portraitMenu = VideoGeometry.floatingMenuFrame(bounds: portraitBounds, safeArea: portraitSafe, position: FloatingMenuPosition())
        check(portraitMenu.maxX == portraitBounds.maxX && portraitMenu.minY == 68,
              "portrait default docks upper-right below top system safety")
        let unobstructedMenu = VideoGeometry.floatingMenuFrame(bounds: screenBounds, safeArea: screenBounds,
            position: FloatingMenuPosition(edge: .left, verticalFraction: 0.5))
        check(unobstructedMenu.minX == screenBounds.minX && unobstructedMenu.midY == screenBounds.midY,
              "screens without side insets allow edge docking at middle height")
        let tinySafe = CGRect(x: 10, y: 20, width: 30, height: 20)
        check(tinySafe.contains(VideoGeometry.floatingMenuFrame(bounds: tinySafe, safeArea: tinySafe, position: upperRight)), "small safe area never pushes control outside bounds")
        let hitBounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        let visual = VideoGeometry.floatingMenuVisualFrame(in: hitBounds)
        check(visual == CGRect(x: 3.5, y: 3.5, width: 37, height: 37), "menu visual is 37pt inside the unchanged 44pt touch envelope")
        check(VideoGeometry.floatingMenuContains(CGPoint(x: 1, y: 22), in: hitBounds), "transparent circular hit margin remains usable for opening and dragging")
        check(!VideoGeometry.floatingMenuContains(CGPoint(x: 1, y: 1), in: hitBounds), "transparent square corners pass game touches through")
        check(!VideoGeometry.floatingMenuContains(CGPoint(x: -1, y: 22), in: hitBounds), "menu never consumes touches outside its 44pt envelope")
        check(tinySafe.contains(VideoGeometry.floatingMenuVisualFrame(in: tinySafe)), "visual remains contained in a reduced hit envelope")
        for safe in [leftSafe, rightSafe, portraitSafe] {
            let bounds = safe == portraitSafe ? portraitBounds : screenBounds
            for edge in [FloatingMenuPosition.Edge.left, .right] {
                let source = VideoGeometry.floatingMenuFrame(bounds: bounds, safeArea: safe, position: FloatingMenuPosition(edge: edge, verticalFraction: 0.9))
                let popup = VideoGeometry.floatingSettingsFrame(bounds: bounds, safeArea: safe, source: source)
                check(safe.contains(popup), "whole settings popup remains inside the actual safe area")
                check(edge == .left ? popup.minX == safe.minX + 8 : popup.maxX == safe.maxX - 8,
                      "settings popup stays at the source edge instead of centering")
            }
        }
        let canvas = VideoGeometry.evenPixelCanvas(points: CGSize(width: 781.5,height: 344.5),nativeScale: 2.75)
        check(canvas.width.truncatingRemainder(dividingBy: 2) == 0 && canvas.height.truncatingRemainder(dividingBy: 2) == 0, "recommended physical canvas has even dimensions")
        check(canvas.width <= 781.5 * 2.75 && canvas.height <= 344.5 * 2.75, "resolution uses actual native scale without rounding outside safety region")
        var rotationQueue = FrameQueue()
        _ = rotationQueue.append([contact(1,1),contact(2,1)])
        _ = rotationQueue.append([contact(1,2,0.2),contact(2,2,0.8)])
        rotationQueue.releaseAll()
        check(rotationQueue.pop() == [], "rotation release sends zero-contact snapshot")
        check(rotationQueue.pop() == nil, "rotation removes all queued old-coordinate contacts")
        var queue = FrameQueue()
        check(queue.append([contact(1,1)]) && queue.append([contact(1)]) && queue.append([contact(1,2,0.7)]), "queue accepts down and moves")
        check(queue.frames.count == 2 && queue.frames.last?.first?.x == 0.7, "move coalescing keeps newest position")
        _ = queue.append([contact(1,3)]); _ = queue.append([contact(2,1)])
        check(queue.frames.map { $0.first!.phase } == [1,2,3,1], "down and up boundaries preserved")
        queue.releaseAll(); check(queue.frames == [[]], "release discards queued stale contacts")
        queue.clear()
        for n in 1...32 { check(queue.append([contact(UInt32(n),1)]), "queue capacity item \(n)") }
        check(!queue.append([contact(33,1)]) && queue.frames.count == 32, "bounded queue rejects overflow")
        let connection = try Connection(text: "http://192.168.1.20:8080/#token=0123456789abcdef")
        let request = connection.request(path: "frame",owner: "aabb",lease: "ccdd",body: Data("{}".utf8))
        check(request.url?.absoluteString == "http://192.168.1.20:8080/frame", "token excluded from request URL")
        check(request.value(forHTTPHeaderField: "Origin") == "http://192.168.1.20:8080", "exact Origin")
        check(request.value(forHTTPHeaderField: "X-Session-Token") == "0123456789abcdef" && request.value(forHTTPHeaderField: "X-Session-Lease") == "ccdd", "token and lease headers")
        rejects("public HTTP endpoint") { _ = try Connection(text: "http://8.8.8.8:8080/#token=0123456789abcdef") }
        rejects("userinfo endpoint") { _ = try Connection(text: "http://user@192.168.1.20:8080/#token=0123456789abcdef") }
        rejects("missing token") { _ = try Connection(text: "http://192.168.1.20:8080/") }
        rejects("duplicate token") { _ = try Connection(text: "http://192.168.1.20:8080/#token=0123456789abcdef&token=0123456789abcdef") }
        print("PASS: \(passed) assertions; parser, Annex-B, geometry, lifecycle queue, and connection auth.")
    }
}
