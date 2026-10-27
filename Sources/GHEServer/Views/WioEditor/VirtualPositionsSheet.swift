import SwiftUI
import GHEServerKit

/// "Translate Virtual Devices" . Any number of rows
/// (8 shown by default), and entries beyond 8 are kept.
struct VirtualPositionsSheet: View {
    struct Line: Identifiable {
        let id = UUID()
        var device = ""
        var action = ""
    }

    let positionName: String
    let loadDevices: () async -> [(name: String, positions: [String])]
    let onSave: ([WioProfile.VirtualEntry]) -> Void
    @State private var lines: [Line]
    @State private var devices: [(name: String, positions: [String])] = []
    @Environment(\.dismiss) private var dismiss

    init(positionName: String, entries: [WioProfile.VirtualEntry],
         loadDevices: @escaping () async -> [(name: String, positions: [String])],
         onSave: @escaping ([WioProfile.VirtualEntry]) -> Void) {
        self.positionName = positionName
        self.loadDevices = loadDevices
        self.onSave = onSave
        var l = entries.map { Line(device: $0.target, action: $0.action) }
        while l.count < 8 { l.append(Line()) }
        _lines = State(initialValue: l)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Translate Virtual Devices: \(positionName)")
                .font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Real Device Name").font(.headline)
                    Text("Real Device Position/Command").font(.headline)
                }
                ForEach($lines) { $line in
                    GridRow {
                        ComboBox(text: $line.device, items: devices.map(\.name), placeholder: "<Enter>")
                            .frame(width: 200)
                        ComboBox(text: $line.action, items: positions(for: line.device), placeholder: "<Enter>")
                            .frame(width: 220)
                    }
                }
            }
            HStack {
                Button("Add Row") { lines.append(Line()) }
                Spacer()
                Text("Rotor = #deg (e.g. #45),  Command = $cmd")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    // Rows with an empty or placeholder cell are dropped.
                    onSave(lines.compactMap { l in
                        let d = l.device.trimmingCharacters(in: .whitespaces)
                        let a = l.action.trimmingCharacters(in: .whitespaces)
                        guard !d.isEmpty, !a.isEmpty, d != "<Enter>", a != "<Enter>" else { return nil }
                        return WioProfile.VirtualEntry(target: d, action: a)
                    })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 500)
        .task { devices = await loadDevices() }
    }

    private func positions(for device: String) -> [String] {
        devices.first { $0.name == device }?.positions ?? []
    }
}
