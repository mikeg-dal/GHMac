import Foundation
import GHEKit

/// Global switch button colour (`SwitchButtonColor`).
public enum SwitchGlobalColor: String, CaseIterable, Sendable, Hashable, Codable {
    case green = "Green", red = "Red", black = "Black", cyan = "Cyan"
}

/// Tray row size (`rotorDisplaySize` 0/1/2).
public enum RotorDisplaySize: Int, CaseIterable, Sendable, Hashable, Codable {
    case small = 0, medium = 1, large = 2
}

/// Switch window size (`switchDisplaySize` 10/11/12).
public enum SwitchDisplaySize: Int, CaseIterable, Sendable, Hashable, Codable {
    case small = 10, medium = 11, large = 12
}

/// settings.ini key names, spelled exactly for file compatibility.
public enum SettingsKey {
    public static let switchButtonColor = "SwitchButtonColor"
    public static let fastExit = "fastExit"
    public static let n1mm = "n1mm", n3fjp = "n3fjp", wintest = "wintest", manual = "manual"
    public static let globalPresetsCheckBox = "globalPresetsCheckBox"
    public static let bandA = "bandA", bandB = "bandB"
    public static let x = "x", y = "y"
    public static let touchScreen = "touchScreen"
    public static let alwaysOnTop = "alwaysOnTop"
    /// [sic] — spelling kept for compatibility.
    public static let loggingFocus = "logginFocus"
    public static let showDropOnSwitches = "showDropOnSwitches"
    public static let rotorDisplaySize = "rotorDisplaySize"
    public static let switchDisplaySize = "switchDisplaySize"
    public static let presetEntryWidth = "presetEntryWidth", presetEntryHeight = "presetEntryHeight"
    public static let rotorPresetsFontSize = "RotorPresetsFontSize"
    public static let rotorMapFrameVisible = "rotorMapFrameVisible"
    public static let rotorStepSize = "rotorStepSize"
    public static let showHotkeysOnButtons = "showHotkeysOnButtons"
    public static let bandsScope = "bandsScope"
    public static let savePasswords = "savePasswords"
    public static let radioPort = "radioPort", rotorPort = "rotorPort", n1mmSelectedVFO = "n1mmSelectedVFO"
    public static let n3fjpRadioPort = "n3fjpRadioPort", n3fjpIPAddress = "n3fjpIPAddress"
    public static let wintestRadioPort = "wintestRadioPort"
    public static let wintestNetworkRadioButton = "wintestNetworkRadioButton"
    public static let wintestLoopbackRadioButton = "wintestLoopbackRadioButton"
    public static let wintestCustomRadioButton = "wintestCustomRadioButton"
    public static let wintestCustomIPAddress = "wintestCustomIPAddress"
    public static let wintestStationCheckBox = "wintestStationCheckBox"
    public static let wintestStationText = "wintestStationText"
    public static let wintestSelectedRadio = "wintestSelectedRadio"
}

/// Every settings.ini value, with its on-load defaults. Software-control
/// settings use the logger types. Unknown keys survive because `ClientSettingsStore` load-modify-stores.
public struct ClientSettings: Sendable, Hashable {
    public var switchButtonColor: SwitchGlobalColor = .green
    public var fastExit = false
    /// From the four radio buttons `n1mm` / `n3fjp` / `wintest` / `manual` (default manual).
    public var loggerSource: LoggerSource = .manual
    public var globalPresetsVisible = false
    public var bandA = Band.allName
    /// Always "ALL" after loading.
    public var bandB = Band.allName
    public var x = 0, y = 0
    /// No UI; kept so the key round-trips.
    public var touchScreen = false
    public var alwaysOnTop = false
    /// `logginFocus`; no UI.
    public var loggingFocus = false
    public var showDropOnSwitches = true
    public var rotorDisplaySize: RotorDisplaySize = .medium
    public var switchDisplaySize: SwitchDisplaySize = .small
    public var presetEntryWidth = 400, presetEntryHeight = 400
    public var presetFontSize = 18
    /// Loaded but never used.
    public var rotorMapFrameVisible = false
    public var rotorStepSize = 10
    public var showHotkeysOnButtons = true
    public var bandScope: BandScope = .hfContest
    public var savePasswords = false
    public var n1mm = N1MMConfig()
    public var n3fjp = N3FJPConfig()
    public var winTest = WinTestConfig()
    /// The custom bind address field, kept even while another Win-Test address option is selected.
    public var winTestCustomIPAddress = ""

    public init() {}

    public static let defaults = ClientSettings()

    /// The logger configuration for `LoggerSupervisor`.
    public func loggerConfiguration(so2rRadio: Int? = nil) -> LoggerConfiguration {
        LoggerConfiguration(source: loggerSource, n1mm: n1mm, winTest: winTest, n3fjp: n3fjp, so2rRadio: so2rRadio)
    }

    // MARK: load

    /// Reads the main and logger settings. Unparsable numbers fall
    /// back to the default.
    public init(properties p: JavaProperties) {
        typealias K = SettingsKey
        switchButtonColor = SwitchGlobalColor(rawValue: p[K.switchButtonColor] ?? "") ?? .green
        // "HF Contest" (the default) matches nothing and keeps HF Contest.
        bandScope = BandScope(settingsValue: p[K.bandsScope])
        showHotkeysOnButtons = legacyBool(p[K.showHotkeysOnButtons], default: true)
        fastExit = legacyBool(p[K.fastExit], default: false)
        // The four modes are radio buttons in one group, set in this order: the last `true` wins and a
        // `false` never deselects, so the initial Manual selection survives when none is true.
        var source = LoggerSource.manual
        for (key, mode, def) in [(K.n1mm, LoggerSource.n1mm, false), (K.n3fjp, .n3fjp, false),
                                 (K.wintest, .wintest, false), (K.manual, .manual, true)]
        where legacyBool(p[key], default: def) {
            source = mode
        }
        loggerSource = source
        globalPresetsVisible = legacyBool(p[K.globalPresetsCheckBox], default: false)
        bandA = p[K.bandA] ?? Band.allName
        bandB = Band.allName
        alwaysOnTop = legacyBool(p[K.alwaysOnTop], default: false)
        touchScreen = legacyBool(p[K.touchScreen], default: false)
        loggingFocus = legacyBool(p[K.loggingFocus], default: false)
        presetEntryHeight = legacyInt(p[K.presetEntryHeight], default: 400)
        presetEntryWidth = legacyInt(p[K.presetEntryWidth], default: 400)
        presetFontSize = legacyInt(p[K.rotorPresetsFontSize], default: 18)
        rotorStepSize = legacyInt(p[K.rotorStepSize], default: 10)
        x = legacyInt(p[K.x], default: 0)
        y = legacyInt(p[K.y], default: 0)
        showDropOnSwitches = legacyBool(p[K.showDropOnSwitches], default: true)
        rotorDisplaySize = RotorDisplaySize(rawValue: legacyInt(p[K.rotorDisplaySize], default: 1)) ?? .medium
        // Default "0" matches no case, so the Small checkbox stays selected.
        switchDisplaySize = SwitchDisplaySize(rawValue: legacyInt(p[K.switchDisplaySize], default: 0)) ?? .small
        rotorMapFrameVisible = legacyBool(p[K.rotorMapFrameVisible], default: false)
        savePasswords = legacyBool(p[K.savePasswords], default: false)

        n1mm = N1MMConfig(radioPort: Self.port(p[K.radioPort], 12060),
                          rotorPort: Self.port(p[K.rotorPort], 12045),
                          selectedVFO: legacyInt(p[K.n1mmSelectedVFO], default: 1))
        n3fjp = N3FJPConfig(host: p[K.n3fjpIPAddress] ?? "127.0.0.1", port: Self.port(p[K.n3fjpRadioPort], 1100))

        winTestCustomIPAddress = p[K.wintestCustomIPAddress] ?? ""
        var bind = WinTestConfig.Bind.network
        if legacyBool(p[K.wintestNetworkRadioButton], default: true) { bind = .network }
        if legacyBool(p[K.wintestLoopbackRadioButton], default: false) { bind = .loopback }
        if legacyBool(p[K.wintestCustomRadioButton], default: false) { bind = .custom(winTestCustomIPAddress) }
        winTest = WinTestConfig(
            port: Self.port(p[K.wintestRadioPort], 9871), bind: bind,
            filter: WinTestFilter(selectedRadio: legacyInt(p[K.wintestSelectedRadio], default: 0),
                                  stationFilterEnabled: legacyBool(p[K.wintestStationCheckBox], default: false),
                                  stationName: p[K.wintestStationText] ?? ""))
    }

    private static func port(_ value: String?, _ fallback: UInt16) -> UInt16 {
        guard let v = value.flatMap(JavaString.parseInt), let p = UInt16(exactly: v), p > 0 else { return fallback }
        return p
    }

    // MARK: store

    /// Writes every key into `p`, leaving other keys alone .
    public func write(into p: inout JavaProperties) {
        typealias K = SettingsKey
        p[K.switchButtonColor] = switchButtonColor.rawValue
        p[K.fastExit] = String(fastExit)
        p[K.n1mm] = String(loggerSource == .n1mm)
        p[K.n3fjp] = String(loggerSource == .n3fjp)
        p[K.wintest] = String(loggerSource == .wintest)
        p[K.manual] = String(loggerSource == .manual)
        p[K.globalPresetsCheckBox] = String(globalPresetsVisible)
        p[K.bandA] = bandA
        p[K.bandB] = bandB
        p[K.x] = String(x)
        p[K.y] = String(y)
        p[K.touchScreen] = String(touchScreen)
        p[K.alwaysOnTop] = String(alwaysOnTop)
        p[K.loggingFocus] = String(loggingFocus)
        p[K.showDropOnSwitches] = String(showDropOnSwitches)
        p[K.rotorDisplaySize] = String(rotorDisplaySize.rawValue)
        p[K.switchDisplaySize] = String(switchDisplaySize.rawValue)
        p[K.presetEntryWidth] = String(presetEntryWidth)
        p[K.presetEntryHeight] = String(presetEntryHeight)
        p[K.rotorPresetsFontSize] = String(presetFontSize)
        p[K.rotorMapFrameVisible] = String(rotorMapFrameVisible)
        p[K.rotorStepSize] = String(rotorStepSize)
        p[K.showHotkeysOnButtons] = String(showHotkeysOnButtons)
        p[K.bandsScope] = bandScope.settingsValue
        p[K.savePasswords] = String(savePasswords)
        p[K.radioPort] = String(n1mm.radioPort)
        p[K.rotorPort] = String(n1mm.rotorPort)
        p[K.n1mmSelectedVFO] = String(n1mm.selectedVFO)
        p[K.n3fjpRadioPort] = String(n3fjp.port)
        p[K.n3fjpIPAddress] = n3fjp.host
        p[K.wintestRadioPort] = String(winTest.port)
        var customIP = winTestCustomIPAddress
        if case .custom(let ip) = winTest.bind { customIP = ip }
        p[K.wintestNetworkRadioButton] = String(winTest.bind == .network)
        p[K.wintestLoopbackRadioButton] = String(winTest.bind == .loopback)
        p[K.wintestCustomRadioButton] = String({ if case .custom = winTest.bind { true } else { false } }())
        p[K.wintestCustomIPAddress] = customIP
        p[K.wintestStationCheckBox] = String(winTest.filter.stationFilterEnabled)
        p[K.wintestStationText] = winTest.filter.stationName
        p[K.wintestSelectedRadio] = String(winTest.filter.selectedRadio)
    }
}

/// settings.ini on disk. Saves load-modify-store so keys this port does not know are kept.
public struct ClientSettingsStore: Sendable {
    public let file: PropertiesFile

    public init(directory: AppDirectories) {
        // Stored with the comment "" (a bare "#" line).
        file = PropertiesFile(directory, ClientFileName.settings, comment: "")
    }

    public func load() -> ClientSettings { ClientSettings(properties: file.readOrEmpty()) }

    public func save(_ settings: ClientSettings) throws {
        try file.update { settings.write(into: &$0) }
    }
}
