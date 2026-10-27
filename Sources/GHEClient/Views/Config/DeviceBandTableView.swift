import SwiftUI
import GHEKit
import GHEClientKit

/// Tray / Map / Switch band tables. Row 0 "All" toggles a whole column, column "All" a whole row.
struct DeviceBandTableView: View {
    enum Kind { case tray, map, switches }

    @Environment(ClientAppModel.self) private var model
    let kind: Kind
    @State private var error: String?

    private struct Row: Identifiable {
        var key: ItemKey
        var id: ItemKey { key }
    }

    private var rows: [Row] {
        switch kind {
        case .tray, .map: model.connections.rotors.map { Row(key: $0.key) }
        case .switches: (model.connections.switches.map(\.key) + model.connections.tornados.map(\.key)).map { Row(key: $0) }
        }
    }

    private var bands: [String] { model.settings.bandScope.columns.map(\.rawValue) }

    var body: some View {
        _ = model.deviceRevision
        let rows = rows
        let cols = bands
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .center, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text(kind == .switches ? "Switch" : "Rotor").bold().gridColumnAlignment(.leading)
                        Text("All").bold()
                        ForEach(cols, id: \.self) { Text($0).bold() }
                        if kind == .map { Text("Beam").bold() }
                        if kind != .switches { Text("Order").bold() }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    // Row 0: column select-all (state derived from the data).
                    GridRow {
                        Text("All").italic().gridColumnAlignment(.leading)
                        Toggle("", isOn: Binding(get: { !rows.isEmpty && rows.allSatisfy { cols.allSatisfy(has($0.key)) } },
                                                 set: { v in for r in rows { setAll(r.key, v) } }))
                        ForEach(cols, id: \.self) { b in
                            Toggle("", isOn: Binding(get: { !rows.isEmpty && rows.allSatisfy { has($0.key)(b) } },
                                                     set: { v in for r in rows { set(r.key, band: b, v) } }))
                                .accessibilityIdentifier("bandTable.All.\(b)")
                        }
                        // The All row has no editable Order / Beam.
                        if kind == .map { Text("") }
                        if kind != .switches { Text("") }
                    }
                    ForEach(rows) { r in
                        GridRow {
                            Text(r.key.name).gridColumnAlignment(.leading)
                            Toggle("", isOn: Binding(get: { cols.allSatisfy(has(r.key)) }, set: { setAll(r.key, $0) }))
                            ForEach(cols, id: \.self) { b in
                                Toggle("", isOn: Binding(get: { has(r.key)(b) }, set: { set(r.key, band: b, $0) }))
                                    .accessibilityIdentifier("bandTable.\(r.key.name).\(b)")
                            }
                            if kind == .map {
                                IntField(value: model.rotorSettings(r.key).beamWidth) { commitBeam(r.key, $0) }
                            }
                            if kind != .switches {
                                IntField(value: order(r.key)) { commitOrder(r.key, $0) }
                            }
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(10)
            }
            if rows.isEmpty {
                Text(kind == .switches ? "No switches connected." : "No rotors connected.").foregroundStyle(.secondary).padding(.horizontal, 10)
            }
            HStack {
                if let error { Text(error).foregroundStyle(.red) }
                Spacer()
                Button("Close") {
                    let id = kind == .tray ? "trayConfigWindow" : kind == .map ? "mapConfigWindow" : "switchConfigWindow"
                    model.windows?.closeConfig(id)
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .bottom], 10)
        }
        .frame(minWidth: 420, idealWidth: 640, minHeight: 200, idealHeight: 320)
    }

    // MARK: Data

    private func bandsOf(_ key: ItemKey) -> [String] {
        switch kind {
        case .tray: model.rotorSettings(key).trayBands
        case .map: model.rotorSettings(key).mapBands
        case .switches: model.switchSettings(key).bands
        }
    }

    private func has(_ key: ItemKey) -> (String) -> Bool {
        let set = Set(bandsOf(key))
        return { set.contains($0) }
    }

    private func set(_ key: ItemKey, band: String, _ on: Bool) {
        func edit(_ list: inout [String]) {
            if on { if !list.contains(band) { list.append(band) } } else { list.removeAll { $0 == band } }
        }
        switch kind {
        case .tray: model.updateRotorSettings(key) { edit(&$0.trayBands) }
        case .map: model.updateRotorSettings(key) { edit(&$0.mapBands) }
        case .switches: model.updateSwitchSettings(key) { edit(&$0.bands) }
        }
    }

    private func setAll(_ key: ItemKey, _ on: Bool) {
        for b in bands { set(key, band: b, on) }
    }

    private func order(_ key: ItemKey) -> Int {
        kind == .map ? model.rotorSettings(key).mapPriority : model.rotorSettings(key).priority
    }

    /// Order must be unique (also on the map table).
    private func commitOrder(_ key: ItemKey, _ value: Int) {
        let others = model.connections.rotors.filter { $0.key != key }.map { order($0.key) }
        guard !others.contains(value) else {
            error = "Order value must be unique."
            return
        }
        error = nil
        model.updateRotorSettings(key) { if kind == .map { $0.mapPriority = value } else { $0.priority = value } }
    }

    /// Beam width 1…360.
    private func commitBeam(_ key: ItemKey, _ value: Int) {
        guard (1...360).contains(value) else {
            error = "Beam width must be 1 to 360 degrees."
            return
        }
        error = nil
        model.updateRotorSettings(key) { $0.beamWidth = value }
    }
}

/// An integer cell that commits on Return or when it loses focus; invalid text reverts.
struct IntField: View {
    let value: Int
    let commit: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .frame(width: 52)
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { text = String(value) }
            .onChange(of: value) { _, v in if !focused { text = String(v) } }
            .onSubmit(apply)
            .onChange(of: focused) { _, f in if !f { apply() } }
    }

    private func apply() {
        if let v = JavaString.parseInt(JavaString.trim(text)), v != value { commit(v) }
        text = String(value)
    }
}
