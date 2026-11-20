#if DEBUG
import AppKit
import DooraySync

/// Makes the real app scriptable in Debug builds. It is compiled out of Release.
///
/// Enabled with `TODOORAY_CONSOLE=1` when the binary inside the bundle is run from a shell.
/// One command per stdin line, one JSON object per stdout line:
///
///     state            {"type":"state", ...}
///     open             {"type":"panel","open":true,"windowNumber":123,"frame":[x,y,w,h]}
///     close            {"type":"panel","open":false}
///     refresh          {"type":"ok"}, then state lines as the sync proceeds
///     settings         {"type":"window","name":"settings","windowNumber":456,"frame":[x,y,w,h]}
///     now <ISO 8601>   {"type":"ok"}, and the render clock is frozen there
///     filter <json>    {"type":"ok"}, and the task filter is set; `filter null` clears it
///     choices          {"type":"choices","projects":[…]}, the settings list with each project's milestone load
///     milestones <id>  {"type":"milestones", ...} once the project's milestone load settles
///     quit             the process exits
///
/// A state line is also printed whenever the app state or the menu bar form changes, so a
/// driver waits for `"kind":"loaded"` instead of sleeping. `windowNumber` works with
/// `screencapture -l`. Closing stdin quits the app.
///
/// Two more Debug-only variables make a run hermetic. `TODOORAY_CONFIG=<file>` reads
/// `{"apiBase": …, "webBase": …, "token": …, "filter": …}` into memory in place of the
/// Keychain and UserDefaults. `filter` is optional and takes the same JSON as the command. `TODOORAY_NOW=<ISO 8601>` freezes the clock from launch.
@MainActor
final class DebugConsole {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TODOORAY_CONSOLE"] == "1"
    }

    private let model: AppModel
    private let statusItem: StatusItemController
    private let panel: PanelController
    private let settingsWindow: SettingsWindowController

    init(model: AppModel, statusItem: StatusItemController, panel: PanelController, settingsWindow: SettingsWindowController) {
        self.model = model
        self.statusItem = statusItem
        self.panel = panel
        self.settingsWindow = settingsWindow
    }

    func start() {
        Task { [weak self] in
            do {
                for try await line in FileHandle.standardInput.bytes.lines {
                    self?.handle(line)
                }
            } catch {}
            NSApp.terminate(nil)
        }
        rerunOnChange { [weak self] in self?.emitState() }
        statusItem.onChange = { [weak self] in self?.emitState() }
    }

    private func handle(_ line: String) {
        let words = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch words.first {
        case "state":
            emitState()
        case "open":
            panel.open()
            emit(PanelEvent(panel))
        case "close":
            panel.close()
            emit(PanelEvent(panel))
        case "refresh":
            model.refresh(.manual)
            emit(Reply(type: "ok"))
        case "settings":
            settingsWindow.show()
            emit(WindowEvent(name: "settings", window: settingsWindow.visibleWindow))
        case "now":
            guard words.count == 2, let date = try? Date.ISO8601FormatStyle().parse(words[1]) else {
                emit(Reply(type: "error", message: "usage: now <ISO 8601>"))
                return
            }
            model.freezeClock(at: date)
            emit(Reply(type: "ok"))
        case "filter":
            let json = words.count == 2 ? words[1] : ""
            guard let filter = json == "null" ? .showAll : try? JSONDecoder().decode(TaskFilter.self, from: Data(json.utf8)) else {
                emit(Reply(type: "error", message: "usage: filter <TaskFilter JSON> | filter null"))
                return
            }
            model.setFilter(filter)
            emit(Reply(type: "ok"))
        case "choices":
            emit(ChoicesEvent(model: model))
        case "milestones":
            guard words.count == 2 else {
                emit(Reply(type: "error", message: "usage: milestones <projectId>"))
                return
            }
            let projectID = words[1]
            let load = model.loadMilestones(of: projectID)
            Task { [weak self] in
                await load.value
                guard let self else { return }
                self.emit(MilestonesEvent(projectID: projectID, load: self.model.milestoneLoads[projectID]))
            }
        case "quit":
            NSApp.terminate(nil)
        default:
            emit(Reply(type: "error", message: "unknown command"))
        }
    }

    private func emitState() {
        emit(DebugState(model: model, statusItem: statusItem, panel: panel))
    }

    private func emit(_ value: some Encodable) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(value) else { return }
        line.append(0x0A)
        FileHandle.standardOutput.write(line)
    }
}

private struct Reply: Encodable {
    let type: String
    var message: String?
}

private struct WindowEvent: Encodable {
    let type = "window"
    let name: String
    let windowNumber: Int?
    let frame: [Double]?

    @MainActor
    init(name: String, window: NSWindow?) {
        self.name = name
        windowNumber = window?.windowNumber
        frame = window.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] }
    }
}

private struct LoadState: Encodable {
    /// `loading`, `loaded`, `failed`, or nil when nothing was asked.
    let state: String?
    let error: String?

    init(_ load: AppModel.MilestoneLoad?) {
        switch load {
        case .loading: (state, error) = ("loading", nil)
        case .loaded: (state, error) = ("loaded", nil)
        case .failed(let failure): (state, error) = ("failed", failure.name)
        case nil: (state, error) = (nil, nil)
        }
    }
}

private struct ChoicesEvent: Encodable {
    struct Project: Encodable {
        let id: String
        let code: String
        let taskCount: Int
        let milestoneLoad: LoadState
        let milestones: [Item]
    }

    struct Item: Encodable {
        /// nil is "단계 없음".
        let id: String?
        let name: String
        let taskCount: Int
    }

    let type = "choices"
    let projects: [Project]

    @MainActor
    init(model: AppModel) {
        projects = model.filterChoices.map { project in
            Project(
                id: project.id,
                code: project.code,
                taskCount: project.taskCount,
                milestoneLoad: LoadState(model.milestoneLoads[project.id]),
                milestones: project.milestones.map { Item(id: $0.milestone?.id, name: $0.name, taskCount: $0.taskCount) }
            )
        }
    }
}

private struct MilestonesEvent: Encodable {
    struct Item: Encodable {
        let id: String
        let name: String
    }

    let type = "milestones"
    let projectId: String
    let load: LoadState
    /// What the client returned, in its order. Empty unless loaded.
    let milestones: [Item]

    init(projectID: String, load: AppModel.MilestoneLoad?) {
        projectId = projectID
        self.load = LoadState(load)
        if case .loaded(let loaded) = load {
            milestones = loaded.map { Item(id: $0.id, name: $0.name) }
        } else {
            milestones = []
        }
    }
}

private struct PanelEvent: Encodable {
    let type = "panel"
    let open: Bool
    let windowNumber: Int?
    /// Screen coordinates with the origin at the bottom left: x, y, width, height.
    let frame: [Double]?

    @MainActor
    init(_ panel: PanelController) {
        open = panel.isOpen
        windowNumber = panel.windowNumber
        frame = panel.frame.map { [$0.minX, $0.minY, $0.width, $0.height] }
    }
}

/// What a driver can assert. It is built from the same pure values the UI renders, and it
/// has no field that could hold the token.
private struct DebugState: Encodable {
    struct MenuBar: Encodable {
        let full: String
        let compact: String
        let symbol: String
        let form: String
        let onScreen: Bool
        /// The status item's frame in screen coordinates while it is on screen.
        let frame: [Double]?
    }

    struct Row: Encodable {
        let id: String
        let key: String
        let subject: String
        let detail: String
        let urgency: String
        let state: String
    }

    struct Next: Encodable {
        let id: String
        let subject: String
        let when: String
        let moreCount: Int
    }

    let type = "state"
    let kind: String
    /// The `DoorayError` name for `stale` and `failed`.
    let error: String?
    let now: Date
    let fetchedAt: Date?
    let menuBar: MenuBar
    let header: PanelModel.Header
    /// Every open task in contract order, in the shape of `expected.json`, filter or not.
    let agenda: [Row]
    /// The ids in `agenda` that the filter shows.
    let visibleIDs: [String]
    /// nil when no filter is on or there is no list.
    let hiddenCount: Int?
    let filter: TaskFilter
    let todayRowIDs: [String]
    let next: Next?
    let footer: String?
    let panel: PanelEvent

    @MainActor
    init(model: AppModel, statusItem: StatusItemController, panel: PanelController) {
        let state = model.state
        let calendar = Calendar.current
        switch state {
        case .needsSetup: (kind, error) = ("needsSetup", nil)
        case .loading: (kind, error) = ("loading", nil)
        case .loaded: (kind, error) = ("loaded", nil)
        case .stale(_, let failure): (kind, error) = ("stale", failure.name)
        case .failed(let failure): (kind, error) = ("failed", failure.name)
        case .authFailed: (kind, error) = ("authFailed", nil)
        }
        now = model.now
        fetchedAt = state.snapshot?.fetchedAt

        let title = StatusTitle.make(state: state, filter: model.filter, now: model.now, calendar: calendar)
        menuBar = MenuBar(
            full: title.full,
            compact: title.compact,
            symbol: title.symbol.rawValue,
            form: statusItem.form.rawValue,
            onScreen: statusItem.placement == .onScreen,
            frame: statusItem.anchorWindow.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] }
        )

        let content = PanelModel.make(state: state, filter: model.filter, now: model.now, calendar: calendar)
        header = content.header
        footer = content.footer
        hiddenCount = content.hiddenCount
        filter = model.filter
        if case .tasks(let today, let upcoming) = content.body {
            todayRowIDs = today.map(\.id)
            next = upcoming.map { Next(id: $0.task.id, subject: $0.subject, when: $0.when, moreCount: $0.moreCount) }
        } else {
            todayRowIDs = []
            next = nil
        }
        let items = Agenda.items(state.snapshot?.tasks ?? [], now: model.now, calendar: calendar)
        agenda = items.map { item in
            Row(
                id: item.task.id,
                key: item.task.key,
                subject: item.task.subject,
                detail: Format.detail(item, now: model.now, calendar: calendar),
                urgency: item.urgency.name,
                state: item.task.state.rawValue
            )
        }
        visibleIDs = items.filter { model.filter.admits($0.task) }.map(\.task.id)
        self.panel = PanelEvent(panel)
    }
}
#endif
