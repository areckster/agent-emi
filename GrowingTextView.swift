import SwiftUI
import AppKit

struct GrowingTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var maxLines: Int = 6
    var onSend: () -> Void
    var placeholderColor: NSColor = NSColor(srgbRed: 0xA7/255.0, green: 0xAF/255.0, blue: 0xB8/255.0, alpha: 1.0)
    var textColor: NSColor = NSColor(srgbRed: 0xE6/255.0, green: 0xE7/255.0, blue: 0xEA/255.0, alpha: 1.0)
    var bgColor: NSColor = NSColor(srgbRed: 0x15/255.0, green: 0x1A/255.0, blue: 0x20/255.0, alpha: 1.0)
    var onFocusChange: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false

        let tv = KeyHandlingTextView()
        tv.backgroundColor = bgColor
        tv.isRichText = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.font = NSFont.systemFont(ofSize: 14)
        tv.textColor = textColor
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.delegate = context.coordinator
        tv.keyHandler = { event in
            // Cmd/Ctrl+Enter sends
            if (event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)) && event.keyCode == 36 {
                onSend(); return true
            }
            // Enter sends, Shift+Enter inserts newline
            if event.keyCode == 36 { // Return
                if event.modifierFlags.contains(.shift) {
                    return false // allow newline
                } else {
                    onSend(); return true
                }
            }
            return false
        }

        let container = tv.textContainer!
        container.widthTracksTextView = true
        scroll.documentView = tv
        context.coordinator.textView = tv

        // Placeholder label overlay
        let ph = NSTextField(labelWithString: placeholder)
        ph.alphaValue = 0.45
        ph.textColor = placeholderColor
        ph.font = tv.font
        ph.lineBreakMode = .byTruncatingTail
        ph.translatesAutoresizingMaskIntoConstraints = false
        ph.isSelectable = false
        ph.isEditable = false
        ph.isBordered = false
        ph.backgroundColor = bgColor
        ph.isEnabled = false
        ph.refusesFirstResponder = true
        ph.setContentHuggingPriority(.required, for: .horizontal)
        ph.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.addSubview(ph)
        // Ensure clicks on placeholder focus the text view
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.focusTextView))
        ph.addGestureRecognizer(click)
        NSLayoutConstraint.activate([
            ph.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 4),
            ph.topAnchor.constraint(equalTo: tv.topAnchor, constant: tv.textContainerInset.height),
            ph.trailingAnchor.constraint(lessThanOrEqualTo: tv.trailingAnchor, constant: -4)
        ])
        context.coordinator.placeholder = ph
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        if tv.string != text { tv.string = text }
        // Placeholder visibility
        context.coordinator.placeholder?.isHidden = !text.isEmpty

        // Resize height up to max lines
        if let layout = tv.layoutManager, let container = tv.textContainer {
            layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: tv.string.count), actualCharacterRange: nil)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).size
            let defaultLH: CGFloat = {
                if let font = tv.font, let lm = layout as NSLayoutManager? { return lm.defaultLineHeight(for: font) }
                if let font = tv.font { return font.ascender - font.descender + font.leading }
                return 16
            }()
            let maxH = defaultLH * CGFloat(maxLines) + tv.textContainerInset.height * 2
            let target = min(maxH, used.height + tv.textContainerInset.height * 2 + 4)
            context.coordinator.ensureHeightConstraint(on: nsView, height: target)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView
        weak var textView: NSTextView?
        weak var placeholder: NSTextField?
        var heightConstraint: NSLayoutConstraint?
        init(_ parent: GrowingTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let tv = textView { parent.text = tv.string }
            placeholder?.isHidden = !(textView?.string.isEmpty ?? true)
        }
        func textDidBeginEditing(_ notification: Notification) { parent.onFocusChange?(true) }
        func textDidEndEditing(_ notification: Notification) { parent.onFocusChange?(false) }
        func ensureHeightConstraint(on scroll: NSScrollView, height: CGFloat) {
            if heightConstraint == nil {
                heightConstraint = scroll.heightAnchor.constraint(equalToConstant: height)
                heightConstraint?.isActive = true
            }
            if abs((heightConstraint?.constant ?? 0) - height) > 0.5 {
                heightConstraint?.constant = height
            }
        }
        @objc func focusTextView() {
            if let tv = textView { tv.window?.makeFirstResponder(tv) }
        }
    }

    final class KeyHandlingTextView: NSTextView {
        var keyHandler: ((NSEvent) -> Bool)?
        override func keyDown(with event: NSEvent) {
            if keyHandler?(event) == true { return }
            super.keyDown(with: event)
        }
    }
}
