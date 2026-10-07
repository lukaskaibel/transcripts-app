import AppKit
import SwiftUI

/// Named places on screen for the debug remote, so a UI check can click a control by name instead of by
/// coordinates. Only filled while the remote is running.
@MainActor
enum DebugFrames {
    static var isActive = false
    private static var anchors: [String: WeakAnchor] = [:]

    private final class WeakAnchor {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    static func register(_ id: String, _ view: NSView) {
        guard isActive else { return }
        anchors[id] = WeakAnchor(view)
    }

    /// The window and the frame (in window coordinates, origin bottom left) of a named view that is on screen.
    static func locate(_ id: String) -> (window: NSWindow, frame: NSRect)? {
        guard let view = anchors[id]?.view, let window = view.window, window.isVisible else { return nil }
        return (window, view.convert(view.bounds, to: nil))
    }

    static var visibleIds: [String] {
        anchors.compactMap { id, anchor in anchor.view?.window?.isVisible == true ? id : nil }.sorted()
    }
}

extension View {
    /// Registers this view's place for the debug remote ("clickid <id>").
    func debugFrame(_ id: String) -> some View {
        background(DebugFrameAnchor(id: id))
    }
}

private struct DebugFrameAnchor: NSViewRepresentable {
    var id: String

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.id = id
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.id = id
        DebugFrames.register(id, view)
    }

    final class AnchorView: NSView {
        var id = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { MainActor.assumeIsolated { DebugFrames.register(id, self) } }
        }
    }
}
