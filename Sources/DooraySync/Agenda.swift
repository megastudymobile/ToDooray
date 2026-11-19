import Foundation

/// Case order is display order.
public enum Urgency: Int, Sendable, Hashable, Comparable {
    case overdue
    case dueToday
    case upcoming
    case noDue

    public static func < (lhs: Urgency, rhs: Urgency) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The name that `fixtures/` uses.
    public var name: String {
        switch self {
        case .overdue: "overdue"
        case .dueToday: "dueToday"
        case .upcoming: "upcoming"
        case .noDue: "noDue"
        }
    }
}

public struct AgendaItem: Sendable, Hashable, Identifiable {
    public let task: DoorayTask
    public let urgency: Urgency
    public var id: String { task.id }
}

/// Urgency and order depend on the time, so callers pass `now` on every render.
/// A task turns overdue at its due minute without a refetch.
public enum Agenda {
    /// `calendar.timeZone` defines "today".
    public static func urgency(dueDate: Date?, now: Date, calendar: Calendar) -> Urgency {
        guard let dueDate else { return .noDue }
        if dueDate < now { return .overdue }
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return .upcoming
        }
        return dueDate < startOfTomorrow ? .dueToday : .upcoming
    }

    /// The contract's total order. Ties end at the id, so any two apps render the same list.
    public static func items(_ tasks: [DoorayTask], now: Date, calendar: Calendar) -> [AgendaItem] {
        tasks
            .map { AgendaItem(task: $0, urgency: urgency(dueDate: $0.dueDate, now: now, calendar: calendar)) }
            .sorted(by: precedes)
    }

    private static func precedes(_ a: AgendaItem, _ b: AgendaItem) -> Bool {
        if a.urgency != b.urgency { return a.urgency < b.urgency }
        if let dueA = a.task.dueDate, let dueB = b.task.dueDate, dueA != dueB { return dueA < dueB }
        if a.task.priority != b.task.priority { return a.task.priority > b.task.priority }
        if a.task.updatedAt != b.task.updatedAt { return a.task.updatedAt > b.task.updatedAt }
        return numericallyPrecedes(a.task.id, b.task.id)
    }

    private static func numericallyPrecedes(_ a: String, _ b: String) -> Bool {
        a.count != b.count ? a.count < b.count : a < b
    }
}
