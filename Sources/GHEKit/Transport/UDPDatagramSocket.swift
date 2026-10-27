import Darwin
import Dispatch
import Foundation
import Synchronization

/// A UDP receiver on a BSD socket. `SO_REUSEADDR` and `SO_REUSEPORT` are set **before**
/// `bind` so several apps (N1MM listeners, two client instances) can share the port, and
/// it binds the wildcard address so subnet broadcasts arrive.
public final class UDPDatagramSocket: DatagramSource {
    private struct State {
        var fd: Int32 = -1
        var source: (any DispatchSourceRead)?
        var continuation: AsyncStream<Datagram>.Continuation?
        var boundPort: UInt16 = 0
    }
    public let requestedPort: UInt16
    /// IPv4 address to bind; nil = INADDR_ANY.
    public let bindAddress: String?
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "ghe.udp")
    static let maxDatagram = 65536

    public init(port: UInt16, bindAddress: String? = nil) {
        requestedPort = port
        self.bindAddress = bindAddress
    }

    /// Port actually bound (after `datagrams()`).
    public var port: UInt16 { state.withLock { $0.boundPort } }

    public func datagrams() async throws -> AsyncStream<Datagram> {
        await close()
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw TransportError.openFailed("socket: \(String(cString: strerror(errno)))") }
        func fail(_ what: String) -> TransportError {
            let e = TransportError.openFailed("\(what): \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            return e
        }
        var one: Int32 = 1
        let len = socklen_t(MemoryLayout<Int32>.size)
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, len) == 0 else { throw fail("SO_REUSEADDR") }
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, len) == 0 else { throw fail("SO_REUSEPORT") }
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, len) == 0 else { throw fail("SO_BROADCAST") }
        var rcv = Int32(Self.maxDatagram)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, len)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requestedPort.bigEndian
        if let bindAddress {
            guard inet_pton(AF_INET, bindAddress, &addr.sin_addr) == 1 else {
                Darwin.close(fd)
                throw TransportError.openFailed("bad IPv4 address \(bindAddress)")
            }
        } else {
            addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { throw fail("bind to port \(requestedPort)") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var bound = sockaddr_in()
        var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &blen) }
        }

        let (stream, cont) = AsyncStream<Datagram>.makeStream(bufferingPolicy: .bufferingNewest(1024))
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { Self.drain(fd: fd, into: cont) }
        src.setCancelHandler { Darwin.close(fd) }
        state.withLock { s in
            s.fd = fd; s.source = src; s.continuation = cont
            s.boundPort = UInt16(bigEndian: bound.sin_port)
        }
        src.resume()
        return stream
    }

    private static func drain(fd: Int32, into cont: AsyncStream<Datagram>.Continuation) {
        var buf = [UInt8](repeating: 0, count: maxDatagram)
        while true {
            var from = sockaddr_in()
            var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBytes { b in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, b.baseAddress, b.count, 0, $0, &flen)
                    }
                }
            }
            guard n >= 0 else { return }   // EAGAIN: drained
            cont.yield(Datagram(bytes: Array(buf[0..<n]), source: describe(from)))
        }
    }

    static func describe(_ a: sockaddr_in) -> String {
        var addr = a.sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN))
        let ip = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return "\(ip):\(UInt16(bigEndian: a.sin_port))"
    }

    public func close() async {
        let (src, cont, fd) = state.withLock { s in
            defer { s.source = nil; s.continuation = nil; s.fd = -1 }
            return (s.source, s.continuation, s.fd)
        }
        if let src { src.cancel() } else if fd >= 0 { Darwin.close(fd) }
        cont?.finish()
    }

    deinit {
        let (src, cont) = state.withLock { ($0.source, $0.continuation) }
        src?.cancel()
        cont?.finish()
    }
}

/// Minimal UDP sender (loopback tests, simulator logger packets).
public final class UDPSender: Sendable {
    private let fd: Int32

    public init(broadcast: Bool = false) throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw TransportError.openFailed("socket: \(String(cString: strerror(errno)))") }
        if broadcast {
            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    public func send(_ bytes: [UInt8], to host: String = "127.0.0.1", port: UInt16) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { throw TransportError.writeFailed("bad IPv4 address \(host)") }
        let n = bytes.withUnsafeBytes { b in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, b.baseAddress, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard n == bytes.count else { throw TransportError.writeFailed(String(cString: strerror(errno))) }
    }

    deinit { Darwin.close(fd) }
}
