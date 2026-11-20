import DooraySync
import Foundation
import Testing
@testable import ToDoorayApp

private let earlier = at("2026-11-19T11:00:00+09:00")
private let previous = Snapshot(tasks: [task("1")], fetchedAt: earlier)
private let fresh = [task("2"), task("3")]

struct Transition: Sendable, CustomStringConvertible {
    let from: AppState
    let event: AppState.Event
    let to: AppState
    var description: String { "\(from) + \(event)" }

    static let all: [Transition] = [
        Transition(from: .needsSetup, event: .configured(complete: false), to: .needsSetup),
        Transition(from: .loaded(previous), event: .configured(complete: false), to: .needsSetup),
        Transition(from: .needsSetup, event: .configured(complete: true), to: .loading),
        Transition(from: .loaded(previous), event: .configured(complete: true), to: .loading),
        Transition(from: .authFailed, event: .configured(complete: true), to: .loading),

        Transition(from: .loading, event: .synced(.success(fresh), at: noon), to: .loaded(Snapshot(tasks: fresh, fetchedAt: noon))),
        Transition(from: .stale(previous, .rateLimited), event: .synced(.success(fresh), at: noon), to: .loaded(Snapshot(tasks: fresh, fetchedAt: noon))),
        Transition(from: .failed(.rateLimited), event: .synced(.success(fresh), at: noon), to: .loaded(Snapshot(tasks: fresh, fetchedAt: noon))),

        Transition(from: .loading, event: .synced(.failure(.unauthorized), at: noon), to: .authFailed),
        Transition(from: .loaded(previous), event: .synced(.failure(.unauthorized), at: noon), to: .authFailed),

        Transition(from: .loaded(previous), event: .synced(.failure(.rateLimited), at: noon), to: .stale(previous, .rateLimited)),
        Transition(from: .stale(previous, .rateLimited), event: .synced(.failure(.http(status: 502)), at: noon), to: .stale(previous, .http(status: 502))),
        Transition(from: .loading, event: .synced(.failure(.rateLimited), at: noon), to: .failed(.rateLimited)),
        Transition(from: .failed(.rateLimited), event: .synced(.failure(.http(status: 502)), at: noon), to: .failed(.http(status: 502))),
        Transition(from: .authFailed, event: .synced(.failure(.rateLimited), at: noon), to: .authFailed),

        Transition(from: .needsSetup, event: .synced(.success(fresh), at: noon), to: .needsSetup),
        Transition(from: .needsSetup, event: .synced(.failure(.unauthorized), at: noon), to: .needsSetup),
    ]
}

@Suite struct AppStateTests {
    @Test(arguments: Transition.all)
    func transition(_ row: Transition) {
        #expect(row.from.reduced(by: row.event) == row.to)
    }

    @Test(arguments: [
        AppState.needsSetup, .loading, .loaded(previous), .stale(previous, .rateLimited), .failed(.rateLimited), .authFailed,
    ])
    func cancelledSyncChangesNothing(_ state: AppState) {
        #expect(state.reduced(by: .synced(.failure(.cancelled), at: noon)) == state)
    }
}

@Suite struct RefreshPolicyTests {
    private func shouldSync(
        _ reason: RefreshReason,
        state: AppState = .loaded(previous),
        inFlight: Bool = false,
        secondsSinceLastAttempt: TimeInterval? = 0
    ) -> Bool {
        RefreshPolicy.shouldSync(
            reason,
            state: state,
            inFlight: inFlight,
            lastAttemptEnd: secondsSinceLastAttempt.map { noon.addingTimeInterval(-$0) },
            now: noon
        )
    }

    @Test func timerSyncsEveryFiveMinutes() {
        #expect(!shouldSync(.timer, secondsSinceLastAttempt: 299))
        #expect(shouldSync(.timer, secondsSinceLastAttempt: 300))
    }

    @Test func panelSyncsWhenTheListIsOlderThanThirtySeconds() {
        #expect(!shouldSync(.panelOpened, secondsSinceLastAttempt: 30))
        #expect(shouldSync(.panelOpened, secondsSinceLastAttempt: 31))
    }

    @Test func aFailedAttemptAlsoHoldsBackTimerAndPanel() {
        #expect(!shouldSync(.timer, state: .stale(previous, .rateLimited), secondsSinceLastAttempt: 10))
        #expect(!shouldSync(.panelOpened, state: .failed(.rateLimited), secondsSinceLastAttempt: 10))
    }

    @Test(arguments: [RefreshReason.launch, .settingsSaved, .wake, .manual])
    func explicitReasonsSyncAtOnce(_ reason: RefreshReason) {
        #expect(shouldSync(reason, secondsSinceLastAttempt: 0))
    }

    @Test(arguments: RefreshReason.allCases)
    func nothingSyncsWhileASyncIsInFlightOrBeforeSetup(_ reason: RefreshReason) {
        #expect(!shouldSync(reason, inFlight: true, secondsSinceLastAttempt: nil))
        #expect(!shouldSync(reason, state: .needsSetup, secondsSinceLastAttempt: nil))
    }

    @Test(arguments: RefreshReason.allCases)
    func firstAttemptAlwaysRuns(_ reason: RefreshReason) {
        #expect(shouldSync(reason, state: .loading, secondsSinceLastAttempt: nil))
    }

    @Test(arguments: RefreshReason.allCases)
    func afterAnAuthFailureOnlyNewSettingsSync(_ reason: RefreshReason) {
        #expect(shouldSync(reason, state: .authFailed, secondsSinceLastAttempt: 3600) == (reason == .settingsSaved))
    }
}
