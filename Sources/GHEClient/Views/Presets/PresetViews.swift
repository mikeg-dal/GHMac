import SwiftUI
import GHEKit
import GHEClientKit

/// Preset buttons window: a 4×4 grid, the rotor name (or "All"), Close and
/// "Keep visible". Global frame turns every active, visible rotor.
struct PresetPanelView: View {
    enum Target: Equatable { case rotor(ItemKey), global }

    @Environment(ClientAppModel.self) private var model
    let target: Target
    let frameName: String

    private static let fontSizes = [10, 14, 18, 22, 26, 30, 34, 38, 42]

    var body: some View {
        let presets = Array(model.presets.prefix(RotorPresets.maxCount))
        let keep = model.presetKeepVisible[frameName] ?? false
        VStack(spacing: 4) {
            if presets.isEmpty {
                Text("No presets.\nUse Configuration ▸ Edit Presets…")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 4), spacing: 1) {
                    ForEach(Array(presets.enumerated()), id: \.offset) { i, p in
                        Button { click(p) } label: {
                            Text(p.name)
                                .font(.system(size: CGFloat(model.settings.presetFontSize), weight: .bold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.4)
                                .frame(maxWidth: .infinity, minHeight: 40, maxHeight: .infinity)
                        }
                        .disabled(rotor.map { !$0.canTurn } ?? false)
                        .accessibilityIdentifier("preset.\(title).\(i)")
                    }
                }
                .frame(maxHeight: .infinity)
            }
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(Color(red: 0, green: 1, blue: 1))
                .foregroundStyle(.black)
            HStack {
                Button("Close") { close() }
                    .disabled(keep)
                Toggle("Keep visible", isOn: Binding(get: { keep }, set: { model.presetKeepVisible[frameName] = $0 }))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("presetKeepVisible")
            }
        }
        .padding(6)
        .frame(minWidth: 240, minHeight: 160)
        // A native context menu.
        .contextMenu {
            Picker("Change the Presets Text Size", selection: Binding(get: { model.settings.presetFontSize },
                                                                      set: { model.settings.presetFontSize = $0 })) {
                ForEach(Self.fontSizes, id: \.self) { Text("\($0)").tag($0) }
            }
        }
        .accessibilityIdentifier("presetPanel.\(title)")
    }

    private var rotor: RotorItem? {
        if case .rotor(let key) = target { return model.connections.rotor(key) }
        return nil
    }

    private var title: String {
        switch target {
        case .global: "All"
        case .rotor(let key): key.name
        }
    }

    private func click(_ p: RotorPreset) {
        switch target {
        case .global:
            // Every active, visible rotor; the global frame never hides.
            model.turnActiveRotors(to: p.heading)
        case .rotor:
            guard let r = rotor, let h = p.headingValue else { return }
            model.turn(r, to: h)
            if model.presetKeepVisible[frameName] != true { close() }
        }
    }

    private func close() {
        if target == .global { model.settings.globalPresetsVisible = false } else { model.windows?.hidePresets(frameName: frameName) }
    }
}

/// Configuration ▸ Edit Presets… ("Preset Locations"): 16 name / heading rows.
/// Rows with a bad heading (not a number, outside 0–360) are reported instead of dropped.
struct PresetsEditorView: View {
    @Environment(ClientAppModel.self) private var model
    @State private var rows: [RotorPreset] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Name:").bold()
                    Text("Heading (deg):").bold()
                }
                ForEach(rows.indices, id: \.self) { i in
                    GridRow {
                        TextField("", text: $rows[i].name)
                            .frame(width: 180)
                            .accessibilityIdentifier("presetName.\(i)")
                        TextField("", text: $rows[i].heading)
                            .frame(width: 90)
                            .foregroundStyle(isBad(rows[i]) ? .red : .primary)
                            .accessibilityIdentifier("presetHeading.\(i)")
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { model.windows?.closeConfig("presetsEditorWindow") }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { save() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("presetsOK")
            }
        }
        .padding(14)
        .onAppear {
            var r = model.presets
            while r.count < RotorPresets.maxCount { r.append(RotorPreset(name: "", heading: "")) }
            rows = r
        }
    }

    private func isBad(_ p: RotorPreset) -> Bool {
        if p.name.isEmpty && p.heading.isEmpty { return false }
        if p.name.isEmpty { return true }
        guard let v = JavaDouble.parse(JavaString.trim(p.heading)) else { return true }
        return !(0...360).contains(v)
    }

    private func save() {
        let bad = rows.enumerated().filter { isBad($0.element) }.map { $0.offset + 1 }
        guard bad.isEmpty else {
            error = "Row \(bad.map(String.init).joined(separator: ", ")): each preset needs a name and a heading from 0 to 360."
            return
        }
        model.savePresets(rows.map { RotorPreset(name: $0.name, heading: JavaString.trim($0.heading)) })
        model.windows?.closeConfig("presetsEditorWindow")
    }
}
