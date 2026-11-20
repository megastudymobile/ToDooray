import Foundation
import Testing
@testable import DooraySync

@Suite struct ScenarioTests {
    @Test(arguments: try Scenario.all())
    func scenario(_ scenario: Scenario) async throws {
        let harness = ScenarioHarness(scenario)
        var result: Result<OpenTasks, DoorayError> = .success(OpenTasks(tasks: [], projects: []))
        for _ in 0..<scenario.runs {
            result = await harness.fetch()
        }

        let expectation = scenario.expectation
        if let expectedError = expectation.error {
            #expect(throws: DoorayError.self) { try result.get() }
            if case .failure(let error) = result {
                #expect(error.name == expectedError)
            }
        } else {
            let expectedTasks = try #require(expectation.tasks)
            let open = try result.get()
            #expect(harness.ordered(open.tasks) == expectedTasks)
            if let expectedProjects = expectation.projects {
                #expect(open.projects.map { Scenario.ExpectedProject(id: $0.id, code: $0.code) } == expectedProjects)
            }
        }
        for (path, count) in expectation.requestCounts ?? [:] {
            #expect(await harness.transport.count(path: path) == count, "requests to \(path)")
        }

        for (projectID, expected) in expectation.milestones ?? [:] {
            switch await harness.fetchMilestones(projectID) {
            case .success(let milestones):
                #expect(milestones.map { Scenario.ExpectedMilestone(id: $0.id, name: $0.name) } == expected.milestones)
            case .failure(let error):
                #expect(error.name == expected.error, "milestones of \(projectID)")
            }
        }
        #expect(await harness.transport.unmatched.isEmpty)

        let maxInFlight = await harness.transport.maxInFlight
        #expect(maxInFlight <= SyncPolicy.standard.maxConcurrentRequests)
        if let bound = expectation.maxConcurrentRequests {
            #expect(maxInFlight == bound)
        }
    }

    @Test func postsCarryTheirMilestoneOrNone() async throws {
        let tasks = try await ScenarioHarness(try Scenario.named("basic")).fetch().get().tasks
        let milestones = Dictionary(uniqueKeysWithValues: tasks.map { ($0.key, $0.milestone) })
        #expect(milestones["APP-88"] == Milestone(id: "7000000000000000001", name: "v1.0.0"))
        #expect(milestones["APP-97"] == Milestone(id: "7000000000000000002", name: "v1.0.1"))
        #expect(milestones["APP-99"] == .some(nil))
        #expect(milestones["FE-1203"] == .some(nil))
    }

    @Test func rateLimitWaitsRetryAfterThenBacksOff() async throws {
        let harness = ScenarioHarness(try Scenario.named("rate-limited"), maxConcurrentRequests: 1)
        _ = try await harness.fetch().get()
        #expect(harness.clock.sleeps == [2, 2])
    }

    @Test func rateLimitGivesUpAfterTheBackoffSchedule() async throws {
        let harness = ScenarioHarness(try Scenario.named("rate-limited-exhausted"))
        #expect(await harness.fetch() == .failure(.rateLimited))
        #expect(harness.clock.sleeps == [1, 2, 4, 8])
    }

    @Test func workflowTableIsReusedUntilSixHoursOld() async throws {
        let harness = ScenarioHarness(try Scenario.named("project-forbidden"))
        let workflows = "/project/v1/projects/3000000000000000003/workflows"

        _ = try await harness.fetch().get()
        #expect(await harness.transport.count(path: workflows) == 1)

        harness.clock.advance(by: 5 * 3600)
        _ = try await harness.fetch().get()
        #expect(await harness.transport.count(path: workflows) == 1)

        harness.clock.advance(by: 2 * 3600)
        _ = try await harness.fetch().get()
        #expect(await harness.transport.count(path: workflows) == 2)
    }

    @Test func cancelledSyncLeavesTheClientUsable() async throws {
        let harness = ScenarioHarness(try Scenario.named("many-projects"))
        let sync = Task { await harness.fetch() }
        try await Task.sleep(for: .milliseconds(20))
        sync.cancel()
        #expect(await sync.value == .failure(.cancelled))

        let tasks = try await harness.fetch().get().tasks
        #expect(tasks.count == harness.scenario.expectation.tasks?.count)
    }
}
