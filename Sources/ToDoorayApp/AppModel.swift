import AppKit
import DooraySync
import Observation

/// Owns the app state and the sync lifecycle. It is the only writer of `state`, `now`,
/// `settings`, `filter` and `milestoneLoads`. Views, the status item, the panel and the debug
/// console read them.
@MainActor
@Observable
final class AppModel {
    private(set) var state: AppState = .needsSetup
    /// The render clock. It ticks on minute boundaries, on wake and when the system clock,
    /// time zone or day changes.
    private(set) var now: Date
    private(set) var settings: Settings
    private(set) var filter: TaskFilter
    /// Keyed by project id. Filled only while the settings window shows a project's
    /// milestones, never by the poll.
    private(set) var milestoneLoads: [String: MilestoneLoad] = [:]

    enum MilestoneLoad: Equatable {
        case loading(Task<Void, Never>)
        case loaded([Milestone])
        case failed(DoorayError)
    }

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var clock: () -> Date
    @ObservationIgnored private var client: DoorayClient?
    @ObservationIgnored private var syncTask: Task<Void, Never>? {
        didSet { isSyncing = syncTask != nil }
    }
    /// Mirrors `syncTask` so views can show progress.
    private(set) var isSyncing = false
    var canRefresh: Bool { RefreshPolicy.acceptsManualRefresh(state: state) }
    @ObservationIgnored private var lastAttemptEnd: Date?
    /// Bumped on every identity change. A result from an older generation is dropped even if
    /// its task ignored cancellation.
    @ObservationIgnored private var generation = 0
    /// True from sleep until shortly after wake.
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?

    init(store: SettingsStore, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.clock = clock
        now = clock()
        settings = store.load()
        filter = store.loadFilter()
    }

    func start() {
        adoptIdentity(reason: .launch)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                let secondsIntoMinute = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                try? await Task.sleep(for: .seconds(60 - secondsIntoMinute))
                self?.tick()
            }
        }
        observeSystem()
    }

    /// Asks for a sync. `RefreshPolicy` decides whether one runs, and a sync in flight makes
    /// every request a no-op.
    func refresh(_ reason: RefreshReason) {
        guard !suspended || reason == .manual, let client,
              RefreshPolicy.shouldSync(
                  reason,
                  state: state,
                  inFlight: syncTask != nil,
                  lastAttemptEnd: lastAttemptEnd,
                  now: clock()
              )
        else { return }

        let generation = generation
        syncTask = Task { [weak self] in
            let result: Result<OpenTasks, DoorayError>
            do throws(DoorayError) {
                result = .success(try await client.fetchOpenTasks())
            } catch {
                result = .failure(error)
            }
            guard let self, generation == self.generation else { return }
            let finishedAt = self.clock()
            self.syncTask = nil
            if result != .failure(.cancelled) {
                self.lastAttemptEnd = finishedAt
            }
            self.apply(.synced(result, at: finishedAt))
        }
    }

    enum SaveError: Error, Equatable {
        case invalid(SettingsDraft.Problem)
        case keychain(OSStatus)
    }

    func save(_ draft: SettingsDraft) throws(SaveError) {
        let new: Settings
        switch draft.validated(keeping: settings) {
        case .success(let validated): new = validated
        case .failure(let problem): throw .invalid(problem)
        }
        do {
            try store.save(new)
        } catch {
            throw .keychain(error.status)
        }
        let identityChanged = new.apiBase != settings.apiBase || new.token != settings.token
        settings = new
        // A new web address alone only changes links, so a list on screen stays.
        if identityChanged || state.snapshot == nil {
            adoptIdentity(reason: .settingsSaved)
        }
    }

    func setFilter(_ filter: TaskFilter) {
        self.filter = filter
        store.saveFilter(filter)
    }

    var filterChoices: [ProjectChoice] {
        filter.choices(
            tasks: state.snapshot?.tasks ?? [],
            projects: state.snapshot?.projects ?? [],
            loadedMilestones: milestoneLoads.compactMapValues { load in
                if case .loaded(let milestones) = load { milestones } else { nil }
            }
        )
    }

    /// Starts loading a project's milestones unless they are loaded or loading, and returns
    /// the load for a caller that waits for it to settle. A failed load starts again, which is
    /// the retry.
    @discardableResult
    func loadMilestones(of projectID: String) -> Task<Void, Never> {
        switch milestoneLoads[projectID] {
        case .loading(let task): return task
        case .loaded: return Task {}
        case .failed, nil: break
        }
        guard let client else { return Task {} }
        let generation = generation
        let task = Task { [weak self] in
            let result: Result<[Milestone], DoorayError>
            do throws(DoorayError) {
                result = .success(try await client.fetchMilestones(projectID: projectID))
            } catch {
                result = .failure(error)
            }
            guard let self, generation == self.generation else { return }
            self.milestoneLoads[projectID] = switch result {
            case .success(let milestones): .loaded(milestones)
            case .failure(.cancelled): nil
            case .failure(let error): .failed(error)
            }
        }
        milestoneLoads[projectID] = .loading(task)
        return task
    }

    /// Called each time the settings window opens, so milestones added or closed in Dooray
    /// since the last look show up. Loads in flight are kept and not started twice.
    func reloadMilestones() {
        milestoneLoads = milestoneLoads.filter { _, load in
            if case .loading = load { true } else { false }
        }
        for (projectID, selection) in filter.projects ?? [:] where selection.milestones != nil {
            loadMilestones(of: projectID)
        }
    }

    func webURL(for task: DoorayTask) -> URL? {
        settings.webBase.map(task.webURL(tenant:))
    }

    #if DEBUG
    func freezeClock(at date: Date) {
        clock = { date }
        now = date
    }
    #endif

    private func adoptIdentity(reason: RefreshReason) {
        generation += 1
        syncTask?.cancel()
        syncTask = nil
        lastAttemptEnd = nil
        for case .loading(let task) in milestoneLoads.values {
            task.cancel()
        }
        milestoneLoads = [:]
        client = settings.isComplete ? settings.token.map { DoorayClient(apiBase: settings.apiBase, token: $0) } : nil
        apply(.configured(complete: settings.isComplete))
        refresh(reason)
    }

    private func apply(_ event: AppState.Event) {
        state = state.reduced(by: event)
    }

    private func tick() {
        now = clock()
        refresh(.timer)
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    private func willSleep() {
        suspended = true
        wakeTask?.cancel()
        syncTask?.cancel()
    }

    private func didWake() {
        now = clock()
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RefreshPolicy.wakeDelay))
            guard let self, !Task.isCancelled else { return }
            self.suspended = false
            self.refresh(.wake)
        }
    }
}

/// Runs `render` now and again whenever an observable property it read changes.
@MainActor
func rerunOnChange(_ render: @escaping @MainActor () -> Void) {
    withObservationTracking {
        render()
    } onChange: {
        Task { @MainActor in rerunOnChange(render) }
    }
}
