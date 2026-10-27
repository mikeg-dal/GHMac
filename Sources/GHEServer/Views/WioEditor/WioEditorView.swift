import SwiftUI
import GHEKit
import GHEServerKit

/// Column widths of the position grid (shared by the header and the rows).
enum WioColumns {
    static let virtual: CGFloat = 30
    static let name: CGFloat = 170
    static let bidirectional: CGFloat = 46
    static let degrees: CGFloat = 58
    static let beamwidth: CGFloat = 66
    static let output: CGFloat = 46
    static let freq: CGFloat = 72
    static let spacing: CGFloat = 6
}

/// The WIO Profile Editor: header fields, display type, the 28-row position grid and the
/// Save / Close bar.
struct WioEditorView: View {
    @Bindable var model: WioEditorModel
    let actions: WioEditorActions
    @State private var virtualRow: VirtualRowRef?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 4) {
                    columnHeader
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(model.rows.indices, id: \.self) { i in
                            WioPositionRowView(model: model, index: i) { virtualRow = VirtualRowRef(index: i) }
                        }
                    }
                    Button("Add Rows") { model.addRows() }
                        .controlSize(.small)
                        .padding(.top, 6)
                        .accessibilityIdentifier("wioAddRows")
                }
                .padding(12)
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 880, minHeight: 400)
        .sheet(item: $virtualRow) { ref in
            VirtualPositionsSheet(positionName: JavaString.trim(model.rows[ref.index].name),
                                  entries: model.rows[ref.index].virtualEntries,
                                  loadDevices: actions.connectedDevices) { newEntries in
                model.rows[ref.index].virtualEntries = newEntries
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Device Type:")
                    TextField("Subtype name", text: $model.deviceType)
                        .frame(width: 220)
                        .accessibilityIdentifier("wioDeviceType")
                }
                Toggle("Matrix Lockout", isOn: $model.matrixLockout)
                    .disabled(!model.matrixLockoutEnabled)
                    .accessibilityIdentifier("wioMatrixLockout")
                Toggle("Virtual Switch", isOn: $model.virtualSwitch)
                    .disabled(!model.virtualEnabled)
                    .accessibilityIdentifier("wioVirtualSwitch")
            }
            Spacer()
            GroupBox("Display Type") {
                Picker("Display Type", selection: $model.displayType) {
                    Text("Buttons").tag(SwitchDisplayType.buttons)
                    Text("Map").tag(SwitchDisplayType.map)
                    Text("Band Switch").tag(SwitchDisplayType.band)
                    // On/Off banks can't be virtual switches.
                    Text("On/Off Bank").tag(SwitchDisplayType.bank).selectionDisabled(model.virtualSwitch)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                .padding(6)
                .accessibilityIdentifier("wioDisplayType")
            }
            .fixedSize()
        }
    }

    private var columnHeader: some View {
        HStack(alignment: .bottom, spacing: WioColumns.spacing) {
            Text(model.virtualSwitch ? "Virtual" : "")
                .frame(width: WioColumns.virtual)
            Text("Name of Setting").frame(width: WioColumns.name, alignment: .leading)
            Text("Bidir.").frame(width: WioColumns.bidirectional).help("Bidirectional")
            Text("Degrees").frame(width: WioColumns.degrees)
            Text("Beamwidth").frame(width: WioColumns.beamwidth)
            VStack(spacing: 2) {
                Text("Outputs")
                HStack(spacing: WioColumns.spacing) {
                    ForEach(1...8, id: \.self) { Text("\($0)").frame(width: WioColumns.output) }
                }
            }
            VStack(spacing: 2) {
                Text("Freq. (MHz)")
                HStack(spacing: WioColumns.spacing) {
                    Text("Lower").frame(width: WioColumns.freq)
                    Text("Upper").frame(width: WioColumns.freq)
                }
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Menu("Open Profile") {
                let names = actions.profileNames()
                if names.isEmpty { Text("No saved profiles") }
                ForEach(names, id: \.self) { n in Button(n) { actions.openProfile(n) } }
                Divider()
                Button("Open File…") { actions.open() }
            }
            .fixedSize()
            .accessibilityIdentifier("wioOpenProfile")
            if model.isDirty {
                Text("Edited — save to keep your changes")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .accessibilityIdentifier("wioDirty")
            } else if model.fileURL != nil {
                Text("Saved").foregroundStyle(.secondary).font(.callout).accessibilityIdentifier("wioSaved")
            }
            Spacer()
            Button("Revert") { actions.revert() }
                .disabled(!model.isDirty || model.fileURL == nil)
            Button("Save As…") { actions.saveAs() }
            Button("Save") { actions.save() }
                .accessibilityIdentifier("wioSave")
            Button("Close") { actions.close() }
        }
    }
}

struct VirtualRowRef: Identifiable {
    let index: Int
    var id: Int { index }
}
