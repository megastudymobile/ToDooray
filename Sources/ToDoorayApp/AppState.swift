import DooraySync
import Foundation

/// The last successful sync. It stores no urgency: that is derived from the time at render.
struct Snapshot: Equatable {
    let tasks: [DoorayTask]
    /// Every project I belong to, so the filter can list one before it has a task.
    let projects: [DoorayProject]
    let fetchedAt: Date
}

enum AppState: Equatable {
    /// No token or no web address saved. No polling.
    case needsSetup
    case loading
    case loaded(Snapshot)
    /// The latest sync failed and the previous list is still shown.
    case stale(Snapshot, DoorayError)
    /// No sync has succeeded yet, so there is no list to keep.
    case failed(DoorayError)
    /// 401. Polling stops until the settings change.
    case authFailed

    var snapshot: Snapshot? {
        switch self {
        case .loaded(let snapshot), .stale(let snapshot, _): snapshot
        case .needsSetup, .loading, .failed, .authFailed: nil
        }
    }

    enum Event: Equatable {
        /// Settings were loaded or saved. `complete` means a token and a web address exist.
        case configured(complete: Bool)
        case synced(Result<OpenTasks, DoorayError>, at: Date)
    }

    /// The only way the state changes.
    func reduced(by event: Event) -> AppState {
        switch event {
        case .configured(let complete):
            // A new identity always restarts from loading: the old list may not be mine.
            return complete ? .loading : .needsSetup

        case .synced(let result, let date):
            switch (self, result) {
            case (.needsSetup, _), (_, .failure(.cancelled)):
                return self
            case (_, .success(let open)):
                return .loaded(Snapshot(tasks: open.tasks, projects: open.projects, fetchedAt: date))
            case (_, .failure(.unauthorized)), (.authFailed, .failure):
                return .authFailed
            case (.loaded(let snapshot), .failure(let error)), (.stale(let snapshot, _), .failure(let error)):
                return .stale(snapshot, error)
            case (.loading, .failure(let error)), (.failed, .failure(let error)):
                return .failed(error)
            }
        }
    }
}

enum RefreshReason: Equatable, CaseIterable {
    case launch, settingsSaved, timer, panelOpened, wake, manual
}

enum RefreshPolicy {
    static let pollInterval: TimeInterval = 5 * 60
    static let panelFreshness: TimeInterval = 30
    /// The network is often not up yet right after wake.
    static let wakeDelay: TimeInterval = 5

    /// Whether the refresh button can do anything in this state. Timing is left out: a manual
    /// refresh ignores how recently the last sync ended.
    static func acceptsManualRefresh(state: AppState) -> Bool {
        shouldSync(.manual, state: state, inFlight: false, lastAttemptEnd: nil, now: .distantPast)
    }

    /// Level-triggered. A heartbeat asks every minute, so a missed timer or a long sleep can
    /// delay a sync but never lose it. `lastAttemptEnd` counts failures too, so opening the
    /// panel repeatedly does not hammer a failing server.
    static func shouldSync(
        _ reason: RefreshReason,
        state: AppState,
        inFlight: Bool,
        lastAttemptEnd: Date?,
        now: Date
    ) -> Bool {
        if inFlight { return false }
        switch state {
        case .needsSetup: return false
        case .authFailed: return reason == .settingsSaved
        case .loading, .loaded, .stale, .failed: break
        }
        guard let lastAttemptEnd else { return true }
        let elapsed = now.timeIntervalSince(lastAttemptEnd)
        switch reason {
        case .launch, .settingsSaved, .wake, .manual: return true
        case .timer: return elapsed >= pollInterval
        case .panelOpened: return elapsed > panelFreshness
        }
    }
}
