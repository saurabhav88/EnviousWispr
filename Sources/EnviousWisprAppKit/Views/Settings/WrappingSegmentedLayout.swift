import SwiftUI

/// Content-sized bars share a width when space permits; a row can still ask
/// for a smaller width. The child's measured height follows that proposal.
struct SegmentedPickerWidthLayout: Layout {
  let matchedWidth: CGFloat?

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let ideal = subviews[0].sizeThatFits(.unspecified)
    // A width reported while narrow must not hold the bars narrow after resize.
    let width = min(proposal.width ?? .infinity, max(matchedWidth ?? 0, ideal.width))
    let fitted = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
    return CGSize(width: width, height: fitted.height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
  }
}

/// Whole, uncompressed buttons wrap in reading order. The fitting one-line
/// HStack remains the first ViewThatFits candidate, preserving existing bars.
struct WrappingSegmentedLayout: Layout {
  private static let spacing: CGFloat = 4

  private func rows(width: CGFloat, sizes: [CGSize]) -> [[Int]] {
    var rows: [[Int]] = []
    var row: [Int] = []
    var used: CGFloat = 0
    for index in sizes.indices {
      let addition = sizes[index].width + (row.isEmpty ? 0 : Self.spacing)
      if !row.isEmpty && used + addition > width {
        rows.append(row)
        row = []
        used = 0
      }
      used += sizes[index].width + (row.isEmpty ? 0 : Self.spacing)
      row.append(index)
    }
    if !row.isEmpty { rows.append(row) }
    return rows
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let ideal = sizes.map(\.width).reduce(0, +) + Self.spacing * CGFloat(max(0, sizes.count - 1))
    let width = proposal.width ?? ideal
    let rows = rows(width: width, sizes: sizes)
    let height = rows.map { row in row.map { sizes[$0].height }.max() ?? 0 }.reduce(0, +)
      + Self.spacing * CGFloat(max(0, rows.count - 1))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    var y = bounds.minY
    for row in rows(width: bounds.width, sizes: sizes) {
      let height = row.map { sizes[$0].height }.max() ?? 0
      let occupied = row.map { sizes[$0].width }.reduce(0, +) + Self.spacing * CGFloat(row.count - 1)
      let extra = max(0, bounds.width - occupied) / CGFloat(row.count)
      var x = bounds.minX
      for index in row {
        let width = sizes[index].width + extra
        subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
          proposal: ProposedViewSize(width: width, height: height))
        x += width + Self.spacing
      }
      y += height + Self.spacing
    }
  }
}
