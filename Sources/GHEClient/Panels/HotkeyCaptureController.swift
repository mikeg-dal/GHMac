import AppKit
import SwiftUI
import GHEClientKit

/// "Press key for <panel> Action: <cmd> (Press Escape to cancel)".
/// The app is activated while capturing and a local key monitor reads the key; global hotkeys are
/// suspended meanwhile. Losing focus cancels.
@MainActor
final class HotkeyCaptureController: NSObject, NSWindowDelegate {
    private static var current: HotkeyCaptureController?

    private let model: ClientAppModel
    private let bind: (KeyName) -> String?
    private let window: NSPanel
    private let message = CaptureMessage()
    private var monitor: Any?

    /// `bind` returns an error message (shown in the window) or nil when the key was taken.
    static func capture(model: ClientAppModel, panel: String, action: String, bind: @escaping (KeyName) -> String?) {
        current?.finish()
        let c = HotkeyCaptureController(model: model, panel: panel, action: action, bind: bind)
        current = c
        c.start()
    }

    private init(model: ClientAppModel, panel: String, action: String, bind: @escaping (KeyName) -> String?) {
        self.model = model
        self.bind = bind
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 130), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        super.init()
        window.title = "Assign Hotkey"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setAccessibilityIdentifier("hotkeyCaptureWindow")
        window.identifier = NSUserInterfaceItemIdentifier("hotkeyCaptureWindow")
        let msg = message
        window.contentView = NSHostingView(rootView: CaptureView(panel: panel, action: action, message: msg) { [weak self] in
            self?.finish()
        })
        window.delegate = self
    }

    private func start() {
        model.hotkeys.suspend()
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue))
        guard let key = KeyName(keyCode: event.keyCode, cgFlags: flags) else {
            message.text = "That key can't be used as a hotkey on this Mac."
            return
        }
        switch HotkeyRegistration.evaluate(key) {
        case .cancel:
            finish()
        case .invalid(let k):
            message.text = "\(k.legacyString) \(HotkeyRegistration.invalidMessage)"
        case .accept(let k):
            model.hotkeys.resume()
            if let error = bind(k) {
                model.hotkeys.suspend()
                message.text = error
            } else {
                finish()
            }
        }
    }

    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if model.hotkeys.isSuspended { model.hotkeys.resume() }
        window.delegate = nil
        window.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    func windowDidResignKey(_ notification: Notification) { finish() }
    func windowWillClose(_ notification: Notification) { finish() }
}

@MainActor @Observable
private final class CaptureMessage { var text = "" }

private struct CaptureView: View {
    let panel: String
    let action: String
    let message: CaptureMessage
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("Press key for \(panel) Action: \(action)").font(.headline)
            Text("(Press Escape to cancel)").foregroundStyle(.secondary)
            if !message.text.isEmpty {
                Text(message.text).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        }
        .padding(16)
        .frame(width: 360)
    }
}
