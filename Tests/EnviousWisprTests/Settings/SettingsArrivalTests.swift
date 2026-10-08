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
    return SettingsReveal(
      entryID: entryID, anchor: request.target, fallbacks: request.fallbacks, token: token)
  }

  @Test("nothing happens without a reveal, for a handled token, or on another page or tab")
  func noArrival() throws {
    let reveal = try Self.reveal("pauseDuration", token: 3)
    #expect(
      Planner.decide(
        reveal: nil, showing: true, mounted: [.pauseDuration], handledToken: nil,
        canMaterialize: false) == .none)
    #expect(
      Planner.decide(
        reveal: reveal, showing: true, mounted: [.pauseDuration], handledToken: 3,
        canMaterialize: false) == .none, "a handled token arrived again")
    #expect(
      Planner.decide(
        reveal: reveal, showing: false, mounted: [.pauseDuration], handledToken: nil,
        canMaterialize: false) == .none, "arrived while another tab was showing")
  }

  @Test("an empty control inventory waits; it is never read as 'hidden'")
  func emptyInventoryWaits() throws {
    let reveal = try Self.reveal("pauseDuration")
    #expect(
      Planner.decide(
        reveal: reveal, showing: true, mounted: [], handledToken: nil, canMaterialize: false)
        == .wait)
  }

  @Test("the chosen control when it is on the page, else the first declared fallback on it")
  func anchorThenFallback() throws {
    let reveal = try Self.reveal("pauseDuration")
    try #require(!reveal.fallbacks.isEmpty, "pauseDuration declares a fallback")
    #expect(
      Planner.decide(
        reveal: reveal, showing: true, mounted: [reveal.anchor, reveal.fallbacks[0]],
        handledToken: nil, canMaterialize: false) == .arrive(reveal.anchor, isFallback: false))
    #expect(
      Planner.decide(
        reveal: reveal, showing: true, mounted: [reveal.fallbacks[0], .windowSearch],
        handledToken: nil, canMaterialize: false)
        == .arrive(reveal.fallbacks[0], isFallback: true))
  }

  @Test("lazy content is scrolled to its top before any fallback; then a missing place faults")
  func materializeBeforeFallback() throws {
    let reveal = try Self.reveal("yourWords.export")
    #expect(
      Planner.decide(
        reveal: reveal, showing: true, mounted: [.enableDictionary], handledToken: nil,
        canMaterialize: true) == .materialize)
    #expect(
      Planner.decide(
        reveal: reveal, showing: true, mounted: [.enableDictionary], handledToken: nil,
        canMaterialize: false) == .fault)
  }

  @Test("a mounted fallback never wins while lazy content may still hold the chosen control")
  func lazyPrimaryBeatsMountedFallback() throws {
    let reveal = try Self.reveal("pauseDuration")
    let fallback = try #require(reveal.fallbacks.first)
    #expect(
      Planner.decide(
        reveal: reveal, showing: true, mounted: [fallback], handledToken: nil,
        canMaterialize: true) == .materialize)
    #expect(
      Planner.decide(
        reveal: reveal, showing: true, mounted: [fallback], handledToken: nil,
        canMaterialize: false) == .arrive(fallback, isFallback: true))
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
  static func arrival(at entryID: String) async throws -> Int? {
    let reveal = try Self.reveal(entryID, token: 7)
    var acknowledged: Int?
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
    }
    .modifier(SettingsArrivalModifier())
    .environment(\.settingsReveal, reveal)
    .environment(\.settingsRevealIsShowing) { _ in acknowledged == nil }
    .environment(\.settingsRevealAcknowledge) { acknowledged = $0 }
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
    return acknowledged
  }

  @Test("a tab outside the page's scroll view and a row far below the fold are both arrived at")
  func pageOwnerReachesEveryPlace() async throws {
    _ = SettingsMap.takeRecordedFaults()
    #expect(try await Self.arrival(at: "dictation.tab.microphone") == 7, "the tab strip")
    #expect(try await Self.arrival(at: "autoCopyToClipboard") == 7, "scrolled into view")
    #expect(
      try await Self.arrival(at: "selfLearningDictionary") == 7, "a row inside a registered card")
    #expect(SettingsMap.takeRecordedFaults().isEmpty)
  }

  // MARK: - The real Dictionary page (#3545 T7)

  /// What a hosted page reports back: the acknowledged token (also as an event the test awaits)
  /// and what it published beside the arrival owner.
  @MainActor final class RevealBox {
    var acknowledged: Int?
    var mounted: Set<SettingsMapID> = []
    let acknowledgements: AsyncStream<Int>
    let acknowledgementSink: AsyncStream<Int>.Continuation
    init() { (acknowledgements, acknowledgementSink) = AsyncStream<Int>.makeStream() }
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
        .onPreferenceChange(SettingsRevealAnchorKey.self) { places in
          MainActor.assumeIsolated { box.mounted = Set(places.keys) }
        }
        .modifier(SettingsArrivalModifier())
        .environment(\.settingsReveal, reveal)
        .environment(\.settingsRevealIsShowing) { _ in box.acknowledged == nil }
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
  ) async throws -> (acknowledged: Int?, scrolledBefore: CGFloat, scrolledAfter: CGFloat) {
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
      box.acknowledgementSink.finish()
    }
    for await _ in box.acknowledgements { break }
    pump.cancel()
    guardTask.cancel()
    host.layoutSubtreeIfNeeded()
    if box.acknowledged == nil {
      Issue.record("no arrival at \(entryID); page published \(box.mounted.map(\.rawValue).sorted())")
    }
    return (box.acknowledged, before, list.contentView.bounds.origin.y)
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
    #expect(pinned.scrolledBefore > 0, "the fixture scrolled the list")
    // Short pane: the controls do not fit pinned, so they scroll away with the words and the
    // arrival has to bring them back.
    let unpinned = try await Self.dictionaryArrival(
      at: "yourWords.add", tab: .yourWords, height: 380, scrolledToBottom: true)
    #expect(unpinned.acknowledged == 9, "unpinned controls far above the visible words")
    #expect(unpinned.scrolledBefore > 0, "the fixture scrolled the list")
    #expect(
      unpinned.scrolledAfter < unpinned.scrolledBefore,
      "the list scrolled back toward the controls: \(unpinned.scrolledBefore) to \(unpinned.scrolledAfter)")
    let learn = try await Self.dictionaryArrival(
      at: "selfLearningDictionary", tab: .learnFrom, height: 700, scrolledToBottom: false)
    #expect(learn.acknowledged == 9, "a Learn From row")
    #expect(SettingsMap.takeRecordedFaults().isEmpty)
  }
}
