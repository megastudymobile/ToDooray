import Foundation
import Testing
@testable import DooraySync
@testable import MegaMindApp

let seoul: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return calendar
}()

func at(_ iso: String) -> Date {
    parseISO8601(iso)!
}

func task(
    _ id: String,
    project: (id: String, code: String) = ("101", "FE"),
    milestone: Milestone? = nil,
    subject: String = "업무",
    due: String? = nil,
    priority: Priority = .normal,
    updated: String = "2026-11-18T10:00:00+09:00"
) -> DoorayTask {
    DoorayTask(
        id: id,
        projectID: project.id,
        projectCode: project.code,
        milestone: milestone,
        number: Int(id) ?? 0,
        subject: subject,
        priority: priority,
        dueDate: due.map(at),
        updatedAt: at(updated),
        state: .registered
    )
}

/// The tasks of fixtures/scenarios/basic, decoded with DooraySync's own decoder and
/// selection rule, so these tests and the contract tests share one input.
func basicTasks() throws -> [DoorayTask] {
    let responses = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "fixtures/scenarios/basic/responses")

    func result<Payload: Decodable>(_ file: String) throws -> Payload {
        let data = try Data(contentsOf: responses.appending(path: file))
        return try #require(JSONDecoder().decode(Envelope<Payload>.self, from: data).result)
    }

    let me: MemberDTO = try result("members-me.json")
    let projects: [ProjectDTO] = try result("projects-0.json")
    return try projects.flatMap { project in
        let workflows: [WorkflowDTO] = try result("workflows-\(project.id).json")
        let table = WorkflowTable(
            classes: workflows.reduce(into: [:]) { $0[$1.id] = $1.workflowClass },
            fetchedAt: .distantPast
        )
        let posts: [PostDTO] = try result("posts-\(project.id)-0.json")
        return try posts.compactMap { post in
            try Selection.openState(of: post, me: me.id, in: table).map { try DoorayTask(post, state: $0) }
        }
    }
}

let noon = at("2026-11-19T12:00:00+09:00")
