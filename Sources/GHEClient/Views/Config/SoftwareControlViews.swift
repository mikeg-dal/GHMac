import SwiftUI
import GHEKit
import GHEClientKit

/// Each dialog loads the current settings when it opens.
/// Cancel discards everything.

/// N1MM Configuration.
struct N1MMConfigView: View {
    @Environment(ClientAppModel.self) private var model
    @State private var radio = ""
    @State private var rotor = ""
    @State private var vfo = 1
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("UDP Port") {
                Grid(alignment: .leading) {
                    GridRow { Text("Radio:"); TextField("", text: $radio).frame(width: 80).accessibilityIdentifier("n1mmRadioPort") }
                    GridRow { Text("Rotor:"); TextField("", text: $rotor).frame(width: 80).accessibilityIdentifier("n1mmRotorPort") }
                }
                .padding(4)
            }
            GroupBox("Display Rotors/Switches From:") {
                Picker("", selection: $vfo) {
                    Text("Both Radios/VFOs (SO2R/V)").tag(3)
                    Text("VFO-A/Radio 1 Only").tag(1)
                    Text("VFO-B/Radio 2 Only").tag(2)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ConfigButtons(error: error, close: "n1mmWindow", ok: save)
        }
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .frame(width: 320)
        .onAppear {
            let c = model.settings.n1mm
            radio = String(c.radioPort); rotor = String(c.rotorPort); vfo = c.selectedVFO
        }
    }

    private func save() -> Bool {
        guard let r = UInt16(JavaString.trim(radio)), r > 0, let t = UInt16(JavaString.trim(rotor)), t > 0 else {
            error = "Port must be integer"
            return false
        }
        model.settings.n1mm = N1MMConfig(radioPort: r, rotorPort: t, selectedVFO: vfo)
        return true
    }
}

/// N3FJP Configuration. OK restarts the monitor with the new address and port.
struct N3FJPConfigView: View {
    @Environment(ClientAppModel.self) private var model
    @State private var host = ""
    @State private var port = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading) {
                GridRow { Text("IP Address"); TextField("", text: $host).frame(width: 140) }
                GridRow { Text("TCP Port"); TextField("", text: $port).frame(width: 80) }
            }
            ConfigButtons(error: error, close: "n3fjpWindow", ok: save)
        }
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .frame(width: 300)
        .onAppear {
            host = model.settings.n3fjp.host
            port = String(model.settings.n3fjp.port)
        }
    }

    private func save() -> Bool {
        guard let p = UInt16(JavaString.trim(port)), p > 0 else { error = "Port must be integer"; return false }
        let h = JavaString.trim(host)
        guard !h.isEmpty, !h.contains(" ") else { error = "Could not resolve IP address"; return false }
        model.settings.n3fjp = N3FJPConfig(host: h, port: p)
        return true
    }
}

/// Win-Test Configuration. The labels describe the old bind addresses for file compatibility; the Mac
/// always binds the wildcard so broadcasts arrive, and "loopback" accepts only local senders.
struct WinTestConfigView: View {
    enum BindChoice: Hashable { case network, loopback, custom }

    @Environment(ClientAppModel.self) private var model
    @State private var port = ""
    @State private var bind = BindChoice.network
    @State private var customIP = ""
    @State private var stationOn = false
    @State private var station = ""
    @State private var radio = 0
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("UDP Port:"); TextField("", text: $port).frame(width: 80) }
            Picker("", selection: $bind) {
                Text("Wintest is broadcasting to local network (192.x.x.255)").tag(BindChoice.network)
                Text("Wintest is broadcasting to loopback (127.255.255.255)").tag(BindChoice.loopback)
                Text("Use custom binding address:").tag(BindChoice.custom)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            TextField("", text: $customIP).frame(width: 160).disabled(bind != .custom).padding(.leading, 20)
            HStack {
                Toggle("Only listen for station name:", isOn: $stationOn).toggleStyle(.checkbox)
                TextField("", text: $station).frame(width: 120).disabled(!stationOn)
            }
            GroupBox("Display Rotors/Switches From:") {
                Picker("", selection: $radio) {
                    Text("Active Radio").tag(0)
                    Text("Radio 1 only").tag(1)
                    Text("Radio 2 only").tag(2)
                    Text("Both Radios (SO2R)").tag(3)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ConfigButtons(error: error, close: "wintestWindow", ok: save)
        }
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .frame(width: 440)
        .onAppear {
            let c = model.settings.winTest
            port = String(c.port)
            customIP = model.settings.winTestCustomIPAddress
            switch c.bind {
            case .network: bind = .network
            case .loopback: bind = .loopback
            case .custom(let ip): bind = .custom; customIP = ip
            }
            stationOn = c.filter.stationFilterEnabled
            station = c.filter.stationName
            radio = c.filter.selectedRadio
        }
    }

    private func save() -> Bool {
        guard let p = UInt16(JavaString.trim(port)), p > 0 else { error = "Port must be integer"; return false }
        var c = model.settings.winTest
        c.port = p
        switch bind {
        case .network: c.bind = .network
        case .loopback: c.bind = .loopback
        case .custom: c.bind = .custom(JavaString.trim(customIP))
        }
        c.filter = WinTestFilter(selectedRadio: radio, stationFilterEnabled: stationOn, stationName: station)
        model.settings.winTestCustomIPAddress = JavaString.trim(customIP)
        model.settings.winTest = c
        return true
    }
}

/// OK / Cancel row shared by the three dialogs.
private struct ConfigButtons: View {
    @Environment(ClientAppModel.self) private var model
    let error: String?
    let close: String
    let ok: () -> Bool

    var body: some View {
        HStack {
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            Spacer()
            Button("Cancel") { model.windows?.closeConfig(close) }.keyboardShortcut(.cancelAction)
            Button("OK") { if ok() { model.windows?.closeConfig(close) } }.keyboardShortcut(.defaultAction)
        }
    }
}

/// Software Control ▸ Test communication… Clear clears, Close closes.
struct SoftwareTestView: View {
    @Environment(ClientAppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.softwareLog.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: model.softwareLog.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
            }
            HStack {
                Text("Mode: \(model.settings.loggerSource.rawValue.uppercased())   Band A: \(model.bands.a)   Band B: \(model.bands.b)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.softwareLog.removeAll() }
                Button("Close") { model.windows?.closeConfig("softwareTestWindow") }
            }
        }
        .padding(10)
        .frame(minWidth: 460, minHeight: 260)
    }
}
