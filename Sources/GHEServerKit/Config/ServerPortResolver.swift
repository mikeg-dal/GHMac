import Foundation
import GHEKit
import Synchronization

/// The server's port list and name → endpoint resolution.
///
/// List order: "N/A", enumerated `/dev/cu.*`, ports.ini keys, extra names (e.g. ports referenced in
/// DeviceManager.xml so a saved selection stays visible), simulated ports. Duplicates are dropped.
public final class ServerPortResolver: PortResolver {
    private struct State: Sendable {
        var ports: PortsIni
        var extraNames: [String]
        var simulated: [(name: String, id: String)]
    }

    private let state: Mutex<State>
    private let serialPorts: @Sendable () -> [String]

    /// - Parameters:
    ///   - simulated: port name → simulated device id (`Endpoint.simulated`).
    ///   - serialPorts: enumerated callout paths; defaults to IOKit enumeration.
    public init(ports: PortsIni = PortsIni(), extraNames: [String] = [], simulated: [(name: String, id: String)] = [],
                serialPorts: @escaping @Sendable () -> [String] = { SerialPortEnumerator.ports().map(\.path) }) {
        state = Mutex(State(ports: ports, extraNames: extraNames, simulated: simulated))
        self.serialPorts = serialPorts
    }

    public func update(ports: PortsIni) { state.withLock { $0.ports = ports } }
    public func update(extraNames: [String]) { state.withLock { $0.extraNames = extraNames } }
    public func update(simulated: [(name: String, id: String)]) { state.withLock { $0.simulated = simulated } }
    public var ports: PortsIni { state.withLock { $0.ports } }

    /// Re-reads ports.ini from the server folder.
    public func reload(from dirs: AppDirectories) { update(ports: PortsIni.load(from: dirs)) }

    public func portNames() -> [String] {
        let s = state.withLock { $0 }
        var out: [String] = [DevicePanelConfig.notApplicable]
        var seen: Set<String> = [DevicePanelConfig.notApplicable]
        for n in serialPorts() + s.ports.portNames + s.extraNames + s.simulated.map(\.name)
        where !n.isEmpty && seen.insert(n).inserted {
            out.append(n)
        }
        return out
    }

    /// `*` characters are stripped first. Resolution order: simulated port,
    /// ports.ini `host:port` value (TCP), ports.ini `/dev/...` value, a `/dev/` path, then the short
    /// name of an enumerated port (`usbserial-A1` or `cu.usbserial-A1`). `COMn` names and
    /// plain ports.ini keys can't be opened on the Mac and give nil.
    public func endpoint(for portName: String, settings: SerialSettings) -> Endpoint? {
        let name = JavaString.trim(portName.replacingOccurrences(of: "*", with: ""))
        guard !name.isEmpty, name != DevicePanelConfig.notApplicable else { return nil }
        let s = state.withLock { $0 }
        if let sim = s.simulated.first(where: { $0.name == name }) { return .simulated(id: sim.id) }
        if let t = s.ports.tcpTarget(for: name) { return .tcp(host: t.host, port: t.port) }
        if let path = s.ports.serialAlias(for: name) { return .serial(path: path, settings) }
        if name.hasPrefix("/dev/") { return .serial(path: name, settings) }
        for path in serialPorts() {
            let short = path.replacingOccurrences(of: "/dev/", with: "")
            if short == name || short.replacingOccurrences(of: "cu.", with: "") == name {
                return .serial(path: path, settings)
            }
        }
        return nil
    }
}
