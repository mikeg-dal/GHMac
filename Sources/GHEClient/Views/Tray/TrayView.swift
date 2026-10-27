import SwiftUI
import AppKit
import GHEClientKit

/// The main window: a menu strip (a menu bar, reachable while the app is inactive) and one
/// row per visible rotor, in Tray order. The window is sized by its content.
struct TrayView: View {
    @Environment(ClientAppModel.self) private var model

    var body: some View {
        let rotors = model.trayRotors
        let size = model.settings.rotorDisplaySize
        VStack(alignment: .leading, spacing: 0) {
            TrayMenuStrip()
                .frame(height: 22)
            Divider()
            if rotors.isEmpty {
                Text(model.connections.supervisors.contains { $0.state == .connected } ? "No rotors for this band" : "No servers connected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("trayEmpty")
            } else {
                ForEach(rotors) { rotor in
                    RotorRowView(rotor: rotor, metrics: .forSize(size))
                    if rotor.key != rotors.last?.key { Divider() }
                }
            }
        }
        .frame(minWidth: 300, alignment: .leading)
        .fixedSize()
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// File / Configuration / Band / Help pull-downs inside the tray window.
struct TrayMenuStrip: NSViewRepresentable {
    @Environment(ClientAppModel.self) private var model

    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        guard let menus = model.windows?.menuController?.trayMenus() else { return stack }
        for (title, make) in menus {
            let b = MenuStripButton(title: title, makeMenu: make)
            stack.addArrangedSubview(b)
        }
        return stack
    }

    func updateNSView(_ nsView: NSStackView, context: Context) {}
}

/// A flat button that drops its menu down, like a menu-bar title.
final class MenuStripButton: NSButton {
    private let makeMenu: () -> NSMenu

    init(title: String, makeMenu: @escaping () -> NSMenu) {
        self.makeMenu = makeMenu
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .recessed
        isBordered = false
        showsBorderOnlyWhileMouseInside = true
        font = .menuFont(ofSize: 13)
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(open)
        setAccessibilityIdentifier("trayMenu.\(title)")
        contentTintColor = .labelColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + 12, height: 20)
    }

    @objc private func open() {
        let m = makeMenu()
        m.delegate?.menuNeedsUpdate?(m)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }
}
