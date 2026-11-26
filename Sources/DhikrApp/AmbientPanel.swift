import AppKit
import SwiftUI

/// The ambient dropdown panel: anchored beneath the menu bar item like a menu
/// (same vibrancy material, grows open from its top edge). It gets out of the
/// way on its own — clicking anywhere outside closes it, and after a session
/// starts it fades away automatically. The menu bar title (live count) is the
/// always-on ambient display; the panel is just the transient control surface.
@MainActor
final class AmbientPanel {

    private var panel: NSPanel?
    private let width: CGFloat = 300
    /// screen rect of the status item at show time — clicks there are the
    /// toggle itself, handled by the button action, not by dismissal
    private var statusItemRect: NSRect?
    private var clickMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    var isShowing: Bool { panel?.isVisible ?? false }

    /// space key counts — forwarded from the panel's keyDown
    var onSpace: (() -> Void)?

    func toggle<Content: View>(below statusItem: NSStatusItem?, content: Content) {
        if isShowing { close(); return }
        show(below: statusItem, content: content)
    }

    func show<Content: View>(below statusItem: NSStatusItem?, content: Content) {
        statusItemRect = nil
        if let button = statusItem?.button, let window = button.window {
            statusItemRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        removeDismissalHooks()
        let hosting = NSHostingView(rootView: content)

        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onEscape = { [weak self] in self?.close() }
        panel.onSpace = { [weak self] in self?.onSpace?() }

        // vibrancy card matching menu material, rounded corners
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
        panel.contentView = effect

        // size to fit content
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let height = max(fitting.height, 100)
        panel.setContentSize(NSSize(width: width, height: height))

        // anchor beneath the status item, menu-style: right-aligned to the item's right edge
        var origin = NSPoint(x: 0, y: 0)
        if let button = statusItem?.button, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            origin = NSPoint(x: rect.maxX - width, y: rect.minY - height - 4)
        } else if let screen = NSScreen.main {
            origin = NSPoint(x: screen.frame.maxX - width - 20, y: screen.frame.maxY - height - 30)
        }
        panel.setFrameOrigin(origin)

        self.panel?.orderOut(nil)
        self.panel = panel
        NSApp.activate()  // so Space and Esc reach the popup (bismillah pattern)
        panel.makeKeyAndOrderFront(nil)
        growOpen(panel)
        installDismissalHooks()
    }

    // MARK: - dismissal: get out of the way

    /// outside clicks close the panel — the standard menu bar popup contract.
    /// The status item rect is excluded: that click is the toggle itself.
    private func installDismissalHooks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closeIfOutsideMouse() }
        }
        guard let panel else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: nil
        ) { [weak self] _ in
            // only close when the app actually deactivates — during menu tracking
            // (device picker) the app stays active, so this never fires mid-menu
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if !panel.isKeyWindow && !NSApp.isActive { self.close() }
            }
        }
    }

    private func removeDismissalHooks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
    }

    private func closeIfOutsideMouse() {
        guard let panel, panel.isVisible else { return }
        let point = NSEvent.mouseLocation
        if panel.frame.contains(point) { return }
        if let rect = statusItemRect, rect.insetBy(dx: -4, dy: -4).contains(point) { return }
        close()
    }

    /// live-resize when content height changes (picker ↔ session layouts differ)
    func resize<Content: View>(content: Content) {
        guard let panel, let effect = panel.contentView else { return }
        // content is re-rendered by SwiftUI; just re-fit height if needed
        effect.layoutSubtreeIfNeeded()
    }

    func close() {
        removeDismissalHooks()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
            panel?.alphaValue = 1
        })
    }

    private func growOpen(_ panel: NSPanel) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = panel.contentView?.layer else { return }
        let top = layer.bounds.maxY
        var grow = CATransform3DMakeTranslation(0, top, 0)
        grow = CATransform3DScale(grow, 0.92, 0.92, 1)
        grow = CATransform3DTranslate(grow, 0, -top, 0)
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = grow
        anim.toValue = CATransform3DIdentity
        anim.duration = 0.18
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "openGrow")
    }
}

/// borderless panel that still receives key events (space counts, esc closes)
private final class KeyPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onSpace: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // esc
            onEscape?()
            return
        }
        if event.keyCode == 49 {  // space
            onSpace?()
            return
        }
        super.keyDown(with: event)
    }
}
