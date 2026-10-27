import SwiftUI
import GHEServerKit

/// One Device Manager slot (`SerialControlPanel`): Name | Port | Base PTT | Device Type | Subtype |
/// WIO Addr. | Status.
struct DeviceRowView: View {
    @Bindable var row: DeviceRowModel
    let dm: DeviceManagerModel

    private static let addresses: [Int] = Array(0...255)

    var body: some View {
        HStack(spacing: DMColumns.spacing) {
            Text("\(row.order + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: DMColumns.number, alignment: .trailing)
            TextField("", text: $row.name)
                .frame(width: DMColumns.name)
                .disabled(!row.fieldsEnabled)
                .accessibilityIdentifier("deviceName.\(row.order)")
            Picker("", selection: $row.port) {
                ForEach(dm.ports(for: row), id: \.self) { p in
                    Text(Self.portLabel(p)).tag(p)
                }
            }
            .labelsHidden()
            .frame(width: DMColumns.port)
            .disabled(!row.portEnabled)
            .accessibilityIdentifier("devicePort.\(row.order)")
            Toggle("", isOn: $row.basePTT)
                .labelsHidden()
                .frame(width: DMColumns.ptt)
                .disabled(!row.basePTTEnabled)
                .help("Base PTT: RTS/CTS flow control for the GHE Base on this port")
                .accessibilityIdentifier("devicePTT.\(row.order)")
            Picker("", selection: $row.deviceType) {
                ForEach(DeviceType.allCases, id: \.self) { t in Text(t.rawValue).tag(t.rawValue) }
            }
            .labelsHidden()
            .frame(width: DMColumns.type)
            .disabled(!row.fieldsEnabled)
            .accessibilityIdentifier("deviceType.\(row.order)")
            Picker("", selection: $row.subType) {
                ForEach(subtypes, id: \.self) { s in Text(s).tag(s) }
            }
            .labelsHidden()
            .frame(width: DMColumns.subtype)
            .disabled(!row.subTypeEnabled)
            .accessibilityIdentifier("deviceSubtype.\(row.order)")
            Picker("", selection: $row.wioAddress) {
                // Building 256 menu items only for editable rows keeps opening the window fast.
                if row.wioAddressEnabled || row.wioAddress == nil { Text("N/A").tag(Int?.none) }
                ForEach(row.wioAddressEnabled ? Self.addresses : row.wioAddress.map { [$0] } ?? [], id: \.self) { a in
                    Text(String(a)).tag(Int?.some(a))
                }
            }
            .labelsHidden()
            .frame(width: DMColumns.wio)
            .disabled(!row.wioAddressEnabled)
            .accessibilityIdentifier("deviceWIO.\(row.order)")
            DeviceStatusButton(status: row.status, busy: row.isBusy) { dm.toggle(row) }
                .frame(width: DMColumns.status)
                .accessibilityIdentifier("deviceStatus.\(row.order)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deviceRow.\(row.order)")
    }

    private var subtypes: [String] {
        let list = dm.subtypeNames
        return list.contains(row.subType) ? list : list + [row.subType]
    }

    /// Serial paths show as their device name (`cu.usbserial-A1`).
    static func portLabel(_ p: String) -> String {
        p.hasPrefix("/dev/") ? String(p.dropFirst(5)) : p
    }
}

/// The status toggle: Disconnected / Connecting... / Validating / Connected / Error / Retrying.
struct DeviceStatusButton: View {
    let status: SlotStatus
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(status.title).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(StatusToggleStyle(pressed: pressed, color: color))
        .disabled(busy && !pressed)
        .help(help)
        .accessibilityLabel(status.title)
    }

    /// Stays pressed while connected, connecting or retrying.
    private var pressed: Bool {
        switch status {
        case .disconnected, .error: false
        default: true
        }
    }

    private var color: Color {
        switch status {
        case .disconnected: .secondary
        case .connecting, .validating: .orange
        case .connected: .green
        case .error: .red
        case .retrying: .yellow
        }
    }

    private var help: String {
        if case .error(let m) = status { return m }
        return pressed ? "Click to disconnect" : "Click to connect"
    }
}

/// A toggle-button look: tinted and inset while "pressed" (connected, connecting, retrying).
struct StatusToggleStyle: ButtonStyle {
    let pressed: Bool
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(pressed ? color.opacity(configuration.isPressed ? 0.35 : 0.22)
                                  : Color(nsColor: .controlColor).opacity(configuration.isPressed ? 0.6 : 1))
            )
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(pressed ? color.opacity(0.7) : Color(nsColor: .separatorColor), lineWidth: 1))
            .contentShape(Rectangle())
    }
}
