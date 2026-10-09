import AppKit
import EnviousWisprCore
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// Arrival after a search navigation (#3482 plan §3.4). When this fails, choosing a result opens
/// the right page but never shows the setting, rings the wrong control, replays an old arrival
/// after a remount, or lands on a fallback while the real control was only off screen.
@MainActor
@Suite("Settings search arrival (#3482)", .tags(.productOutcome))
struct SettingsArrivalTests {
  typealias Planner = SettingsArrivalPlanner

  static func reveal(_ entryID: String, token: Int = 1) throws -> SettingsReveal {
    let request = try #require(SettingsSearchRequest(entryID: entryID))
    return SettingsReveal(request: request, token: token)
  }

  /// Places as a page publishes them: each control with the content it was drawn in.
  static func places(
    _ content: SettingsArrivalContent?, _ ids: SettingsMapID...
  ) -> [SettingsMapID: SettingsArrivalContent?] {
    Dictionary(uniqueKeysWithValues: ids.map { ($0, content) })
  }

  static let engine = SettingsArrivalContent(page: .dictation, dictationTab: .engine)
  static let clipboard = SettingsArrivalContent(page: .dictation, dictationTab: .clipboard)
  static let dictation = SettingsArrivalContent(page: .dictation)

  static func decide(
    _ reveal: SettingsReveal?, _ places: [SettingsMapID: SettingsArrivalContent?],
    lazyTop: SettingsArrivalLazyTop? = nil, handled: Int? = nil, materialized: Int? = nil
  ) -> Planner.Action {
    Planner.decide(
      reveal: reveal, places: places, lazyTop: lazyTop, handledToken: handled,
      materializedToken: materialized)
  }

  @Test("nothing happens without a reveal or for a token already arrived at")
  func noArrival() throws {
    let reveal = try Self.reveal("pauseDuration", token: 3)
    let content = reveal.content
    #expect(Self.decide(nil, Self.places(content, .pauseDuration)) == .none)
    #expect(
      Self.decide(reveal, Self.places(content, .pauseDuration), handled: 3) == .none,
      "a handled token arrived again")
  }

  @Test("readiness is the destination's own content: none, untagged or another tab's waits")
  func readinessIsTaggedContent() throws {
    let reveal = try Self.reveal("autoCopyToClipboard")
    #expect(reveal.content == Self.clipboard)
    #expect(Self.decide(reveal, [:]) == .wait, "nothing rendered")
    #expect(
      Self.decide(reveal, Self.places(Self.dictation, .dictationTabEngine, .dictationTabClipboard))
        == .wait, "only the tab strip: the tab's own rows have not rendered")
    #expect(
      Self.decide(reveal, Self.places(Self.engine, .unloadModelAfter, .autoCopyToClipboard)) == .wait,
      "the previous tab's controls, even one with the target's id, prove nothing")
    #expect(
      Self.decide(reveal, Self.places(nil, .autoCopyToClipboard)) == .wait,
      "an untagged control proves nothing")
    #expect(
      Self.decide(reveal, Self.places(Self.clipboard, .autoCopyToClipboard))
        == .arrive(.autoCopyToClipboard, kind: .target))
  }

  @Test("a fixed target, such as a tab, arrives before the tab's content renders")
  func fixedTargetArrivesFirst() throws {
    let reveal = try Self.reveal("dictation.tab.microphone")
    #expect(
      Self.decide(reveal, Self.places(Self.dictation, .dictationTabMicrophone))
        == .arrive(.dictationTabMicrophone, kind: .target))
  }

  @Test("each rung in order: target, declared fallback, section, then the tab")
  func ladderOrder() throws {
    let reveal = try Self.reveal("pauseDuration")
    let content = reveal.content
    let ladder = reveal.ladder
    try #require(ladder.count >= 4, "pauseDuration has a fallback, a section and a tab: \(ladder.map(\.id))")
    #expect(ladder.map(\.kind) == [.target, .fallback, .section, .landing])
    let all = ladder.map(\.id)
    for (index, rung) in ladder.enumerated() {
      // Every rung below this one is on screen; the ones above are not.
      var placed = Dictionary(uniqueKeysWithValues: all[index...].map { ($0, Optional(content)) })
      if rung.kind == .landing { placed[rung.id] = content.pageOnly }
      // The tab's content has rendered, with a row that is no rung of this entry.
      placed[.theme] = content
      #expect(Self.decide(reveal, placed) == .arrive(rung.id, kind: rung.kind), "\(rung)")
    }
  }

  @Test("lazy content is scrolled to its top once, before any lower rung; never for another tab")
  func materializeOnce() throws {
    let reveal = try Self.reveal("yourWords.export")
    let content = reveal.content
    let lazy = SettingsArrivalLazyTop(scrollID: "top", content: content)
    let other = SettingsArrivalLazyTop(
      scrollID: "top", content: SettingsArrivalContent(page: .dictionary, dictionaryTab: .learnFrom))
    let tab = try #require(reveal.ladder.last?.id)
    let strip = Self.places(content.pageOnly, tab, .enableDictionary)
    // Some of the tab's content is on screen, not the target.
    var partial = strip
    partial[.yourWordsSearch] = content
    #expect(Self.decide(reveal, partial, lazyTop: lazy) == .materialize)
    #expect(
      Self.decide(reveal, partial, lazyTop: lazy, materialized: reveal.token)
        == .arrive(tab, kind: .landing), "after the one scroll, the best rung on screen")
    #expect(
      Self.decide(reveal, partial, lazyTop: other) == .arrive(tab, kind: .landing),
      "another tab's lazy content is never scrolled")
    // None of the tab's content is on screen yet.
    #expect(Self.decide(reveal, strip, lazyTop: lazy) == .materialize)
    #expect(
      Self.decide(reveal, strip, lazyTop: lazy, materialized: reveal.token)
        == .arrive(tab, kind: .landing))
    #expect(Self.decide(reveal, strip, lazyTop: other) == .wait)
    #expect(Self.decide(reveal, strip) == .wait)
  }

  @Test("every committed navigation and a window close move the navigation epoch")
  func epochMoves() throws {
    var state = SettingsNavigationState()
    let start = state.epoch
    state.selectSidebar(.keybinds)
    state.apply(try #require(SettingsSearchRequest(entryID: "pauseDuration")))
    state.apply(.snippets)
    state.endWindowSession()
    #expect(state.epoch == start + 4)
    #expect(state.reveal == nil)
  }

  @Test("acknowledging clears only the matching reveal; a newer one survives")
  func acknowledgeMatchesToken() throws {
    var state = SettingsNavigationState()
    let first = try #require(SettingsSearchRequest(entryID: "pauseDuration"))
    state.apply(first)
    let firstToken = try #require(state.reveal?.token)
    state.apply(first)
    let secondToken = try #require(state.reveal?.token)
    #expect(secondToken != firstToken, "choosing the same result again reused its token")
    state.acknowledgeReveal(token: firstToken)
    #expect(state.reveal?.token == secondToken, "a stale acknowledgement cleared the newer reveal")
    state.acknowledgeReveal(token: secondToken)
    #expect(state.reveal == nil)
  }

  @Test("a direct tab change ends the arrival and its ring; the tab a search opened does not")
  func tabChanges() throws {
    var state = SettingsNavigationState()
    state.apply(try #require(SettingsSearchRequest(entryID: "pauseDuration")))
    let afterSearch = state.epoch
    // The search request set the tab itself: its own arrival survives the tab-change hook.
    state.noteTabChange()
    #expect(state.reveal != nil)
    #expect(state.epoch == afterSearch)
    // The person picks another tab.
    state.dictationTab = state.dictationTab == .engine ? .microphone : .engine
    state.noteTabChange()
    #expect(state.reveal == nil, "the arrival survived a change to another tab")
    #expect(state.epoch == afterSearch + 1, "the ring would survive a direct tab change")
    // After an acknowledged arrival (no reveal left), a direct change still ends the ring.
    state.noteTabChange()
    #expect(state.epoch == afterSearch + 2)
  }

  @Test("a finished arrival stays current only until any navigation, even to the same place")
  func arrivalCurrency() throws {
    let request = try #require(SettingsSearchRequest(entryID: "pauseDuration"))
    var state = SettingsNavigationState()
    state.apply(request)
    let token = try #require(state.reveal?.token)
    state.acknowledgeReveal(token: token)
    #expect(state.arrivalIsCurrent(token: token, entryID: "pauseDuration"))
    // An ordinary commit to the same page and tab: still showing, no longer this arrival's.
    state.apply(request.destination)
    #expect(state.isShowing(request.destination, dictionaryTab: nil))
    #expect(state.arrivalIsCurrent(token: token, entryID: "pauseDuration") == false)

    var closed = SettingsNavigationState()
    closed.apply(request)
    let closedToken = try #require(closed.reveal?.token)
    closed.acknowledgeReveal(token: closedToken)
    closed.endWindowSession()
    #expect(closed.arrivalIsCurrent(token: closedToken, entryID: "pauseDuration") == false)

    var newer = SettingsNavigationState()
    newer.apply(request)
    let olderToken = try #require(newer.reveal?.token)
    newer.apply(request)
    #expect(newer.arrivalIsCurrent(token: olderToken, entryID: "pauseDuration") == false)
  }

  @Test("the Dictionary tab is part of what 'showing' means")
  func dictionaryTabShowing() throws {
    var state = SettingsNavigationState()
    let request = try #require(SettingsSearchRequest(entryID: "quickAdd.shortcut"))
    state.apply(request)
    #expect(state.dictionaryTab == .quickAdd)
    #expect(state.isShowing(request.destination, dictionaryTab: request.dictionaryTab))
    state.dictionaryTab = .yourWords
    #expect(state.isShowing(request.destination, dictionaryTab: request.dictionaryTab) == false)
  }

  @Test("arrival announcements name the chosen place, and the fallback when one opened")
  func announcements() {
    #expect(SettingsSearchCopy.arrived("Pause duration") == "Showing Pause duration")
    #expect(
      SettingsSearchCopy.arrivedAtFallback(landed: "Stop recording", chosen: "Pause duration")
        == "Showing Stop recording for Pause duration")
  }

  // MARK: - The page's one owner

  @Test("a control counts as on screen only inside its own scroll view; a fixed one, in the page")
  func visibilityClip() {
    let page = CGRect(x: 0, y: 0, width: 700, height: 500)
    let viewport = SettingsArrivalViewportID()
    let viewports = [viewport: CGRect(x: 0, y: 60, width: 700, height: 440)]
    let inScroll = SettingsArrivalVisibility.clip(
      page: page, viewport: viewport, viewports: viewports)
    let fixed = SettingsArrivalVisibility.clip(page: page, viewport: nil, viewports: viewports)
    // A row scrolled up under the tab strip: inside the page, outside its scroll view.
    let underStrip = CGRect(x: 20, y: 10, width: 200, height: 30)
    #expect(SettingsArrivalVisibility.partly(underStrip, in: inScroll) == false)
    #expect(SettingsArrivalVisibility.fully(underStrip, in: fixed), "the tab strip itself")
    let half = CGRect(x: 20, y: 480, width: 200, height: 40)
    #expect(SettingsArrivalVisibility.partly(half, in: inScroll))
    #expect(SettingsArrivalVisibility.fully(half, in: inScroll) == false)
    // A scroll view that has not reported its frame hides its controls rather than guessing.
    let unknown = SettingsArrivalVisibility.clip(
      page: page, viewport: SettingsArrivalViewportID(), viewports: viewports)
    #expect(SettingsArrivalVisibility.partly(CGRect(x: 0, y: 100, width: 10, height: 10), in: unknown) == false)
  }

  /// Hosts a page shaped like Dictation Settings (a tab strip above the page's scroll view, a row
  /// far below the fold) under one arrival owner, and returns the acknowledged token once the
  /// arrival for `entryID` completes. A missing arrival is a wiring fault, which stops a Debug run.
  static func arrival(at entryID: String) async throws -> (token: Int?, landed: SettingsMapID?) {
    let reveal = try Self.reveal(entryID, token: 7)
    var acknowledged: Int?
    var landed: SettingsMapID?
    let page = VStack(spacing: 0) {
      Button("Microphone") {}
        .settingsMapRegistration(.dictationTabMicrophone)
        .frame(height: 40)
      SettingsContentView {
        Color.clear.frame(height: 2_000)
        Toggle("Copy to clipboard", isOn: .constant(false))
          .settingsMapRegistration(.autoCopyToClipboard)
        // A row inside a card that is itself registered, like Self-Learning Dictionary inside
        // the Learn From panel (#3545).
        VStack {
          Toggle("Self-Learning Dictionary", isOn: .constant(false))
            .settingsMapRegistration(.selfLearningDictionary)
        }
        .settingsMapRegistration(.learnFrom)
      }
      // The scrolling content is the reveal's own tab; the strip above it is the page's (#3545).
      .environment(\.settingsArrivalContent, reveal.content)
    }
    .environment(\.settingsArrivalContent, reveal.content.pageOnly)
    .modifier(SettingsArrivalModifier())
    .environment(\.settingsReveal, reveal)
    .environment(\.settingsRevealAcknowledge) { acknowledged = $0 }
    .environment(\.settingsArrivalStillCurrent) { _ in true }
    .environment(\.settingsArrivalDecided) { decision in
      if case .arrive(let id, _) = decision.action { landed = id }
    }
    .frame(width: 700, height: 500)
    let host = NSHostingView(rootView: page)
    host.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    // deadline-fallback: a hang guard; the wait ends on the acknowledgement itself.
    let deadline = ContinuousClock.now + .seconds(10)
    while acknowledged == nil, ContinuousClock.now < deadline {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
    return (acknowledged, landed)
  }

  @Test("a tab outside the page's scroll view and a row far below the fold are both arrived at")
  func pageOwnerReachesEveryPlace() async throws {
    _ = SettingsMap.takeRecordedFaults()
    let tab = try await Self.arrival(at: "dictation.tab.microphone")
    #expect(tab.token == 7 && tab.landed == .dictationTabMicrophone, "the tab strip: \(tab)")
    let row = try await Self.arrival(at: "autoCopyToClipboard")
    #expect(row.token == 7 && row.landed == .autoCopyToClipboard, "below the fold: \(row)")
    let nested = try await Self.arrival(at: "selfLearningDictionary")
    #expect(
      nested.token == 7 && nested.landed == .selfLearningDictionary,
      "a row inside a registered card: \(nested)")
    #expect(SettingsMap.takeRecordedFaults().isEmpty)
  }

  // MARK: - Tagged content, hosted (#3545 T3, T4, T6, T12)

  /// Rows that appear one pass after their tab opens, as rows that wait on state do.
  struct LateRows: View {
    let ids: [SettingsMapID]
    @State private var ready = false
    var body: some View {
      VStack {
        if ready {
          ForEach(ids, id: \.self) { id in
            Toggle(id.rawValue, isOn: .constant(false)).settingsMapRegistration(id)
          }
        }
      }
      .onAppear { DispatchQueue.main.async { ready = true } }
    }
  }

  /// A Dictation-shaped page: a fixed tab strip (page tag) above one tab's rows, under one arrival
  /// owner, as `page { }` and DictationSettingsView build it. `rowTab` tags the rows (nil: untagged),
  /// `lazy` publishes a lazy-content top marker for `tab`.
  struct TaggedPage: View {
    let box: RevealBox
    let reveal: SettingsReveal?
    let tab: DictationTab
    var rows: [SettingsMapID] = []
    var rowTab: DictationTab??
    var late = false
    var lazy = false
    /// The tab the lazy marker says it tops (default: the drawn tab).
    var lazyTab: DictationTab?
    /// Pins Reduce Motion for the arrival owner and its ring.
    var reduceMotion: Bool?
    /// Space above the rows, so they start below the fold and arrival has to scroll.
    var spacer: CGFloat = 0
    /// Space after each row, so later rows sit below the fold.
    var rowGap: CGFloat = 0
    /// A text field in the page, which consumes the keys typed into it.
    var textField = false

    var body: some View {
      let drawn = SettingsArrivalContent(page: .dictation, dictationTab: tab)
      let rowTag = (rowTab ?? .some(tab)).map {
        SettingsArrivalContent(page: .dictation, dictationTab: $0)
      }
      return VStack(spacing: 0) {
        ForEach(DictationTab.allCases, id: \.self) { tab in
          Button(tab.rawValue) {}.settingsMapRegistration(tab.mapID)
        }
        SettingsContentView {
          Color.clear.frame(height: 0).id("lazyTop")
          FocusRequestProbe(box: box)
          if textField { TextField("Typing", text: .constant("")) }
          Color.clear.frame(height: spacer)
          if late {
            LateRows(ids: rows)
          } else {
            ForEach(rows, id: \.self) { id in
              Toggle(id.rawValue, isOn: .constant(false)).settingsMapRegistration(id)
                .padding(.bottom, rowGap)
            }
          }
        }
        .environment(\.settingsArrivalContent, rowTag)
        .preference(
          key: SettingsArrivalLazyTopKey.self,
          value: lazy
            ? SettingsArrivalLazyTop(
              scrollID: "lazyTop",
              content: lazyTab.map { SettingsArrivalContent(page: .dictation, dictationTab: $0) } ?? drawn)
            : nil)
      }
      .environment(\.settingsArrivalContent, SettingsArrivalContent(page: .dictation))
      .modifier(SettingsArrivalModifier())
      .environment(\.settingsReveal, reveal)
      .environment(\.settingsRevealAcknowledge) { token in
        box.acknowledged = token
        box.acknowledgementSink.yield(token)
      }
      .environment(\.settingsArrivalStillCurrent) { _ in box.current }
      .environment(\.settingsArrivalDecided) { box.record($0) }
      .environment(\.settingsArrivalRingDrawn) { id, rect, clip in box.rings.append((id, rect, clip)) }
      .environment(\.settingsArrivalReduceMotion, reduceMotion)
      .frame(width: 700, height: 500)
    }
  }

  /// Records every focus request the arrival owner publishes to the page's adapters.
  struct FocusRequestProbe: View {
    let box: RevealBox
    @Environment(\.settingsArrivalFocusRequest) private var request
    var body: some View {
      Color.clear.frame(width: 1, height: 1)
        .onChange(of: request, initial: true) { _, new in
          if let new {
            box.focusRequests.append(new)
            box.focusSink.yield(new)
          }
        }
    }
  }

  /// One hosted page the test steps through. Each step hands the host a new root (as the window
  /// hands a page a new reveal or tab) and waits for the arrival owner's own decision about it.
  @MainActor final class Stepper {
    let host: NSHostingView<TaggedPage>
    let window: NSWindow
    let box: RevealBox

    init(_ page: TaggedPage) {
      box = page.box
      host = NSHostingView(rootView: page)
      host.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
      window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = host
      host.layoutSubtreeIfNeeded()
    }

    /// The controls `page` publishes once drawn, with their tags: what a decision about it read.
    static func expected(_ page: TaggedPage) -> [SettingsMapID: SettingsArrivalContent?] {
      var places = Dictionary(
        uniqueKeysWithValues: DictationTab.allCases.map {
          ($0.mapID, Optional(SettingsArrivalContent(page: .dictation)))
        })
      let rowTag = (page.rowTab ?? .some(page.tab)).map {
        SettingsArrivalContent(page: .dictation, dictationTab: $0)
      }
      for row in page.rows { places[row] = rowTag }
      return places
    }

    /// Shows `page` and returns the owner's first decision made on exactly what `page` draws
    /// (its controls, tags and marker), or nil when none came before the hang guard.
    func show(_ page: TaggedPage) async -> SettingsArrivalDecision? {
      let want = Self.expected(page)
      let marker: SettingsArrivalLazyTop? =
        page.lazy
        ? SettingsArrivalLazyTop(
          scrollID: "lazyTop",
          content: SettingsArrivalContent(page: .dictation, dictationTab: page.lazyTab ?? page.tab))
        : nil
      let since = box.decisions.count
      host.rootView = page
      let found = await decision(after: since) {
        $0.reveal == page.reveal && $0.places == want && $0.lazyTop == marker
      }
      if found == nil {
        Issue.record(
          "no decision on \(want.keys.map(\.rawValue).sorted()); decisions since: \(box.decisions.dropFirst(since).map { "\(String(describing: $0.action)) \($0.places.mapValues { $0.map { "\($0.dictationTab.map(\.rawValue) ?? "page")" } ?? "nil" })" })"
        )
      }
      return found
    }

    /// The first decision at or after index `since` that `accept` takes, waiting on the owner's
    /// decision events (layout pumped meanwhile), or nil when none came before the hang guard.
    func decision(
      after since: Int, _ accept: @escaping (SettingsArrivalDecision) -> Bool
    ) async -> SettingsArrivalDecision? {
      // test-fixture-timer: an offscreen host only lays out when asked; this pumps layout while
      // the test waits on the owner's decision events.
      let pump = Task { @MainActor [host, window] in
        while !Task.isCancelled {
          // Display as well as layout: a state change made in a preference callback is applied in
          // the host's display pass, not by layout alone.
          host.layoutSubtreeIfNeeded()
          window.displayIfNeeded()
          try? await Task.sleep(for: .milliseconds(20))
        }
      }
      box.hangGuardFired = false
      let guardTask = Task { @MainActor [box] in
        // deadline-fallback: a hang guard around the decision events; the wait is the event.
        try? await Task.sleep(for: .seconds(5))
        // A cancelled sleep returns at once; only a guard that ran its full time fires.
        guard !Task.isCancelled else { return }
        box.hangGuardFired = true
        box.decisionSink.yield(
          SettingsArrivalDecision(reveal: nil, action: nil, places: [:], lazyTop: nil))
      }
      defer {
        pump.cancel()
        guardTask.cancel()
      }
      func found() -> SettingsArrivalDecision? {
        box.decisions.dropFirst(since).first(where: accept)
      }
      if let decision = found() { return decision }
      for await _ in box.decisionEvents {
        if let decision = found() { return decision }
        if box.hangGuardFired { return nil }
      }
      return nil
    }

    func close() { window.contentView = nil }

    /// The host's current paint.
    func paint() throws -> NSBitmapImageRep {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds), "no bitmap")
      host.cacheDisplay(in: host.bounds, to: rep)
      return rep
    }

    /// Types `key` into the first text field in the page, through the application's own event
    /// dispatch (the path a real key takes), with that field holding keyboard focus.
    func type(_ key: String) throws {
      window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
      window.orderFrontRegardless()
      func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? [] + view.subviews.flatMap(fields)
      }
      let field = try #require(fields(host).first { $0.isEditable }, "no text field in the page")
      try #require(window.makeFirstResponder(field), "the text field did not take keyboard focus")
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
          keyCode: 0))
      NSApp.sendEvent(event)
      host.layoutSubtreeIfNeeded()
    }

    /// The next focus request the owner publishes, or nil when none came before the hang guard.
    func focusRequest() async -> SettingsArrivalFocusRequest? {
      if let first = box.focusRequests.first { return first }
      let pump = Task { @MainActor [host, window] in
        while !Task.isCancelled {
          host.layoutSubtreeIfNeeded()
          window.displayIfNeeded()
          try? await Task.sleep(for: .milliseconds(20))
        }
      }
      let guardTask = Task { @MainActor [box] in
        // deadline-fallback: a hang guard around the focus events; the wait is the event.
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled else { return }
        box.focusSink.finish()
      }
      defer {
        pump.cancel()
        guardTask.cancel()
      }
      for await request in box.focusEvents { return request }
      return nil
    }

    /// A click at `point` (host coordinates, top-left origin), as the person's tap in the page. The
    /// window is ordered in far off screen so the click is hit-tested like a real one.
    func click(at point: CGPoint) {
      window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
      window.orderFrontRegardless()
      let location = NSPoint(x: point.x, y: host.bounds.height - point.y)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let event = NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        {
          window.sendEvent(event)
        }
      }
      host.layoutSubtreeIfNeeded()
    }
  }

  /// How many pixels differ between two paints inside `rect` (host points).
  static func changedPixels(_ before: NSBitmapImageRep, _ after: NSBitmapImageRep, in rect: CGRect) -> Int {
    let scale = CGFloat(before.pixelsWide) / max(1, before.size.width)
    let box = rect.intersection(CGRect(origin: .zero, size: before.size))
    guard !box.isNull else { return 0 }
    var changed = 0
    for y in stride(from: Int(box.minY * scale), to: Int(box.maxY * scale), by: 1) {
      for x in stride(from: Int(box.minX * scale), to: Int(box.maxX * scale), by: 1) {
        if before.colorAt(x: x, y: y) != after.colorAt(x: x, y: y) { changed += 1 }
      }
    }
    return changed
  }

  @Test(
    "a tab's rows arrive only from that tab: stale, empty and same-id old-tab rows wait",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/3545", "late tab content"))
  func staleThenRealContent() async throws {
    _ = SettingsMap.takeRecordedFaults()
    let reveal = try Self.reveal("autoCopyToClipboard", token: 5)
    let box = RevealBox()
    let stepper = Stepper(TaggedPage(box: box, reveal: nil, tab: .engine, rows: [.unloadModelAfter]))
    defer { stepper.close() }
    // The choice opens Clipboard while the Engine tab's rows are still the ones drawn.
    let stale = await stepper.show(
      TaggedPage(box: box, reveal: reveal, tab: .clipboard, rows: [.unloadModelAfter], rowTab: .engine))
    #expect(stale?.action == .wait, "previous tab's rows: \(String(describing: stale?.action))")
    // A row with the target's own id, still tagged with the previous tab.
    let sameID = await stepper.show(
      TaggedPage(box: box, reveal: reveal, tab: .clipboard, rows: [.autoCopyToClipboard], rowTab: .engine))
    #expect(sameID?.action == .wait, "same-id row of the previous tab: \(String(describing: sameID?.action))")
    // The tab is drawn but its rows are not there yet.
    let empty = await stepper.show(TaggedPage(box: box, reveal: reveal, tab: .clipboard))
    #expect(empty?.action == .wait, "no rows yet: \(String(describing: empty?.action))")
    // The rows render one pass after the tab.
    let real = await stepper.show(
      TaggedPage(box: box, reveal: reveal, tab: .clipboard, rows: [.autoCopyToClipboard], late: true))
    #expect(real?.action == .arrive(.autoCopyToClipboard, kind: .target))
    #expect(box.landings == [SettingsArrivalRung(id: .autoCopyToClipboard, kind: .target)])
    #expect(box.acknowledged == 5)
    #expect(SettingsMap.takeRecordedFaults().isEmpty)
  }

  @Test("a result chosen in the same turn as the page's first layout still arrives")
  func sameTurnChoiceArrives() async throws {
    let reveal = try Self.reveal("autoCopyToClipboard", token: 6)
    let box = RevealBox()
    let stepper = Stepper(TaggedPage(box: box, reveal: nil, tab: .clipboard, rows: [.autoCopyToClipboard]))
    defer { stepper.close() }
    // No wait between the first layout and the choice: the first decision is still queued.
    let decision = await stepper.show(
      TaggedPage(box: box, reveal: reveal, tab: .clipboard, rows: [.autoCopyToClipboard]))
    #expect(
      decision?.action == .arrive(.autoCopyToClipboard, kind: .target),
      "the reveal committed while the first decision was queued was lost: \(box.decisions.map(\.action))")
  }

  @Test("a hidden target lands on its section, and on the tab when the section is hidden too")
  func hiddenTargetLandsLower() async throws {
    let reveal = try Self.reveal("pauseDuration", token: 7)
    let section = try #require(reveal.ladder.first { $0.kind == .section }?.id)
    let tab = try #require(reveal.content.dictationTab)
    let box = RevealBox()
    let stepper = Stepper(TaggedPage(box: box, reveal: nil, tab: tab, rows: [section]))
    defer { stepper.close() }
    let onSection = await stepper.show(TaggedPage(box: box, reveal: reveal, tab: tab, rows: [section]))
    #expect(onSection?.action == .arrive(section, kind: .section))
    // Another row of the same tab, so the tab's content has rendered but holds no rung.
    let rungs = Set(reveal.ladder.map(\.id))
    let destination = SettingsMap.node(.pauseDuration).destination
    let unrelated = try #require(
      SettingsMap.nodes.first {
        $0.structure == .item && $0.destination == destination && !rungs.contains($0.id)
      }?.id)
    let other = RevealBox()
    let second = Stepper(TaggedPage(box: other, reveal: nil, tab: tab, rows: [unrelated]))
    defer { second.close() }
    let onTab = await second.show(
      TaggedPage(box: other, reveal: try Self.reveal("pauseDuration", token: 8), tab: tab, rows: [unrelated]))
    #expect(onTab?.action == .arrive(tab.mapID, kind: .landing))
  }

  @Test("a lazy-content marker scrolls once only when it tops this tab, even with the same scroll id")
  func lazyMarkerRetag() async throws {
    let reveal = try Self.reveal("autoCopyToClipboard", token: 4)
    let box = RevealBox()
    let stepper = Stepper(TaggedPage(box: box, reveal: nil, tab: .clipboard))
    defer { stepper.close() }
    let bare = await stepper.show(TaggedPage(box: box, reveal: reveal, tab: .clipboard))
    #expect(bare?.action == .wait, "no content and no marker")
    // A marker with the same scroll id that still says it tops the previous tab.
    let other = await stepper.show(
      TaggedPage(box: box, reveal: reveal, tab: .clipboard, lazy: true, lazyTab: .engine))
    #expect(other?.action == .wait, "another tab's marker is never scrolled")
    // Same scroll id, same controls; only the marker's tab changes.
    let before = box.decisions.count
    let mine = await stepper.show(TaggedPage(box: box, reveal: reveal, tab: .clipboard, lazy: true))
    #expect(mine?.action == .materialize)
    // After the one scroll, the owner decides again and lands on the best rung on screen.
    let landed = await stepper.decision(after: before) {
      if case .arrive = $0.action { true } else { false }
    }
    #expect(landed?.action == .arrive(.dictationTabClipboard, kind: .landing))
    #expect(box.landings == [SettingsArrivalRung(id: .dictationTabClipboard, kind: .landing)])
    #expect(box.decisions.filter { $0.action == .materialize }.count == 1, "scrolled more than once")
  }

  @Test("waiting content never rings; a navigation before it renders ends the arrival")
  func untaggedAndOverriddenWait() async throws {
    _ = SettingsMap.takeRecordedFaults()
    let reveal = try Self.reveal("autoCopyToClipboard", token: 9)
    let box = RevealBox()
    let stepper = Stepper(TaggedPage(box: box, reveal: nil, tab: .clipboard))
    defer { stepper.close() }
    // Content that never says what it is proves nothing: the owner keeps waiting.
    let untagged = await stepper.show(
      TaggedPage(box: box, reveal: reveal, tab: .clipboard, rows: [.autoCopyToClipboard], rowTab: .some(nil)))
    #expect(untagged?.action == .wait)
    // Another navigation makes this arrival history; the content then renders.
    box.current = false
    let overtaken = await stepper.show(
      TaggedPage(box: box, reveal: reveal, tab: .clipboard, rows: [.autoCopyToClipboard]))
    try #require(overtaken != nil, "the owner never looked at the rendered content")
    #expect(overtaken?.action == nil, "an arrival overtaken by navigation still decided")
    #expect(box.landings.isEmpty)
    #expect(box.acknowledged == nil)
    #expect(SettingsMap.takeRecordedFaults().isEmpty)
  }

  // MARK: - Moving up once (#3545 T5, T11)

  /// A row of pauseDuration's tab that is no rung of its ladder.
  static func unrelatedRow(for reveal: SettingsReveal) throws -> SettingsMapID {
    let rungs = Set(reveal.ladder.map(\.id))
    let destination = SettingsMap.node(.pauseDuration).destination
    return try #require(
      SettingsMap.nodes.first {
        $0.structure == .item && $0.destination == destination && !rungs.contains($0.id)
      }?.id)
  }

  @Test("a late target lifts an arrival from its section once, keeps focus and the ring's deadline")
  func lateTargetUpgradesOnce() async throws {
    let reveal = try Self.reveal("pauseDuration", token: 11)
    let tab = try #require(reveal.content.dictationTab)
    let section = try #require(reveal.ladder.first { $0.kind == .section }?.id)
    let other = try Self.unrelatedRow(for: reveal)
    let box = RevealBox()
    let stepper = Stepper(TaggedPage(box: box, reveal: nil, tab: tab, rows: [other]))
    defer { stepper.close() }
    // Only an unrelated row: the arrival lands on the tab.
    let onTab = await stepper.show(TaggedPage(box: box, reveal: reveal, tab: tab, rows: [other]))
    #expect(onTab?.action == .arrive(tab.mapID, kind: .landing))
    // The section renders: one move up.
    let toSection = await stepper.show(TaggedPage(box: box, reveal: reveal, tab: tab, rows: [other, section]))
    #expect(toSection?.action == .arrive(section, kind: .section))
    // The target renders after that: no second move.
    let after = await stepper.show(
      TaggedPage(box: box, reveal: reveal, tab: tab, rows: [other, section, .pauseDuration]))
    #expect(after != nil, "the owner never looked at the rendered target")
    #expect(after?.action != .arrive(.pauseDuration, kind: .target), "moved up twice")
    #expect(box.landings.map(\.id) == [tab.mapID, section])
    // Focus was asked only for where the arrival first landed; the upgrade asked nothing.
    #expect(!box.focusRequests.isEmpty, "the arrival asked no focus at all")
    #expect(
      box.focusRequests.allSatisfy { $0.target == tab.mapID },
      "an upgrade moved focus: \(box.focusRequests.map(\.target.rawValue))")
    #expect(box.acknowledged == 11)
  }

  @Test("the target lifts an arrival straight from its section")
  func sectionToTarget() async throws {
    let reveal = try Self.reveal("pauseDuration", token: 12)
    let tab = try #require(reveal.content.dictationTab)
    let section = try #require(reveal.ladder.first { $0.kind == .section }?.id)
    let box = RevealBox()
    let stepper = Stepper(TaggedPage(box: box, reveal: nil, tab: tab, rows: [section]))
    defer { stepper.close() }
    let first = await stepper.show(TaggedPage(box: box, reveal: reveal, tab: tab, rows: [section]))
    #expect(first?.action == .arrive(section, kind: .section))
    // As the window does, the page no longer carries the reveal once it was acknowledged.
    let since = box.decisions.count
    stepper.host.rootView = TaggedPage(box: box, reveal: nil, tab: tab, rows: [section, .pauseDuration])
    let up = await stepper.decision(after: since) {
      if case .arrive = $0.action { true } else { false }
    }
    #expect(up?.action == .arrive(.pauseDuration, kind: .target))
    #expect(up?.reveal == reveal, "the upgrade lost the reveal it belongs to")
    #expect(box.rings.last?.id == .pauseDuration, "the ring did not move to the target")
    #expect(box.acknowledged == 12)
  }

  @Test("a click in the page ends the chance to move up")
  func clickEndsUpgrade() async throws {
    let reveal = try Self.reveal("pauseDuration", token: 13)
    let tab = try #require(reveal.content.dictationTab)
    let section = try #require(reveal.ladder.first { $0.kind == .section }?.id)
    let box = RevealBox()
    let stepper = Stepper(TaggedPage(box: box, reveal: nil, tab: tab, rows: [section]))
    defer { stepper.close() }
    let first = await stepper.show(TaggedPage(box: box, reveal: reveal, tab: tab, rows: [section]))
    #expect(first?.action == .arrive(section, kind: .section))
    try #require(box.rings.last?.id == section, "no ring to end")
    // The person clicks an empty part of the page.
    stepper.click(at: CGPoint(x: 650, y: 450))
    let after = await stepper.show(TaggedPage(box: box, reveal: reveal, tab: tab, rows: [section, .pauseDuration]))
    #expect(after != nil, "the owner never looked at the rendered target")
    #expect(after?.action != .arrive(.pauseDuration, kind: .target), "moved up after the person clicked")
  }

  @Test("a click after the arrival and before its focus move cancels the move; navigation is still current")
  func clickBeforeFocusDelivery() async throws {
    let reveal = try Self.reveal("autoCopyToClipboard", token: 17)
    let box = RevealBox()
    let stepper = Stepper(TaggedPage(box: box, reveal: nil, tab: .clipboard, rows: [.autoCopyToClipboard]))
    defer { stepper.close() }
    // The click lands inside the owner's own decision report: after the arrival queued its focus
    // move, before that queued move can run.
    var clicked = false
    box.afterDecision = { decision in
      guard decision.action == .arrive(.autoCopyToClipboard, kind: .target) else { return }
      box.afterDecision = nil
      stepper.click(at: CGPoint(x: 650, y: 450))
      clicked = true
    }
    let arrived = await stepper.show(
      TaggedPage(box: box, reveal: reveal, tab: .clipboard, rows: [.autoCopyToClipboard]))
    #expect(arrived?.action == .arrive(.autoCopyToClipboard, kind: .target))
    try #require(clicked, "the click did not happen inside the decision")
    #expect(box.current, "navigation stays current: only the person's click can cancel")
    // The queued move runs (or not) on the next main-queue turn; this observes a negative, so a
    // drain is the instrument, weaker than the event waits elsewhere.
    await SettingsArrivalFocusTests.afterQueuedMainWork()
    stepper.host.layoutSubtreeIfNeeded()
    #expect(box.focusRequests.isEmpty, "focus moved after the person clicked: \(box.focusRequests)")
  }

  @Test("without a click, the same arrival does move focus to its place")
  func focusMovesWithoutClick() async throws {
    let reveal = try Self.reveal("autoCopyToClipboard", token: 18)
    let box = RevealBox()
    let stepper = Stepper(TaggedPage(box: box, reveal: nil, tab: .clipboard, rows: [.autoCopyToClipboard]))
    defer { stepper.close() }
    _ = await stepper.show(TaggedPage(box: box, reveal: reveal, tab: .clipboard, rows: [.autoCopyToClipboard]))
    let request = await stepper.focusRequest()
    #expect(request?.target == .autoCopyToClipboard)
  }

  @Test("a key typed into a text field that takes it still ends the chance to move up")
  func consumedKeyEndsUpgrade() async throws {
    let reveal = try Self.reveal("pauseDuration", token: 19)
    let tab = try #require(reveal.content.dictationTab)
    let section = try #require(reveal.ladder.first { $0.kind == .section }?.id)
    let box = RevealBox()
    let stepper = Stepper(TaggedPage(box: box, reveal: nil, tab: tab, rows: [section], textField: true))
    defer { stepper.close() }
    let first = await stepper.show(TaggedPage(box: box, reveal: reveal, tab: tab, rows: [section], textField: true))
    #expect(first?.action == .arrive(section, kind: .section))
    #expect(box.current, "navigation stays current")
    // The person types into the field; the field takes the key.
    try stepper.type("a")
    let after = await stepper.show(
      TaggedPage(box: box, reveal: reveal, tab: tab, rows: [section, .pauseDuration], textField: true))
    #expect(after != nil, "the owner never looked at the rendered target")
    #expect(after?.action != .arrive(.pauseDuration, kind: .target), "moved up after the person typed")
  }

  @Test("each rung is visible in its own clip and the ring is painted there; Reduce Motion too")
  func ringPaintedOnEveryRung() async throws {
    let reveal = try Self.reveal("pauseDuration", token: 14)
    let tab = try #require(reveal.content.dictationTab)
    let ladder = reveal.ladder
    let other = try Self.unrelatedRow(for: reveal)
    for reduceMotion in [false, true] {
      for (index, rung) in ladder.enumerated() {
        // Every rung from this one down is drawn; the tab rung is the strip itself. The rows are
        // in view (an offscreen host does not run a scroll animation; the scroll policy has its
        // own test below).
        let rows = ladder[index...].map(\.id).filter { $0 != tab.mapID } + [other]
        let box = RevealBox()
        let page = { (reveal: SettingsReveal?) in
          TaggedPage(box: box, reveal: reveal, tab: tab, rows: rows, reduceMotion: reduceMotion)
        }
        let stepper = Stepper(page(nil))
        defer { stepper.close() }
        _ = await stepper.decision(after: 0) { _ in true }
        let before = try stepper.paint()
        let control = try stepper.paint()
        let decision = await stepper.show(page(reveal))
        #expect(decision?.action == .arrive(rung.id, kind: rung.kind), "\(rung) motion=\(reduceMotion)")
        let drawn = try #require(box.rings.last { $0.id == rung.id }, "no ring drawn on \(rung)")
        #expect(
          SettingsArrivalVisibility.partly(drawn.rect, in: drawn.clip),
          "\(rung) is not visible in its clip: \(drawn.rect) in \(drawn.clip)")
        let after = try stepper.paint()
        let region = drawn.rect.insetBy(dx: -4, dy: -4)
        // Same input, no arrival: nothing in that region changes.
        #expect(
          Self.changedPixels(before, control, in: region) == 0,
          "\(rung): the region changed without an arrival")
        let changed = Self.changedPixels(control, after, in: region)
        #expect(changed > 50, "\(rung): the ring changed \(changed) pixels")
      }
    }
  }

  @Test("an arrival scrolls without animation under Reduce Motion, and with it otherwise")
  func arrivalFollowsReduceMotion() async throws {
    for reduceMotion in [false, true] {
      let reveal = try Self.reveal("pauseDuration", token: 16)
      let tab = try #require(reveal.content.dictationTab)
      let box = RevealBox()
      // The target sits far below the fold.
      let page = { (reveal: SettingsReveal?) in
        TaggedPage(
          box: box, reveal: reveal, tab: tab, rows: [.pauseDuration], reduceMotion: reduceMotion,
          spacer: 900)
      }
      let stepper = Stepper(page(nil))
      defer { stepper.close() }
      let decision = await stepper.show(page(reveal))
      #expect(decision?.action == .arrive(.pauseDuration, kind: .target))
      let animated = try #require(decision?.scrolledAnimated, "the arrival did not scroll")
      #expect(animated == !reduceMotion, "Reduce Motion \(reduceMotion): animated \(animated)")
    }
  }

  @Test("an upgrade scrolls without animation under Reduce Motion, and with it otherwise")
  func upgradeFollowsReduceMotion() async throws {
    let section: SettingsMapID = try #require(
      try Self.reveal("pauseDuration").ladder.first { $0.kind == .section }?.id)
    for reduceMotion in [false, true] {
      let reveal = try Self.reveal("pauseDuration", token: 15)
      let tab = try #require(reveal.content.dictationTab)
      let box = RevealBox()
      // The section sits at the top; the target renders later, far below it.
      let stepper = Stepper(TaggedPage(box: box, reveal: nil, tab: tab, rows: [section], reduceMotion: reduceMotion))
      defer { stepper.close() }
      let first = await stepper.show(
        TaggedPage(box: box, reveal: reveal, tab: tab, rows: [section], reduceMotion: reduceMotion))
      #expect(first?.action == .arrive(section, kind: .section))
      let since = box.decisions.count
      stepper.host.rootView = TaggedPage(
        box: box, reveal: reveal, tab: tab, rows: [section, .pauseDuration], reduceMotion: reduceMotion,
        rowGap: 900)
      let up = await stepper.decision(after: since) {
        if case .arrive = $0.action { true } else { false }
      }
      #expect(up?.action == .arrive(.pauseDuration, kind: .target))
      // Far below the visible section: the upgrade scrolls, animated exactly when motion is allowed.
      let animated = try #require(up?.scrolledAnimated, "the upgrade did not scroll")
      #expect(animated == !reduceMotion, "Reduce Motion \(reduceMotion): animated \(animated)")
    }
  }

  @Test("the Reduce Motion pin is read only by arrival; the app never sets it")
  func reduceMotionPinIsTestOnly() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL("Sources/EnviousWisprAppKit/Views/Settings/SettingsArrival.swift"),
      encoding: .utf8)
    let settingsDir = RepoRoot.sourceURL("Sources")
    let files = try #require(FileManager.default.enumerator(at: settingsDir, includingPropertiesForKeys: nil))
    var setters: [String] = []
    for case let url as URL in files where url.pathExtension == "swift" {
      let text = try String(contentsOf: url, encoding: .utf8)
      if text.contains("\\.settingsArrivalReduceMotion,") { setters.append(url.lastPathComponent) }
    }
    #expect(setters.isEmpty, "the app sets the Reduce Motion pin: \(setters)")
    #expect(source.contains("pinnedReduceMotion ?? systemReduceMotion"))
  }

  // MARK: - The real Dictionary page (#3545 T7)

  /// What a hosted page reports back: the acknowledged token (also as an event the test awaits)
  /// and what it published beside the arrival owner.
  @MainActor final class RevealBox {
    var acknowledged: Int?
    var mounted: Set<SettingsMapID> = []
    /// Every decision the arrival owner made, in order, and the same as events to wait on.
    var decisions: [SettingsArrivalDecision] = []
    let decisionEvents: AsyncStream<SettingsArrivalDecision>
    let decisionSink: AsyncStream<SettingsArrivalDecision>.Continuation
    /// Where the arrival owner landed, in order.
    var landings: [SettingsArrivalRung] {
      decisions.compactMap {
        if case .arrive(let id, let kind) = $0.action { SettingsArrivalRung(id: id, kind: kind) } else { nil }
      }
    }
    /// Runs synchronously inside the owner's decision report, before the test's await resumes.
    var afterDecision: ((SettingsArrivalDecision) -> Void)?
    func record(_ decision: SettingsArrivalDecision) {
      decisions.append(decision)
      afterDecision?(decision)
      decisionSink.yield(decision)
    }
    let focusEvents: AsyncStream<SettingsArrivalFocusRequest>
    let focusSink: AsyncStream<SettingsArrivalFocusRequest>.Continuation
    /// Where the owner said it drew the ring: place, frame and clip, latest last.
    var rings: [(id: SettingsMapID, rect: CGRect, clip: CGRect)] = []
    /// Every focus request the owner published, in order.
    var focusRequests: [SettingsArrivalFocusRequest] = []
    /// Set by a stepper's hang guard when no matching decision came.
    var hangGuardFired = false
    /// What `settingsArrivalStillCurrent` answers: false once another navigation happened.
    var current = true
    let acknowledgements: AsyncStream<Int>
    let acknowledgementSink: AsyncStream<Int>.Continuation
    init() {
      (acknowledgements, acknowledgementSink) = AsyncStream<Int>.makeStream()
      (decisionEvents, decisionSink) = AsyncStream<SettingsArrivalDecision>.makeStream()
      (focusEvents, focusSink) = AsyncStream<SettingsArrivalFocusRequest>.makeStream()
    }
  }

  /// The real Dictionary page under one arrival owner, as the window's `page { }` hosts it.
  struct DictionaryPage: View {
    let box: RevealBox
    /// Handed in as a new root value once the page is scrolled, as the window hands a page its
    /// reveal.
    let reveal: SettingsReveal?
    @State var tab: DictionaryTab
    let environment: (AnyView) -> AnyView

    var body: some View {
      environment(AnyView(YourWordsView(selection: $tab)))
        // What the window's `page { }` sets; YourWordsView tags its own tab inside (#3545).
        .environment(\.settingsArrivalContent, SettingsArrivalContent(page: .dictionary))
        .onPreferenceChange(SettingsRevealAnchorKey.self) { places in
          MainActor.assumeIsolated { box.mounted = Set(places.keys) }
        }
        .modifier(SettingsArrivalModifier())
        .environment(\.settingsReveal, reveal)
        .environment(\.settingsArrivalStillCurrent) { _ in box.current }
        .environment(\.settingsArrivalDecided) { box.record($0) }
        .environment(\.settingsRevealAcknowledge) { token in
          box.acknowledged = token
          box.acknowledgementSink.yield(token)
        }
    }
  }

  /// The scroll view holding the most content: the Dictionary's word list.
  static func tallestScrollView(in view: NSView) -> NSScrollView? {
    var all: [NSScrollView] = []
    func walk(_ v: NSView) {
      if let scroll = v as? NSScrollView { all.append(scroll) }
      v.subviews.forEach(walk)
    }
    walk(view)
    return all.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
  }

  /// Hosts the real Dictionary page with 200 words (four pages of 50), optionally scrolls its
  /// list to the bottom, then reveals `entryID`. Returns the acknowledged token and how far the
  /// list is scrolled afterwards (AppKit's own reading, independent of the arrival's geometry).
  static func dictionaryArrival(
    at entryID: String, tab: DictionaryTab, height: CGFloat, scrolledToBottom: Bool
  ) async throws -> (
    acknowledged: Int?, landed: SettingsArrivalRung?, scrolledBefore: CGFloat, scrolledAfter: CGFloat
  ) {
    let (home, words) = try SettingsMapRenderingTests.dictionaryHome()
    for index in 0..<200 {
      try #require(words.add(CustomWord(canonical: "Arrivalword\(index)")) == nil)
    }
    let box = RevealBox()
    let environment: (AnyView) -> AnyView = { view in
      (try? SettingsMapRenderingTests.dictionaryEnvironment(view, home: home, words: words))
        ?? AnyView(EmptyView())
    }
    func page(_ reveal: SettingsReveal?) -> some View {
      DictionaryPage(box: box, reveal: reveal, tab: tab, environment: environment)
        .frame(width: 900, height: height)
    }
    let host = NSHostingView(rootView: page(nil))
    host.frame = CGRect(x: 0, y: 0, width: 900, height: height)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let list = try #require(tallestScrollView(in: host), "the page has no scroll view")
    if scrolledToBottom {
      let document = try #require(list.documentView)
      let bottom = max(0, document.frame.height - list.contentView.bounds.height)
      list.contentView.scroll(to: NSPoint(x: 0, y: bottom))
      list.reflectScrolledClipView(list.contentView)
      host.layoutSubtreeIfNeeded()
    }
    let before = list.contentView.bounds.origin.y
    // Finish the work the first layout and the scroll queued, so the page's own deferred decision
    // has run before the person chooses; choosing in that same turn is chunk 2's case (#3545).
    await SettingsArrivalFocusTests.afterQueuedMainWork()
    host.layoutSubtreeIfNeeded()
    if scrolledToBottom && height < 400 {
      try #require(
        box.mounted.contains(.yourWordsAdd) == false,
        "the short-pane fixture must unmount Add before arrival: \(box.mounted.map(\.rawValue).sorted())")
    }
    host.rootView = page(try Self.reveal(entryID, token: 9))
    // test-fixture-timer: an offscreen host only lays out when asked; this pumps layout (and the
    // scroll the arrival starts) while the test waits on the acknowledgement event itself.
    let pump = Task { @MainActor in
      while !Task.isCancelled {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(20))
      }
    }
    let guardTask = Task { @MainActor in
      // deadline-fallback: a hang guard around the event stream; the wait is the event itself.
      try? await Task.sleep(for: .seconds(10))
      guard !Task.isCancelled else { return }
      box.acknowledgementSink.finish()
    }
    for await _ in box.acknowledgements { break }
    pump.cancel()
    guardTask.cancel()
    host.layoutSubtreeIfNeeded()
    if box.acknowledged == nil {
      Issue.record("no arrival at \(entryID); page published \(box.mounted.map(\.rawValue).sorted())")
    }
    return (box.acknowledged, box.landings.last, before, list.contentView.bounds.origin.y)
  }

  @Test(
    "the real Dictionary page: a Your Words control from the bottom of a long list, and a Learn From row",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/3545", "Dictionary arrival"))
  func realDictionaryArrival() async throws {
    _ = SettingsMap.takeRecordedFaults()
    // Tall pane: the list controls are pinned, so they stay on screen while the words scroll.
    let pinned = try await Self.dictionaryArrival(
      at: "yourWords.add", tab: .yourWords, height: 700, scrolledToBottom: true)
    #expect(pinned.acknowledged == 9, "pinned controls, list scrolled to the bottom")
    #expect(pinned.landed == SettingsArrivalRung(id: .yourWordsAdd, kind: .target))
    #expect(pinned.scrolledBefore > 0, "the fixture scrolled the list")
    // Short pane: the controls do not fit pinned, so they scroll away with the words and the
    // arrival has to bring them back.
    let unpinned = try await Self.dictionaryArrival(
      at: "yourWords.add", tab: .yourWords, height: 380, scrolledToBottom: true)
    #expect(unpinned.acknowledged == 9, "unpinned controls far above the visible words")
    #expect(unpinned.landed == SettingsArrivalRung(id: .yourWordsAdd, kind: .target))
    #expect(unpinned.scrolledBefore > 0, "the fixture scrolled the list")
    #expect(
      unpinned.scrolledAfter < unpinned.scrolledBefore,
      "the list scrolled back toward the controls: \(unpinned.scrolledBefore) to \(unpinned.scrolledAfter)")
    let learn = try await Self.dictionaryArrival(
      at: "selfLearningDictionary", tab: .learnFrom, height: 700, scrolledToBottom: false)
    #expect(learn.acknowledged == 9, "a Learn From row")
    #expect(learn.landed == SettingsArrivalRung(id: .selfLearningDictionary, kind: .target))
    #expect(SettingsMap.takeRecordedFaults().isEmpty)
  }
}
