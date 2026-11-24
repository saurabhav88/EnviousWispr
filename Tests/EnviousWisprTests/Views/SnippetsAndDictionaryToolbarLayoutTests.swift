import AppKit
import EnviousWisprCore
import EnviousWisprStorage
import SwiftUI
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPostProcessing

/// #4901: protects Snippets and Dictionary toolbars at 750 pt through 1100 pt, search field
/// identity across reflow and Mass edit transitions, and `SearchActionToolbarLayout` contracts.
@MainActor
@Suite("Snippets and Dictionary toolbar layout (#4901)", .tags(.productOutcome))
struct SnippetsAndDictionaryToolbarLayoutTests {
  init() { _ = NSApplication.shared }

  private struct AnchorSnapshot: Equatable {
    var width: CGFloat = 0
    var rects: [SettingsMapID: CGRect] = [:]
  }

  @MainActor
  private final class ObservedState {
    var anchors = AnchorSnapshot()
    var headerHeight: CGFloat = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
      let current = waiters
      waiters.removeAll(keepingCapacity: true)
      for c in current { c.resume() }
    }
    func next() async { await withCheckedContinuation { waiters.append($0) } }
  }

  private func pumpUntil(
    _ host: NSHostingView<some View>, window: NSWindow, state: ObservedState, width: CGFloat,
    condition: @escaping @MainActor () -> Bool = { true }
  ) async throws {
    let rect = NSRect(x: 0, y: 0, width: width, height: 760)
    window.setContentSize(rect.size); host.frame = rect
    host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    let ready = { abs(state.anchors.width - width) < 0.5 && condition() }
    if ready() { return }
    try await withThrowingTimeout(seconds: 5) { @MainActor in
      while !ready() && !Task.isCancelled {
        await Task.yield(); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        if ready() || Task.isCancelled { break }
        await withTaskCancellationHandler { await state.next() } onCancel: { Task { @MainActor in state.signal() } }
      }
    }
    host.layoutSubtreeIfNeeded()
  }

  private func withObservedPage(
    _ rootView: some View, width: CGFloat,
    body: @MainActor (NSHostingView<AnyView>, NSWindow, ObservedState) async throws -> Void
  ) async throws {
    let state = ObservedState()
    let observed = rootView
      .overlayPreferenceValue(DictionaryPinnedHeaderHeightKey.self) { h in
        Color.clear.onChange(of: h, initial: true) { _, n in MainActor.assumeIsolated { state.headerHeight = n; state.signal() } }
          .allowsHitTesting(false).accessibilityHidden(true)
      }
      .overlayPreferenceValue(SettingsRevealAnchorKey.self) { places in
        GeometryReader { g in
          let snap = AnchorSnapshot(width: g.size.width, rects: places.mapValues { g[$0.bounds] })
          Color.clear.onChange(of: snap, initial: true) { _, n in MainActor.assumeIsolated { state.anchors = n; state.signal() } }
        }.allowsHitTesting(false).accessibilityHidden(true)
      }
    let host = NSHostingView(rootView: AnyView(observed))
    host.frame = NSRect(x: 0, y: 0, width: width, height: 760)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.contentView = nil; window.close() }
    try await pumpUntil(host, window: window, state: state, width: width)
    try await body(host, window, state)
  }

  private func click(at point: CGPoint, in host: NSView, window: NSWindow) {
    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); window.orderFrontRegardless()
    let loc = NSPoint(x: point.x, y: host.bounds.height - point.y)
    for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      if let e = NSEvent.mouseEvent(
        with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(e) }
    }
    host.layoutSubtreeIfNeeded()
  }

  private func searchField(in view: NSView, matching fragment: String) -> NSTextField? {
    for sub in view.subviews {
      if let tf = sub as? NSTextField,
        (tf.placeholderString?.localizedCaseInsensitiveContains(fragment) ?? false)
          || (tf.accessibilityLabel()?.localizedCaseInsensitiveContains(fragment) ?? false) { return tf }
      if let found = searchField(in: sub, matching: fragment) { return found }
    }
    return nil
  }

  private func frameInHost(_ view: NSView, host: NSView) -> CGRect {
    let r = view.convert(view.bounds, to: host)
    return host.isFlipped ? r : CGRect(x: r.minX, y: host.bounds.height - r.maxY, width: r.width, height: r.height)
  }

  private func lineHeight(_ title: String, size: EnviousButtonFace.Size, image: String? = nil) -> CGFloat {
    let b = Button(action: {}) { EnviousButtonLabel(LocalizedStringResource(stringLiteral: title), size: size, systemImage: image) }
      .settingsButton(shape: .roundedRect, size: size, isEnabled: true).fixedSize()
    return NSHostingView(rootView: b).fittingSize.height
  }

  @Test("Snippets toolbar fits single-line buttons and full placeholder across 750, 820, inline boundary, 1100, and empty trailing alignment")
  func snippetsToolbarGeometry() async throws {
    let home = try SettingsMapRenderingTests.Home()
    let coordinator = SnippetsCoordinator(manager: SnippetsManager(fileURL: home.directory.appending(path: "snippets.json")))
    let lineH = lineHeight("Import", size: .medium, image: "square.and.arrow.down")
    let placeholderW = ceil(NSAttributedString(
      string: String(localized: SettingsItemCopy.Snippets.search),
      attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .regular)]).size().width)
    let ids: [SettingsMapID] = [.snippetsImport, .snippetsExport, .snippetsAdd]
    let w750 = SettingsRenderGeometry.pageWidth(window: 750), w1100 = SettingsRenderGeometry.pageWidth(window: 1100)

    try await withObservedPage(SnippetsView().environment(coordinator), width: w750) { host, window, state in
      try await pumpUntil(host, window: window, state: state, width: w750) {
        ids.allSatisfy { state.anchors.rects[$0] != nil } && state.anchors.rects[.snippetsSearch] != nil
      }
      let tf750 = try #require(searchField(in: host, matching: "Search snippets"))
      let sr750 = try #require(state.anchors.rects[.snippetsSearch])
      #expect(frameInHost(tf750, host: host).width >= placeholderW && sr750.width >= 360)
      let b750 = try ids.map { try #require(state.anchors.rects[$0]) }
      for r in b750 {
        #expect(r.height <= lineH + 1.5 && r.midY > sr750.midY + 12)
        #expect(r.minX >= SettingsLayout.contentH - 1 && r.maxX <= w750 - SettingsLayout.contentH + 1)
      }
      #expect(b750[0].intersects(b750[1]) == false && b750[0].intersects(b750[2]) == false && b750[1].intersects(b750[2]) == false)

      for winW in [820 as CGFloat, 1100] {
        let pw = SettingsRenderGeometry.pageWidth(window: winW)
        try await pumpUntil(host, window: window, state: state, width: pw) {
          guard let a = state.anchors.rects[.snippetsAdd], let s = state.anchors.rects[.snippetsSearch] else { return false }
          return abs(a.midY - s.midY) < 6
        }
        let tf = try #require(searchField(in: host, matching: "Search snippets"))
        let sr = try #require(state.anchors.rects[.snippetsSearch])
        #expect(frameInHost(tf, host: host).width >= placeholderW)
        for id in ids {
          let r = try #require(state.anchors.rects[id])
          #expect(r.height <= lineH + 1.5 && abs(r.midY - sr.midY) < 6 && r.minX > sr.maxX && r.maxX <= pw - SettingsLayout.contentH + 1)
        }
      }

      var sawStacked = false, firstInline: CGFloat?, w = w750
      while w <= SettingsRenderGeometry.pageWidth(window: 820) {
        try await pumpUntil(host, window: window, state: state, width: w)
        let sr = try #require(state.anchors.rects[.snippetsSearch]), add = try #require(state.anchors.rects[.snippetsAdd])
        let tf = try #require(searchField(in: host, matching: "Search snippets"))
        if abs(add.midY - sr.midY) < 6 { firstInline = w; #expect(frameInHost(tf, host: host).width >= placeholderW); break }
        sawStacked = true; w += 2
      }
      #expect(sawStacked && firstInline != nil)

      for s in coordinator.snippets { coordinator.delete(s) }
      try await pumpUntil(host, window: window, state: state, width: w750) { state.anchors.rects[.snippetsSearch] == nil && state.anchors.rects[.snippetsImport] != nil }
      try await pumpUntil(host, window: window, state: state, width: w1100) { state.anchors.rects[.snippetsSearch] == nil && state.anchors.rects[.snippetsImport] != nil }
      let wideImp = try #require(state.anchors.rects[.snippetsImport]), wideAdd = try #require(state.anchors.rects[.snippetsAdd])
      #expect(wideImp.minX > w1100 / 2 && abs(wideAdd.midY - wideImp.midY) < 4)
      #expect(abs(wideAdd.maxX - (w1100 - SettingsLayout.contentH - SettingsLayout.rowPaddingH)) < 3)
    }
  }

  private struct ProposalProbe: Layout {
    let width: CGFloat
    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
      subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
      subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
    }
  }

  @Test("SearchActionToolbarLayout handles inline equality, stacking, DE/ES-width wrapping, zero actions, and nil/infinity/zero proposals")
  func layoutContractHandlesBreakpointsAndEdgeProposals() {
    func box(_ w: CGFloat, _ h: CGFloat) -> some View { Color.blue.frame(width: w, height: h).fixedSize() }
    let toolbar = SearchActionToolbarLayout(minSearchWidth: 180) {
      Color.red.frame(height: 32); WrappingHStack(spacing: 8) { box(76, 28); box(36, 28) }
    }
    #expect(NSHostingView(rootView: toolbar.frame(width: 310)).fittingSize == CGSize(width: 310, height: 32))
    #expect(NSHostingView(rootView: toolbar.frame(width: 309)).fittingSize == CGSize(width: 309, height: 70))
    #expect(NSHostingView(rootView: toolbar.frame(width: 160)).fittingSize == CGSize(width: 160, height: 70))
    let wideBoxes = SearchActionToolbarLayout(minSearchWidth: 200) {
      Color.red.frame(height: 32); WrappingHStack(spacing: 8) { box(165, 28); box(110, 28) }
    }
    #expect(NSHostingView(rootView: wideBoxes.frame(width: 200)).fittingSize == CGSize(width: 200, height: 106))
    let noActions = SearchActionToolbarLayout(minSearchWidth: 180) { Color.red.frame(height: 32); WrappingHStack(spacing: 8) {} }
    #expect(NSHostingView(rootView: noActions.frame(width: 240)).fittingSize == CGSize(width: 240, height: 32))
    #expect(NSHostingView(rootView: toolbar.fixedSize()).fittingSize == CGSize(width: 310, height: 32))
    #expect(NSHostingView(rootView: ProposalProbe(width: .infinity) { toolbar }).fittingSize == CGSize(width: 310, height: 32))
    #expect(NSHostingView(rootView: ProposalProbe(width: 0) { toolbar }).fittingSize == CGSize(width: 180, height: 70))
  }

  @Test("Dictionary Your Words Row 2 keeps single-line buttons and 200 pt search at 750 pt and 1 row at 1100 pt")
  func dictionaryToolbarGeometry() async throws {
    let (home, words) = try SettingsMapRenderingTests.dictionaryHome()
    try await #require(words.add(CustomWord(canonical: "AlphaCustomTerm")) == nil)
    try await #require(words.add(CustomWord(canonical: "BetaCustomTerm")) == nil)
    let lineH = lineHeight("Mass edit", size: .regular)
    let w750 = SettingsRenderGeometry.pageWidth(window: 750), w1100 = SettingsRenderGeometry.pageWidth(window: 1100)

    try await withObservedPage(YourWordsView(selection: .constant(.yourWords)).environment(home.settings).environment(words), width: w750) { host, window, state in
      try await pumpUntil(host, window: window, state: state, width: w750) {
        state.anchors.rects[.yourWordsSearch] != nil && state.anchors.rects[.yourWordsMassEdit] != nil && state.anchors.rects[.yourWordsCategoryFilter] != nil
      }
      let tf750 = try #require(searchField(in: host, matching: "Search by word"))
      let sr750 = try #require(state.anchors.rects[.yourWordsSearch]), mass750 = try #require(state.anchors.rects[.yourWordsMassEdit])
      let catIdle = try #require(state.anchors.rects[.yourWordsCategoryFilter])
      #expect(frameInHost(tf750, host: host).width >= 160 && mass750.height <= lineH + 1.5 && mass750.midY > sr750.midY + 12)
      #expect(mass750.maxX <= w750 - SettingsLayout.contentH + 1)

      click(at: CGPoint(x: mass750.midX, y: mass750.midY), in: host, window: window)
      try await pumpUntil(host, window: window, state: state, width: w750) {
        state.anchors.rects[.yourWordsMassEdit] == nil && state.anchors.rects[.yourWordsCategoryFilter] != nil && state.headerHeight > 0
      }
      let tfSel = try #require(searchField(in: host, matching: "Search by word")), catSel = try #require(state.anchors.rects[.yourWordsCategoryFilter])
      #expect(frameInHost(tfSel, host: host).width >= 160 && abs(catSel.minY - catIdle.minY) <= 2)

      let idleH = state.headerHeight
      click(at: CGPoint(x: sr750.minX + 36, y: sr750.maxY + 21), in: host, window: window)
      try await pumpUntil(host, window: window, state: state, width: w750) { state.headerHeight > idleH + 10 }
      let catDeselect = try #require(state.anchors.rects[.yourWordsCategoryFilter])
      #expect(abs(catDeselect.minY - catIdle.minY) <= 2)
    }

    try await withObservedPage(YourWordsView(selection: .constant(.yourWords)).environment(home.settings).environment(words), width: w1100) { host, window, state in
      try await pumpUntil(host, window: window, state: state, width: w1100) {
        state.anchors.rects[.yourWordsSearch] != nil && state.anchors.rects[.yourWordsMassEdit] != nil
      }
      let sr1100 = try #require(state.anchors.rects[.yourWordsSearch]), mass1100 = try #require(state.anchors.rects[.yourWordsMassEdit])
      let tf1100 = try #require(searchField(in: host, matching: "Search by word"))
      #expect(abs(mass1100.midY - sr1100.midY) < 6 && mass1100.minX > sr1100.maxX && frameInHost(tf1100, host: host).width >= 200)
    }
  }

  @Test("Dictionary search preserves mounted NSTextField identity across breakpoint resize and Mass edit show/hide")
  func searchFieldPreservesIdentityAcrossReflowAndZeroMatches() async throws {
    let (home, words) = try SettingsMapRenderingTests.dictionaryHome()
    try await #require(words.add(CustomWord(canonical: "AlphaCustomTerm")) == nil)
    let w1100 = SettingsRenderGeometry.pageWidth(window: 1100), w750 = SettingsRenderGeometry.pageWidth(window: 750)

    try await withObservedPage(YourWordsView(selection: .constant(.yourWords)).environment(home.settings).environment(words), width: w1100) { host, window, state in
      let initial = try #require(searchField(in: host, matching: "Search by word")), id = ObjectIdentifier(initial)
      #expect(window.makeFirstResponder(initial))
      let editor = try #require(initial.currentEditor() as? NSTextView)

      try await pumpUntil(host, window: window, state: state, width: w750) {
        guard let m = state.anchors.rects[.yourWordsMassEdit], let s = state.anchors.rects[.yourWordsSearch] else { return false }
        return m.midY > s.midY + 12
      }
      #expect(ObjectIdentifier(try #require(searchField(in: host, matching: "Search by word"))) == id)

      editor.insertText("zzzz-no-match", replacementRange: editor.selectedRange())
      try await pumpUntil(host, window: window, state: state, width: w750) { state.anchors.rects[.yourWordsMassEdit] == nil }
      let zeroMatch = try #require(searchField(in: host, matching: "Search by word"))
      #expect(ObjectIdentifier(zeroMatch) == id && window.firstResponder === zeroMatch.currentEditor())

      editor.selectAll(nil); editor.delete(nil)
      try await pumpUntil(host, window: window, state: state, width: w1100) {
        guard let m = state.anchors.rects[.yourWordsMassEdit], let s = state.anchors.rects[.yourWordsSearch] else { return false }
        return abs(m.midY - s.midY) < 6
      }
      let restored = try #require(searchField(in: host, matching: "Search by word"))
      #expect(ObjectIdentifier(restored) == id && window.firstResponder === restored.currentEditor())
    }
  }
}
