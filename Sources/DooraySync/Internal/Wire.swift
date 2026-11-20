import Foundation

typealias MemberID = String
typealias ProjectID = String
typealias WorkflowID = String

struct EnvelopeHeader: Decodable {
    let isSuccessful: Bool
    let resultCode: Int
    let resultMessage: String

    private enum CodingKeys: String, CodingKey { case isSuccessful, resultCode, resultMessage }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isSuccessful = try container.decode(Bool.self, forKey: .isSuccessful)
        resultCode = try container.decodeIfPresent(Int.self, forKey: .resultCode) ?? 0
        resultMessage = try container.decodeIfPresent(String.self, forKey: .resultMessage) ?? ""
    }
}

/// Decoded before the payload, so a failed call whose `result` has another shape still
/// surfaces as the API's own error.
struct EnvelopeStatus: Decodable {
    let header: EnvelopeHeader
}

struct Envelope<Payload: Decodable>: Decodable {
    let result: Payload?
    let totalCount: Int?
}

struct MemberDTO: Decodable, Sendable {
    let id: MemberID
}

struct ProjectDTO: Decodable, Sendable {
    let id: ProjectID
    let code: String
}

struct MilestoneDTO: Sendable {
    let id: String
    let name: String
    let isClosed: Bool
}

extension MilestoneDTO: Decodable {
    private enum CodingKeys: String, CodingKey { case id, name, status, closedAt }

    /// Only `id` and `name` are verified on the public API, so an unreadable `status` or
    /// `closedAt` keeps the milestone instead of failing the call.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let status = try? container.decodeIfPresent(String.self, forKey: .status)
        let hasClosedAt = (try? container.decodeNil(forKey: .closedAt)) == false
        isClosed = status == "closed" || hasClosedAt
    }
}

struct WorkflowDTO: Decodable, Sendable {
    let id: WorkflowID
    let workflowClass: WorkflowClass?

    private enum CodingKeys: String, CodingKey { case id, workflowClass = "class" }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(WorkflowID.self, forKey: .id)
        workflowClass = WorkflowClass(lenient: try container.decodeIfPresent(String.self, forKey: .workflowClass))
    }
}

enum WorkflowClass: String, Sendable {
    case backlog, registered, working, closed

    init?(lenient raw: String?) {
        guard let raw, let value = WorkflowClass(rawValue: raw) else { return nil }
        self = value
    }

    var openState: OpenState? {
        switch self {
        case .registered: .registered
        case .working: .working
        case .backlog, .closed: nil
        }
    }
}

struct WorkflowTable: Sendable {
    /// Workflows whose class is unknown are absent, so they read as "not found".
    let classes: [WorkflowID: WorkflowClass]
    let fetchedAt: Date
}

struct PostDTO: Sendable {
    let id: String
    let subject: String
    let project: ProjectDTO
    let milestone: MilestoneDTO?
    let number: Int
    let priority: String?
    let dueDate: String?
    let workflowClass: WorkflowClass?
    let updatedAt: String
    let assignees: [Assignee]
}

extension PostDTO: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, subject, project, milestone, number, priority, dueDate, workflowClass, updatedAt, users
    }

    private struct Users: Decodable {
        let to: [Assignee]
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        subject = try container.decode(String.self, forKey: .subject)
        project = try container.decode(ProjectDTO.self, forKey: .project)
        milestone = try container.decodeIfPresent(MilestoneDTO.self, forKey: .milestone)
        number = try container.decode(Int.self, forKey: .number)
        priority = try container.decodeIfPresent(String.self, forKey: .priority)
        dueDate = try container.decodeIfPresent(String.self, forKey: .dueDate)
        workflowClass = WorkflowClass(lenient: try container.decodeIfPresent(String.self, forKey: .workflowClass))
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        assignees = try container.decode(Users.self, forKey: .users).to
    }
}

/// One `users.to[]` entry. The shape depends on `type`.
enum Assignee: Sendable {
    case member(memberID: MemberID, workflowID: WorkflowID?)
    case group(members: [GroupMember])
    /// Any other `type`, or an entry without a member id. It cannot be me.
    case other

    struct GroupMember: Sendable {
        let memberID: MemberID
        let workflowID: WorkflowID?
    }
}

extension Assignee: Decodable {
    private enum CodingKeys: String, CodingKey { case type, member, workflow, group }

    private struct Member: Decodable {
        let organizationMemberId: MemberID?
    }

    private struct Workflow: Decodable {
        let id: WorkflowID?
    }

    private struct Group: Decodable {
        let members: [Entry]?

        struct Entry: Decodable {
            let organizationMemberId: MemberID?
            let workflowId: WorkflowID?
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .type) {
        case "member":
            guard let memberID = try container.decodeIfPresent(Member.self, forKey: .member)?.organizationMemberId else {
                self = .other
                return
            }
            let workflowID = try container.decodeIfPresent(Workflow.self, forKey: .workflow)?.id
            self = .member(memberID: memberID, workflowID: workflowID)
        case "group":
            let entries = try container.decodeIfPresent(Group.self, forKey: .group)?.members ?? []
            self = .group(members: entries.compactMap { entry in
                entry.organizationMemberId.map { GroupMember(memberID: $0, workflowID: entry.workflowId) }
            })
        default:
            self = .other
        }
    }
}

extension Priority {
    init(wire: String?) {
        switch wire {
        case "highest": self = .highest
        case "high": self = .high
        case "normal": self = .normal
        case "low": self = .low
        default: self = .none
        }
    }
}

func parseISO8601(_ text: String) -> Date? {
    (try? Date.ISO8601FormatStyle().parse(text))
        ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
}

extension DoorayTask {
    init(_ post: PostDTO, state: OpenState) throws(DoorayError) {
        // An unreadable deadline is an error, never "no due date": the app must not hide one.
        var dueDate: Date?
        if let raw = post.dueDate {
            guard let parsed = parseISO8601(raw) else { throw .invalidResponse("posts[\(post.id)].dueDate") }
            dueDate = parsed
        }
        guard let updatedAt = parseISO8601(post.updatedAt) else {
            throw .invalidResponse("posts[\(post.id)].updatedAt")
        }
        self.init(
            id: post.id,
            projectID: post.project.id,
            projectCode: post.project.code,
            milestone: post.milestone.map { Milestone(id: $0.id, name: $0.name) },
            number: post.number,
            subject: post.subject,
            priority: Priority(wire: post.priority),
            dueDate: dueDate,
            updatedAt: updatedAt,
            state: state
        )
    }
}

struct Page: Sendable {
    let index: Int
    let size: Int
}

enum Endpoint: Sendable {
    case me
    case projects
    case workflows(ProjectID)
    case milestones(ProjectID)
    case posts(ProjectID, assignee: MemberID)

    /// `base` may carry a path prefix, so the path is appended to it.
    func url(base: URL, page: Page?) -> URL {
        let path: String
        var query: [URLQueryItem] = []
        switch self {
        case .me:
            path = "common/v1/members/me"
        case .projects:
            path = "project/v1/projects"
            query.append(URLQueryItem(name: "member", value: "me"))
        case .workflows(let project):
            path = "project/v1/projects/\(project)/workflows"
        case .milestones(let project):
            path = "project/v1/projects/\(project)/milestones"
        case .posts(let project, let assignee):
            path = "project/v1/projects/\(project)/posts"
            query.append(URLQueryItem(name: "toMemberIds", value: assignee))
            query.append(URLQueryItem(name: "postWorkflowClasses", value: "registered,working"))
        }
        if let page {
            query.append(URLQueryItem(name: "page", value: String(page.index)))
            query.append(URLQueryItem(name: "size", value: String(page.size)))
        }
        let url = base.appending(path: path)
        return query.isEmpty ? url : url.appending(queryItems: query)
    }
}
