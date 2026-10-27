import SwiftUI
import GHEKit
import GHEClientKit

/// Fonts and widths of the three tray-row sizes.
struct RotorRowMetrics {
    enum TurnStyle { case icon, text }
    enum PresetUI { case popupMenu, window }

    var size: RotorDisplaySize
    var checkboxWidth: CGFloat
    var nameFont: Font
    var nameWidth: CGFloat
    var stackSize: CGFloat
    var stackFontSize: CGFloat
    var headingFontSize: CGFloat
    var headingWidth: CGFloat
    var headingHeight: CGFloat
    var spinnerFontSize: CGFloat
    var spinnerWidth: CGFloat
    var turnStyle: TurnStyle
    var buttonFont: Font
    var jogFont: Font
    var jogWidth: CGFloat
    var stopWidth: CGFloat
    var hasJog: Bool
    var presetUI: PresetUI
    /// 0 = no colour swatch (Medium).
    var swatchWidth: CGFloat
    var rowPadding: CGFloat

    static func forSize(_ size: RotorDisplaySize) -> RotorRowMetrics {
        switch size {
        case .small:
            RotorRowMetrics(size: size, checkboxWidth: 18, nameFont: .system(size: 12), nameWidth: 95,
                            stackSize: 22, stackFontSize: 8, headingFontSize: 13, headingWidth: 46, headingHeight: 22,
                            spinnerFontSize: 11, spinnerWidth: 44, turnStyle: .icon, buttonFont: .system(size: 11),
                            jogFont: .system(size: 11, weight: .bold), jogWidth: 0, stopWidth: 35, hasJog: false,
                            presetUI: .popupMenu, swatchWidth: 12, rowPadding: 3)
        case .medium:
            RotorRowMetrics(size: size, checkboxWidth: 24, nameFont: .system(size: 24), nameWidth: 150,
                            stackSize: 49, stackFontSize: 11, headingFontSize: 30, headingWidth: 96, headingHeight: 52,
                            spinnerFontSize: 18, spinnerWidth: 57, turnStyle: .text, buttonFont: .system(size: 14),
                            jogFont: .system(size: 14, weight: .bold), jogWidth: 48, stopWidth: 52, hasJog: true,
                            presetUI: .window, swatchWidth: 0, rowPadding: 4)
        case .large:
            RotorRowMetrics(size: size, checkboxWidth: 30, nameFont: .system(size: 36), nameWidth: 199,
                            stackSize: 83, stackFontSize: 14, headingFontSize: 48, headingWidth: 152, headingHeight: 80,
                            spinnerFontSize: 30, spinnerWidth: 94, turnStyle: .text, buttonFont: .system(size: 14, weight: .bold),
                            jogFont: .system(size: 24, weight: .bold), jogWidth: 79, stopWidth: 79, hasJog: true,
                            presetUI: .window, swatchWidth: 7, rowPadding: 5)
        }
    }
}

/// Status → colour / tooltip / control state.
enum RotorStatusStyle {
    static let headingYellow = Color(red: 1, green: 1, blue: 51.0 / 255)

    static func color(_ status: RotorStatus) -> Color {
        switch status {
        case .ok, .moving, .turningCW, .turningCCW, .readOnly: headingYellow
        case .offline, .error: .red
        case .stopped, .clone: .cyan
        case .fixed: Color(white: 0.75)
        }
    }

    static func tooltip(_ status: RotorStatus) -> String? {
        switch status {
        case .ok, .moving: nil
        case .offline: "Offline"
        case .stopped: "Stopped"
        case .turningCW: "Turning CW"
        case .turningCCW: "Turning CCW"
        case .error: "Rotor not responding"
        case .readOnly: "Rotor is Read Only"
        case .fixed: "Fixed Rotor"
        case .clone: "Cloned Rotor"
        }
    }

    /// The "active" checkbox is usable. Cloned rotors are disabled in every size.
    static func checkboxEnabled(_ r: RotorItem) -> Bool {
        guard r.isConnected else { return false }
        switch r.status {
        case .error, .readOnly, .fixed, .clone: return false
        default: return true
        }
    }
}
