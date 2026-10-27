import Foundation
import Testing
@testable import GHEKit

/// Real sockets, 127.0.0.1 and ephemeral ports only.
@Suite(.tags(.loopback), .serialized) struct LoopbackTransportTests {
    @Test func listenerAndConnectorExchangeChunks() async throws {
        let listener = NWStreamListener(port: 0)
        let accepted = try await listener.start()
        let port = listener.port
        #expect(port != 0)

        let client = try await NWStreamConnector().connect(host: "127.0.0.1", port: port)
        var acceptIt = accepted.makeAsyncIterator()
        let server = try #require(await acceptIt.next())
        #expect(server.peerAddress == "127.0.0.1")

        try await client.send(Array("BI2;".utf8))
        var sIt = server.incoming.makeAsyncIterator()
        var got: [UInt8] = []
        while got.count < 4, let c = try await sIt.next() { got += c }
        #expect(got == Array("BI2;".utf8))

        try await server.send(Array("358.4;".utf8))
        var cIt = client.incoming.makeAsyncIterator()
        var back: [UInt8] = []
        while back.count < 6, let c = try await cIt.next() { back += c }
        #expect(back == Array("358.4;".utf8))

        await client.close()   // server sees EOF
        #expect(try await sIt.next() == nil)
        await server.close()
        await listener.stop()
    }

    @Test func tcpTransportAgainstLoopbackListener() async throws {
        let listener = NWStreamListener(port: 0)
        let accepted = try await listener.start()
        let device = FakeRT21Device(heading: 358.4, clock: ManualClock())
        // Bridge each accepted connection to the fake device (a fake "network module").
        let bridge = Task {
            for await conn in accepted {
                let link = device.makeTransport()
                guard let replies = try? await link.open() else { await conn.close(); continue }
                Task { for try await r in replies { try await conn.send(r) } }
                do { for try await chunk in conn.incoming { try await link.write(chunk) } } catch {}
                await link.close()
                await conn.close()
            }
        }

        let t = TCPTransport(host: "127.0.0.1", port: listener.port)
        var it = try await t.open().makeAsyncIterator()
        try await t.write(RT21Commands.pollTenths())
        var p = RT21ReplyParser()
        var out: [RT21Reply] = []
        while out.isEmpty, let c = try await it.next() { out += p.push(c) }
        #expect(out == [.heading(358.4, model: 21)])

        // close() waits for the connection to be cancelled; the device sees the link go away.
        await t.close()
        #expect(await eventually { device.openLinkCount == 0 })
        // Reconnect works and never overlaps.
        _ = try await t.open()
        #expect(await eventually { device.openLinkCount == 1 })
        await t.close()

        await listener.stop()
        bridge.cancel()
    }

    @Test func tcpTransportReportsLinkLostOnPeerClose() async throws {
        let listener = NWStreamListener(port: 0)
        let accepted = try await listener.start()
        let t = TCPTransport(host: "127.0.0.1", port: listener.port)
        var it = try await t.open().makeAsyncIterator()
        var acc = accepted.makeAsyncIterator()
        let server = try #require(await acc.next())
        await server.close()
        await #expect(throws: TransportError.linkLost) { while try await it.next() != nil {} }
        await #expect(throws: TransportError.notOpen) { try await t.write([0x3B]) }
        await listener.stop()
    }

    @Test func tcpConnectRefusedFailsFast() async throws {
        // Grab an ephemeral port, then close it so nothing listens there.
        let l = NWStreamListener(port: 0)
        _ = try await l.start()
        let port = l.port
        await l.stop()
        try await Task.sleep(for: .milliseconds(50))
        let t = TCPTransport(host: "127.0.0.1", port: port, connectTimeout: .seconds(2))
        await #expect(throws: TransportError.self) { _ = try await t.open() }
    }

    @Test func udpSocketReceivesWithSource() async throws {
        let sock = UDPDatagramSocket(port: 0, bindAddress: "127.0.0.1")
        let stream = try await sock.datagrams()
        #expect(sock.port != 0)
        let sender = try UDPSender()
        try sender.send(Array("<RadioInfo/>".utf8), to: "127.0.0.1", port: sock.port)
        var it = stream.makeAsyncIterator()
        let d = try #require(await it.next())
        #expect(d.bytes == Array("<RadioInfo/>".utf8))
        #expect(d.source.hasPrefix("127.0.0.1:"))
        await sock.close()
        #expect(await it.next() == nil)
    }

    @Test func udpPortCanBeSharedWithReusePort() async throws {
        let a = UDPDatagramSocket(port: 0)
        _ = try await a.datagrams()
        let b = UDPDatagramSocket(port: a.port)   // second bind on the same port succeeds
        _ = try await b.datagrams()
        #expect(b.port == a.port)
        await a.close(); await b.close()
    }
}

@Suite struct SerialPortTests {
    @Test func enumeratorReturnsWithoutCrashing() {
        let ports = SerialPortEnumerator.ports()
        #expect(ports.allSatisfy { $0.path.hasPrefix("/dev/cu.") })
    }

    @Test func ioctlCodes() {
        #expect(IOCTL.TIOCEXCL == 0x2000_740D)
        #expect(IOCTL.TIOCMBIS == 0x8004_746C)
        #expect(IOCTL.TIOCMBIC == 0x8004_746B)
        #expect(IOCTL.TIOCMGET == 0x4004_746A)
    }

    @Test func serialOpenOfMissingDeviceFails() async {
        let t = POSIXSerialTransport(path: "/dev/cu.does-not-exist-wp2", settings: .rotor)
        await #expect(throws: TransportError.self) { _ = try await t.open() }
        await #expect(throws: TransportError.notOpen) { try await t.write([0x3B]) }
        await #expect(throws: TransportError.self) { _ = try await POSIXSerialTransport(path: "/dev/null", settings: SerialSettings(baud: 1234)).open() }
    }
}
