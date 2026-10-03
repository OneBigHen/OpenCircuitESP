// Width-driven layout for foldables and iPads.
//
// Closed (a normal iPhone-width window) the app keeps its single, calm column: `AdaptiveColumns`
// with one column is the same stack the screens used before — same spacing, same centring.
// Open (a wide window — an unfolded phone, an iPad, a split view) the same cards flow into two
// columns instead of stretching edge to edge.
//
// It keys off the width the layout is PROPOSED, not the device idiom or a size class: the fold
// posture, rotation, Split View and Stage Manager all just change that width, and the layout
// follows with no per-device branching.
//
// Pure layout, no state, safe to use anywhere a `VStack(spacing: Theme.sectionSpacing)` was.

import SwiftUI

/// Marks a child that spans every column (section headers, pickers, charts that want the width).
private struct SpansColumnsKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Make this child take the full width of an enclosing `AdaptiveColumns` (a no-op elsewhere).
    func spansColumns(_ spans: Bool = true) -> some View {
        layoutValue(key: SpansColumnsKey.self, value: spans)
    }
}

/// A vertical stack that becomes a short-column ("masonry") flow when it has the room.
struct AdaptiveColumns: Layout {
    var spacing: CGFloat = Theme.sectionSpacing
    /// Narrowest a column may get. Two columns need `2 × this + spacing` of width, so a phone
    /// (closed foldable included, ≤ ~440pt wide) always stays at one column.
    var minColumnWidth: CGFloat = 310
    var maxColumns: Int = 2

    private struct Placement { var midX: CGFloat; var y: CGFloat; var width: CGFloat; var height: CGFloat }
    private struct Plan { var placements: [Int: Placement]; var height: CGFloat }

    private func columnCount(for width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return max(1, min(maxColumns, Int(((width + spacing) / (minColumnWidth + spacing)).rounded(.down))))
    }

    private func plan(width: CGFloat, subviews: Subviews) -> Plan {
        let cols = columnCount(for: width)
        let colWidth = (width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        var bottoms = [CGFloat](repeating: 0, count: cols)
        var used = [Bool](repeating: false, count: cols)
        var placements: [Int: Placement] = [:]

        func nextY(_ c: Int) -> CGFloat { used[c] ? bottoms[c] + spacing : 0 }

        for (i, sv) in subviews.enumerated() {
            if cols == 1 || sv[SpansColumnsKey.self] {
                let size = sv.sizeThatFits(ProposedViewSize(width: width, height: nil))
                if size.height <= 0 { continue }        // renders nothing: no gap (EmptyView-alike)
                let y = (0..<cols).map(nextY).max() ?? 0
                placements[i] = Placement(midX: width / 2, y: y, width: width, height: size.height)
                for c in 0..<cols { bottoms[c] = y + size.height; used[c] = true }
            } else {
                let size = sv.sizeThatFits(ProposedViewSize(width: colWidth, height: nil))
                if size.height <= 0 { continue }
                let c = (0..<cols).min { nextY($0) < nextY($1) } ?? 0
                let y = nextY(c)
                placements[i] = Placement(midX: CGFloat(c) * (colWidth + spacing) + colWidth / 2,
                                          y: y, width: colWidth, height: size.height)
                bottoms[c] = y + size.height; used[c] = true
            }
        }
        let height = zip(bottoms, used).filter { $0.1 }.map { $0.0 }.max() ?? 0
        return Plan(placements: placements, height: height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        guard width.isFinite, width > 0 else {
            // Unspecified/ideal width: behave like a plain stack.
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }.filter { $0.height > 0 }
            let h = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
            return CGSize(width: sizes.map(\.width).max() ?? 0, height: h)
        }
        return CGSize(width: width, height: plan(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = plan(width: bounds.width, subviews: subviews)
        for (i, sv) in subviews.enumerated() {
            guard let p = plan.placements[i] else { continue }
            sv.place(at: CGPoint(x: bounds.minX + p.midX, y: bounds.minY + p.y), anchor: .top,
                     proposal: ProposedViewSize(width: p.width, height: nil))
        }
    }
}

// MARK: - Readable width / adaptive tab bar

extension View {
    /// Keep a full-bleed scroller (a `List`) at a comfortable reading width and centre it on the
    /// page background when the window is wider than `maxWidth`. A no-op at phone widths, so the
    /// closed layout is untouched.
    func readableWidth(_ maxWidth: CGFloat = 700) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
            .background(Theme.pageBackground)
    }

    /// iPadOS 18+/wide windows: let the bottom tab bar become the top bar / sidebar. Phone widths
    /// still get the standard bottom tab bar, and iOS 17 keeps it everywhere.
    @ViewBuilder
    func adaptiveTabBar() -> some View {
        if #available(iOS 18.0, *) {
            self.tabViewStyle(.sidebarAdaptable)
        } else {
            self
        }
    }
}
