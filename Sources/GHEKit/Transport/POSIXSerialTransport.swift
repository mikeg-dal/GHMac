import Darwin
import Dispatch
import Foundation

/// Serial port on a `/dev/cu.*` device using termios: 8N1, `CLOCAL`, flow control
/// none or RTS/CTS, DTR/RTS asserted per `SerialSettings`, exclusive access.
///
/// The actor runs on its own serial dispatch queue so blocking
/// syscalls never sit on Swift's cooperative pool; the read source shares that queue,
/// so reads never block a writer.
public actor POSIXSerialTransport: ByteTransport, ModemControl {
    public let path: String
    public let settings: SerialSettings
    private let queue: DispatchSerialQueue
    private var fd: Int32 = -1
    private var source: (any DispatchSourceRead)?
    private var continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation?

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(path: String, settings: SerialSettings = .rotor) {
        self.path = path
        self.settings = settings
        self.queue = DispatchSerialQueue(label: "ghe.serial", qos: .userInitiated)
    }

    static func speed(for baud: Int) throws -> speed_t {
        switch baud {
        case 1200: speed_t(B1200)
        case 2400: speed_t(B2400)
        case 4800: speed_t(B4800)
        case 9600: speed_t(B9600)
        case 19200: speed_t(B19200)
        case 38400: speed_t(B38400)
        case 57600: speed_t(B57600)
        case 115200: speed_t(B115200)
        case 230400: speed_t(B230400)
        default: throw TransportError.unsupported("baud rate \(baud)")
        }
    }

    public func open() async throws -> AsyncThrowingStream<[UInt8], any Error> {
        closeNow(error: nil)
        let speed = try Self.speed(for: settings.baud)
        let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else { throw TransportError.openFailed(String(cString: strerror(errno))) }

        func fail(_ what: String) -> TransportError {
            let msg = "\(what): \(String(cString: strerror(errno)))"
            Darwin.close(handle)
            return .openFailed(msg)
        }

        guard ioctl(handle, IOCTL.TIOCEXCL) == 0 else { throw fail("exclusive access") }

        var tio = termios()
        guard tcgetattr(handle, &tio) == 0 else { throw fail("tcgetattr") }
        cfmakeraw(&tio)
        tio.c_cflag |= tcflag_t(CS8 | CREAD | CLOCAL)
        tio.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CCTS_OFLOW | CRTS_IFLOW)
        if settings.flow == .rtsCts {
            tio.c_cflag |= tcflag_t(CCTS_OFLOW | CRTS_IFLOW)
        }
        tio.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        // Non-blocking reads are driven by the dispatch source.
        withUnsafeMutableBytes(of: &tio.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 0
        }
        guard cfsetspeed(&tio, speed) == 0 else { throw fail("cfsetspeed") }
        guard tcsetattr(handle, TCSANOW, &tio) == 0 else { throw fail("tcsetattr") }
        tcflush(handle, TCIOFLUSH)

        var set: Int32 = 0, clear: Int32 = 0
        if settings.assertDTR { set |= TIOCM_DTR } else { clear |= TIOCM_DTR }
        if settings.assertRTS { set |= TIOCM_RTS } else if settings.flow == .none { clear |= TIOCM_RTS }
        if set != 0 { _ = ioctl(handle, IOCTL.TIOCMBIS, &set) }
        if clear != 0 { _ = ioctl(handle, IOCTL.TIOCMBIC, &clear) }

        fd = handle
        let (stream, cont) = AsyncThrowingStream<[UInt8], any Error>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont

        let src = DispatchSource.makeReadSource(fileDescriptor: handle, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.assumeIsolated { $0.drain() }
        }
        src.setCancelHandler { Darwin.close(handle) }
        source = src
        src.resume()
        return stream
    }

    private func drain() {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                continuation?.yield(Array(buf[0..<n]))
                if n < buf.count { return }
            } else if n == 0 {
                // Readable but no data: the device went away (USB adapter unplugged).
                closeNow(error: TransportError.linkLost)
                return
            } else {
                if errno == EAGAIN || errno == EINTR { return }
                closeNow(error: TransportError.linkLost)
                return
            }
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard fd >= 0 else { throw TransportError.notOpen }
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                offset += n
            } else if n < 0, errno == EAGAIN || errno == EINTR {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&pfd, 1, 1000)
            } else {
                let why = String(cString: strerror(errno))
                closeNow(error: TransportError.linkLost)
                throw TransportError.writeFailed(why)
            }
        }
    }

    public func modemLines() async throws -> ModemLines {
        guard fd >= 0 else { throw TransportError.notOpen }
        var bits: Int32 = 0
        guard ioctl(fd, IOCTL.TIOCMGET, &bits) == 0 else {
            throw TransportError.openFailed("TIOCMGET: \(String(cString: strerror(errno)))")
        }
        return ModemLines(cts: bits & TIOCM_CTS != 0, dsr: bits & TIOCM_DSR != 0,
                          dcd: bits & TIOCM_CD != 0, ri: bits & TIOCM_RI != 0)
    }

    public func close() async { closeNow(error: nil) }

    private func closeNow(error: (any Error)?) {
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
        continuation = nil
        if let source {
            source.cancel()   // the cancel handler closes the descriptor
            self.source = nil
        } else if fd >= 0 {
            Darwin.close(fd)
        }
        fd = -1
    }
}
