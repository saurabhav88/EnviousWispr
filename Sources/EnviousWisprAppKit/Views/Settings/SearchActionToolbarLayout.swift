import SwiftUI

/// Reflows the toolbar for `SnippetsView` and `CustomTermsSection` between one inline row and
/// search-above-actions when `minSearchWidth + gap + actionsIdealWidth > width`.
///
/// Scoped helper for those two pages (not a `DESIGN.md` Approved part). The trailing subview is
/// expected to be an unmodified `WrappingHStack` holding `.fixedSize()` action buttons.
struct SearchActionToolbarLayout: Layout {
  /// Minimum search field width required before keeping the search field inline with actions.
  let minSearchWidth: CGFloat

  private static let gap: CGFloat = 10

  private struct Arrangement {
    let totalSize: CGSize
    let searchWidth: CGFloat
    let actionsWidth: CGFloat
    let isInline: Bool
    let hasActions: Bool
    let searchHeight: CGFloat
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    arrangement(for: proposal.width, subviews: subviews).totalSize
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    guard let search = subviews.first else { return }
    let plan = arrangement(for: bounds.width, subviews: subviews)

    guard plan.hasActions, subviews.count > 1 else {
      search.place(
        at: bounds.origin,
        anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: nil))
      if subviews.count > 1 {
        subviews[1].place(
          at: bounds.origin,
          anchor: .topLeading,
          proposal: .zero)
      }
      return
    }

    let actions = subviews[1]
    if plan.isInline {
      let midY = bounds.minY + plan.totalSize.height / 2
      search.place(
        at: CGPoint(x: bounds.minX, y: midY),
        anchor: .leading,
        proposal: ProposedViewSize(width: plan.searchWidth, height: nil))
      actions.place(
        at: CGPoint(x: bounds.minX + plan.searchWidth + Self.gap, y: midY),
        anchor: .leading,
        proposal: ProposedViewSize(width: plan.actionsWidth, height: nil))
    } else {
      search.place(
        at: bounds.origin,
        anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: nil))
      actions.place(
        at: CGPoint(x: bounds.minX, y: bounds.minY + plan.searchHeight + Self.gap),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
  }

  private func arrangement(for proposedWidth: CGFloat?, subviews: Subviews) -> Arrangement {
    guard let search = subviews.first else {
      return Arrangement(
        totalSize: .zero,
        searchWidth: 0,
        actionsWidth: 0,
        isInline: true,
        hasActions: false,
        searchHeight: 0)
    }

    let actionsIdeal = subviews.count > 1 ? subviews[1].sizeThatFits(.unspecified) : .zero
    let hasActions = subviews.count > 1 && actionsIdeal.width > 0 && actionsIdeal.height > 0

    guard hasActions else {
      let width = proposedWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? minSearchWidth
      let searchHeight = search.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
      return Arrangement(
        totalSize: CGSize(width: width, height: searchHeight),
        searchWidth: width,
        actionsWidth: 0,
        isInline: true,
        hasActions: false,
        searchHeight: searchHeight)
    }

    let actions = subviews[1]
    guard let rawWidth = proposedWidth, rawWidth.isFinite else {
      let searchHeight = search.sizeThatFits(ProposedViewSize(width: minSearchWidth, height: nil)).height
      return Arrangement(
        totalSize: CGSize(
          width: minSearchWidth + Self.gap + actionsIdeal.width,
          height: max(searchHeight, actionsIdeal.height)),
        searchWidth: minSearchWidth,
        actionsWidth: actionsIdeal.width,
        isInline: true,
        hasActions: true,
        searchHeight: searchHeight)
    }

    let actionsMinWidth = actions.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
    let width = rawWidth > 0 ? max(rawWidth, actionsMinWidth) : max(minSearchWidth, actionsMinWidth)

    if minSearchWidth + Self.gap + actionsIdeal.width <= width {
      let searchWidth = width - Self.gap - actionsIdeal.width
      let searchHeight = search.sizeThatFits(ProposedViewSize(width: searchWidth, height: nil)).height
      let actionsSize = actions.sizeThatFits(ProposedViewSize(width: actionsIdeal.width, height: nil))
      return Arrangement(
        totalSize: CGSize(width: width, height: max(searchHeight, actionsSize.height)),
        searchWidth: searchWidth,
        actionsWidth: actionsIdeal.width,
        isInline: true,
        hasActions: true,
        searchHeight: searchHeight)
    } else {
      let searchHeight = search.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
      let actionsSize = actions.sizeThatFits(ProposedViewSize(width: width, height: nil))
      return Arrangement(
        totalSize: CGSize(width: width, height: searchHeight + Self.gap + actionsSize.height),
        searchWidth: width,
        actionsWidth: width,
        isInline: false,
        hasActions: true,
        searchHeight: searchHeight)
    }
  }
}
