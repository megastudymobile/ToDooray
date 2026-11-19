import AppKit
import DooraySync
import SwiftUI

enum PanelAction: Equatable {
    case openTask(DoorayTask)
    case openDooray
    case openSettings
    case quit
}

/// The glass panel under the status item: a borderless, non-activating NSPanel hosting
/// `PanelView`. Opening it never activates MegaMind, so the frontmost app keeps its focus.
@MainActor
final class PanelController {
    private let model: AppModel
    /// Asked on every placement and never cached: the status item moves and can get hidden.
    private let anchorWindow: () -> NSWindow?
    private let perform: (PanelAction) -> Void
    private var panel: KeyablePanel?
    private var host: SizeReportingHostingView<PanelView>?
    private var eventMonitors: [Any] = []
    private var observations: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    var onVisibilityChange: ((Bool) -> Void)?

    init(model: AppModel, anchorWindow: @escaping () -> NSWindow?, perform: @escaping (PanelAction) -> Void) {
        self.model = model
        self.anchorWindow = anchorWindow
        self.perform = perform
    }

    var isOpen: Bool { panel?.isVisible == true }
    var windowNumber: Int? { isOpen ? panel?.windowNumber : nil }
    var frame: NSRect? { isOpen ? panel?.frame : nil }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        guard !isOpen else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place()
        panel.orderFrontRegardless()
        // Key without activating the app, so Escape reaches the panel.
        panel.makeKey()
        installDismissal()
        onVisibilityChange?(true)
        model.refresh(.panelOpened)
    }

    func close() {
        guard isOpen else { return }
        panel?.orderOut(nil)
        removeDismissal()
        onVisibilityChange?(false)
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow
        panel.onEscape = { [weak self] in self?.close() }

        let host = SizeReportingHostingView(rootView: PanelView(model: model, perform: perform))
        host.sizingOptions = [.intrinsicContentSize]
        host.onSizeChange = { [weak self] in
            guard let self, self.isOpen else { return }
            self.place()
        }
        panel.contentView = host
        self.host = host
        return panel
    }

    private func place() {
        guard let panel, let host else { return }
        let anchor = anchorWindow()
        guard let screen = anchor?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = PanelPlacement.frame(
            contentSize: host.fittingSize,
            anchor: anchor?.frame,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrame(frame, display: true)
    }

    /// A mouse-down on the status item is left to the item's own action, which toggles the
    /// panel. Closing here as well would let that action reopen the panel at once. Resigning
    /// key is not a trigger for the same reason: it fires for that click too.
    private func installDismissal() {
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown, handler: { [weak self] _ in
            self?.closeUnlessOnStatusItem()
        }) {
            eventMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown, handler: { [weak self] event in
            if let self, event.window !== self.panel {
                self.closeUnlessOnStatusItem()
            }
            return event
        }) {
            eventMonitors.append(monitor)
        }

        let workspace = NSWorkspace.shared.notificationCenter
        close(on: NSWorkspace.activeSpaceDidChangeNotification, from: workspace)
        close(on: NSWorkspace.didActivateApplicationNotification, from: workspace) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            return app?.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        close(on: NSApplication.didChangeScreenParametersNotification, from: .default)
    }

    private func close(
        on name: Notification.Name,
        from center: NotificationCenter,
        when shouldClose: @escaping @Sendable (Notification) -> Bool = { _ in true }
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            guard shouldClose(notification) else { return }
            MainActor.assumeIsolated { self?.close() }
        }
        observations.append((center, token))
    }

    private func closeUnlessOnStatusItem() {
        if let statusItem = anchorWindow(), statusItem.frame.contains(NSEvent.mouseLocation) { return }
        close()
    }

    private func removeDismissal() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors = []
        observations.forEach { $0.center.removeObserver($0.token) }
        observations = []
    }
}

/// A borderless panel refuses key status by default. This one accepts it, and
/// `.nonactivatingPanel` keeps that from activating the app.
final class KeyablePanel: NSPanel {
    private static let escapeKeyCode: UInt16 = 53

    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.escapeKeyCode {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Reports SwiftUI size changes so an open panel can follow its content with its top edge fixed.
final class SizeReportingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        // Resizing the window inside this layout pass would re-enter it.
        DispatchQueue.main.async { [weak self] in
            self?.onSizeChange?()
        }
    }
}
