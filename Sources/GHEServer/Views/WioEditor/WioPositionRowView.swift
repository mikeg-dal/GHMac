import SwiftUI
import GHEKit

/// One row of the position grid (`SwitchEntryPanel`).
struct WioPositionRowView: View {
    @Bindable var model: WioEditorModel
    let index: Int
    let editVirtual: () -> Void

    var body: some View {
        let row = model.rows[index]
        HStack(spacing: WioColumns.spacing) {
            Group {
                if model.virtualSwitch {
                    Button("…", action: editVirtual)
                        .controlSize(.small)
                        .help("Edit Virtual Positions")
                        .disabled(JavaString.trim(row.name).isEmpty)
                        .accessibilityIdentifier("wioVirtual.\(index)")
                } else {
                    Color.clear
                }
            }
            .frame(width: WioColumns.virtual)
            TextField("", text: $model.rows[index].name)
                .frame(width: WioColumns.name)
                .accessibilityIdentifier("wioName.\(index)")
            Toggle("", isOn: $model.rows[index].bidirectional)
                .labelsHidden()
                .frame(width: WioColumns.bidirectional)
                .accessibilityIdentifier("wioBidirectional.\(index)")
            numberField($model.rows[index].degrees, width: WioColumns.degrees, enabled: model.degreesEnabled,
                        invalid: model.degreesError(row), help: "Heading is not a valid integer")
                .accessibilityIdentifier("wioDegrees.\(index)")
            numberField($model.rows[index].beamwidth, width: WioColumns.beamwidth, enabled: model.degreesEnabled,
                        invalid: model.beamwidthError(row), help: "Beamwidth is not a valid integer")
                .accessibilityIdentifier("wioBeamwidth.\(index)")
            ForEach(0..<8, id: \.self) { pin in
                OutputStateMenu(state: $model.rows[index].outputs[pin])
                    .frame(width: WioColumns.output)
                    .disabled(!model.outputsEnabled)
                    .opacity(model.outputsEnabled ? 1 : 0.35)
                    .accessibilityIdentifier("wioOutput.\(index).\(pin + 1)")
            }
            numberField($model.rows[index].lower, width: WioColumns.freq, enabled: model.frequencyEnabled,
                        invalid: model.frequencyError(row.lower), help: "Lower frequency in MHz")
                .accessibilityIdentifier("wioLower.\(index)")
            numberField($model.rows[index].upper, width: WioColumns.freq, enabled: model.frequencyEnabled,
                        invalid: model.frequencyError(row.upper), help: "Upper frequency in MHz")
                .accessibilityIdentifier("wioUpper.\(index)")
        }
    }

    /// Inline validation: an invalid number gets a red border and a tooltip.
    private func numberField(_ text: Binding<String>, width: CGFloat, enabled: Bool, invalid: Bool, help: String) -> some View {
        TextField("", text: text)
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .disabled(!enabled)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.red, lineWidth: invalid ? 1.5 : 0))
            .help(invalid ? help : "")
    }
}

/// An output pin's state as a coloured chip with a menu (N/C, ON, OFF, MOM) — the colours of the
/// bundled `nc/on/off/mom.bmp` bitmaps.
struct OutputStateMenu: View {
    @Binding var state: WioEditorModel.PinState

    var body: some View {
        Menu {
            ForEach(WioEditorModel.PinState.allCases) { s in
                Button(s.title) { state = s }
            }
        } label: {
            OutputChip(state: state)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityValue(state.title)
    }
}

struct OutputChip: View {
    let state: WioEditorModel.PinState

    var body: some View {
        Text(state.title)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 40, height: 17)
            .background(RoundedRectangle(cornerRadius: 3).fill(state.color))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.35), lineWidth: 0.5))
    }
}

extension WioEditorModel.PinState {
    /// Exact colours of the shipped bitmaps.
    var color: Color {
        switch self {
        case .on: Color(red: 34 / 255, green: 177 / 255, blue: 76 / 255)
        case .off: Color(red: 237 / 255, green: 28 / 255, blue: 36 / 255)
        case .notConnected: Color(red: 195 / 255, green: 195 / 255, blue: 195 / 255)
        case .momentary: Color(red: 255 / 255, green: 242 / 255, blue: 0)
        }
    }
}
