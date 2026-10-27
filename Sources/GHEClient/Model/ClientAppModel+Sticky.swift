import Foundation
import GHEKit
import GHEClientKit

/// The hidden "Sticky Port": a serial port whose CTS/DSR lines drive PTT LOCK bank positions and
/// make map switches jump to their sticky position. Only present when `w2fu.txt` exists.
extension ClientAppModel {
    var isStickyEnabled: Bool { FileManager.default.fileExists(atPath: directories.file("w2fu.txt").path) }

    func setSticky(_ key: ItemKey, position: String?) { stickyPositions[key] = position }

    /// Opens the port (not persisted) and follows its modem lines.
    func startStickyPort(path: String?) {
        stickyTask?.cancel()
        let old = stickyMonitor
        stickyMonitor = nil
        Task { await old?.stop() }
        stickyPortPath = path
        guard let path else { return }
        let port = POSIXSerialTransport(path: path)
        let monitor = ModemLineMonitor(port: port)
        stickyMonitor = monitor
        stickyTask = Task {
            do { _ = try await port.open() } catch {
                self.logSoftware("Sticky Port: cannot open \(path): \(error.localizedDescription)")
                return
            }
            for await event in await monitor.start() { self.handleSticky(event) }
            await port.close()
        }
    }

    private func handleSticky(_ event: StickyEvent) {
        switch event {
        case .pttLock(let on):
            for sw in connections.switches where sw.isBank && isSwitchVisible(sw.key) {
                for p in sw.positionNames where p.uppercased().contains("PTT LOCK") {
                    connections.setSwitch(sw, position: p, on: on)
                }
            }
        case .jumpToSticky:
            for (key, pos) in stickyPositions {
                if let sw = connections.switchItem(key), isSwitchVisible(key) { selectSwitch(sw, position: pos) }
            }
        case .failed(let message):
            logSoftware("Sticky Port: \(message)")
        }
    }
}
