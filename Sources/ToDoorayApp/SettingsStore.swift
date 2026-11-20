import DooraySync
import Foundation
import os
import Security

struct KeychainError: Error, Equatable {
    let status: OSStatus
}

/// The only reader and writer of persisted settings. The token lives in the Keychain, and
/// the two addresses and the task filter in UserDefaults. The token never enters
/// UserDefaults or a log line.
@MainActor
final class SettingsStore {
    private enum Backend {
        case system(defaults: UserDefaults, keychainService: String)
        /// Nothing is read from or written to the Keychain or UserDefaults.
        case memory(Settings, TaskFilter)
    }

    private static let account = "dooray-api-token"
    private static let filterKey = "taskFilter"
    private static let log = Logger(subsystem: "ToDooray", category: "settings")
    private var backend: Backend

    init(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) {
        #if DEBUG
        // End-to-end runs pass a fake token here so they can never read or replace a real one.
        if let path = environment["TODOORAY_CONFIG"] {
            let config = Self.config(at: path)
            backend = .memory(config.settings, config.filter)
            return
        }
        #endif
        backend = .system(defaults: .standard, keychainService: bundle.bundleIdentifier ?? "ToDooray")
    }

    func load() -> Settings {
        switch backend {
        case .memory(let settings, _):
            return settings
        case .system(let defaults, let service):
            return Settings(
                apiBase: defaults.string(forKey: "apiBase").flatMap(Settings.parseAPIBase) ?? Settings.defaultAPIBase,
                webBase: defaults.string(forKey: "webBase").flatMap(Settings.parseWebBase),
                token: Self.readToken(service: service)
            )
        }
    }

    func save(_ settings: Settings) throws(KeychainError) {
        switch backend {
        case .memory(_, let filter):
            backend = .memory(settings, filter)
        case .system(let defaults, let service):
            if let token = settings.token {
                try Self.writeToken(token, service: service)
            }
            defaults.set(settings.apiBase.absoluteString, forKey: "apiBase")
            defaults.set(settings.webBase?.absoluteString, forKey: "webBase")
        }
    }

    func loadFilter() -> TaskFilter {
        switch backend {
        case .memory(_, let filter):
            return filter
        case .system(let defaults, _):
            guard let data = defaults.data(forKey: Self.filterKey) else { return .showAll }
            do {
                return try JSONDecoder().decode(TaskFilter.self, from: data)
            } catch {
                Self.log.error("Ignoring an unreadable task filter: \(error)")
                return .showAll
            }
        }
    }

    func saveFilter(_ filter: TaskFilter) {
        switch backend {
        case .memory(let settings, _):
            backend = .memory(settings, filter)
        case .system(let defaults, _):
            defaults.set(try? JSONEncoder().encode(filter), forKey: Self.filterKey)
        }
    }

    private static func itemQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readToken(service: String) -> APIToken? {
        var query = itemQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            if status != errSecSuccess, status != errSecItemNotFound {
                log.error("Keychain read failed with status \(status)")
            }
            return nil
        }
        return APIToken(text)
    }

    private static func writeToken(_ token: APIToken, service: String) throws(KeychainError) {
        let data = Data(token.reveal().utf8)
        let query = itemQuery(service: service)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    #if DEBUG
    private struct ConfigFile: Decodable {
        let apiBase: String?
        let webBase: String?
        let token: String?
        let filter: TaskFilter?
    }

    private static func config(at path: String) -> (settings: Settings, filter: TaskFilter) {
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(ConfigFile.self, from: data) else { return (.empty, .showAll) }
        let settings = Settings(
            apiBase: file.apiBase.flatMap(Settings.parseAPIBase) ?? Settings.defaultAPIBase,
            webBase: file.webBase.flatMap(Settings.parseWebBase),
            token: file.token.flatMap { APIToken($0) }
        )
        return (settings, file.filter ?? .showAll)
    }
    #endif
}
