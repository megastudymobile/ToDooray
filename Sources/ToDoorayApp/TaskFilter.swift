import DooraySync
import Foundation

/// Which tasks the menu bar and the panel show. It is a preference, so a project or
/// milestone the user never picked stays hidden, including one that appears later.
/// A task shows only when it passes both parts: the projects and milestones, and `directOnly`.
struct TaskFilter: Equatable, Codable {
    /// Keyed by project id. nil shows every project.
    var projects: [String: ProjectSelection]?
    /// Hides tasks that reach me only through a group.
    var directOnly = false

    struct ProjectSelection: Equatable, Codable {
        /// Kept so a picked project with no open task can still be listed by name.
        var code: String
        /// nil shows every milestone of the project.
        var milestones: MilestoneSelection?
    }

    struct MilestoneSelection: Equatable, Codable {
        /// Milestone id to name. The name lists a picked milestone that has no open task.
        var picked: [String: String]
        /// "단계 없음": tasks without a milestone.
        var withoutMilestone: Bool

        func admits(_ milestone: Milestone?) -> Bool {
            milestone.map { picked[$0.id] != nil } ?? withoutMilestone
        }
    }

    static let showAll = TaskFilter()

    var isActive: Bool { projects != nil || directOnly }

    func admits(_ task: DoorayTask) -> Bool {
        if directOnly && !task.isDirectlyAssigned { return false }
        guard let projects else { return true }
        guard let selection = projects[task.projectID] else { return false }
        return selection.milestones?.admits(task.milestone) ?? true
    }

    func apply(_ tasks: [DoorayTask]) -> (visible: [DoorayTask], hiddenCount: Int) {
        let visible = tasks.filter(admits)
        return (visible, tasks.count - visible.count)
    }
}

extension TaskFilter {
    private enum CodingKeys: String, CodingKey { case projects, directOnly }

    /// A filter saved before `directOnly` existed has no such key and must keep working.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([String: ProjectSelection].self, forKey: .projects)
        directOnly = try container.decodeIfPresent(Bool.self, forKey: .directOnly) ?? false
    }
}

// MARK: - Settings list

/// One project row of the settings list. Derived from the last sync, the loaded milestones
/// and the filter, never stored.
struct ProjectChoice: Equatable, Identifiable {
    let id: String
    let code: String
    let taskCount: Int
    /// Sorted by name, with "단계 없음" last.
    let milestones: [MilestoneChoice]
}

struct MilestoneChoice: Equatable, Hashable {
    /// nil is "단계 없음".
    let milestone: Milestone?
    let taskCount: Int

    var name: String { milestone?.name ?? Copy.noMilestone }
}

extension TaskFilter {
    /// Every project I belong to, plus every project and milestone the filter picks, so a
    /// pick never vanishes from the list while it has no tasks. Projects with open tasks
    /// come first.
    func choices(tasks: [DoorayTask], projects: [DoorayProject], loadedMilestones: [String: [Milestone]]) -> [ProjectChoice] {
        var codes: [String: String] = [:]
        var milestones: [String: [String: Milestone]] = [:]
        func add(_ milestone: Milestone, to projectID: String) {
            milestones[projectID, default: [:]][milestone.id] = milestone
        }
        for (id, selection) in self.projects ?? [:] {
            codes[id] = selection.code
            for (milestoneID, name) in selection.milestones?.picked ?? [:] {
                add(Milestone(id: milestoneID, name: name), to: id)
            }
        }
        for project in projects {
            codes[project.id] = project.code
        }
        for (projectID, loaded) in loadedMilestones {
            loaded.forEach { add($0, to: projectID) }
        }
        for task in tasks {
            codes[task.projectID] = task.projectCode
            task.milestone.map { add($0, to: task.projectID) }
        }

        return codes.map { id, code in
            let projectTasks = tasks.filter { $0.projectID == id }
            let named = (milestones[id] ?? [:]).values
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { milestone in
                    MilestoneChoice(milestone: milestone, taskCount: projectTasks.count { $0.milestone?.id == milestone.id })
                }
            let none = MilestoneChoice(milestone: nil, taskCount: projectTasks.count { $0.milestone == nil })
            return ProjectChoice(id: id, code: code, taskCount: projectTasks.count, milestones: named + [none])
        }
        .sorted { a, b in
            if (a.taskCount > 0) != (b.taskCount > 0) { return a.taskCount > 0 }
            return a.code.localizedStandardCompare(b.code) == .orderedAscending
        }
    }

    /// Turning the project part on picks every listed project whole, so nothing disappears
    /// until the user unchecks something.
    func pickingEvery(_ choices: [ProjectChoice]) -> TaskFilter {
        var next = self
        next.projects = Dictionary(uniqueKeysWithValues: choices.map {
            ($0.id, ProjectSelection(code: $0.code, milestones: nil))
        })
        return next
    }

    mutating func setProject(_ project: ProjectChoice, picked: Bool) {
        projects?[project.id] = picked ? ProjectSelection(code: project.code, milestones: nil) : nil
    }

    /// Turning "모든 단계" off picks every listed milestone, for the same reason as `pickingEvery`.
    mutating func setEveryMilestone(of project: ProjectChoice, picked: Bool) {
        projects?[project.id]?.milestones = picked ? nil : MilestoneSelection(
            picked: Dictionary(uniqueKeysWithValues: project.milestones.compactMap(\.milestone).map { ($0.id, $0.name) }),
            withoutMilestone: true
        )
    }

    mutating func setMilestone(_ milestone: Milestone?, of project: ProjectChoice, picked: Bool) {
        guard var selection = projects?[project.id]?.milestones else { return }
        if let milestone {
            selection.picked[milestone.id] = picked ? milestone.name : nil
        } else {
            selection.withoutMilestone = picked
        }
        projects?[project.id]?.milestones = selection
    }
}
