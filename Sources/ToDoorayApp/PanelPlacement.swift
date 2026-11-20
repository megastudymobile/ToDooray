import CoreGraphics
import Foundation

enum PanelPlacement {
    static let gap: CGFloat = 6
    static let margin: CGFloat = 8

    /// Screen coordinates with the origin at the bottom left. The top edge stays just below
    /// the anchor, so content that grows extends downward. With no anchor, which means the
    /// status item is hidden, the panel goes to the top right of `visibleFrame`.
    static func frame(contentSize: CGSize, anchor: CGRect?, visibleFrame: CGRect) -> CGRect {
        let height = min(contentSize.height, visibleFrame.height - 2 * margin)
        let top = min(anchor?.minY ?? visibleFrame.maxY, visibleFrame.maxY) - gap
        let rightmost = visibleFrame.maxX - contentSize.width - margin
        let ideal = anchor.map { $0.midX - contentSize.width / 2 } ?? rightmost
        let x = max(min(ideal, rightmost), visibleFrame.minX + margin)
        return CGRect(x: x, y: top - height, width: contentSize.width, height: height)
    }
}
