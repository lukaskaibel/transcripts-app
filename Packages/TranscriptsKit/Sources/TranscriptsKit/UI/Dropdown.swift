import AppKit
import SwiftUI

/// A Linear-style dropdown: a floating panel without an arrow that opens right under what was clicked,
/// takes the keyboard straight away, and closes when you pick, press Escape or click elsewhere.
/// Taken from Issues for GitHub, so both apps open their pickers the same way.
/// A dropdown opened from inside another one stacks on top of it, such as a status picker for one row of the
/// sub-issue list; closing it hands the keyboard back to the one underneath.
@MainActor
enum Dropdown {
    /// Open dropdowns, the first opened from a window and each further one from the one before.
    private static var panels: [DropdownPanel] = []

    static var isOpen: Bool { !panels.isEmpty }

    #if DEBUG
    /// Set by the debug remote to follow what dropdowns do.
    static var trace: ((String) -> Void)?
    #else
    static let trace: ((String) -> Void)? = nil
    #endif

    /// Opens a dropdown under `rect`, given in `view`'s coordinates. From a view inside an open dropdown it
    /// opens on top of that one; from anywhere else it replaces whatever is open.
    @discardableResult
    static func show<Content: View>(
        below rect: NSRect, in view: NSView, model: AppModel, onClose: @escaping () -> Void = {},
        @ViewBuilder content: (_ close: @escaping () -> Void) -> Content
    ) -> DropdownPanel? {
        // Never from a window that is going away: a dropdown closing redraws its content one last time, and a
        // picker it asked for then would be attached to a window being released (a crash in AppKit).
        guard let window = view.window, window.isVisible else { return nil }
        if let host = window as? DropdownPanel {
            guard let index = panels.firstIndex(where: { $0 === host }) else { return nil }
            close(from: index + 1)
        } else {
            close()
        }
        let handle = PanelHandle()
        let close: () -> Void = { if let panel = handle.panel { Dropdown.close(panel) } }
        let root = content(close)
            .environment(model)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.popover))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.popoverBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .fixedSize()
        let hosting = ResizingHostingView(rootView: root)
        let size = hosting.fittingSize

        // Under the anchor, left edges aligned; above it when there's no room below.
        let anchor = window.convertToScreen(view.convert(rect, to: nil))
        let screen = window.screen?.visibleFrame ?? .infinite
        var origin = NSPoint(x: anchor.minX - 4, y: anchor.minY - 4 - size.height)
        if origin.y < screen.minY { origin.y = anchor.maxY + 4 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)

        let panel = DropdownPanel(contentRect: NSRect(origin: origin, size: size))
        handle.panel = panel
        let opensUpward = origin.y > anchor.minY
        hosting.onFittingSizeChange = { [weak panel] fitting in
            guard let panel, fitting.height > 0 else { return }
            var frame = panel.frame
            // Keep the edge next to what was clicked where it is.
            if !opensUpward { frame.origin.y = frame.maxY - fitting.height }
            frame.size = fitting
            panel.setFrame(frame, display: true)
        }
        panel.contentView = hosting
        panel.appearance = window.effectiveAppearance
        panel.onClose = onClose
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panels.append(panel)
        trace?("show: \(panels.count) open, nested=\(window is DropdownPanel)")
        return panel
    }

    /// Closes every open dropdown.
    static func close() {
        close(from: 0)
    }

    /// Closes this dropdown and any opened from it.
    static func close(_ panel: DropdownPanel) {
        if let index = panels.firstIndex(where: { $0 === panel }) { close(from: index) }
    }

    private static func close(from index: Int) {
        guard panels.indices.contains(index) else { return }
        trace?("close from \(index) of \(panels.count)")
        let closing = panels[index...].reversed()
        let underneath = panels[index].parent
        panels.removeSubrange(index...)
        for panel in closing {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.onClose()
        }
        // Back to what the dropdown was opened from, so its keys work again.
        if let underneath, underneath.isVisible { underneath.makeKey() }
    }

    fileprivate static func panelDidResignKey(_ resigned: DropdownPanel) {
        // The new key window is known only once AppKit has finished switching.
        DispatchQueue.main.async {
            guard let index = panels.firstIndex(where: { $0 === resigned }) else { return }
            let key = NSApp.keyWindow
            trace?("resigned \(index); key is \(key.map { String(describing: type(of: $0)) } ?? "nil") at \(panels.firstIndex(where: { $0 === key }).map(String.init) ?? "-")")
            if let keyIndex = panels.firstIndex(where: { $0 === key }) {
                // A click back in a dropdown further down closes the ones on top of it.
                if keyIndex < index { close(from: keyIndex + 1) }
            } else {
                // A click anywhere else closes them all, as a menu would.
                close()
            }
        }
    }
}

private final class PanelHandle {
    weak var panel: DropdownPanel?
}

/// A hosting view that reports when its content wants a different size.
final class ResizingHostingView<Content: View>: NSHostingView<Content> {
    var onFittingSizeChange: ((NSSize) -> Void)?
    private var lastSize: NSSize = .zero

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        let size = fittingSize
        guard size != lastSize else { return }
        lastSize = size
        DispatchQueue.main.async { [weak self] in self?.onFittingSizeChange?(size) }
    }
}

final class DropdownPanel: NSPanel {
    var onClose: () -> Void = {}

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Clicking anywhere else closes it, as a menu would.
    override func resignKey() {
        super.resignKey()
        MainActor.assumeIsolated { Dropdown.panelDidResignKey(self) }
    }

    /// Escape, when nothing inside handled it.
    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { Dropdown.close(self) }
    }
}

// MARK: - SwiftUI

extension View {
    /// Shows a dropdown under this view while `isPresented` is true.
    func dropdown<Content: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping (_ close: @escaping () -> Void) -> Content
    ) -> some View {
        modifier(DropdownModifier(isPresented: isPresented, dropdownContent: content))
    }
}

private struct DropdownModifier<DropdownContent: View>: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    var dropdownContent: (_ close: @escaping () -> Void) -> DropdownContent

    func body(content: Content) -> some View {
        content.background(
            DropdownAnchor(isPresented: $isPresented, model: model, content: dropdownContent)
        )
    }
}

private struct DropdownAnchor<DropdownContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    var model: AppModel
    var content: (_ close: @escaping () -> Void) -> DropdownContent

    func makeNSView(context: Context) -> PassthroughView { PassthroughView() }

    func updateNSView(_ view: PassthroughView, context: Context) {
        if isPresented, !view.isShowing {
            Dropdown.trace?("anchor wants to show: window=\(view.window.map { String(describing: type(of: $0)) } ?? "nil") visible=\(view.window?.isVisible ?? false) content=\(String(describing: DropdownContent.self).prefix(60))")
            view.isShowing = true
            let binding = $isPresented
            view.panel = Dropdown.show(below: view.bounds, in: view, model: model, onClose: { [weak view] in
                view?.isShowing = false
                binding.wrappedValue = false
            }, content: content)
            if view.panel == nil {
                // Nothing could open (the window is gone): put the state back, so the next click works.
                view.isShowing = false
                DispatchQueue.main.async { binding.wrappedValue = false }
            }
        } else if !isPresented, view.isShowing, let panel = view.panel {
            Dropdown.close(panel)
        }
    }
}

/// A view that is never the target of a click, for anchoring and measuring.
final class PassthroughView: NSView {
    var isShowing = false
    weak var panel: DropdownPanel?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
