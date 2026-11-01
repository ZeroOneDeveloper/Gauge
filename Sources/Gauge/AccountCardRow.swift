import SwiftUI

/// Measure both cards at the same column width, then give them the tallest card's height.
/// Each row grows with its content, including provider-specific limits and errors.
struct AccountCardRow: Layout {
    var spacing: CGFloat = 20

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 800
        let columnWidth = max(0, (width - spacing) / 2)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columnWidth = max(0, (bounds.width - spacing) / 2)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (columnWidth + spacing), y: bounds.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(width: columnWidth, height: bounds.height))
        }
    }
}
