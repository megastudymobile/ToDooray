import AppKit
import DooraySync

/// The app target is one line: `MegaMind.run()`.
public enum MegaMind {
    /// Plain AppKit lifecycle. A SwiftUI `MenuBarExtra` cannot be opened or closed from code.
    @MainActor
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?
    private var panel: PanelController?
    private var settingsWindow: SettingsWindowController?
    #if DEBUG
    private var console: DebugConsole?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()

        let model = AppModel(store: SettingsStore(), clock: Self.clock())
        let settingsWindow = SettingsWindowController(model: model)
        let statusItem = StatusItemController(model: model) { [weak self] in
            self?.panel?.toggle()
        }
        let panel = PanelController(
            model: model,
            anchorWindow: { [weak statusItem] in statusItem?.anchorWindow },
            perform: { [weak self] in self?.perform($0) }
        )
        panel.onVisibilityChange = { [weak statusItem] in statusItem?.setHighlighted($0) }

        self.model = model
        self.settingsWindow = settingsWindow
        self.statusItem = statusItem
        self.panel = panel
        model.start()

        #if DEBUG
        if DebugConsole.isEnabled {
            let console = DebugConsole(model: model, statusItem: statusItem, panel: panel, settingsWindow: settingsWindow)
            console.start()
            self.console = console
            return
        }
        #endif
        // On first run the menu bar item may be hidden, so the user is not left to find it.
        if model.state == .needsSetup {
            settingsWindow.show()
        }
    }

    private func perform(_ action: PanelAction) {
        panel?.close()
        switch action {
        case .openTask(let task):
            if let url = model?.webURL(for: task) { NSWorkspace.shared.open(url) }
        case .openDooray:
            if let url = model?.settings.webBase { NSWorkspace.shared.open(url) }
        case .openSettings:
            settingsWindow?.show()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    private static func clock() -> () -> Date {
        #if DEBUG
        if let text = ProcessInfo.processInfo.environment["MEGAMIND_NOW"],
           let frozen = try? Date.ISO8601FormatStyle().parse(text) {
            return { frozen }
        }
        #endif
        return Date.init
    }

    /// An accessory app never shows this menu, but without it ⌘V, ⌘C and ⌘W do nothing in
    /// the settings window.
    private static func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "MegaMind 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: "윈도우")
        windowMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }
}
