import Foundation

/// One decoded inbound XBee API frame.
public enum XBeeInbound: Sendable, Equatable {
    /// 0x88: `frame[7]` is the status.
    case localATResponse(frameID: UInt8, command: [UInt8], status: UInt8, data: [UInt8])
    /// 0x97: source 16-bit at `frame[13..14]`, status at `frame[17]`, data from `frame[18]`.
    case remoteATResponse(frameID: UInt8, source64: [UInt8], source16: UInt16, command: [UInt8], status: UInt8, data: [UInt8])
    /// 0x81: RSSI byte at `frame[6]`, payload from `frame[8]`.
    case rx16(source16: UInt16, rssi: UInt8, options: UInt8, payload: [UInt8])
    /// Any other API id (TX status 0x89 and friends): ignored by the server.
    case other(apiID: UInt8, data: [UInt8])

    /// WIO address the frame belongs to (LSB of the source address; 0 for local responses), unsigned.
    public var wioAddress: Int? {
        switch self {
        case .localATResponse: 0
        case .remoteATResponse(_, _, let s16, _, _, _): Int(s16 & 0xFF)
        case .rx16(let s16, _, _, _): Int(s16 & 0xFF)
        case .other: nil
        }
    }

    /// Parses frame data (API id first, checksum excluded).
    static func parse(_ d: [UInt8]) -> XBeeInbound {
        guard let api = d.first else { return .other(apiID: 0, data: []) }
        switch api {
        case XBeeAPI.localATResponse where d.count >= 5:
            return .localATResponse(frameID: d[1], command: Array(d[2..<4]), status: d[4], data: Array(d[5...]))
        case XBeeAPI.remoteATResponse where d.count >= 15:
            return .remoteATResponse(frameID: d[1], source64: Array(d[2..<10]),
                                     source16: UInt16(d[10]) << 8 | UInt16(d[11]),
                                     command: Array(d[12..<14]), status: d[14], data: Array(d[15...]))
        case XBeeAPI.rx16 where d.count >= 5:
            return .rx16(source16: UInt16(d[1]) << 8 | UInt16(d[2]), rssi: d[3], options: d[4], payload: Array(d[5...]))
        default:
            return .other(apiID: api, data: Array(d.dropFirst()))
        }
    }
}

/// Streaming XBee API-1 decoder.
///
/// Resyncs on the next 0x7E, reads an unsigned
/// 16-bit length, and verifies the checksum; bad frames are dropped and counted.
public struct XBeeDecoder: Sendable {
    /// Longest frame we accept; longer "lengths" are treated as garbage.
    public static let maxFrameLength = 256

    private var buffer: [UInt8] = []
    /// Frames dropped for a bad checksum or impossible length.
    public private(set) var badFrames = 0
    /// Bytes skipped while hunting for a start byte.
    public private(set) var discardedBytes = 0

    public init() {}

    public mutating func push(_ bytes: [UInt8]) -> [XBeeInbound] {
        buffer.append(contentsOf: bytes)
        var out: [XBeeInbound] = []
        while true {
            // Hunt for the start byte.
            if let i = buffer.firstIndex(of: XBeeAPI.startByte) {
                if i > 0 { discardedBytes += i; buffer.removeFirst(i) }
            } else {
                discardedBytes += buffer.count; buffer.removeAll(); break
            }
            guard buffer.count >= 3 else { break }
            let len = Int(buffer[1]) << 8 | Int(buffer[2])
            if len == 0 || len > Self.maxFrameLength {
                badFrames += 1; dropStart(); continue
            }
            guard buffer.count >= len + 4 else { break }
            let data = Array(buffer[3..<(3 + len)])
            let cs = buffer[3 + len]
            if XBeeFrame.checksum(data) != cs {
                badFrames += 1; dropStart(); continue
            }
            buffer.removeFirst(len + 4)
            out.append(XBeeInbound.parse(data))
        }
        return out
    }

    /// Drops the current start byte so the hunt resumes at the next 0x7E.
    private mutating func dropStart() {
        buffer.removeFirst()
        discardedBytes += 1
    }
}
