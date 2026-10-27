import SwiftUI

/// Measures each cell at its column's final width before assigning row heights. A horizontal
/// scroller proposes no width, so a Grid's initial single-line heights cannot be reused here.
struct TranscriptTableLayout: Layout {
    let columns: Int
    let maximumColumnWidth: CGFloat
    private let columnSpacing: CGFloat = 18
    private let rowSpacing: CGFloat = 8

    struct Measurements {
        let widths: [CGFloat]
        let heights: [CGFloat]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = measure(subviews)
        return CGSize(
            width: sizes.widths.reduce(0, +) + CGFloat(max(0, sizes.widths.count - 1)) * columnSpacing,
            height: sizes.heights.reduce(0, +) + CGFloat(max(0, sizes.heights.count - 1)) * rowSpacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = measure(subviews)
        guard columns > 0 else { return }
        var y = bounds.minY
        for row in sizes.heights.indices {
            var x = bounds.minX
            for column in sizes.widths.indices {
                let index = row * columns + column
                if subviews.indices.contains(index) {
                    subviews[index].place(
                        at: CGPoint(x: x, y: y), anchor: .topLeading,
                        proposal: ProposedViewSize(width: sizes.widths[column], height: sizes.heights[row])
                    )
                }
                x += sizes.widths[column] + columnSpacing
            }
            y += sizes.heights[row] + rowSpacing
        }
    }

    private func measure(_ subviews: Subviews) -> Measurements {
        guard columns > 0, !subviews.isEmpty else { return Measurements(widths: [], heights: []) }
        var widths = Array(repeating: CGFloat.zero, count: columns)
        for index in subviews.indices {
            let ideal = subviews[index].sizeThatFits(.unspecified).width
            widths[index % columns] = max(widths[index % columns], min(maximumColumnWidth, ideal))
        }
        var heights = Array(repeating: CGFloat.zero, count: (subviews.count + columns - 1) / columns)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: widths[index % columns], height: nil))
            heights[index / columns] = max(heights[index / columns], size.height)
        }
        return Measurements(widths: widths, heights: heights)
    }
}
