import Testing

extension Tag {
    /// Tests that open real sockets on 127.0.0.1 only (never any other host).
    @Tag static var loopback: Self
}
