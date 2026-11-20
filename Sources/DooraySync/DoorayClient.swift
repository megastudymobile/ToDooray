import Foundation
import os

/// The whole Dooray contract behind one call.
///
///     let client = DoorayClient(apiBase: apiBase, token: token)
///     let tasks = try await client.fetchOpenTasks()
///     let items = Agenda.items(tasks, now: .now, calendar: .current)
///
/// One instance per (apiBase, token). The cached member id and workflow tables belong to
/// that identity, so a change to either needs a new client.
public actor DoorayClient {
    private let apiBase: URL
    private let token: APIToken
    private let transport: any HTTPTransport
    private let policy: SyncPolicy
    private let log = Logger(subsystem: "ToDooray", category: "sync")

    private var memberID: MemberID?
    private var workflowTables: [ProjectID: WorkflowTable] = [:]
    /// When any request sees 429, every request waits until this instant.
    private var resumeAt: Date?

    public init(apiBase: URL, token: APIToken) {
        self.init(apiBase: apiBase, token: token, transport: URLSessionTransport(), policy: .standard)
    }

    init(apiBase: URL, token: APIToken, transport: any HTTPTransport, policy: SyncPolicy) {
        self.apiBase = apiBase
        self.token = token
        self.transport = transport
        self.policy = policy
    }

    /// Every task assigned to me whose per-assignee workflow class is registered or working.
    /// The order is unspecified. Use `Agenda.items` to order it.
    ///
    /// All or nothing, with one exception: a project that answers 403 or 404 is skipped.
    /// Any other failure throws, so the caller keeps its previous list instead of showing
    /// a shorter one that looks complete.
    public func fetchOpenTasks() async throws(DoorayError) -> [DoorayTask] {
        let me = try await member()
        let listed: [ProjectDTO] = try await allPages(.projects)
        var seenProjects = Set<ProjectID>()
        let projects = listed.filter { seenProjects.insert($0.id).inserted }

        let perProject = try await boundedMap(projects, width: policy.maxConcurrentRequests) {
            (project: ProjectDTO) async throws(DoorayError) -> [DoorayTask]? in
            try await self.openTasks(in: project, me: me)
        }

        var seenTasks = Set<String>()
        return perProject.compactMap { $0 }.joined().filter { seenTasks.insert($0.id).inserted }
    }

    private func member() async throws(DoorayError) -> MemberID {
        if let memberID { return memberID }
        let me: MemberDTO = try await one(.me)
        memberID = me.id
        return me.id
    }

    /// nil when the project answers 403 or 404.
    private func openTasks(in project: ProjectDTO, me: MemberID) async throws(DoorayError) -> [DoorayTask]? {
        do {
            var (table, fresh) = try await workflowTable(for: project.id, forceRefresh: false)
            let posts: [PostDTO] = try await allPages(.posts(project.id, assignee: me))
            // A workflow added after the table was cached would otherwise fall back to rule 4
            // and misjudge my state.
            if !fresh, posts.contains(where: { Selection.referencesUnknownWorkflow($0, me: me, in: table) }) {
                (table, fresh) = try await workflowTable(for: project.id, forceRefresh: true)
            }
            var tasks: [DoorayTask] = []
            for post in posts {
                if let state = Selection.openState(of: post, me: me, in: table) {
                    tasks.append(try DoorayTask(post, state: state))
                }
            }
            return tasks
        } catch {
            guard case .http(let status) = error, status == 403 || status == 404 else { throw error }
            log.notice("skipping project \(project.code, privacy: .public): HTTP \(status)")
            return nil
        }
    }

    /// `fresh` is true when this call fetched the table, so a missing id is real and not staleness.
    private func workflowTable(
        for project: ProjectID,
        forceRefresh: Bool
    ) async throws(DoorayError) -> (table: WorkflowTable, fresh: Bool) {
        if !forceRefresh, let cached = workflowTables[project],
           policy.now().timeIntervalSince(cached.fetchedAt) < policy.workflowTTL {
            return (cached, false)
        }
        let rows: [WorkflowDTO] = try await one(.workflows(project))
        let classes = rows.reduce(into: [WorkflowID: WorkflowClass]()) { classes, row in
            classes[row.id] = row.workflowClass
        }
        let table = WorkflowTable(classes: classes, fetchedAt: policy.now())
        workflowTables[project] = table
        return (table, true)
    }

    /// Stops at `totalCount`, at an empty page, or at `policy.maxPages`, so a wrong or shifting
    /// `totalCount` cannot loop forever. Callers dedupe by id.
    private func allPages<Item: Decodable & Sendable>(_ endpoint: Endpoint) async throws(DoorayError) -> [Item] {
        var items: [Item] = []
        for index in 0..<policy.maxPages {
            let envelope: Envelope<[Item]> = try await send(endpoint, page: Page(index: index, size: policy.pageSize))
            let batch = envelope.result ?? []
            items += batch
            if batch.isEmpty { break }
            if let totalCount = envelope.totalCount {
                if items.count >= totalCount { break }
            } else if batch.count < policy.pageSize {
                break
            }
        }
        return items
    }

    private func one<Item: Decodable & Sendable>(_ endpoint: Endpoint) async throws(DoorayError) -> Item {
        let envelope: Envelope<Item> = try await send(endpoint, page: nil)
        guard let result = envelope.result else { throw .invalidResponse("result") }
        return result
    }

    private func send<Payload: Decodable>(_ endpoint: Endpoint, page: Page?) async throws(DoorayError) -> Envelope<Payload> {
        let request = HTTPRequest(
            url: endpoint.url(base: apiBase, page: page),
            headers: ["Authorization": "dooray-api \(token.reveal())", "Accept": "application/json"]
        )
        for attempt in 0...policy.maxRateLimitRetries {
            try await waitForGate()
            let response = try await perform(request)
            switch response.status {
            case 200..<300:
                return try decodeEnvelope(response.body)
            case 401:
                throw .unauthorized
            case 429:
                let delay = retryAfter(response.headers) ?? policy.backoff(attempt)
                resumeAt = max(resumeAt ?? .distantPast, policy.now().addingTimeInterval(delay))
            default:
                throw .http(status: response.status)
            }
        }
        throw .rateLimited
    }

    private func waitForGate() async throws(DoorayError) {
        while let resumeAt, resumeAt > policy.now() {
            do {
                try await policy.sleep(resumeAt.timeIntervalSince(policy.now()))
            } catch {
                throw .cancelled
            }
        }
        if Task.isCancelled { throw .cancelled }
    }

    private func perform(_ request: HTTPRequest) async throws(DoorayError) -> HTTPResponse {
        do {
            return try await transport.get(request)
        } catch let error as URLError {
            throw error.code == .cancelled ? .cancelled : .network(error.code)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network(.unknown)
        }
    }
}

private func decodeEnvelope<Payload: Decodable>(_ body: Data) throws(DoorayError) -> Envelope<Payload> {
    do {
        let decoder = JSONDecoder()
        let header = try decoder.decode(EnvelopeStatus.self, from: body).header
        guard header.isSuccessful else {
            throw DoorayError.api(code: header.resultCode, message: header.resultMessage)
        }
        return try decoder.decode(Envelope<Payload>.self, from: body)
    } catch let error as DoorayError {
        throw error
    } catch let error as DecodingError {
        throw .invalidResponse(codingPath(of: error))
    } catch {
        throw .invalidResponse("body")
    }
}

private func codingPath(of error: DecodingError) -> String {
    let path: [any CodingKey]
    switch error {
    case .keyNotFound(let key, let context): path = context.codingPath + [key]
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context): path = context.codingPath
    @unknown default: path = []
    }
    return path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
}

/// Runs `transform` over `items` with at most `width` in flight, as a sliding window.
/// Output keeps input order. The first failure cancels the rest.
func boundedMap<Item: Sendable, Output: Sendable>(
    _ items: [Item],
    width: Int,
    _ transform: @escaping @Sendable (Item) async throws(DoorayError) -> Output
) async throws(DoorayError) -> [Output] {
    let outcome = await withTaskGroup(of: (Int, Result<Output, DoorayError>).self) { group -> Result<[Output], DoorayError> in
        var outputs = [Output?](repeating: nil, count: items.count)
        var nextIndex = 0

        func startNext() {
            guard nextIndex < items.count else { return }
            let index = nextIndex
            let item = items[index]
            nextIndex += 1
            group.addTask {
                do throws(DoorayError) {
                    return (index, .success(try await transform(item)))
                } catch {
                    return (index, .failure(error))
                }
            }
        }

        for _ in 0..<min(width, items.count) { startNext() }
        while let (index, result) = await group.next() {
            switch result {
            case .success(let output):
                outputs[index] = output
                startNext()
            case .failure(let error):
                group.cancelAll()
                return .failure(error)
            }
        }
        return .success(outputs.compactMap { $0 })
    }
    return try outcome.get()
}
