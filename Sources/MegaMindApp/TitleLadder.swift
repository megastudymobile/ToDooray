import CoreGraphics
import Foundation

/// Picks how much of the menu bar title to show: full text, the count, or the icon alone.
///
/// macOS silently hides a status item that does not fit, and a hidden item cannot be clicked.
/// There is no API for the room left, so the only signal is trial: show a form, then observe
/// whether the item survived. The ladder remembers what failed so the title does not flicker
/// back every minute.
struct TitleLadder: Equatable {
    enum Form: String, Equatable {
        case full, compact, iconOnly
    }

    /// The narrowest full title that was observed hidden. A title that wide is never shown
    /// in full again, so each new failure is narrower than the last.
    private var hiddenFullWidth: CGFloat?
    private var compactWasHidden = false
    private var fullWidth: CGFloat = 0

    var form: Form {
        if let hiddenFullWidth, fullWidth >= hiddenFullWidth {
            return compactWasHidden ? .iconOnly : .compact
        }
        return .full
    }

    mutating func titleChanged(fullWidth: CGFloat) {
        self.fullWidth = fullWidth
    }

    /// The item was found off screen while showing `form`.
    mutating func itemWasHidden() {
        switch form {
        case .full: hiddenFullWidth = fullWidth
        case .compact: compactWasHidden = true
        case .iconOnly: break
        }
    }

    /// The menu bar may have more room now, so every form gets a new chance.
    mutating func environmentChanged() {
        hiddenFullWidth = nil
        compactWasHidden = false
    }
}
