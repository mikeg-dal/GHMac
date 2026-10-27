import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GHEKit
import GHEServerKit

/// Opens WIO Profile Editor windows; several may be open at once.
@MainActor
final class WioEditorManager {
    weak var app: ServerAppModel?
    private var controllers: [WioEditorWindowController] = []

    /// The editor in front, for File menu commands.
    var keyEditor: WioEditorWindowController? {
        controllers.first { $0.window?.isKeyWindow == true } ?? controllers.first { $0.window?.isMainWindow == true }
    }

    @discardableResult
    func openNew() -> WioEditorWindowController {
        let c = WioEditorWindowController(manager: self)
        controllers.append(c)
        if let last = controllers.dropLast().last?.window, let w = c.window {
            w.setFrameTopLeftPoint(w.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        }
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        return c
    }

    func didClose(_ c: WioEditorWindowController) {
        controllers.removeAll { $0 === c }
    }

    var profileStore: WioProfileStore? { app?.deviceManager.profileStore }
    var profileNames: [String] { app?.deviceManager.profileNames ?? [] }

    func profilesChanged() async { await app?.deviceManager.reloadProfiles() }

    func connectedDevices() async -> [(name: String, positions: [String])] {
        await app?.deviceManager.connectedDevices() ?? []
    }
}

/// One editor window: AppKit owns the window so closing can ask about unsaved changes.
@MainActor
final class WioEditorWindowController: NSWindowController, NSWindowDelegate {
    let model = WioEditorModel()
    private unowned let manager: WioEditorManager
    private var allowClose = false

    init(manager: WioEditorManager) {
        self.manager = manager
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("wioEditor")
        window.setAccessibilityIdentifier("wioEditor")
        window.minSize = NSSize(width: 900, height: 420)
        window.center()
        super.init(window: window)
        window.delegate = self
        let actions = WioEditorActions(
            save: { [weak self] in Task { await self?.save() } },
            saveAs: { [weak self] in Task { await self?.saveAs() } },
            open: { [weak self] in Task { await self?.openWithPanel() } },
            openProfile: { [weak self] name in Task { await self?.openProfile(named: name) } },
            revert: { [weak self] in self?.revert() },
            close: { [weak self] in self?.window?.performClose(nil) },
            profileNames: { [weak manager] in manager?.profileNames ?? [] },
            connectedDevices: { [weak manager] in await manager?.connectedDevices() ?? [] })
        window.contentViewController = NSHostingController(rootView: WioEditorView(model: model, actions: actions))
        window.setContentSize(NSSize(width: 1060, height: 720))
        observeTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Keeps the window title and the edited dot in sync with the document.
    private func observeTitle() {
        withObservationTracking {
            window?.title = model.title
            window?.isDocumentEdited = model.isDirty
            window?.representedURL = model.fileURL
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeTitle() }
        }
    }

    // MARK: Close

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose || !model.isDirty { return true }
        Task { await confirmClose() }
        return false
    }

    private func confirmClose() async {
        guard let window else { return }
        let a = NSAlert()
        a.messageText = "Do you wish to save this profile before closing?"
        a.informativeText = "Your changes will be lost if you don’t save them."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Don’t Save")
        switch await a.beginSheetModal(for: window) {
        case .alertFirstButtonReturn:
            // The window stays open if the save didn't happen.
            guard await save() else { return }
        case .alertThirdButtonReturn:
            break
        default:
            return
        }
        allowClose = true
        window.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        manager.didClose(self)
        if model.savedThisSession {
            let a = NSAlert()
            a.messageText = "WIO Profile Editor"
            a.informativeText = "You will need to disconnect and reconnect any devices you have changed during this editing session."
            a.runModal()
        }
    }

    // MARK: Save

    @discardableResult
    func save() async -> Bool {
        guard let url = model.fileURL else { return await saveAs() }
        return await write(to: url)
    }

    @discardableResult
    func saveAs() async -> Bool {
        guard let window, let profile = validProfile() else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        if let dir = await manager.profileStore?.directory { panel.directoryURL = model.fileURL?.deletingLastPathComponent() ?? dir }
        panel.nameFieldStringValue = model.fileURL?.lastPathComponent ?? "\(profile.name).xml"
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return false }
        return await write(to: url)
    }

    private func validProfile() -> WioProfile? {
        switch model.makeProfile() {
        case .success(let p): return p
        case .failure(let problems):
            show("The profile can’t be saved.", problems.messages.joined(separator: "\n"))
            return nil
        }
    }

    private func write(to url: URL) async -> Bool {
        guard let profile = validProfile() else { return false }
        do {
            // UTF-8 bytes, matching the XML declaration.
            try WioProfileXML.write(profile, to: url)
        } catch {
            show("The profile couldn’t be saved.", error.localizedDescription)
            return false
        }
        model.didSave(to: url)
        await manager.profilesChanged()
        return true
    }

    // MARK: Open

    private func confirmDiscard() async -> Bool {
        guard model.isDirty, let window else { return true }
        let a = NSAlert()
        a.messageText = "Would you like to save your changes?"
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Don’t Save")
        switch await a.beginSheetModal(for: window) {
        case .alertFirstButtonReturn: return await save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func openWithPanel() async {
        guard await confirmDiscard(), let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.directoryURL = await manager.profileStore?.directory
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
        load(url)
    }

    func openProfile(named name: String) async {
        guard await confirmDiscard(), let url = await manager.profileStore?.fileURL(forProfile: name) else { return }
        load(url)
    }

    /// A bad file is reported, never half-loaded.
    private func load(_ url: URL) {
        let r = WioProfileXML.load(from: url)
        guard let p = r.profile else {
            show("“\(url.lastPathComponent)” isn’t a valid WIO profile.", r.errors.joined(separator: "\n"))
            return
        }
        model.load(p, from: url)
        if !r.warnings.isEmpty { show("The profile was opened with warnings.", r.warnings.joined(separator: "\n")) }
    }

    /// Revert only exists when there is a file to revert to.
    func revert() {
        guard let url = model.fileURL else { return }
        load(url)
    }

    private func show(_ message: String, _ info: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        if let window { a.beginSheetModal(for: window) } else { a.runModal() }
    }
}

/// What the SwiftUI editor view can ask its window controller to do.
struct WioEditorActions {
    var save: () -> Void
    var saveAs: () -> Void
    var open: () -> Void
    var openProfile: (String) -> Void
    var revert: () -> Void
    var close: () -> Void
    var profileNames: () -> [String]
    var connectedDevices: () async -> [(name: String, positions: [String])]
}
