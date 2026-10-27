import Foundation

/// Turns a radio report into band-slot and band-switch frequency events, per logger.
/// Order: band-switch frequency first, then band display.
public enum RadioRouting {
    /// N1MM `RadioNr` → radio "1"/"2": 1/3 → 1, 2/4 → 2, anything else/absent → 1.
    public static func n1mmRadio(_ radioNr: String?) -> Int {
        switch radioNr { case "2", "4": 2; default: 1 }
    }

    /// Whether the band display follows this packet (table). `vfoSetting`:
    /// 1 = radio 1 only, 2 = radio 2 only, 3 = both.
    public static func n1mmProcess(radioNr: String?, vfoSetting: Int) -> Bool {
        switch radioNr {
        case nil: true
        case "1", "3": vfoSetting == 1 || vfoSetting == 3
        case "2", "4": vfoSetting == 2 || vfoSetting == 3
        default: false
        }
    }

    /// N1MM routing. The band-switch frequency is not gated by `process`.
    // Band switches follow the VFO boxes, not the "Display from" setting.
    public static func n1mm(radioNr: String?, vfoSetting: Int, freqMHz: Double, band: Band?) -> [LoggerEvent] {
        let radio = n1mmRadio(radioNr)
        let name = band?.rawValue
        var out: [LoggerEvent] = [.frequency(vfo: radio == 1 ? .a : .b, mhz: freqMHz)]
        guard n1mmProcess(radioNr: radioNr, vfoSetting: vfoSetting) else { return out }
        if radio == 1 {
            out.append(.band(slot: .a, band: name))
            if vfoSetting == 1 { out.append(.band(slot: .b, band: name)) }
        } else {
            out.append(.band(slot: .b, band: name))
            if vfoSetting == 2 { out.append(.band(slot: .a, band: name)) }
        }
        return out
    }

    /// Win-Test STATUS routing. `setting`: 0 = active radio, 1 = radio 1 only,
    /// 2 = radio 2 only, 3 = both. `rad` is the reported radio (0 or 1).
    public static func winTest(rad: Int, setting: Int, freqMHz: Double, band: Band?) -> [LoggerEvent] {
        var out: [LoggerEvent] = []
        if rad == 0 { out.append(.frequency(vfo: .a, mhz: freqMHz)) }
        if rad == 1 { out.append(.frequency(vfo: .b, mhz: freqMHz)) }
        let accepted = rad == 1 ? [0, 2, 3].contains(setting) : [0, 1, 3].contains(setting)
        guard accepted else { return out }
        let name = band?.rawValue
        if rad == 0 {
            out.append(.band(slot: .a, band: name))
            if setting == 0 { out.append(.band(slot: .b, band: name)) }
        } else if rad == 1 {
            out.append(.band(slot: .b, band: name))
            if setting == 0 { out.append(.band(slot: .a, band: name)) }
        }
        return out
    }

    /// N3FJP routing: every band switch gets the frequency whatever its VFO boxes,
    /// and only slot A changes. The contract has no "all switches" event, so the frequency is
    /// sent once per VFO; consumers apply each to switches with that VFO box checked.
    public static func n3fjp(freqMHz: Double, band: Band?) -> [LoggerEvent] {
        [.frequency(vfo: .a, mhz: freqMHz), .frequency(vfo: .b, mhz: freqMHz),
         .band(slot: .a, band: band?.rawValue)]
    }
}
