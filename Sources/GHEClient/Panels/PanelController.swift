import AppKit
import SwiftUI

/// Hosting view that takes the first click, so a button on an inactive panel works at once.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Panel that can become key (text fields, keyboard) without activating the app.
final class GHEPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One window. Operating windows (tray, map, switches, presets) are non-activating panels so a click
/// never takes focus from the logging program. Config windows are ordinary windows.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    enum Kind { case operatingPanel, configWindow }

    let window: NSWindow
    let id: String
    /// Whether the window is resizable when unlocked.
    let baseResizable: Bool
    /// Return false to keep the window open (e.g. the tray asks to quit instead).
    var shouldClose: (() -> Bool)?
    var didClose: (() -> Void)?
    /// Called after the user moves or resizes the window.
    var frameChanged: ((NSRect) -> Void)?
    private var isLocked = false
    /// Content-sized windows keep their top-left corner when SwiftUI resizes them (AppKit keeps the bottom-left).
    private var topLeftAnchor: NSPoint?

    init<Content: View>(id: String, title: String, kind: Kind, resizable: Bool,
                        contentSizedToFit: Bool = true, @ViewBuilder content: () -> Content) {
        self.id = id
        baseResizable = resizable
        var style: NSWindow.StyleMask = [.titled, .closable]
        if resizable { style.insert(.resizable) }
        let w: NSWindow
        switch kind {
        case .operatingPanel:
            style.insert(.nonactivatingPanel)
            style.insert(.miniaturizable)
            let p = GHEPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: style, backing: .buffered, defer: false)
            p.isFloatingPanel = false
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = false
            w = p
        case .configWindow:
            style.insert(.miniaturizable)
            w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: style, backing: .buffered, defer: false)
        }
        window = w
        super.init()
        w.title = title
        w.isReleasedWhenClosed = false
        w.identifier = NSUserInterfaceItemIdentifier(id)
        w.setAccessibilityIdentifier(id)
        w.collectionBehavior.insert(.fullScreenAuxiliary)
        w.tabbingMode = .disallowed
        let host = FirstMouseHostingView(rootView: content())
        if !contentSizedToFit { host.sizingOptions = [.minSize] }
        w.contentView = host
        w.delegate = self
    }

    func show(activate: Bool = false) {
        if activate { NSApp.activate() }
        if activate { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
    }

    func hide() { window.orderOut(nil) }

    var isVisible: Bool { window.isVisible }

    func setFloating(_ on: Bool) { window.level = on ? .floating : .normal }

    /// File ▸ Lock Window Positions: no moving or resizing.
    func setLocked(_ locked: Bool) {
        isLocked = locked
        window.isMovable = !locked
        if baseResizable {
            if locked { window.styleMask.remove(.resizable) } else { window.styleMask.insert(.resizable) }
        }
    }

    /// File ▸ Reset Window Positions: top-left of the main screen, size kept.
    func moveToOrigin() {
        guard let screen = NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        topLeftAnchor = NSPoint(x: vf.minX, y: vf.maxY)
        window.setFrameTopLeftPoint(NSPoint(x: vf.minX, y: vf.maxY))
    }

    /// Places the window from a top-left-origin position; nil sizes keep the current size.
    func setJavaFrame(x: Int, y: Int, width: Int? = nil, height: Int? = nil) {
        if let width, let height, baseResizable {
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: max(width, 120), height: max(height, 80))), display: false)
        }
        var tl = NSPoint(x: CGFloat(x), y: JavaScreen.primaryHeight - CGFloat(y))
        if let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(tl) }) ?? NSScreen.screens.first {
            let vf = screen.visibleFrame
            tl.y = min(tl.y, vf.maxY)
            tl.x = min(max(tl.x, vf.minX), vf.maxX - 60)
            tl.y = max(tl.y, vf.minY + 60)
        }
        window.setFrameTopLeftPoint(tl)
        topLeftAnchor = tl
    }

    /// Resizes the window to the SwiftUI content's fitting size (keeping the top-left corner).
    func fitToContent(growOnly: Bool = false, minimum: NSSize = .zero) {
        guard let fit = window.contentView?.fittingSize, fit.width > 0, fit.height > 0 else { return }
        var size = NSSize(width: max(fit.width, minimum.width), height: max(fit.height, minimum.height))
        if growOnly {
            let cur = window.contentLayoutRect.size
            size = NSSize(width: max(cur.width, size.width), height: max(cur.height, size.height))
        }
        let top = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(size)
        window.setFrameTopLeftPoint(top)
        topLeftAnchor = top
    }

    var javaFrame: (x: Int, y: Int, width: Int, height: Int) { JavaScreen.javaFrame(window.frame) }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose?() ?? true }
    func windowWillClose(_ notification: Notification) { didClose?() }
    func windowDidMove(_ notification: Notification) {
        topLeftAnchor = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        frameChanged?(window.frame)
    }

    func windowDidResize(_ notification: Notification) {
        guard !window.inLiveResize, let a = topLeftAnchor, NSPoint(x: window.frame.minX, y: window.frame.maxY) != a else { return }
        window.setFrameTopLeftPoint(a)
    }
    func windowDidEndLiveResize(_ notification: Notification) { frameChanged?(window.frame) }
}

/// Screen coordinates with the origin at the top-left of the primary screen.
enum JavaScreen {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 900 }

    static func cocoaOrigin(x: Int, y: Int, height: CGFloat) -> NSPoint {
        NSPoint(x: CGFloat(x), y: primaryHeight - CGFloat(y) - height)
    }

    static func javaFrame(_ f: NSRect) -> (x: Int, y: Int, width: Int, height: Int) {
        (Int(f.minX.rounded()), Int((primaryHeight - f.maxY).rounded()), Int(f.width.rounded()), Int(f.height.rounded()))
    }
}

/// Re-runs `apply` whenever an observable value read by `read` changes (until cancelled).
@MainActor
final class ObservationLoop {
    private var cancelled = false
    private let read: @MainActor () -> Void
    private let apply: @MainActor () -> Void

    init<T: Equatable>(_ read: @escaping @MainActor () -> T, apply: @escaping @MainActor (T) -> Void) {
        let box = LastValue<T>()
        self.read = { box.next = read() }
        self.apply = {
            guard let v = box.next, box.value != v else { return }
            box.value = v
            apply(v)
        }
        track()
    }

    private func track() {
        guard !cancelled else { return }
        withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        apply()
    }

    func cancel() { cancelled = true }

    private final class LastValue<T> { var value: T?; var next: T? }
}
