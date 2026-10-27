import SwiftUI
import GHEServerKit

/// Column widths of the Device Manager (`RotorManagerHeadingPanel` and `SerialControlPanel`).
enum DMColumns {
    static let number: CGFloat = 22
    static let name: CGFloat = 118
    static let port: CGFloat = 108
    static let ptt: CGFloat = 60
    static let type: CGFloat = 128
    static let subtype: CGFloat = 132
    static let wio: CGFloat = 64
    static let status: CGFloat = 112
    static let spacing: CGFloat = 6
}

/// The Device Manager window: a heading row over 100 fixed slot rows.
struct DeviceManagerView: View {
    @Bindable var dm: DeviceManagerModel
    let openEditor: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DeviceHeaderRow()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(dm.visibleRows) { row in
                        DeviceRowView(row: row, dm: dm)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 800, minHeight: 300)
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $dm.hideEmptyRows) { Label("Hide Empty Rows", systemImage: "line.3.horizontal.decrease") }
                    .help("Hide empty rows")
                    .accessibilityIdentifier("hideEmptyRows")
                Button { dm.rescanPorts() } label: { Label("Rescan Ports", systemImage: "arrow.clockwise") }
                    .help("Rescan ports")
                    .accessibilityIdentifier("rescanPorts")
                Button(action: openEditor) { Label("WIO Profile Editor", systemImage: "slider.horizontal.3") }
                    .help("WIO Profile Editor…")
                    .accessibilityIdentifier("openWioEditor")
            }
        }
        .sheet(item: $dm.prompt) { p in
            DevicePromptSheet(prompt: p, deviceName: dm.rows[p.row].name) { dm.answer(p, text: $0) }
        }
        .alert(dm.alert?.title ?? "", isPresented: Binding(get: { dm.alert != nil }, set: { if !$0 { dm.alert = nil } }),
               presenting: dm.alert) { a in
            if let r = a.continueRow {
                Button("Connect Anyway") { dm.continueConnect(dm.rows[r]) }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { a in
            Text(a.message)
        }
        .onAppear { dm.rescanPorts() }   // Refresh ports each time the window opens
    }
}

struct DeviceHeaderRow: View {
    var body: some View {
        HStack(spacing: DMColumns.spacing) {
            Text("#").frame(width: DMColumns.number, alignment: .trailing)
            Text("Name").frame(width: DMColumns.name, alignment: .leading)
            Text("Port").frame(width: DMColumns.port, alignment: .leading)
            Text("Base PTT").lineLimit(1).fixedSize().frame(width: DMColumns.ptt)
            Text("Device Type").frame(width: DMColumns.type, alignment: .leading)
            Text("Subtype").frame(width: DMColumns.subtype, alignment: .leading)
            Text("WIO Addr.").frame(width: DMColumns.wio, alignment: .leading)
            Text("Status").frame(width: DMColumns.status)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

/// The Fixed heading / Clone offset prompt (Cancel leaves the row disconnected).
struct DevicePromptSheet: View {
    let prompt: DeviceManagerModel.Prompt
    let deviceName: String
    let submit: (String) -> String?
    @State private var text = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var message: String {
        prompt.kind == .fixedHeading ? "Enter heading for this fixed antenna:" : "Enter offset for this Cloned antenna (+/- 180.0):"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(deviceName).font(.headline)
            Text(message)
            TextField("", text: $text)
                .frame(width: 240)
                .accessibilityIdentifier("devicePromptField")
                .onSubmit(ok)
            if prompt.kind == .fixedHeading {
                Text("A heading above 360 shows as “---” on clients (no heading).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).accessibilityIdentifier("devicePromptError")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK", action: ok).keyboardShortcut(.defaultAction).accessibilityIdentifier("devicePromptOK")
            }
        }
        .padding(20)
        .onAppear { text = prompt.initial }
    }

    private func ok() {
        if let e = submit(text) { error = e } else { dismiss() }
    }
}
