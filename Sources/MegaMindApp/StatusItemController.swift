import AppKit

/// Owns the NSStatusItem. It renders `StatusTitle.make(state, now)` in the widest form that
/// keeps the item on screen.
@MainActor
final class StatusItemController: NSObject {
    private static let probeDelay: Duration = .milliseconds(500)
    private static let retryInterval: TimeInterval = 30 * 60

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let onClick: () -> Void
    private var title: StatusTitle?
    private var ladder = TitleLadder()
    private var lastRetry = Date()
    private var probe: Task<Void, Never>?

    /// Called after the shown form or its visibility may have changed.
    var onChange: (() -> Void)?

    init(model: AppModel, onClick: @escaping () -> Void) {
        self.model = model
        self.onClick = onClick
        super.init()

        item.autosaveName = "MegaMind.status"
        // Without `.removalAllowed`, dragging the item out of the menu bar cannot strand the app.
        item.behavior = []
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        rerunOnChange { [weak self] in self?.render() }

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryWiderForms() }
        }
        if let window = item.button?.window {
            for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleProbe() }
                }
            }
        }
    }

    var form: TitleLadder.Form { ladder.form }

    enum Placement {
        /// The menu bar has not laid the item out yet.
        case pending
        case onScreen
        /// macOS hid the item because the menu bar has no room for it.
        case hidden
    }

    /// A hidden item keeps its window, but the window reports no screen and a frame outside
    /// every screen.
    var placement: Placement {
        guard let window = item.button?.window, !window.frame.isEmpty else { return .pending }
        let visible = window.screen != nil && NSScreen.screens.contains { $0.frame.intersects(window.frame) }
        return visible ? .onScreen : .hidden
    }

    /// The window the panel hangs from, or nil while the item is hidden.
    var anchorWindow: NSWindow? {
        placement == .onScreen ? item.button?.window : nil
    }

    func setHighlighted(_ highlighted: Bool) {
        // AppKit resets the highlight when the click that opened the panel ends.
        DispatchQueue.main.async { [weak self] in
            self?.item.button?.highlight(highlighted)
        }
    }

    @objc private func clicked() {
        onClick()
    }

    private func render() {
        let newTitle = StatusTitle.make(state: model.state, now: model.now, calendar: .current)
        let retry = Date().timeIntervalSince(lastRetry) >= Self.retryInterval
        guard newTitle != title || retry else { return }
        title = newTitle
        ladder.titleChanged(fullWidth: width(of: newTitle.full))
        if retry {
            retryWiderForms()
        } else {
            apply()
        }
    }

    private func retryWiderForms() {
        lastRetry = Date()
        ladder.environmentChanged()
        apply()
    }

    private func apply() {
        guard let button = item.button, let title else { return }
        let image = NSImage(systemSymbolName: symbolName(title.symbol), accessibilityDescription: "MegaMind")
        image?.isTemplate = true
        button.image = image
        let text = switch ladder.form {
        case .full: title.full
        case .compact: title.compact
        case .iconOnly: ""
        }
        button.title = text.isEmpty ? "" : " " + text
        scheduleProbe()
        onChange?()
    }

    /// The menu bar lays out asynchronously, so visibility is read a moment after each change.
    private func scheduleProbe() {
        probe?.cancel()
        probe = Task { [weak self] in
            try? await Task.sleep(for: Self.probeDelay)
            guard let self, !Task.isCancelled else { return }
            switch self.placement {
            case .pending:
                self.scheduleProbe()
            case .onScreen:
                self.onChange?()
            case .hidden:
                let before = self.ladder.form
                self.ladder.itemWasHidden()
                if self.ladder.form != before {
                    self.apply()
                }
            }
        }
    }

    private func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.menuBarFont(ofSize: 0)]).width
    }

    private func symbolName(_ symbol: StatusSymbol) -> String {
        switch symbol {
        case .normal: "checklist"
        case .allDone: "checklist.checked"
        case .attention: "exclamationmark.circle"
        }
    }
}
