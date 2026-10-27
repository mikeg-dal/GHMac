import SwiftUI
import GHEKit
import GHEClientKit

/// Hotkeys ▸ View All HotKeys… (HotKeyDialog): Rotors / Switches / Stack Match, leaves "<cmd|pos> (<key>)".
struct HotkeysView: View {
    @Environment(ClientAppModel.self) private var model

    private struct Leaf: Identifiable, Hashable {
        var target: HotkeyTarget
        var key: KeyName
        var text: String
        var failure: String?
        var id: String { "\(key.legacyString)|\(text)|\(target)" }
    }

    private struct Group: Identifiable {
        var title: String
        var panels: [(String, [Leaf])]
        var id: String { title }
    }

    private var groups: [Group] {
        _ = model.hotkeyRevision
        var rotors: [String: [Leaf]] = [:], switches: [String: [Leaf]] = [:], stacks: [String: [Leaf]] = [:]
        let b = model.hotkeys.bindings
        for k in b.keys {
            let failure = model.hotkeys.failures[k].map { $0.errorDescription ?? "unsupported" }
            for t in b.targets(for: k) {
                switch t {
                case .rotor(let panel, _, let cmd):
                    rotors[Self.short(panel), default: []].append(Leaf(target: t, key: k, text: "\(cmd.rawValue) (\(k.legacyString))", failure: failure))
                case .switchPosition(let panel, _, let pos):
                    switches[Self.short(panel), default: []].append(Leaf(target: t, key: k, text: "\(pos) (\(k.legacyString))", failure: failure))
                case .stack(let name):
                    stacks[name, default: []].append(Leaf(target: t, key: k, text: "\(name) (\(k.legacyString))", failure: failure))
                }
            }
        }
        func sorted(_ d: [String: [Leaf]]) -> [(String, [Leaf])] { d.keys.sorted().map { ($0, d[$0]!) } }
        return [Group(title: "Rotors", panels: sorted(rotors)), Group(title: "Switches", panels: sorted(switches)),
                Group(title: "Stack Match", panels: sorted(stacks))]
    }

    static func short(_ legacyKey: String) -> String {
        legacyKey.split(separator: "\u{1E}", maxSplits: 1).first.map(String.init) ?? legacyKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                Section("Global Hotkeys") {
                    ForEach(groups) { g in
                        DisclosureGroup(g.title) {
                            if g.panels.isEmpty { Text("None").foregroundStyle(.secondary) }
                            ForEach(g.panels, id: \.0) { panel, leaves in
                                DisclosureGroup(panel) {
                                    ForEach(leaves) { leaf in
                                        HStack {
                                            Text(leaf.text)
                                            if let f = leaf.failure {
                                                Text("unsupported on this Mac").foregroundStyle(.red).font(.caption).help(f)
                                            }
                                            Spacer()
                                            Button("Remove") {
                                                model.hotkeys.unbind(leaf.target)
                                                model.saveHotkeys()
                                            }
                                            .buttonStyle(.link)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("hotkeysTree")
            if model.isSimulator {
                Text("Simulator: hotkeys are recorded but not registered with macOS.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Close") { model.windows?.closeConfig("hotkeysWindow") }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(10)
        .frame(minWidth: 380, minHeight: 320)
    }
}

/// Configuration ▸ RSSI Test Window ("Device RSSI Test").
struct RSSITestView: View {
    @Environment(ClientAppModel.self) private var model
    @State private var showAll = false
    @State private var clearedAt = Date.distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(alignment: .leading, spacing: 4) {
                        // "Clear" empties the list; it refills with the next readings.
                        if ctx.date.timeIntervalSince(clearedAt) > 1 {
                            ForEach(model.connections.rssiEntries(showAll: showAll)) { e in
                                Text(e.line).font(.system(size: 24, weight: .bold, design: .rounded))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            HStack {
                Toggle("Show All", isOn: $showAll).toggleStyle(.checkbox)
                Spacer()
                Button("Clear") { clearedAt = Date() }
            }
        }
        .padding(10)
        .frame(minWidth: 420, minHeight: 260)
    }
}

/// Window ▸ Traffic Log: what the client sends and receives (Mac addition for diagnostics).
struct TrafficLogView: View {
    @Environment(ClientAppModel.self) private var model
    @State private var lines: [String] = []

    var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                            Text(l).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: lines.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
            }
            HStack {
                Spacer()
                Button("Clear") { lines.removeAll() }
            }
        }
        .padding(10)
        .frame(minWidth: 520, minHeight: 300)
        .task {
            let time = Date.FormatStyle(date: .omitted, time: .standard)
            for await e in model.connections.traffic.subscribe() {
                let dir = switch e.direction { case .incoming: "<-"; case .outgoing: "->"; case .note: "--" }
                lines.append("\(Date().formatted(time)) \(e.server) \(dir) \(e.text)")
                if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
            }
        }
    }
}

/// Hidden "Sticky Port" (CommPortDialog): pick the serial port whose modem lines are watched.
struct StickyPortView: View {
    @Environment(ClientAppModel.self) private var model
    @State private var ports: [SerialPortInfo] = []
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select 'Sticky' Port")
            Picker("", selection: $selection) {
                Text("None").tag(String?.none)
                ForEach(ports) { Text($0.displayName).tag(Optional($0.path)) }
            }
            .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel") { model.windows?.closeConfig("stickyPortWindow") }
                Button("OK") {
                    model.startStickyPort(path: selection)
                    model.windows?.closeConfig("stickyPortWindow")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            ports = SerialPortEnumerator.ports()
            selection = model.stickyPortPath
        }
    }
}
