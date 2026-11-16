import AppKit
import EnviousWisprCore
import SwiftUI

/// #4611: History's list on an `NSTableView`, the AppKit list that Mail and Finder use for long
/// lists of rows with different heights. Each row is the same SwiftUI view the diary always drew,
/// hosted in a reusable cell.
///
/// Why not `LazyVStack`: it forgets the height of a row that leaves the screen and estimates it
/// again when the row comes back, so the content height and the scroll offset keep changing
/// while the reader scrolls (the drift measured in #4609 and #4611 after no card resized).
///
/// **Heights.** A row is measured once, at the list's width, by an off-screen copy of the row
/// before it reaches the screen (an off-screen SwiftUI host runs no appear or task work), and the
/// height is kept for as long as the list lives. A row on screen that changes its own height (Show
/// edits, a notice, a title being edited) reports it, and only that row is measured again.
///
/// **Keeping the reader's place.** Every change that can move rows (a page arriving, a newer
/// page at the top, a height change, a width change) keeps the row at the top of the window and
/// its offset where they were, so nothing the reader is looking at moves.
struct HistoryDiaryTable: NSViewRepresentable {
  /// One row of the list: the newer-page button, a day heading or an item, the older-page button.
  enum RowID: Hashable {
    case newer
    case entry(HistoryDiaryLayout.EntryID)
    case older
  }

  /// Puts `target` at the top of the window once, after the rows that hold it are installed;
  /// `nil` means the top of the list. A new `token` asks again.
  struct Restore: Equatable {
    let token: Int
    let target: HistoryDiaryLayout.EntryID?
  }

  let rows: [RowID]
  let restore: Restore?
  /// True when `rows` are the full answer for the current search, so a restore whose target is
  /// not among them is given up instead of waiting.
  let rowsAreFinal: Bool
  let content: (RowID) -> AnyView
  /// The entry at the top of the window after a scroll by the reader (never a scroll this list
  /// makes itself to keep or restore a place).
  let onScroll: (HistoryDiaryLayout.EntryID?) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let coordinator = context.coordinator
    let table = HistoryTableView()
    table.headerView = nil
    table.style = .plain
    table.backgroundColor = .clear
    table.selectionHighlightStyle = .none
    table.allowsEmptySelection = true
    table.allowsTypeSelect = false
    table.usesAlternatingRowBackgroundColors = false
    table.gridStyleMask = []
    table.intercellSpacing = NSSize(width: 0, height: 12)
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.focusRingType = .none
    let column = NSTableColumn(identifier: Coordinator.columnID)
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)

    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsets(
      top: 0, left: 0, bottom: SettingsLayout.contentBottom, right: 0)
    scroll.documentView = table
    scroll.contentView.postsBoundsChangedNotifications = true
    scroll.postsFrameChangedNotifications = true

    coordinator.attach(table: table, scroll: scroll)
    table.dataSource = coordinator
    table.delegate = coordinator
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.update(
      rows: rows, restore: restore, rowsAreFinal: rowsAreFinal, content: content,
      onScroll: onScroll, environment: context.environment)
  }

  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    coordinator.detach()
  }

  // MARK: - Coordinator

  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let columnID = NSUserInterfaceItemIdentifier("HistoryDiaryColumn")
    static let cellID = NSUserInterfaceItemIdentifier("HistoryDiaryCell")

    private weak var table: NSTableView?
    private weak var scroll: NSScrollView?
    private var observers: [NSObjectProtocol] = []

    private var rows: [RowID] = []
    private var index: [RowID: Int] = [:]
    private var content: (RowID) -> AnyView = { _ in AnyView(EmptyView()) }
    private var onScroll: (HistoryDiaryLayout.EntryID?) -> Void = { _ in }
    private var environment = EnvironmentValues()

    /// Measured heights, kept for the list's life. A height measured at another width still
    /// stands in for the row until the row is measured again at the current width.
    private var heights: [RowID: (height: CGFloat, width: CGFloat)] = [:]
    /// Rows whose height came from their state on screen (Show edits open, a notice). When the
    /// cell is reused, that state is gone, so the row is measured again before it comes back.
    private var heightsFromScreen: Set<RowID> = []
    private var width: CGFloat = 0
    private lazy var sizer = NSHostingView(rootView: HostedRow.empty)

    private var restore: Restore?
    private var appliedRestoreToken: Int?
    private var rowsAreFinal = false
    /// Set while this list moves the window itself, so the move is not reported as the reader's.
    private var isMovingWindow = false
    private var verifyScheduled = false
    /// Set while the table inserts or removes rows: AppKit can scroll mid-change, when its row
    /// count and `rows` disagree, so the window is not measured until the change is applied
    /// (the update settles right after).
    private var isApplyingRows = false
    /// #4611: the reader is dragging the scroll bar. While the knob is held, the list never moves
    /// the window itself (the knob would leave the pointer) and measures only the rows on screen;
    /// it measures around the window and settles when the knob is let go.
    private var isDraggingKnob = false
    #if DEBUG
      private var listener = ScrollListener()
    #endif

    func attach(table: NSTableView, scroll: NSScrollView) {
      self.table = table
      self.scroll = scroll
      sizer.sizingOptions = [.intrinsicContentSize]
      let center = NotificationCenter.default
      observers.append(
        center.addObserver(
          forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.windowMoved() } })
      observers.append(
        center.addObserver(
          forName: NSView.frameDidChangeNotification, object: scroll, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.frameChanged() } })
      observers.append(
        center.addObserver(
          forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.liveScrollStarted() } })
      observers.append(
        center.addObserver(
          forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.liveScrollEnded() } })
      // The column takes its new width after the scroll view's frame changes.
      observers.append(
        center.addObserver(
          forName: NSTableView.columnDidResizeNotification, object: table, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.frameChanged() } })
    }

    /// A live scroll that starts with the mouse button down is a scroll bar drag; a trackpad or
    /// wheel scroll keeps measuring ahead of the window so rows arrive at their real height.
    private func liveScrollStarted() {
      isDraggingKnob = NSEvent.pressedMouseButtons & 1 != 0
      #if DEBUG
        listener.begin(knob: isDraggingKnob, rows: rows.count)
      #endif
    }

    private func liveScrollEnded() {
      let wasDragging = isDraggingKnob
      isDraggingKnob = false
      #if DEBUG
        listener.end(rows: rows.count)
      #endif
      if wasDragging { settle(keeping: captureAnchor()) }
    }

    func detach() {
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
    }

    func update(
      rows newRows: [RowID], restore: Restore?, rowsAreFinal: Bool,
      content: @escaping (RowID) -> AnyView,
      onScroll: @escaping (HistoryDiaryLayout.EntryID?) -> Void, environment: EnvironmentValues
    ) {
      self.content = content
      self.onScroll = onScroll
      self.environment = environment
      self.restore = restore
      self.rowsAreFinal = rowsAreFinal
      guard let table else { return }

      let anchor = captureAnchor()
      if newRows != rows {
        let difference = newRows.difference(from: rows)
        var removed = IndexSet()
        var inserted = IndexSet()
        for change in difference {
          switch change {
          case .remove(let offset, _, _): removed.insert(offset)
          case .insert(let offset, _, _): inserted.insert(offset)
          }
        }
        #if DEBUG
          listener.rowsChanged(from: rows.count, to: newRows.count)
        #endif
        // #4611: a new dictation arriving while the reader is at the top slides in, measured
        // first so it lands at its real height; every other change (a page, a deletion)
        // applies at once.
        let slidesIn =
          isAtNewest && removed.isEmpty && !inserted.isEmpty && (inserted.last ?? 0) < 4
        rows = newRows
        index = Dictionary(
          newRows.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        isApplyingRows = true
        defer { isApplyingRows = false }
        if slidesIn {
          let currentWidth = table.tableColumns.first?.width ?? 0
          if currentWidth > 1 {
            width = currentWidth
            for row in inserted { measure(newRows[row]) }
            sizer.rootView = .empty
          }
          table.beginUpdates()
          table.insertRows(at: inserted, withAnimation: [.effectFade, .slideDown])
          table.endUpdates()
        } else {
          withoutAnimation {
            table.beginUpdates()
            if !removed.isEmpty { table.removeRows(at: removed, withAnimation: []) }
            if !inserted.isEmpty { table.insertRows(at: inserted, withAnimation: []) }
            table.endUpdates()
          }
        }
      }
      // Rows that stay on screen show the latest search, selection mode and environment.
      reconfigureVisibleRows()
      settle(keeping: anchor)
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      guard rows.indices.contains(row) else { return 1 }
      return heights[rows[row]]?.height ?? Self.estimate(rows[row])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
      guard rows.indices.contains(row) else { return nil }
      let cell =
        (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? HostCell)
        ?? HostCell(identifier: Self.cellID) { [weak self] in self?.scheduleVerify() }
      if let previous = cell.shownID, previous != rows[row], heightsFromScreen.remove(previous) != nil {
        heights[previous]?.width = 0
      }
      cell.show(hosted(rows[row]))
      return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
      HistoryTableRowView()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    // MARK: Heights and place

    private static func estimate(_ row: RowID) -> CGFloat {
      switch row {
      case .newer, .older: 40
      case .entry(.day): 48
      case .entry(.item): 160
      }
    }

    private func hosted(_ row: RowID) -> HostedRow {
      HostedRow(id: row, content: content(row), width: max(width, 1), environment: environment)
    }

    /// Measures every row near the window that has no height at the current width, applies the
    /// heights without moving `anchor`, restores a pending place, and repeats while measuring
    /// moved which rows are near the window.
    private func settle(keeping anchor: Anchor?) {
      guard let table, let scroll else { return }
      let currentWidth = table.tableColumns.first?.width ?? 0
      guard currentWidth > 1, scroll.contentView.bounds.height > 1 else { return }
      width = currentWidth
      var keep = anchor
      if let target = pendingRestoreTarget() {
        // Go to the restored place first, so the rows measured are the ones around it.
        move(to: target)
        keep = target
        appliedRestoreToken = restore?.token
      }
      if isDraggingKnob {
        noteHeights(measureRowsNearWindow(), keepingPlace: false)
        return
      }
      for _ in 0..<4 {
        let changed = measureRowsNearWindow()
        if changed.isEmpty { break }
        noteHeights(changed)
      }
      if let keep { move(to: keep) }
      scheduleVerify()
    }

    /// The restore still owed, as a place to keep: its row at the top, or the very top.
    private func pendingRestoreTarget() -> Anchor? {
      guard let restore, restore.token != appliedRestoreToken else { return nil }
      guard let target = restore.target else {
        if rows.isEmpty && !rowsAreFinal { return nil }
        return Anchor(row: nil, offset: 0)
      }
      if index[.entry(target)] != nil { return Anchor(row: .entry(target), offset: 0) }
      if rowsAreFinal { appliedRestoreToken = restore.token }
      return nil
    }

    private func measureRowsNearWindow() -> IndexSet {
      guard let table, let scroll else { return [] }
      let visible = scroll.contentView.bounds
      let near = isDraggingKnob ? visible : visible.insetBy(dx: 0, dy: -visible.height)
      let range = table.rows(in: near)
      guard range.length > 0 else { return [] }
      var changed = IndexSet()
      for row in range.location..<(range.location + range.length) where rows.indices.contains(row) {
        let id = rows[row]
        if let known = heights[id], known.width == width { continue }
        #if DEBUG
          let started = DispatchTime.now().uptimeNanoseconds
        #endif
        sizer.rootView = hosted(id)
        let height = max(1, ceil(sizer.fittingSize.height))
        #if DEBUG
          listener.measured(nanoseconds: DispatchTime.now().uptimeNanoseconds - started)
        #endif
        if heights[id]?.height != height { changed.insert(row) }
        heights[id] = (height, width)
      }
      sizer.rootView = .empty
      return changed
    }

    /// Measures one row at the current width with the off-screen copy and keeps the height.
    private func measure(_ id: RowID) {
      sizer.rootView = hosted(id)
      heights[id] = (max(1, ceil(sizer.fittingSize.height)), width)
    }

    private func noteHeights(_ rows: IndexSet, keepingPlace: Bool = true) {
      guard let table, !rows.isEmpty else { return }
      let anchor = keepingPlace && !isDraggingKnob ? captureAnchor() : nil
      withoutAnimation { table.noteHeightOfRows(withIndexesChanged: rows) }
      if let anchor { move(to: anchor) }
    }

    /// A row on screen changed its own height: measure the rows on screen as they are drawn now.
    private func scheduleVerify() {
      guard !verifyScheduled else { return }
      verifyScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.verifyScheduled = false
        self.verifyVisibleRows()
      }
    }

    private func verifyVisibleRows() {
      guard let table, let scroll, width > 1 else { return }
      let range = table.rows(in: scroll.contentView.bounds)
      guard range.length > 0 else { return }
      var changed = IndexSet()
      for row in range.location..<(range.location + range.length) where rows.indices.contains(row) {
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HostCell,
          let shown = cell.shownID, shown == rows[row]
        else { continue }
        let height = max(1, ceil(cell.naturalHeight))
        if heights[shown]?.height != height || heights[shown]?.width != width {
          heights[shown] = (height, width)
          heightsFromScreen.insert(shown)
          changed.insert(row)
        }
      }
      noteHeights(changed)
    }

    private func reconfigureVisibleRows() {
      guard let table, let scroll else { return }
      let range = table.rows(
        in: scroll.contentView.bounds.insetBy(dx: 0, dy: -scroll.contentView.bounds.height))
      guard range.length > 0 else { return }
      for row in range.location..<(range.location + range.length) where rows.indices.contains(row) {
        (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HostCell)?.show(
          hosted(rows[row]))
      }
    }

    private struct Anchor {
      /// `nil` keeps the very top of the list.
      let row: RowID?
      /// How far the top of the window is below the top of `row`.
      let offset: CGFloat
    }

    private func captureAnchor() -> Anchor? {
      guard let table, let scroll, !rows.isEmpty else { return nil }
      let top = scroll.contentView.bounds.minY
      // #4611: a reader at the very top of a list that starts at the newest item stays at the
      // top, so a new dictation arrives in view rather than above it.
      if isAtNewest { return Anchor(row: nil, offset: 0) }
      let row = table.row(at: NSPoint(x: 1, y: max(top, 0)))
      guard rows.indices.contains(row) else { return nil }
      return Anchor(row: rows[row], offset: top - table.rect(ofRow: row).minY)
    }

    private func move(to anchor: Anchor) {
      guard let table, let scroll else { return }
      var y: CGFloat = 0
      if let row = anchor.row {
        guard let index = index[row] else { return }
        y = table.rect(ofRow: index).minY + anchor.offset
      }
      let clip = scroll.contentView
      let maxY = max(0, table.frame.height + scroll.contentInsets.bottom - clip.bounds.height)
      let target = min(max(0, y), maxY)
      guard abs(clip.bounds.minY - target) > 0.25 else { return }
      isMovingWindow = true
      clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
      scroll.reflectScrolledClipView(clip)
      isMovingWindow = false
    }

    /// The window shows the top of a list that has no newer page above it.
    private var isAtNewest: Bool {
      guard let scroll, let first = rows.first else { return false }
      if case .newer = first { return false }
      return scroll.contentView.bounds.minY <= 0.5
    }

    private func windowMoved() {
      guard !isMovingWindow, !isApplyingRows, let table, let scroll else { return }
      #if DEBUG
        let started = DispatchTime.now().uptimeNanoseconds
        defer { listener.moved(nanoseconds: DispatchTime.now().uptimeNanoseconds - started) }
      #endif
      // Measure what is about to come into view before it arrives.
      let changed = measureRowsNearWindow()
      noteHeights(changed)
      let row = table.row(at: NSPoint(x: 1, y: max(scroll.contentView.bounds.minY, 0)))
      guard rows.indices.contains(row) else { return }
      // At the newest item the saved place is "the newest", so a refresh reads from the newest
      // and includes a dictation made since.
      if isAtNewest { return onScroll(nil) }
      switch rows[row] {
      case .entry(let entry): onScroll(entry)
      case .newer: onScroll(nil)
      case .older:
        onScroll(rows.dropLast().last.flatMap { if case .entry(let e) = $0 { e } else { nil } })
      }
    }

    private func frameChanged() {
      guard let table else { return }
      let anchor = captureAnchor()
      let current = table.tableColumns.first?.width ?? 0
      if abs(current - width) > 0.5 {
        width = current
        reconfigureVisibleRows()
      }
      settle(keeping: anchor)
    }

    private func withoutAnimation(_ body: () -> Void) {
      NSAnimationContext.beginGrouping()
      NSAnimationContext.current.duration = 0
      NSAnimationContext.current.allowsImplicitAnimation = false
      body()
      NSAnimationContext.endGrouping()
    }
  }
}

/// The SwiftUI row inside one cell, at the list's width, with the environment of the list it
/// sits in (an `NSHostingView` does not inherit SwiftUI environment from the AppKit view above
/// it, so every home and value the rows read is passed down here, in one place).
struct HostedRow: View {
  let id: HistoryDiaryTable.RowID?
  let content: AnyView
  let width: CGFloat
  let environment: EnvironmentValues?

  static let empty = HostedRow(id: nil, content: AnyView(EmptyView()), width: 1, environment: nil)

  var body: some View {
    if let environment {
      row.environment(\.self, environment)
    } else {
      row
    }
  }

  private var row: some View {
    content
      .padding(.horizontal, SettingsLayout.contentH)
      .frame(width: width, alignment: .topLeading)
      .fixedSize(horizontal: false, vertical: true)
      // Its own identity per row, so a reused cell starts the row's tasks and state afresh.
      .id(id)
  }
}

/// No row selection and no key handling of its own: clicks, focus and keys belong to the
/// SwiftUI rows, which may take first responder without the table selecting anything.
private final class HistoryTableView: NSTableView {
  override var acceptsFirstResponder: Bool { false }

  override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?)
    -> Bool
  {
    true
  }
}

private final class HistoryTableRowView: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {}
  override func drawBackground(in dirtyRect: NSRect) {}
}

/// A reusable cell that hosts one row and reports when the row changes its own height.
private final class HostCell: NSView {
  private let host: ReportingHostingView
  private(set) var shownID: HistoryDiaryTable.RowID?

  init(identifier: NSUserInterfaceItemIdentifier, onResize: @escaping () -> Void) {
    host = ReportingHostingView(rootView: .empty)
    super.init(frame: .zero)
    self.identifier = identifier
    clipsToBounds = false
    host.sizingOptions = [.intrinsicContentSize]
    host.clipsToBounds = false
    host.translatesAutoresizingMaskIntoConstraints = true
    host.autoresizingMask = [.width, .height]
    host.frame = bounds
    host.onResize = onResize
    addSubview(host)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func show(_ row: HostedRow) {
    shownID = row.id
    host.rootView = row
  }

  var naturalHeight: CGFloat { host.intrinsicContentSize.height }
}

private final class ReportingHostingView: NSHostingView<HostedRow> {
  var onResize: (() -> Void)?

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    onResize?()
  }
}

#if DEBUG
  /// #4611 listening code: what one scroll costs, written to app.log when the scroll ends.
  @MainActor private struct ScrollListener {
    private var active = false
    private var knob = false
    private var began: UInt64 = 0
    private var moves = 0
    private var moveTotal: UInt64 = 0
    private var moveMax: UInt64 = 0
    private var slowMoves = 0
    private var measured = 0
    private var measureTotal: UInt64 = 0
    private var rowChanges: [String] = []
    private var startRows = 0

    mutating func begin(knob: Bool, rows: Int) {
      self = ScrollListener()
      active = true
      self.knob = knob
      began = DispatchTime.now().uptimeNanoseconds
      startRows = rows
    }

    mutating func moved(nanoseconds: UInt64) {
      guard active else { return }
      moves += 1
      moveTotal += nanoseconds
      moveMax = max(moveMax, nanoseconds)
      if nanoseconds > 16_000_000 { slowMoves += 1 }
    }

    mutating func measured(nanoseconds: UInt64) {
      guard active else { return }
      measured += 1
      measureTotal += nanoseconds
    }

    mutating func rowsChanged(from: Int, to: Int) {
      guard active else { return }
      rowChanges.append("\(from)->\(to)")
    }

    mutating func end(rows: Int) {
      guard active else { return }
      active = false
      let ms = { (n: UInt64) in String(format: "%.1f", Double(n) / 1_000_000) }
      let line =
        "scroll kind=\(knob ? "scrollbar" : "trackpad") duration=\(ms(DispatchTime.now().uptimeNanoseconds - began))ms "
        + "moves=\(moves) moveTotal=\(ms(moveTotal))ms moveMax=\(ms(moveMax))ms slowMoves(>16ms)=\(slowMoves) "
        + "rowsMeasured=\(measured) measureTotal=\(ms(measureTotal))ms rows=\(startRows)->\(rows) "
        + "pageLoads=[\(rowChanges.joined(separator: ","))]"
      Task { await AppLogger.shared.log(line, level: .info, category: "HistoryScroll") }
    }
  }
#endif
