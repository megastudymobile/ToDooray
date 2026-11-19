import AppKit
import SwiftUI

final class StatusPanelController: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?

    override init() {
        super.init()
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.title = " B " + FakeData.menuBarTitle
        button.target = self
        button.action = #selector(toggle)
    }

    var statusFrame: NSRect { item.button?.window?.frame ?? .zero }
    var panelWindowNumber: Int? { panel?.isVisible == true ? panel?.windowNumber : nil }

    @objc func toggle() {
        if panel?.isVisible == true { close() } else { open() }
    }

    func open() {
        guard let buttonWindow = item.button?.window else { return }
        guard let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let host = NSHostingView(rootView: PanelContent(chrome: .custom))
        let size = host.fittingSize
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = host

        let anchor = buttonWindow.frame
        let bounds = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, bounds.minX + 8), bounds.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()

        DispatchQueue.main.async { self.item.button?.highlight(true) }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        panel?.orderOut(nil)
        item.button?.highlight(false)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}
