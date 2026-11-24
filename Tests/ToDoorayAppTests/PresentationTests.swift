import DooraySync
import Foundation
import Testing
@testable import ToDoorayApp

private func loaded(_ tasks: [DoorayTask], fetchedAt: Date = noon) -> AppState {
    .loaded(Snapshot(tasks: tasks, projects: [], fetchedAt: fetchedAt))
}

private func title(_ state: AppState, at now: Date = noon, filter: TaskFilter = .showAll) -> StatusTitle {
    StatusTitle.make(state: state, filter: filter, now: now, calendar: seoul)
}

@Suite struct StatusTitleTests {
    @Test func showsTheEarliestDeadlineLeftToday() throws {
        let state = loaded(try basicTasks())
        #expect(title(state) == StatusTitle(symbol: .normal, full: "디자인 리뷰 반영 · 18:00", compact: "9"))
    }

    @Test func followsTheClockWithoutARefetch() throws {
        let state = loaded(try basicTasks())
        #expect(title(state, at: at("2026-11-19T18:01:00+09:00")).full == "푸시 알림 문구 수… · 23:59")
        #expect(title(state, at: at("2026-11-20T00:30:00+09:00")).full == "API 문서 정리 · 10:00")
    }

    @Test func countsOverdueTasksWhenNothingElseIsDueToday() {
        let state = loaded([
            task("1", due: "2026-11-18T18:00:00+09:00"),
            task("2", due: "2026-11-19T09:00:00+09:00"),
            task("3"),
            task("4", due: "2026-11-21T10:00:00+09:00"),
        ])
        #expect(title(state) == StatusTitle(symbol: .normal, full: "마감 지남 2건", compact: "4"))
    }

    @Test func countsOpenTasksWhenNothingIsDueTodayOrOverdue() {
        let state = loaded([task("1"), task("2"), task("3", due: "2026-11-21T10:00:00+09:00")])
        #expect(title(state) == StatusTitle(symbol: .normal, full: "할 일 3건", compact: "3"))
    }

    @Test func saysSoWhenNothingIsOpen() {
        #expect(title(loaded([])) == StatusTitle(symbol: .allDone, full: "할 일 없음", compact: ""))
    }

    @Test func aStaleListRendersLikeAFreshOne() throws {
        let snapshot = Snapshot(tasks: try basicTasks(), projects: [], fetchedAt: noon)
        #expect(title(.stale(snapshot, .rateLimited)) == title(.loaded(snapshot)))
    }

    @Test func statesWithoutAListAskForAttentionOrStayQuiet() {
        #expect(title(.needsSetup) == StatusTitle(symbol: .attention, full: "설정 필요", compact: ""))
        #expect(title(.authFailed) == StatusTitle(symbol: .attention, full: "토큰 확인", compact: ""))
        #expect(title(.failed(.rateLimited)) == StatusTitle(symbol: .attention, full: "", compact: ""))
        #expect(title(.loading) == StatusTitle(symbol: .normal, full: "", compact: ""))
    }

    @Test func capsTheSubjectByDisplayWidth() {
        #expect(TitleText.capped("abcdefghijklmnopqr") == "abcdefghijklmnopqr")
        #expect(TitleText.capped("abcdefghijklmnopqrs") == "abcdefghijklmnopq…")
        #expect(TitleText.capped("가나다라마바사아자") == "가나다라마바사아자")
        #expect(TitleText.capped("가나다라마바사아자차") == "가나다라마바사아…")
        #expect(TitleText.capped("API 문서 정리 및 배포 확인") == "API 문서 정리 및…")
        #expect(TitleText.capped("릴리스\n노트   검토 ") == "릴리스 노트 검토")
    }

    @Test func neverSplitsAGraphemeWhenCapping() {
        let family = "👨‍👩‍👧‍👦"
        let capped = TitleText.capped(String(repeating: family, count: 10))
        #expect(capped == String(repeating: family, count: 8) + "…")
    }
}

@Suite struct PanelModelTests {
    private func panel(_ state: AppState, at now: Date = noon, filter: TaskFilter = .showAll) -> PanelModel {
        PanelModel.make(state: state, filter: filter, now: now, calendar: seoul)
    }

    @Test func headerShowsTheDayAndEveryOpenTask() throws {
        let header = panel(loaded(try basicTasks())).header
        #expect(header == PanelModel.Header(weekday: "목요일", date: "2026년 11월 19일", openCount: 9))
    }

    @Test func todayListHoldsEverythingButUpcomingTasksNotStartedInContractOrder() throws {
        guard case .tasks(let today, let next) = panel(loaded(try basicTasks())).body else {
            Issue.record("expected a task list")
            return
        }
        #expect(today.map(\.id) == [
            "5000000000000000001", "5000000000000000004", "5000000000000000007", "5000000000000000005",
            "5000000000000000003", "5000000000000000011", "5000000000000000009", "5000000000000000010",
        ])
        #expect(today.map(\.detail) == [
            "FE-1203 · 마감 지남 · 어제 18:00",
            "APP-88 · 오늘 18:00 · 6시간 남음",
            "APP-97 · 오늘 23:59 · 11시간 남음",
            "APP-91 · 내일 10:00",
            "FE-1215 · 마감 없음",
            "OPS-17 · 마감 없음",
            "OPS-12 · 마감 없음",
            "OPS-15 · 마감 없음",
        ])
        #expect(today.first?.subject == "결제 모듈 오류 수정")
        #expect(today.map(\.urgency) == [.overdue, .dueToday, .dueToday, .upcoming, .noDue, .noDue, .noDue, .noDue])

        #expect(next?.task.id == "5000000000000000008")
        #expect(next?.subject == "온보딩 화면 개선")
        #expect(next?.when == "11월 25일 (수) 18:00")
        #expect(next?.moreCount == 0)
    }

    @Test func workInProgressStaysInTodayWhateverItsDeadline() {
        let state = loaded([
            task("1", due: "2026-11-20T23:59:00+09:00", state: .working),
            task("2", due: "2026-11-20T09:00:00+09:00"),
            task("3", due: "2026-11-21T09:00:00+09:00"),
            task("4", state: .working),
        ])
        guard case .tasks(let today, let next) = panel(state).body else {
            Issue.record("expected a task list")
            return
        }
        #expect(today.map(\.id) == ["1", "4"])
        #expect(today.first?.detail == "FE-1 · 내일 23:59")
        #expect(next?.task.id == "2")
        #expect(next?.moreCount == 1)
    }

    @Test func detailsCountDownAndNameOlderDays() {
        let state = loaded([
            task("1", due: "2026-11-19T12:25:30+09:00"),
            task("2", due: "2026-11-19T12:00:20+09:00"),
            task("3", due: "2026-11-19T09:00:00+09:00"),
            task("4", due: "2026-11-17T18:00:00+09:00"),
            task("5", due: "2025-12-31T18:00:00+09:00"),
        ])
        guard case .tasks(let today, _) = panel(state).body else {
            Issue.record("expected a task list")
            return
        }
        #expect(Set(today.map(\.detail)) == [
            "FE-1 · 오늘 12:25 · 25분 남음",
            "FE-2 · 오늘 12:00 · 1분 남음",
            "FE-3 · 마감 지남 · 오늘 09:00",
            "FE-4 · 마감 지남 · 11월 17일 18:00",
            "FE-5 · 마감 지남 · 2025년 12월 31일 18:00",
        ])
    }

    @Test func nextLineNamesTheDayBeyondTomorrow() {
        let state = loaded([
            task("1", due: "2026-11-25T18:00:00+09:00"),
            task("2", due: "2027-01-04T09:30:00+09:00"),
            task("3", due: "2027-01-05T09:30:00+09:00"),
        ])
        guard case .tasks(let today, let next) = panel(state).body else {
            Issue.record("expected a task list")
            return
        }
        #expect(today.isEmpty)
        #expect(next?.when == "11월 25일 (수) 18:00")
        #expect(next?.moreCount == 2)

        let later = loaded([task("2", due: "2027-01-04T09:30:00+09:00")])
        guard case .tasks(_, let nextYear) = panel(later).body else {
            Issue.record("expected a task list")
            return
        }
        #expect(nextYear?.when == "2027년 1월 4일 (월) 09:30")
        #expect(nextYear?.moreCount == 0)
    }

    @Test func footerTellsHowOldTheListIs() {
        let tasks = [task("1")]
        #expect(panel(loaded(tasks, fetchedAt: noon.addingTimeInterval(-20))).footer == "방금 업데이트")
        #expect(panel(loaded(tasks, fetchedAt: noon.addingTimeInterval(-3 * 60))).footer == "3분 전 업데이트")
        #expect(panel(loaded(tasks, fetchedAt: noon.addingTimeInterval(-2 * 3600))).footer == "2시간 전 업데이트")

        let snapshot = Snapshot(tasks: tasks, projects: [], fetchedAt: at("2026-11-19T11:57:00+09:00"))
        #expect(panel(.stale(snapshot, .network(.notConnectedToInternet))).footer == "업데이트 실패 · 네트워크 연결 없음 · 11:57 기준")
        #expect(panel(.stale(snapshot, .http(status: 502))).footer == "업데이트 실패 · Dooray 서버 오류 (502) · 11:57 기준")
    }

    @Test func aStaleListKeepsItsRows() throws {
        let snapshot = Snapshot(tasks: try basicTasks(), projects: [], fetchedAt: noon)
        #expect(panel(.stale(snapshot, .rateLimited)).body == panel(.loaded(snapshot)).body)
    }

    @Test func statesWithoutAListHaveNoCountAndNoFooter() {
        let cases: [(AppState, PanelModel.Body)] = [
            (.needsSetup, .needsSetup),
            (.loading, .loading),
            (.authFailed, .authFailed),
            (.failed(.http(status: 502)), .failed(message: "Dooray 서버 오류 (502)")),
            (.failed(.api(code: -1, message: "일시적인 오류")), .failed(message: "Dooray 오류: 일시적인 오류")),
        ]
        for (state, body) in cases {
            let model = panel(state)
            #expect(model.body == body)
            #expect(model.header.openCount == nil)
            #expect(model.footer == nil)
        }
    }

    @Test func aFilterCountsOnlyVisibleTasksAndSaysHowManyItHides() throws {
        let state = loaded(try basicTasks())
        let filter = TaskFilter(projects: [
            "3000000000000000002": .init(
                code: "APP",
                milestones: .init(picked: ["7000000000000000002": "v1.0.1"], withoutMilestone: true)
            ),
        ])
        let model = panel(state, filter: filter)
        #expect(model.header.openCount == 2)
        guard case .tasks(let today, let next) = model.body else {
            Issue.record("expected a task list")
            return
        }
        #expect(today.map(\.id) == ["5000000000000000007"])
        #expect(next?.task.id == "5000000000000000008")
        #expect(model.footer == "방금 업데이트")
        #expect(model.filterNote == "필터 적용 중 · 숨긴 업무 7건")
        #expect(title(state, filter: filter) == StatusTitle(symbol: .normal, full: "푸시 알림 문구 수… · 23:59", compact: "2"))
    }

    @Test func aFilterThatHidesEverythingIsAllDoneButStillCountsTheHidden() throws {
        let state = loaded(try basicTasks())
        let filter = TaskFilter(projects: [:])
        let model = panel(state, filter: filter)
        #expect(model.body == .allDone)
        #expect(model.header.openCount == 0)
        #expect(model.filterNote == "필터 적용 중 · 숨긴 업무 9건")
        #expect(title(state, filter: filter) == StatusTitle(symbol: .allDone, full: "할 일 없음", compact: ""))
    }

    @Test func directOnlyCountsTheGroupTaskAsHidden() throws {
        let state = loaded(try basicTasks())
        let model = panel(state, filter: TaskFilter(directOnly: true))
        #expect(model.header.openCount == 8)
        #expect(model.filterNote == "필터 적용 중 · 숨긴 업무 1건")
        #expect(title(state, filter: TaskFilter(directOnly: true)).compact == "8")
    }

    @Test func theFilterNoteShowsOnlyWhileAFilterIsOn() throws {
        let tasks = try basicTasks()
        #expect(panel(loaded(tasks)).filterNote == nil)
        let everything = TaskFilter.showAll.pickingEvery(TaskFilter.showAll.choices(tasks: tasks, projects: [], loadedMilestones: [:]))
        #expect(panel(loaded(tasks), filter: everything).filterNote == "필터 적용 중 · 숨긴 업무 0건")
        #expect(panel(.loading, filter: everything).filterNote == nil)
    }

    @Test func anEmptyListIsAllDone() {
        let model = panel(loaded([]))
        #expect(model.body == .allDone)
        #expect(model.header.openCount == 0)
    }
}
