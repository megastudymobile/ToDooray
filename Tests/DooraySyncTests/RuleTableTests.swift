import Foundation
import Testing
@testable import DooraySync

private struct RuleFile<Case: Decodable>: Decodable {
    let cases: [Case]
}

private func loadCases<Case: Decodable>(_ rule: String, as type: Case.Type = Case.self) throws -> [Case] {
    let url = fixturesRoot.appending(path: "rules").appending(path: "\(rule).json")
    return try JSONDecoder().decode(RuleFile<Case>.self, from: Data(contentsOf: url)).cases
}

private func calendar(in timeZone: String) throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: timeZone))
    return calendar
}

struct UrgencyCase: Decodable, Sendable, CustomStringConvertible {
    let name: String
    let now: String
    let timeZone: String
    let dueDate: String?
    let expect: String
    var description: String { name }
}

struct SelectionCase: Decodable, Sendable, CustomStringConvertible {
    let name: String
    let me: String
    let workflows: [String: String]
    let workflowClass: String?
    let to: [Assignee]
    let expect: String?
    var description: String { name }
}

struct OrderingCase: Decodable, Sendable, CustomStringConvertible {
    struct Row: Decodable, Sendable {
        let id: String
        let priority: String
        let dueDate: String?
        let updatedAt: String
    }

    let name: String
    let now: String
    let timeZone: String
    let tasks: [Row]
    let expect: [String]
    var description: String { name }
}

@Suite struct RuleTableTests {
    @Test(arguments: try loadCases("urgency", as: UrgencyCase.self))
    func urgency(_ c: UrgencyCase) throws {
        let urgency = Agenda.urgency(
            dueDate: try c.dueDate.map { try #require(parseISO8601($0)) },
            now: try #require(parseISO8601(c.now)),
            calendar: try calendar(in: c.timeZone)
        )
        #expect(urgency.name == c.expect)
    }

    @Test(arguments: try loadCases("selection", as: SelectionCase.self))
    func selection(_ c: SelectionCase) {
        let post = PostDTO(
            id: "1",
            subject: "",
            project: ProjectDTO(id: "1", code: "P"),
            number: 1,
            priority: nil,
            dueDate: nil,
            workflowClass: WorkflowClass(lenient: c.workflowClass),
            updatedAt: "",
            assignees: c.to
        )
        let table = WorkflowTable(
            classes: c.workflows.compactMapValues { WorkflowClass(lenient: $0) },
            fetchedAt: .distantPast
        )
        #expect(Selection.openState(of: post, me: c.me, in: table)?.rawValue == c.expect)
    }

    @Test(arguments: try loadCases("ordering", as: OrderingCase.self))
    func ordering(_ c: OrderingCase) throws {
        let tasks = try c.tasks.map { row in
            DoorayTask(
                id: row.id,
                projectID: "1",
                projectCode: "P",
                number: 1,
                subject: "",
                priority: Priority(wire: row.priority),
                dueDate: try row.dueDate.map { try #require(parseISO8601($0)) },
                updatedAt: try #require(parseISO8601(row.updatedAt)),
                state: .registered
            )
        }
        let items = Agenda.items(tasks, now: try #require(parseISO8601(c.now)), calendar: try calendar(in: c.timeZone))
        #expect(items.map(\.id) == c.expect)
    }

    @Test func datesParseWithOffsetsAndFractionalSeconds() throws {
        let instant = Date(timeIntervalSince1970: 1_794_193_200)
        #expect(parseISO8601("2026-11-09T03:00:00Z") == instant)
        #expect(parseISO8601("2026-11-09T12:00:00+09:00") == instant)
        #expect(parseISO8601("2026-11-09T03:00:00.000Z") == instant)
        #expect(parseISO8601("2026-11-09T12:00:00.000+09:00") == instant)
        #expect(parseISO8601("내일까지") == nil)
    }

    @Test func priorityMapsUnknownValuesToNone() {
        #expect(["highest", "high", "normal", "low", "none"].map { Priority(wire: $0) } == [.highest, .high, .normal, .low, .none])
        #expect(Priority(wire: "urgent") == Priority.none)
        #expect(Priority(wire: nil) == Priority.none)
        #expect(Priority.highest > Priority.high)
    }

    @Test func tokenNeverRendersItsSecret() throws {
        let token = try #require(APIToken("  secret-value\n"))
        #expect(token.reveal() == "secret-value")

        var dumped = ""
        dump(token, to: &dumped)
        for rendering in ["\(token)", String(describing: token), String(reflecting: token), dumped] {
            #expect(!rendering.contains("secret-value"))
        }

        #expect(APIToken("") == nil)
        #expect(APIToken("   ") == nil)
        #expect(APIToken("a b") == nil)
        #expect(APIToken("a\nb") == nil)
    }

    @Test func webURLFollowsTheContract() throws {
        let task = DoorayTask(
            id: "3001",
            projectID: "101",
            projectCode: "FE",
            number: 1203,
            subject: "",
            priority: .normal,
            dueDate: nil,
            updatedAt: .distantPast,
            state: .working
        )
        let expected = "https://acme.dooray.com/task/101/3001"
        #expect(task.webURL(tenant: try #require(URL(string: "https://acme.dooray.com"))).absoluteString == expected)
        #expect(task.webURL(tenant: try #require(URL(string: "https://acme.dooray.com/"))).absoluteString == expected)
    }
}
