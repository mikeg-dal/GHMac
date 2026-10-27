import AppKit
import SwiftUI

/// The black/yellow log: an `NSTextView` for speed, appended incrementally,
/// wrapping long lines and following the end while the user is scrolled to the bottom.
struct ServerLogView: NSViewRepresentable {
    let log: LogBuffer
    /// Passed in so SwiftUI re-runs `updateNSView` when lines arrive.
    let revision: Int

    static let textColor = NSColor(srgbRed: 1, green: 1, blue: 102 / 255, alpha: 1)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = true
        tv.backgroundColor = .black
        tv.textColor = Self.textColor
        tv.font = context.coordinator.font
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.textContainer?.widthTracksTextView = true
        tv.setAccessibilityIdentifier("serverLog")
        tv.setAccessibilityLabel("Server log")
        context.coordinator.textView = tv
        context.coordinator.sync(log)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.sync(log)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        private var lastSequence = 0
        private var lineLengths: [Int] = []
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        private var attributes: [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: ServerLogView.textColor]
        }

        func sync(_ log: LogBuffer) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let (lines, gap) = log.entries(after: lastSequence)
            guard !lines.isEmpty || gap else { return }
            let atBottom = isScrolledToBottom(tv)
            storage.beginEditing()
            if gap {
                storage.setAttributedString(NSAttributedString())
                lineLengths.removeAll()
            }
            for l in lines {
                let s = l.text + "\n"
                storage.append(NSAttributedString(string: s, attributes: attributes))
                lineLengths.append((s as NSString).length)
            }
            // Ring buffer: drop the oldest lines instead of clearing everything.
            let excess = lineLengths.count - log.capacity
            if excess > 0 {
                let len = lineLengths.prefix(excess).reduce(0, +)
                storage.deleteCharacters(in: NSRange(location: 0, length: len))
                lineLengths.removeFirst(excess)
            }
            storage.endEditing()
            lastSequence = log.lastSequence
            if atBottom { tv.scrollToEndOfDocument(nil) }
        }

        private func isScrolledToBottom(_ tv: NSTextView) -> Bool {
            guard let clip = tv.enclosingScrollView?.contentView else { return true }
            return clip.bounds.maxY >= tv.bounds.maxY - 20
        }
    }
}
