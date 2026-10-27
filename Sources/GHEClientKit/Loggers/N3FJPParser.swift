import Foundation

/// N3FJP API lines, e.g. `<CMD><READBMFRESPONSE>…<FREQ>14.025</FREQ></CMD>`.
public enum N3FJPParser {
    /// `<FREQ>` in MHz.
    public static func frequency(in line: String) -> LoggerFrequency? {
        guard let raw = LoggerText.tag("FREQ", in: line), let mhz = LoggerText.parseNumber(raw), mhz.isFinite
        else { return nil }
        return LoggerFrequency(kHz: mhz * 1000, mhz: mhz)
    }

    /// Band for an N3FJP MHz value. Same table as N1MM (60 m at 5.0 MHz).
    public static func band(mhz: Double) -> Band? { Band.classify(mhz: mhz) }

    public static func events(for line: String) -> [LoggerEvent] {
        var out: [LoggerEvent] = [.raw(line)]
        if let f = frequency(in: line) { out += RadioRouting.n3fjp(freqMHz: f.mhz, band: band(mhz: f.mhz)) }
        return out
    }
}
