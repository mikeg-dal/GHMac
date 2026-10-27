import Foundation
import Observation
import GHEKit
import GHEServerKit

/// The Device Manager: 100 slot rows loaded from `DeviceManager.xml`, the port and subtype lists,
/// connect/disconnect with the Fixed/Cloned prompts, and debounced saves.
@Observable
final class DeviceManagerModel {
    /// A pending heading/offset prompt (sheet on the Device Manager window).
    struct Prompt: Identifiable, Equatable {
        enum Kind { case fixedHeading, cloneOffset }
        let row: Int
        let kind: Kind
        let initial: String
        var id: String { "\(row)-\(kind)" }
    }

    struct Alert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// Set for the duplicate-name warning: "Connect Anyway" continues with this row.
        var continueRow: Int?
    }

    private(set) var rows: [DeviceRowModel] = []
    private(set) var portNames: [String] = [DevicePanelConfig.notApplicable]
    private(set) var profileNames: [String] = []
    var hideEmptyRows = false
    var prompt: Prompt?
    var alert: Alert?

    @ObservationIgnored let environment: DeviceEnvironment
    @ObservationIgnored let resolver: ServerPortResolver
    @ObservationIgnored let profileStore: WioProfileStore
    @ObservationIgnored let directories: AppDirectories
    @ObservationIgnored private let log: (String) -> Void
    @ObservationIgnored private var saver: Debouncer!
    @ObservationIgnored private var portMonitor: SerialPortMonitor?
    @ObservationIgnored var requestWindow: (() -> Void)?
    @ObservationIgnored private var loaded = false

    init(environment: DeviceEnvironment, resolver: ServerPortResolver, profileStore: WioProfileStore,
         directories: AppDirectories, log: @escaping (String) -> Void) {
        self.environment = environment
        self.resolver = resolver
        self.profileStore = profileStore
        self.directories = directories
        self.log = log
        saver = Debouncer { [weak self] in self?.saveNow() }
    }

    // MARK: Lists

    /// Subtype menu: built-ins, then every profile `<devicename>` (built-in names win).
    var subtypeNames: [String] {
        WIOSubtypes.builtIn + profileNames.filter { !WIOSubtypes.builtIn.contains($0) }
    }

    var visibleRows: [DeviceRowModel] {
        hideEmptyRows ? rows.filter { !$0.isEmpty || $0.isActive } : rows
    }

    /// Ports for one row: the shared list plus the row's own value if it isn't listed.
    func ports(for row: DeviceRowModel) -> [String] {
        portNames.contains(row.port) || row.port.isEmpty ? portNames : portNames + [row.port]
    }

    // MARK: Load / save

    /// Reads `DeviceManager.xml` (tolerant) and builds the 100 rows.
    func load() async {
        let result = DeviceManagerXML.load(from: directories.file(DeviceManagerXML.fileName))
        for w in result.warnings { log("DeviceManager.xml: \(w)") }
        resolver.update(extraNames: result.referencedPorts)
        if rows.isEmpty {
            rows = result.panels.map { cfg in
                let row = DeviceRowModel(config: cfg, slot: DeviceSlotController(config: cfg, environment: environment))
                wire(row)
                return row
            }
        } else {
            for (row, cfg) in zip(rows, result.panels) {
                row.replace(with: cfg)
                await row.slot.update(config: cfg)
            }
        }
        await reloadProfiles()
        rescanPorts()
        loaded = true
    }

    private func wire(_ row: DeviceRowModel) {
        row.onChange = { [weak self] in self?.scheduleSave() }
        row.onBasePTTChange = { [weak self] r in self?.syncBasePTT(from: r) }
        row.onSlotEvent = { [weak self] r, e in self?.handle(e, for: r) }
    }

    func scheduleSave() {
        guard loaded else { return }
        saver.schedule()
    }

    /// Writes DeviceManager.xml now. `rotornames.ini` is no longer written.
    func saveNow() {
        guard loaded else { return }
        do {
            try DeviceManagerXML.write(rows.map(\.config), to: directories.file(DeviceManagerXML.fileName))
        } catch {
            log("***ERROR*** Could not save DeviceManager.xml: \(error.localizedDescription)")
        }
    }

    func flushSave() { saver.flush() }

    // MARK: Ports and profiles

    /// Refreshes every row's list; ports.ini is re-read too.
    func rescanPorts() {
        resolver.reload(from: directories)
        portNames = resolver.portNames()
    }

    /// Re-enumerates whenever a serial port appears or disappears.
    func startPortMonitor() {
        guard portMonitor == nil else { return }
        let m = SerialPortMonitor { [weak self] in self?.rescanPorts() }
        m.start()
        portMonitor = m
    }

    func reloadProfiles() async {
        let issues = await profileStore.reload()
        for i in issues { log("\(i.isError ? "***ERROR*** " : "")WIO profile \(i.file): \(i.message)") }
        profileNames = await profileStore.profileNames()
    }

    /// Rows driving the same Base port share one Base PTT setting.
    private func syncBasePTT(from source: DeviceRowModel) {
        guard source.usesBase else { return }
        for r in rows where r !== source && r.usesBase && r.port == source.port && r.basePTT != source.basePTT {
            r.basePTT = source.basePTT
        }
    }

    // MARK: Connect / disconnect

    /// The status toggle.
    func toggle(_ row: DeviceRowModel) {
        guard !row.isBusy else { return }
        if row.isActive {
            Task { await disconnect(row) }
            return
        }
        // Warn about duplicate names (clients key devices by name).
        if !row.name.isEmpty,
           rows.contains(where: { $0 !== row && $0.name == row.name && $0.isActive }) {
            alert = Alert(title: "Duplicate Name",
                          message: "Another connected device is already named “\(row.name)”. Clients can’t tell devices with the same name apart.",
                          continueRow: row.order)
            return
        }
        continueConnect(row)
    }

    /// Second half of `toggle`: Fixed/Cloned rows ask for their value first (pre-filled).
    func continueConnect(_ row: DeviceRowModel) {
        switch row.type {
        case .fixedAntenna where !row.name.isEmpty:
            let h = row.fixedHeading.flatMap { $0 == DevicePanelConfig.fixedHeadingUnset ? nil : $0 } ?? 0
            prompt = Prompt(row: row.order, kind: .fixedHeading, initial: JavaDouble.string(h))
        case .clonedAntenna where !row.name.isEmpty:
            let o = row.cloneOffset.flatMap { $0 == DevicePanelConfig.cloneOffsetUnset ? nil : $0 } ?? 0
            prompt = Prompt(row: row.order, kind: .cloneOffset, initial: JavaDouble.string(o))
        default:
            Task { await connect(row, userInitiated: true) }
        }
    }

    /// Validates a prompt answer. Returns an error message, or nil after starting the connect.
    func answer(_ p: Prompt, text: String) -> String? {
        let row = rows[p.row]
        guard let v = JavaDouble.parse(JavaString.trim(text)), v.isFinite else {
            return p.kind == .fixedHeading ? "You must enter a valid heading." : "You must enter a valid OFFSET."
        }
        switch p.kind {
        case .fixedHeading:
            row.fixedHeading = v   // any double; >360 shows "---" on clients
        case .cloneOffset:
            guard (-180...180).contains(v) else { return "You must enter a valid OFFSET." }
            row.cloneOffset = v
        }
        prompt = nil
        Task { await connect(row, userInitiated: true) }
        return nil
    }

    func connect(_ row: DeviceRowModel, userInitiated: Bool) async {
        row.isBusy = true
        defer { row.isBusy = false }
        await row.slot.update(config: row.config)
        await row.slot.connect()
        let status = await row.slot.status
        if case .error(let message) = status {
            log("***ERROR*** \(row.name.isEmpty ? "Row \(row.order + 1)" : row.name): \(message.replacingOccurrences(of: "\n", with: " "))")
            // Configuration errors are shown, not turned into an endless retry.
            let retrying = await row.slot.isRetrying
            if userInitiated && !retrying {
                alert = Alert(title: "Device Error", message: message)
            }
        } else if status != .disconnected {
            row.initialState = true
        }
        scheduleSave()
    }

    func disconnect(_ row: DeviceRowModel) async {
        row.isBusy = true
        defer { row.isBusy = false }
        await row.slot.disconnect()
        row.initialState = false
        scheduleSave()
    }

    /// Auto-connects `initialState` rows in `order` (not document index), one at a time so a
    /// clone finds its source; runs off the main thread inside the slot actors.
    func autoConnect() async {
        for row in rows where row.initialState && !row.isEmpty {
            await connect(row, userInitiated: false)
        }
    }

    /// Closes every device without touching `initialState` (they reconnect on the next launch).
    func closeAll() async {
        await withTaskGroup(of: Void.self) { g in
            for r in rows where r.isActive || r.status.isError {
                let slot = r.slot
                g.addTask { await slot.disconnect() }
            }
        }
    }

    private func handle(_ e: SlotEvent, for row: DeviceRowModel) {
        switch e {
        case .status:
            break
        case .needsFixedHeading:
            // Auto-connect of a Fixed row without a saved heading: ask.
            prompt = Prompt(row: row.order, kind: .fixedHeading, initial: "0.0")
            requestWindow?()
        case .needsCloneOffset:
            prompt = Prompt(row: row.order, kind: .cloneOffset, initial: "0.0")
            requestWindow?()
        }
    }

    /// Names of connected devices and their positions, for the Virtual Positions sheet.
    func connectedDevices() async -> [(name: String, positions: [String])] {
        let inv = await environment.registry.inventory()
        var out: [(String, [String])] = inv.switches.map { ($0.name, $0.positions.map(\.name)) }
        out += inv.rotors.map { ($0, ["#0", "#90", "#180", "#270"]) }
        return out
    }
}
