import AppKit
import SwiftUI

/// An editable `NSComboBox`, bound to text.
struct ComboBox: NSViewRepresentable {
    @Binding var text: String
    var items: [String]
    var placeholder = ""
    var identifier: String?

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.usesDataSource = false
        box.completes = true
        box.isEditable = true
        box.numberOfVisibleItems = 12
        box.placeholderString = placeholder
        box.delegate = context.coordinator
        box.target = context.coordinator
        box.action = #selector(Coordinator.selectionChanged(_:))
        if let identifier { box.setAccessibilityIdentifier(identifier) }
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if box.objectValues as? [String] != items {
            box.removeAllItems()
            box.addItems(withObjectValues: items)
        }
        if box.stringValue != text { box.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ComboBox
        init(_ p: ComboBox) { parent = p }

        @objc func selectionChanged(_ sender: NSComboBox) { parent.text = sender.stringValue }

        func controlTextDidChange(_ obj: Notification) {
            if let box = obj.object as? NSComboBox { parent.text = box.stringValue }
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox, box.indexOfSelectedItem >= 0,
                  let v = box.itemObjectValue(at: box.indexOfSelectedItem) as? String else { return }
            parent.text = v
        }
    }
}
