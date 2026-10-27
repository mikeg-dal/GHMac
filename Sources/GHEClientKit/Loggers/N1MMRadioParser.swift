import Foundation

/// A frequency as reported by a logger, in both units the client needs.
public struct LoggerFrequency: Sendable, Equatable {
    /// For the band table.
    public var kHz: Double
    /// For band switches.
    public var mhz: Double
    public init(kHz: Double, mhz: Double) { self.kHz = kHz; self.mhz = mhz }
    public var band: Band? { Band.classify(kHz: kHz) }
}

/// Fields of an N1MM+ `RadioInfo` packet that the client uses.
public struct N1MMRadioInfo: Sendable, Equatable {
    /// Raw `<RadioNr>` text; nil when absent (FRStack/PSTRotator packets).
    public var radioNr: String?
    public var freq: LoggerFrequency?
    public var txFreq: LoggerFrequency?
    /// Raw `<FocusEntry>` (a window handle; kept only for completeness).
    public var focusEntry: String?
    /// `<FocusRadioNr>` (first character as a digit).
    public var focusRadioNr: Int?

    /// TXFreq is preferred (split-aware); Freq is the fallback.
    public var effectiveFrequency: LoggerFrequency? { txFreq ?? freq }
}

/// Tolerant substring parser for N1MM `RadioInfo` (works on malformed XML).
public enum N1MMRadioParser {
    public static func parse(_ text: String) -> N1MMRadioInfo {
        var info = N1MMRadioInfo()
        info.focusEntry = LoggerText.tag("FocusEntry", in: text)
        if let f = LoggerText.tag("FocusRadioNr", in: text)?.trimmingCharacters(in: .whitespaces).first {
            info.focusRadioNr = f.wholeNumberValue
        }
        info.radioNr = LoggerText.tag("RadioNr", in: text)?.trimmingCharacters(in: .whitespaces)
        info.txFreq = LoggerText.tag("TXFreq", in: text).flatMap(frequency)
        info.freq = LoggerText.tag("Freq", in: text).flatMap(frequency)
        return info
    }

    /// N1MM frequencies are integers in 10 Hz units (`1402500` = 14.025 MHz).
    /// A value with a decimal separator (`14025,00`, from loggers that format the number)
    /// is read as kHz, which is what that text means.
    // Comma/point decimals are accepted instead of killing the listener.
    public static func frequency(_ raw: String) -> LoggerFrequency? {
        guard let v = LoggerText.parseNumber(raw), v.isFinite else { return nil }
        if LoggerText.hasDecimalSeparator(raw) { return LoggerFrequency(kHz: v, mhz: v / 1000) }
        return LoggerFrequency(kHz: v / 100, mhz: v / 100_000)
    }

    /// Events for one packet: raw text, focus radio, then routing.
    public static func events(for text: String, vfoSetting: Int) -> [LoggerEvent] {
        let info = parse(text)
        var out: [LoggerEvent] = [.raw(text)]
        if let f = info.focusRadioNr { out.append(.focusRadio(f)) }
        if let f = info.effectiveFrequency {
            out += RadioRouting.n1mm(radioNr: info.radioNr, vfoSetting: vfoSetting, freqMHz: f.mhz, band: f.band)
        }
        return out
    }
}
