import Foundation

/// XBee 802.15.4 API identifiers used on the Base bus.
public enum XBeeAPI {
    public static let startByte: UInt8 = 0x7E
    /// Outbound: local AT command.
    public static let localAT: UInt8 = 0x08
    /// Outbound: remote AT command request.
    public static let remoteAT: UInt8 = 0x17
    /// Outbound: TX request, 16-bit address.
    public static let tx16: UInt8 = 0x01
    /// Inbound: local AT command response.
    public static let localATResponse: UInt8 = 0x88
    /// Inbound: remote AT command response.
    public static let remoteATResponse: UInt8 = 0x97
    /// Inbound: RX packet, 16-bit source address.
    public static let rx16: UInt8 = 0x81
    /// Inbound: TX status (ignored by the server).
    public static let txStatus: UInt8 = 0x89
}

/// Builders for the outbound frames (API mode 1, no escaping).
public enum XBeeFrame {
    /// Standard XBee checksum over the frame data (API id … last data byte).
    public static func checksum<C: Collection>(_ frameData: C) -> UInt8 where C.Element == UInt8 {
        var sum: UInt8 = 0
        for b in frameData { sum &+= b }
        return 0xFF &- sum
    }

    /// Wraps frame data (starting with the API id) as `7E len_hi len_lo <data> <checksum>`.
    public static func encode(_ frameData: [UInt8]) -> [UInt8] {
        let n = frameData.count
        return [XBeeAPI.startByte, UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + frameData + [checksum(frameData)]
    }

    /// 16-bit MY address of the Remote with WIO address `wio` (0x10nn).
    public static func remoteAddress16(_ wio: Int) -> UInt16 { 0x1000 | UInt16(wio & 0xFF) }

    /// Local AT command (`7E 00 len 08 <id> <cmd> <param…> <cs>`).
    public static func localAT(id: UInt8, command: String, parameter: [UInt8] = []) -> [UInt8] {
        encode([XBeeAPI.localAT, id] + Array(command.utf8.prefix(2)) + parameter)
    }

    /// Remote AT command to `0x10nn` with dest64 = 0 and options 0x02 (apply changes).
    public static func remoteAT(id: UInt8, wioAddress: Int, command: String, parameter: [UInt8] = [],
                                options: UInt8 = 0x02) -> [UInt8] {
        let a = remoteAddress16(wioAddress)
        return encode([XBeeAPI.remoteAT, id] + [UInt8](repeating: 0, count: 8)
                      + [UInt8(a >> 8), UInt8(a & 0xFF), options] + Array(command.utf8.prefix(2)) + parameter)
    }

    /// Transparent data to the RT-21 behind remote `0x10nn` (TX16, options 0).
    public static func tx16(id: UInt8, wioAddress: Int, payload: [UInt8], options: UInt8 = 0) -> [UInt8] {
        let a = remoteAddress16(wioAddress)
        return encode([XBeeAPI.tx16, id, UInt8(a >> 8), UInt8(a & 0xFF), options] + payload)
    }

    /// Relay image to a remote, or to the Base's own I/O when `wioAddress == 0`.
    public static func relaySet(id: UInt8, wioAddress: Int, relayByte: UInt8) -> [UInt8] {
        wioAddress == 0
            ? localAT(id: id, command: "IO", parameter: [relayByte])
            : remoteAT(id: id, wioAddress: wioAddress, command: "IO", parameter: [relayByte])
    }

    /// RSSI query (`DB`) to a remote.
    public static func rssiQuery(id: UInt8, wioAddress: Int) -> [UInt8] {
        remoteAT(id: id, wioAddress: wioAddress, command: "DB")
    }

    /// For wire compatibility: local `DD` **with** a 0x00 parameter, frame id 0 (no reply).
    /// Bytes: `7E 00 05 08 00 44 44 00 6F`.
    public static let validate: [UInt8] = localAT(id: 0, command: "DD", parameter: [0x00])
}
