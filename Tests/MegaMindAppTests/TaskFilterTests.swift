import DooraySync
import Foundation
import Testing
@testable import MegaMindApp

private let fe = "3000000000000000001"
private let app = "3000000000000000002"
private let v100 = Milestone(id: "7000000000000000001", name: "v1.0.0")
private let v101 = Milestone(id: "7000000000000000002", name: "v1.0.1")

private func only(_ milestones: [Milestone], withoutMilestone: Bool = false) -> TaskFilter.MilestoneSelection {
    TaskFilter.MilestoneSelection(
        picked: Dictionary(uniqueKeysWithValues: milestones.map { ($0.id, $0.name) }),
        withoutMilestone: withoutMilestone
    )
}

private func keys(_ tasks: [DoorayTask]) -> Set<String> {
    Set(tasks.map(\.key))
}

@Suite struct TaskFilterTests {
    @Test func noFilterShowsEveryTask() throws {
        let tasks = try basicTasks()
        let result = TaskFilter.showAll.apply(tasks)
        #expect(result.visible == tasks)
        #expect(result.hiddenCount == 0)
    }

    @Test func aProjectNeverPickedIsHiddenEvenWhenItAppearsLater() throws {
        let filter = TaskFilter(projects: [fe: .init(code: "FE", milestones: nil)])
        let newcomer = task("1", project: ("3000000000000000099", "NEW"))
        let result = filter.apply(try basicTasks() + [newcomer])
        #expect(keys(result.visible) == ["FE-1203", "FE-1215"])
        #expect(result.hiddenCount == 8)
    }

    @Test func aPickedProjectShowsEveryMilestoneOrOnlyThePickedOnes() throws {
        let tasks = try basicTasks()
        func visible(_ milestones: TaskFilter.MilestoneSelection?) -> Set<String> {
            keys(TaskFilter(projects: [app: .init(code: "APP", milestones: milestones)]).apply(tasks).visible)
        }
        #expect(visible(nil) == ["APP-88", "APP-91", "APP-97", "APP-99"])
        #expect(visible(only([v100])) == ["APP-88", "APP-91"])
        #expect(visible(only([v101], withoutMilestone: true)) == ["APP-97", "APP-99"])
        #expect(visible(only([])).isEmpty)
    }

    @Test func choicesListPicksWithoutTasksByTheirStoredNames() throws {
        let filter = TaskFilter(projects: [
            app: .init(code: "APP", milestones: only([Milestone(id: "7000000000000000009", name: "v0.9.0")])),
            "3000000000000000009": .init(code: "OLD", milestones: nil),
        ])
        let choices = filter.choices(for: try basicTasks())

        #expect(choices.map(\.code) == ["APP", "FE", "OLD", "OPS"])
        #expect(choices.map(\.taskCount) == [4, 2, 0, 3])
        let appMilestones = try #require(choices.first).milestones
        #expect(appMilestones.map(\.name) == ["v0.9.0", "v1.0.0", "v1.0.1", "단계 없음"])
        #expect(appMilestones.map(\.taskCount) == [0, 2, 1, 1])
        #expect(choices[2].milestones == [MilestoneChoice(milestone: nil, taskCount: 0)])
    }

    @Test func milestonesSortByNameWithNumbersInOrder() {
        let tasks = [
            task("1", milestone: Milestone(id: "a", name: "v1.0.10")),
            task("2", milestone: Milestone(id: "b", name: "v1.0.9")),
        ]
        #expect(TaskFilter.showAll.choices(for: tasks).first?.milestones.map(\.name) == ["v1.0.9", "v1.0.10", "단계 없음"])
    }

    @Test func turningTheFilterOnHidesNothingUntilSomethingIsUnchecked() throws {
        let tasks = try basicTasks()
        var filter = TaskFilter.pickingEvery(TaskFilter.showAll.choices(for: tasks))
        #expect(filter.isActive)
        #expect(filter.apply(tasks).hiddenCount == 0)

        let appChoice = try #require(filter.choices(for: tasks).first { $0.id == app })
        filter.setEveryMilestone(of: appChoice, picked: false)
        #expect(filter.apply(tasks).hiddenCount == 0)

        filter.setMilestone(v100, of: appChoice, picked: false)
        filter.setMilestone(nil, of: appChoice, picked: false)
        #expect(keys(filter.apply(tasks).visible.filter { $0.projectID == app }) == ["APP-97"])

        let feChoice = try #require(filter.choices(for: tasks).first { $0.id == fe })
        filter.setProject(feChoice, picked: false)
        #expect(filter.apply(tasks).hiddenCount == 5)

        filter.setEveryMilestone(of: appChoice, picked: true)
        #expect(filter.apply(tasks).hiddenCount == 2)
    }

    @Test func readsTheJSONTheConsoleAndConfigFileTake() throws {
        let json = """
        {"projects": {"3000000000000000002": {"code": "APP",
            "milestones": {"picked": {"7000000000000000001": "v1.0.0"}, "withoutMilestone": true}}}}
        """
        let filter = try JSONDecoder().decode(TaskFilter.self, from: Data(json.utf8))
        #expect(filter == TaskFilter(projects: [app: .init(code: "APP", milestones: only([v100], withoutMilestone: true))]))
        #expect(try JSONDecoder().decode(TaskFilter.self, from: Data("{}".utf8)) == .showAll)
    }
}
