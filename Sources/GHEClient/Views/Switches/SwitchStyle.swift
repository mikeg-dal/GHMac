import SwiftUI
import GHEClientKit

/// Fonts per switch display size.
struct SwitchMetrics {
    var buttonFont: Font
    var nameFont: Font
    var buttonHeight: CGFloat

    static func forSize(_ s: SwitchDisplaySize) -> SwitchMetrics {
        switch s {
        case .small: SwitchMetrics(buttonFont: .system(size: 13, weight: .semibold), nameFont: .system(size: 13, weight: .bold), buttonHeight: 26)
        case .medium: SwitchMetrics(buttonFont: .system(size: 24, weight: .semibold), nameFont: .system(size: 24, weight: .bold), buttonHeight: 44)
        case .large: SwitchMetrics(buttonFont: .system(size: 36, weight: .semibold), nameFont: .system(size: 36, weight: .bold), buttonHeight: 62)
        }
    }
}

/// Switch button colours.
enum SwitchColors {
    static let unselected = Color(red: 240 / 255, green: 240 / 255, blue: 240 / 255)
    static let locked = Color(red: 1, green: 175 / 255, blue: 175 / 255)

    static func global(_ c: SwitchGlobalColor) -> Color {
        switch c {
        case .green: Color(red: 0, green: 1, blue: 0)
        case .red: .red
        case .cyan: Color(red: 0, green: 1, blue: 1)
        case .black: .black
        }
    }

    static func button(_ c: SwitchButtonColor) -> Color {
        switch c {
        case .green: Color(red: 0, green: 1, blue: 0)
        case .red: .red
        case .yellow: Color(red: 1, green: 1, blue: 0)
        case .cyan: Color(red: 0, green: 1, blue: 1)
        case .orange: Color(red: 1, green: 200 / 255, blue: 0)
        case .black: .black
        }
    }

    /// The "momentary" colour shown on the previous position while the switch reports UNKNOWN.
    static func momentary(_ c: SwitchGlobalColor) -> Color {
        switch c {
        case .green: Color(red: 150 / 255, green: 1, blue: 150 / 255)
        case .red: Color(red: 1, green: 150 / 255, blue: 150 / 255)
        case .cyan: Color(red: 184 / 255, green: 237 / 255, blue: 1)
        case .black: Color(white: 150 / 255)
        }
    }

    static func isDark(_ color: Color) -> Bool { color == .black }

    /// Tooltip for a switch status (sc/*SwitchControlPanel).
    static func statusText(_ status: Int) -> String? {
        switch status {
        case -1, 0, 9: nil   // 9 is not an error.
        case 1: "ERROR response from device"
        case 2: "INVALID COMMAND response from device"
        case 3: "INVALID PARAMETER response from device"
        case 4: "NO RESPONSE from device"
        default: "Device responded with response code \(status)"
        }
    }

    static func shortStatusText(_ status: Int) -> String {
        switch status {
        case 2: "INV. COMMAND"
        case 3: "INV. PARAM."
        case 4: "NO RESPONSE"
        default: "ERROR"
        }
    }
}

/// A flat, colour-filled toggle button (native rounding).
struct ColoredButtonStyle: ButtonStyle {
    var fill: Color
    var textColor: Color
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? textColor : textColor.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 5).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}
