import Foundation

struct StreamPacket: Equatable {
    enum Kind: String { case video = "GSV1", audio = "GSA1", heartbeat = "GSH1" }
    let kind: Kind
    let timestampMicroseconds: UInt64
    let a: UInt32
    let b: UInt32
    let payload: Data
}

enum StreamProtocolError: Error, LocalizedError {
    case invalidHeader, oversizedPayload, invalidVideo, invalidAudio, invalidHeartbeat, truncatedStream
    var errorDescription: String? { "串流数据无效（\(self)）" }
}

/// URLSession removes HTTP chunk framing. This parser only consumes the 24-byte record framing.
struct StreamParser {
    static let maximumPayload = 4 * 1024 * 1024
    private var storage = Data()
    private(set) var bufferedBytes = 0

    mutating func append(_ data: Data, receive: (StreamPacket) throws -> Void) throws {
        var input = data.startIndex
        // Never retain an unbounded delegate chunk: consume at most one frame at a time.
        while input < data.endIndex {
            let target: Int
            if storage.count < 24 { target = 24 } else {
                target = 24 + (try validateHeader()).length
            }
            let amount = min(target - storage.count, data.endIndex - input)
            if amount > 0 {
                storage.append(contentsOf: data[input..<(input + amount)])
                input += amount
            }
            bufferedBytes = storage.count
            if storage.count >= 24 {
                let (kind, length) = try validateHeader()
                if storage.count == 24 + length {
                    guard kind != .heartbeat || storage[24] == 0 else {
                        throw StreamProtocolError.invalidHeartbeat
                    }
                    let packet = StreamPacket(kind: kind, timestampMicroseconds: read64(8),
                                              a: read32(16), b: read32(20), payload: Data(storage.dropFirst(24)))
                    storage.removeAll(keepingCapacity: true)
                    bufferedBytes = 0
                    try receive(packet)
                }
            }
        }
    }
    func finish() throws { if !storage.isEmpty { throw StreamProtocolError.truncatedStream } }
    private func read32(_ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(storage[offset + $1]) }
    }
    private func read64(_ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(storage[offset + $1]) }
    }
    private func validateHeader() throws -> (kind: StreamPacket.Kind, length: Int) {
        guard let kind = StreamPacket.Kind(rawValue: String(decoding: storage.prefix(4), as: UTF8.self)) else {
            throw StreamProtocolError.invalidHeader
        }
        let count = Int(read32(4)), a = read32(16), b = read32(20)
        guard count > 0, count <= Self.maximumPayload else { throw StreamProtocolError.oversizedPayload }
        switch kind {
        case .video:
            guard a >= 16, b >= 16, a <= 8192, b <= 8192 else { throw StreamProtocolError.invalidVideo }
        case .audio:
            guard a == 48_000, b == 2, count % 8 == 0, count <= 48_000 * 8 / 4 else {
                throw StreamProtocolError.invalidAudio
            }
        case .heartbeat:
            guard a == 0, b == 0, count == 1 else { throw StreamProtocolError.invalidHeartbeat }
        }
        return (kind, count)
    }
}

struct AnnexB {
    /// Accept both Annex-B start code lengths. The output excludes start codes.
    static func units(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = [], i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    starts.append((i, 4)); i += 4; continue
                }
            }
            i += 1
        }
        guard let first = starts.first, bytes[..<first.0].allSatisfy({ $0 == 0 }) else {
            throw StreamProtocolError.invalidVideo
        }
        var result: [Data] = []
        for n in starts.indices {
            let begin = starts[n].0 + starts[n].1
            let end = n + 1 < starts.count ? starts[n + 1].0 : bytes.count
            guard end > begin, bytes[begin] & 0x80 == 0 else { throw StreamProtocolError.invalidVideo }
            result.append(Data(bytes[begin..<end]))
        }
        return result
    }
    static func avcc(_ units: [Data]) -> Data {
        var result = Data()
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(unit)
        }
        return result
    }
}
