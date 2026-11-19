import Foundation

/// A Dooray personal API token. Every textual rendering is redacted, so interpolation,
/// `print`, `dump` and logging cannot leak it. `reveal()` is the only way back to the secret.
public struct APIToken: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let secret: String

    /// nil when empty after trimming, or when whitespace or a control character remains inside.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: forbidden) == nil else { return nil }
        secret = trimmed
    }

    public func reveal() -> String { secret }

    public var description: String { "APIToken(•••)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
