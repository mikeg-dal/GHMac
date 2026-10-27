import Testing
import GHEKit
@testable import GHEServerKit

@Suite struct XBeeFrameTests {
    private func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

    @Test func workedExampleRelayToRemote() {
        #expect(XBeeFrame.relaySet(id: 2, wioAddress: 5, relayByte: 0x01)
                == hex("7E 00 10 17 02 00 00 00 00 00 00 00 00 10 05 02 49 4F 01 36"))
    }

    @Test func workedExampleDBQuery() {
        #expect(XBeeFrame.rssiQuery(id: 4, wioAddress: 5)
                == hex("7E 00 0F 17 04 00 00 00 00 00 00 00 00 10 05 02 44 42 47"))
    }

    @Test func workedExampleTX16() {
        #expect(XBeeFrame.tx16(id: 0, wioAddress: 5, payload: Array("BI2;".utf8))
                == hex("7E 00 09 01 00 10 05 00 42 49 32 3B F1"))
    }

    @Test func workedExampleLocalRelay() {
        #expect(XBeeFrame.relaySet(id: 3, wioAddress: 0, relayByte: 0x80) == hex("7E 00 05 08 03 49 4F 80 DC"))
    }

    @Test func validateFrame() {
        #expect(XBeeFrame.validate == hex("7E 00 05 08 00 44 44 00 6F"))
    }

    @Test func highAddressesAreUnsigned() {
        let f = XBeeFrame.relaySet(id: 1, wioAddress: 200, relayByte: 0xFF)
        #expect(f[13] == 0x10 && f[14] == 200)
        var d = XBeeDecoder()
        let reply = XBeeFrame.encode([0x97, 1] + [UInt8](repeating: 0, count: 8) + [0x10, 200] + Array("IO".utf8) + [0])
        let out = d.push(reply)
        #expect(out.count == 1)
        #expect(out.first?.wioAddress == 200)
    }

    @Test func decodesAllInboundTypes() {
        var d = XBeeDecoder()
        let local = XBeeFrame.encode([0x88, 3, 0x49, 0x4F, 0])
        let remote = XBeeFrame.encode([0x97, 4] + [UInt8](repeating: 0, count: 8) + [0x10, 5] + Array("DB".utf8) + [0, 0x28])
        let rx = XBeeFrame.encode([0x81, 0x10, 5, 0x30, 0] + Array("358.4;".utf8))
        let status = XBeeFrame.encode([0x89, 1, 0])
        let out = d.push(local + remote + rx + status)
        #expect(out == [
            .localATResponse(frameID: 3, command: Array("IO".utf8), status: 0, data: []),
            .remoteATResponse(frameID: 4, source64: [UInt8](repeating: 0, count: 8), source16: 0x1005,
                              command: Array("DB".utf8), status: 0, data: [0x28]),
            .rx16(source16: 0x1005, rssi: 0x30, options: 0, payload: Array("358.4;".utf8)),
            .other(apiID: 0x89, data: [1, 0]),
        ])
        #expect(out[0].wioAddress == 0)
        #expect(out[2].wioAddress == 5)
        #expect(out[3].wioAddress == nil)
    }

    @Test func resyncsOnGarbageAndSplitFrames() {
        var d = XBeeDecoder()
        let f = XBeeFrame.encode([0x88, 1, 0x49, 0x4F, 0])
        var got: [XBeeInbound] = []
        got += d.push([0x01, 0x02, 0x4F, 0x4B])        // garbage incl. "OK"
        for b in f { got += d.push([b]) }               // byte by byte
        got += d.push([0xAA] + f + [0x55])              // garbage around a frame
        #expect(got.count == 2)
        #expect(d.discardedBytes == 6)
    }

    @Test func badChecksumIsDroppedAndCounted() {
        var d = XBeeDecoder()
        var bad = XBeeFrame.encode([0x88, 1, 0x49, 0x4F, 0])
        bad[bad.count - 1] &+= 1
        let good = XBeeFrame.encode([0x88, 2, 0x49, 0x4F, 0])
        let out = d.push(bad + good)
        #expect(d.badFrames == 1)
        #expect(out == [.localATResponse(frameID: 2, command: Array("IO".utf8), status: 0, data: [])])
    }

    @Test func longFramesUseUnsignedLength() {
        var d = XBeeDecoder()
        let payload = [UInt8](repeating: 0x41, count: 140)   // length 145 ≥ 128
        let f = XBeeFrame.encode([0x81, 0x10, 7, 0x20, 0] + payload)
        #expect(f[2] == 145)
        #expect(d.push(f) == [.rx16(source16: 0x1007, rssi: 0x20, options: 0, payload: payload)])
    }

    @Test func absurdLengthResyncs() {
        var d = XBeeDecoder()
        let good = XBeeFrame.encode([0x88, 2, 0x49, 0x4F, 0])
        let out = d.push([0x7E, 0x7F, 0xFF] + good)
        #expect(out.count == 1)
        #expect(d.badFrames == 1)
    }
}
