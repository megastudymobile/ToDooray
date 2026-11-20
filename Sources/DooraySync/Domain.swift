import Foundation

/// A task I still have to handle. Only `DoorayClient.fetchOpenTasks()` creates these, so every
/// value has already passed the per-assignee selection rule.
public struct DoorayTask: Sendable, Hashable, Identifiable {
    /// A numeric string. Ids can exceed 2^53, so it is never parsed as a number.
    public let id: String
    public let projectID: String
    public let projectCode: String
    /// Dooray's web UI calls this "단계".
    public let milestone: Milestone?
    public let number: Int
    public let subject: String
    public let priority: Priority
    public let dueDate: Date?
    public let updatedAt: Date
    /// My own per-assignee state, not the post's overall `workflowClass`.
    public let state: OpenState

    public var key: String { "\(projectCode)-\(number)" }

    /// `{tenant}/task/{projectId}/{postId}`.
    public func webURL(tenant: URL) -> URL {
        tenant.appending(path: "task").appending(path: projectID).appending(path: id)
    }
}

/// A project I belong to.
public struct DoorayProject: Sendable, Hashable {
    public let id: String
    public let code: String

    public init(id: String, code: String) {
        self.id = id
        self.code = code
    }
}

/// One sync: my open tasks and the projects they were read from.
public struct OpenTasks: Sendable, Hashable {
    public let tasks: [DoorayTask]
    /// Every project I belong to, open task or not, minus those skipped for 403 or 404.
    public let projects: [DoorayProject]

    public init(tasks: [DoorayTask], projects: [DoorayProject]) {
        self.tasks = tasks
        self.projects = projects
    }
}

public struct Milestone: Sendable, Hashable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The two workflow classes the app shows. `backlog` and `closed` cannot be represented.
public enum OpenState: String, Sendable, Hashable {
    case registered
    case working
}

/// `>` means more important.
public enum Priority: Int, Sendable, Hashable, Comparable {
    case none = 0, low, normal, high, highest

    public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum DoorayError: Error, Sendable, Equatable {
    /// HTTP 401. Retrying with the same token cannot help.
    case unauthorized
    /// HTTP 429 persisted after the retry budget.
    case rateLimited
    case http(status: Int)
    /// 2xx with `header.isSuccessful == false`.
    case api(code: Int, message: String)
    /// No HTTP response at all.
    case network(URLError.Code)
    /// The body did not match the documented shape. The string names the field path.
    case invalidResponse(String)
    case cancelled

    /// The case name that `fixtures/scenarios/*/expected.json` uses in `error`.
    public var name: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .rateLimited: "rateLimited"
        case .http: "http"
        case .api: "api"
        case .network: "network"
        case .invalidResponse: "invalidResponse"
        case .cancelled: "cancelled"
        }
    }
}
