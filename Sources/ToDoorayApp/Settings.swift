import DooraySync
import Foundation

/// Launch at login is not here. Its truth lives in the system's login item list.
struct Settings: Equatable {
    var apiBase: URL
    /// Tenant web address for links. nil until the user sets it.
    var webBase: URL?
    var token: APIToken?

    static let defaultAPIBase = URL(string: "https://api.dooray.com")!
    static let empty = Settings(apiBase: defaultAPIBase, webBase: nil, token: nil)

    var isComplete: Bool { token != nil && webBase != nil }

    /// `https`, or `http` to a loopback host only, so a token can never travel to a remote
    /// host in clear text. A path prefix is kept. Query, fragment and trailing slash are dropped.
    static func parseAPIBase(_ text: String) -> URL? {
        guard var components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host, !host.isEmpty else { return nil }
        let loopback = ["127.0.0.1", "[::1]", "localhost"].contains(host.lowercased())
        guard components.scheme == "https" || (components.scheme == "http" && loopback) else { return nil }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.url
    }

    /// Accepts `acme`, `acme.dooray.com` or a full `https` URL. A bare word is a tenant name
    /// under dooray.com. Only the origin is kept.
    static func parseWebBase(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.wholeMatch(of: /[A-Za-z0-9-]+/) != nil { text += ".dooray.com" }
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text), components.scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        origin.port = components.port
        return origin.url
    }
}

struct SettingsDraft: Equatable {
    /// Empty keeps the stored token.
    var token = ""
    var webAddress = ""
    var apiBase = Settings.defaultAPIBase.absoluteString

    enum Problem: Error, Equatable {
        case tokenMissing
        case tokenMalformed
        case webAddressInvalid
        case apiBaseInvalid
    }

    /// A successful result is always complete.
    func validated(keeping current: Settings) -> Result<Settings, Problem> {
        let newToken: APIToken
        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let stored = current.token else { return .failure(.tokenMissing) }
            newToken = stored
        } else {
            guard let parsed = APIToken(token) else { return .failure(.tokenMalformed) }
            newToken = parsed
        }
        guard let webBase = Settings.parseWebBase(webAddress) else { return .failure(.webAddressInvalid) }
        guard let apiBase = Settings.parseAPIBase(apiBase) else { return .failure(.apiBaseInvalid) }
        return .success(Settings(apiBase: apiBase, webBase: webBase, token: newToken))
    }
}
