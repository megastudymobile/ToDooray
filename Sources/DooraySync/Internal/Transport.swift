import Foundation

struct HTTPRequest: Sendable {
    let url: URL
    let headers: [String: String]
}

struct HTTPResponse: Sendable {
    let status: Int
    /// Lower-cased header names.
    let headers: [String: String]
    let body: Data
}

protocol HTTPTransport: Sendable {
    /// Throws only when there is no response. A non-2xx status is a normal return.
    func get(_ request: HTTPRequest) async throws -> HTTPResponse
}

struct URLSessionTransport: HTTPTransport {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        // Offline should fail fast so the app can mark its list stale.
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (body, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name.lowercased()] = value
            }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: body)
    }
}

struct SyncPolicy: Sendable {
    var pageSize = 100
    var maxPages = 100
    var maxConcurrentRequests = 4
    var maxRateLimitRetries = 4
    var backoff: @Sendable (_ attempt: Int) -> TimeInterval = { attempt in pow(2, Double(attempt)) }
    var workflowTTL: TimeInterval = 6 * 60 * 60
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    var now: @Sendable () -> Date = { Date() }

    static let standard = SyncPolicy()
}

/// The seconds form only. An HTTP-date falls back to the backoff schedule.
func retryAfter(_ headers: [String: String]) -> TimeInterval? {
    guard let raw = headers["retry-after"], let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)), seconds >= 0 else {
        return nil
    }
    return seconds
}
