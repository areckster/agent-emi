import SwiftUI
import AppKit

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragHandleNSView(frame: .zero)
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class DragHandleNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        return self
    }
}

