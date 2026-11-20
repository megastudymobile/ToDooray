import Foundation
@testable import DooraySync

/// Fixtures are read by path, not as SwiftPM resources, so the mock server and other
/// platforms read the same files.
let fixturesRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "fixtures")

/// One directory under fixtures/scenarios. The format is in fixtures/README.md.
struct Scenario: Sendable, CustomStringConvertible {
    let name: String
    let now: Date
    let timeZone: TimeZone
    let token: String
    let pageSize: Int?
    let runs: Int
    let routes: [Route]
    let expectation: Expectation

    struct Route: Sendable {
        let path: String
        let query: [String: String]
        let responses: [CannedResponse]
    }

    struct CannedResponse: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
        let delay: TimeInterval
    }

    struct Expectation: Decodable, Sendable {
        let tasks: [ExpectedTask]?
        let projects: [ExpectedProject]?
        let error: String?
        let requestCounts: [String: Int]?
        let maxConcurrentRequests: Int?
        /// Keyed by project id. Each call runs after the sync.
        let milestones: [String: ExpectedMilestones]?
    }

    struct ExpectedProject: Decodable, Sendable, Equatable {
        let id: String
        let code: String
    }

    struct ExpectedMilestones: Decodable, Sendable {
        let milestones: [ExpectedMilestone]?
        let error: String?
    }

    struct ExpectedMilestone: Decodable, Sendable, Equatable {
        let id: String
        let name: String
    }

    struct ExpectedTask: Decodable, Sendable, Equatable {
        let id: String
        let key: String
        let urgency: String
        let state: String
    }

    var description: String { name }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func all() throws -> [Scenario] {
        let root = fixturesRoot.appending(path: "scenarios")
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { try Scenario(directory: root.appending(path: $0)) }
    }

    static func named(_ name: String) throws -> Scenario {
        try Scenario(directory: fixturesRoot.appending(path: "scenarios").appending(path: name))
    }

    private struct File: Decodable {
        let now: String
        let timeZone: String
        let token: String
        let pageSize: Int?
        let runs: Int?
        let requests: [FileRoute]
        let expect: String
    }

    private struct FileRoute: Decodable {
        let path: String
        let query: [String: String]?
        let responses: [FileResponse]
    }

    private struct FileResponse: Decodable {
        let status: Int
        let headers: [String: String]?
        let body: String?
        let delayMs: Int?
    }

    private struct Malformed: Error {
        let reason: String
    }

    init(directory: URL) throws {
        let decoder = JSONDecoder()
        let file = try decoder.decode(File.self, from: Data(contentsOf: directory.appending(path: "scenario.json")))
        guard let now = parseISO8601(file.now) else { throw Malformed(reason: "now") }
        guard let timeZone = TimeZone(identifier: file.timeZone) else { throw Malformed(reason: "timeZone") }
        name = directory.lastPathComponent
        self.now = now
        self.timeZone = timeZone
        token = file.token
        pageSize = file.pageSize
        runs = file.runs ?? 1
        routes = try file.requests.map { route in
            Route(
                path: route.path,
                query: route.query ?? [:],
                responses: try route.responses.map { response in
                    CannedResponse(
                        status: response.status,
                        headers: response.headers ?? [:],
                        body: try response.body.map { try Data(contentsOf: directory.appending(path: $0)) } ?? Data(),
                        delay: TimeInterval(response.delayMs ?? 0) / 1000
                    )
                }
            )
        }
        expectation = try decoder.decode(
            Expectation.self,
            from: Data(contentsOf: directory.appending(path: file.expect))
        )
    }
}

/// Serves a scenario in process with the same matching rules as tools/mock-dooray/server.py.
actor FixtureTransport: HTTPTransport {
    private let scenario: Scenario
    private var hits: [Int: Int] = [:]
    private var inFlight = 0
    private(set) var requests: [HTTPRequest] = []
    private(set) var unmatched: [HTTPRequest] = []
    private(set) var maxInFlight = 0

    init(_ scenario: Scenario) {
        self.scenario = scenario
    }

    func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        requests.append(request)

        guard request.headers["Authorization"] == "dooray-api \(scenario.token)" else {
            return HTTPResponse(status: 401, headers: [:], body: Data())
        }
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        let query = Dictionary(
            (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        guard let index = scenario.routes.firstIndex(where: { $0.path == components?.path && $0.query == query }) else {
            unmatched.append(request)
            return HTTPResponse(status: 599, headers: [:], body: Data())
        }
        let responses = scenario.routes[index].responses
        let response = responses[min(hits[index, default: 0], responses.count - 1)]
        hits[index, default: 0] += 1
        if response.delay > 0 {
            try await Task.sleep(for: .seconds(response.delay))
        }
        let headers = Dictionary(uniqueKeysWithValues: response.headers.map { ($0.key.lowercased(), $0.value) })
        return HTTPResponse(status: response.status, headers: headers, body: response.body)
    }

    func count(path: String) -> Int {
        requests.count { $0.url.path == path }
    }
}

/// A clock that only moves when the client sleeps or a test advances it.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var recorded: [TimeInterval] = []

    init(now: Date) {
        current = now
    }

    var now: Date { lock.withLock { current } }
    var sleeps: [TimeInterval] { lock.withLock { recorded } }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }

    func sleep(_ interval: TimeInterval) {
        lock.withLock {
            recorded.append(interval)
            current = current.addingTimeInterval(interval)
        }
    }
}

/// A client wired to one scenario, with the handles a test asserts on.
struct ScenarioHarness {
    let scenario: Scenario
    let transport: FixtureTransport
    let clock: TestClock
    let client: DoorayClient

    init(_ scenario: Scenario, maxConcurrentRequests: Int = SyncPolicy.standard.maxConcurrentRequests) {
        let clock = TestClock(now: scenario.now)
        let transport = FixtureTransport(scenario)
        var policy = SyncPolicy.standard
        policy.pageSize = scenario.pageSize ?? policy.pageSize
        policy.maxConcurrentRequests = maxConcurrentRequests
        policy.sleep = { clock.sleep($0) }
        policy.now = { clock.now }
        self.scenario = scenario
        self.transport = transport
        self.clock = clock
        client = DoorayClient(
            apiBase: URL(string: "https://api.test")!,
            token: APIToken(scenario.token)!,
            transport: transport,
            policy: policy
        )
    }

    func fetch() async -> Result<OpenTasks, DoorayError> {
        do {
            return .success(try await client.fetchOpenTasks())
        } catch {
            return .failure(error)
        }
    }

    func fetchMilestones(_ projectID: String) async -> Result<[Milestone], DoorayError> {
        do {
            return .success(try await client.fetchMilestones(projectID: projectID))
        } catch {
            return .failure(error)
        }
    }

    func ordered(_ tasks: [DoorayTask]) -> [Scenario.ExpectedTask] {
        Agenda.items(tasks, now: scenario.now, calendar: scenario.calendar).map {
            Scenario.ExpectedTask(id: $0.task.id, key: $0.task.key, urgency: $0.urgency.name, state: $0.task.state.rawValue)
        }
    }
}
