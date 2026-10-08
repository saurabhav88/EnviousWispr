import AppKit
import SwiftParser
import SwiftSyntax
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// Focus after a Settings search arrival (#3482 plan §3.4). **When this fails, choosing a result
/// leaves keyboard focus stuck in the search field, moves it onto something that cannot take it,
/// gives a heading a tab stop, or moves VoiceOver or the keyboard after the person already went
/// somewhere else.** Real keyboard and VoiceOver focus cannot be asserted here (a test process
/// has no key window); the decisions, the adapters each page publishes, the one-shot request and
/// the no-new-tab-stop rule are, and the live check covers the rest.
@MainActor
@Suite("Settings search arrival focus (#3482)", .tags(.productOutcome))
struct SettingsArrivalFocusTests {
  typealias Planner = SettingsArrivalFocusPlanner

  // MARK: - The decision

  @Test("a control gets keyboard and VoiceOver focus, a read-only place VoiceOver focus only")
  func planKinds() {
    let kinds: [SettingsMapID: SettingsArrivalFocusKind] = [
      .theme: .control, .sectionAppearance: .readOnly,
    ]
    #expect(
      Planner.plan(target: .theme, token: 4, kinds: kinds).request
        == SettingsArrivalFocusRequest(token: 4, target: .theme, kind: .control))
    #expect(
      Planner.plan(target: .sectionAppearance, token: 4, kinds: kinds).request
        == SettingsArrivalFocusRequest(token: 4, target: .sectionAppearance, kind: .readOnly))
  }

  @Test("the search field is released for every arrival, even one with no adapter")
  func searchIsAlwaysReleased() {
    #expect(Planner.plan(target: .theme, token: 1, kinds: [.theme: .control]).releaseSearch)
    let none = Planner.plan(target: .theme, token: 1, kinds: [:])
    #expect(none.releaseSearch, "focus would stay in the search field")
    #expect(none.request == nil, "a request for a place nobody can focus")
  }

  @Test("keyboard focus is asked of a toggle or button only with Full Keyboard Access on")
  func keyboardFocusNeedsAControlThatTakesIt() {
    #expect(!Planner.mayAskKeyboardFocus(takesFocusAlways: false, fullKeyboardAccess: false))
    #expect(Planner.mayAskKeyboardFocus(takesFocusAlways: false, fullKeyboardAccess: true))
    #expect(Planner.mayAskKeyboardFocus(takesFocusAlways: true, fullKeyboardAccess: false))
  }

  @Test("a control beats a read-only registration of the same place, in either order")
  func controlWins() {
    var value: [SettingsMapID: SettingsArrivalFocusKind] = [:]
    SettingsArrivalFocusKey.reduce(value: &value) { [.theme: .readOnly] }
    SettingsArrivalFocusKey.reduce(value: &value) { [.theme: .control] }
    #expect(value[.theme] == .control)
    var other: [SettingsMapID: SettingsArrivalFocusKind] = [:]
    SettingsArrivalFocusKey.reduce(value: &other) { [.theme: .control] }
    SettingsArrivalFocusKey.reduce(value: &other) { [.theme: .readOnly] }
    #expect(other[.theme] == .control)
  }

  @Test("a pending move runs only for the arrival just handled, and only while its page is showing")
  func revalidation() {
    #expect(Planner.mayMove(pendingToken: 3, handledToken: 3, showing: true))
    #expect(Planner.mayMove(pendingToken: 3, handledToken: 3, showing: false) == false)
    #expect(
      Planner.mayMove(pendingToken: 3, handledToken: 4, showing: true) == false, "a newer arrival")
    #expect(Planner.mayMove(pendingToken: 3, handledToken: nil, showing: true) == false)
  }

  // MARK: - A real arrival, hosted

  enum Event: Equatable {
    case acknowledged(Int)
    case released
    case request(SettingsArrivalFocusRequest?)
  }

  @MainActor final class Recorder {
    let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private(set) var events: [Event] = []
    /// The window's navigation, as `SettingsNavigationState` keeps it: the reveal clears when it is
    /// acknowledged; `showing` is whether its page and tab are on screen.
    var showing = true
    var revealToken: Int? = 1
    /// Runs inside the acknowledgement, before the arrival's focus move is judged.
    var onAcknowledge: (() -> Void)?

    init() { (stream, continuation) = AsyncStream<Event>.makeStream() }
    func record(_ event: Event) {
      events.append(event)
      continuation.yield(event)
    }
    func finish() { continuation.finish() }
  }

  /// Stands where an adapter stands: reads the request the arrival owner publishes and reports it,
  /// and takes it, as the adapter that acts does.
  struct Probe: View {
    let recorder: Recorder
    @Environment(\.settingsArrivalFocusRequest) private var request
    @Environment(\.settingsArrivalFocusTaken) private var taken

    var body: some View {
      Color.clear.frame(width: 1, height: 1)
        .onChange(of: request, initial: true) { _, new in
          recorder.record(.request(new))
          if let new { taken(new) }
        }
    }
  }

  /// A page with `content` arriving at `entryID`. Returns once `done` accepts an event, and keeps
  /// the page alive until then.
  static func arrive(
    at entryID: String, recorder: Recorder,
    @ViewBuilder content: () -> some View, until done: (Event) -> Bool
  ) async throws {
    let request = try #require(SettingsSearchRequest(entryID: entryID))
    let reveal = SettingsReveal(
      entryID: entryID, anchor: request.target, fallbacks: request.fallbacks, token: 1)
    // Built as the window's `page { }` builds it: the page's one arrival owner above the page.
    let page = SettingsContentView {
      content()
      Probe(recorder: recorder)
    }
    .modifier(SettingsArrivalModifier())
    .environment(\.settingsReveal, reveal)
    .environment(\.settingsRevealIsShowing) { [recorder] reveal in
      recorder.showing && recorder.revealToken == reveal.token
    }
    .environment(\.settingsArrivalStillCurrent) { [recorder] reveal in
      recorder.showing && reveal.token == 1
    }
    .environment(\.settingsRevealAcknowledge) { [recorder] token in
      if recorder.revealToken == token { recorder.revealToken = nil }
      recorder.onAcknowledge?()
      recorder.record(.acknowledged(token))
    }
    .environment(\.settingsArrivalReleaseSearchFocus) { [recorder] in recorder.record(.released) }
    .frame(width: 700, height: 500)
    let host = NSHostingView(rootView: page)
    host.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    host.layoutSubtreeIfNeeded()
    var finished = false
    let guardTask = Task { @MainActor in
      // deadline-fallback: a hang guard around the event stream; the wait is the events themselves
      try? await Task.sleep(for: .seconds(10))
      recorder.finish()
    }
    for await event in recorder.stream {
      host.layoutSubtreeIfNeeded()
      if done(event) {
        finished = true
        break
      }
    }
    guardTask.cancel()
    #expect(finished, "the arrival never produced the expected events: \(recorder.events)")
  }

  /// Runs after everything already queued on the main queue, which is where the arrival queues
  /// its focus move: the way to observe that a move did NOT happen.
  static func afterQueuedMainWork() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  @Test("arriving at a control releases the search field, then asks that control once")
  func controlArrival() async throws {
    let recorder = Recorder()
    var sawRequest = false
    try await Self.arrive(
      at: "pauseDuration", recorder: recorder,
      content: {
        Button("Pause duration") {}
          .settingsArrivalFocusControl()
          .settingsMapRegistration(.pauseDuration)
      },
      until: { event in
        if case .request(.some) = event { sawRequest = true }
        return sawRequest && event == .request(nil)
      })
    let events = recorder.events
    let expected = SettingsArrivalFocusRequest(token: 1, target: .pauseDuration, kind: .control)
    #expect(events.filter { $0 == .released }.count == 1, "\(events)")
    #expect(events.filter { $0 == .request(expected) }.count == 1, "\(events)")
    let released = try #require(events.firstIndex(of: .released))
    let asked = try #require(events.firstIndex(of: .request(expected)))
    #expect(released < asked, "focus was moved before the search field let go: \(events)")
    // Taken once: the request goes back to nil and is not offered again.
    #expect(events.last == .request(nil))
  }

  /// Hosts one real control adapter handed `request` directly, with the owner's live check
  /// answering `current`; returns how often the adapter acted and reported the request taken.
  static func adapterActs(
    current: Bool, textEntry: Bool = true, fullKeyboardAccess: Bool = false
  ) async -> (performed: Int, taken: Int) {
    let request = SettingsArrivalFocusRequest(token: 1, target: .pauseDuration, kind: .control)
    var performed = 0
    var taken = 0
    let view = Button("Pause duration") {}
      .settingsArrivalFocusControl(textEntry: textEntry, perform: { performed += 1 })
      .settingsMapRegistration(.pauseDuration)
      .environment(\.settingsArrivalFocusRequest, request)
      .environment(\.settingsArrivalFullKeyboardAccess, fullKeyboardAccess)
      .environment(\.settingsArrivalFocusIsCurrent) { asked in asked == request && current }
      .environment(\.settingsArrivalFocusTaken) { _ in taken += 1 }
      .frame(width: 300, height: 100)
    let host = NSHostingView(rootView: view)
    host.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    host.layoutSubtreeIfNeeded()
    await afterQueuedMainWork()
    host.layoutSubtreeIfNeeded()
    await afterQueuedMainWork()
    return (performed, taken)
  }

  @Test("an adapter acts only while the owner says its arrival is current")
  func adapterChecksCurrency() async {
    // Control: the same request acts when current, so the refusal below is the check's doing.
    let live = await Self.adapterActs(current: true)
    #expect(live.performed == 1 && live.taken == 1, "\(live)")
    // A request that outlived its arrival (a same-place navigation or a window close since).
    let stale = await Self.adapterActs(current: false)
    #expect(stale.performed == 0 && stale.taken == 0, "\(stale)")
  }

  @Test("a tab or button is not asked for keyboard focus without Full Keyboard Access, a text field is")
  func adapterGatesKeyboardFocus() async {
    // The Dictation tab strip: it moves focus through its owner's closure, and a tab cannot take
    // focus with Full Keyboard Access off, so asking made focus fall back to the search field.
    let tab = await Self.adapterActs(current: true, textEntry: false, fullKeyboardAccess: false)
    #expect(tab.performed == 0, "a tab was asked for keyboard focus with Full Keyboard Access off: \(tab)")
    #expect(tab.taken == 1, "the request must still be taken, so it is not offered again: \(tab)")
    // Controls: the same adapter asks with Full Keyboard Access on, and a text field always asks.
    let withAccess = await Self.adapterActs(current: true, textEntry: false, fullKeyboardAccess: true)
    #expect(withAccess.performed == 1, "\(withAccess)")
    let textField = await Self.adapterActs(current: true, textEntry: true, fullKeyboardAccess: false)
    #expect(textField.performed == 1, "\(textField)")
  }

  @Test("a place that is not a control is offered to VoiceOver only")
  func readOnlyArrival() async throws {
    let recorder = Recorder()
    var sawRequest = false
    try await Self.arrive(
      at: "pauseDuration", recorder: recorder,
      content: {
        Text("Pause duration").settingsMapRegistration(.pauseDuration)
      },
      until: { event in
        if case .request(.some) = event { sawRequest = true }
        return sawRequest && event == .request(nil)
      })
    let expected = SettingsArrivalFocusRequest(token: 1, target: .pauseDuration, kind: .readOnly)
    #expect(recorder.events.contains(.request(expected)), "\(recorder.events)")
    #expect(recorder.events.contains(.released), "the search field kept focus")
  }

  @Test("a fallback place is focused through its own adapter, not the missing primary's")
  func fallbackArrival() async throws {
    let recorder = Recorder()
    var sawRequest = false
    // Pause duration is not on the page (auto-stop is off); Stop recording on silence is.
    try await Self.arrive(
      at: "pauseDuration", recorder: recorder,
      content: {
        Button("Stop recording on silence") {}
          .settingsArrivalFocusControl()
          .settingsMapRegistration(.stopOnSilence)
      },
      until: { event in
        if case .request(.some) = event { sawRequest = true }
        return sawRequest && event == .request(nil)
      })
    let expected = SettingsArrivalFocusRequest(token: 1, target: .stopOnSilence, kind: .control)
    #expect(recorder.events.contains(.request(expected)), "\(recorder.events)")
  }

  @Test("an arrival whose page stopped showing in between moves nothing")
  func staleArrivalMovesNothing() async throws {
    let recorder = Recorder()
    // Judged again one layout pass after the scroll: the person has gone to another tab.
    recorder.onAcknowledge = { [recorder] in recorder.showing = false }
    try await Self.arrive(
      at: "pauseDuration", recorder: recorder,
      content: {
        Button("Pause duration") {}
          .settingsArrivalFocusControl()
          .settingsMapRegistration(.pauseDuration)
      },
      until: { $0 == .acknowledged(1) })
    await Self.afterQueuedMainWork()
    #expect(recorder.events.contains(.released) == false, "\(recorder.events)")
    #expect(
      recorder.events.contains { if case .request(.some) = $0 { true } else { false } } == false,
      "\(recorder.events)")
  }

  // MARK: - What each real page publishes

  struct Published {
    let kinds: [SettingsMapID: SettingsArrivalFocusKind]
    let registered: Set<SettingsMapID>
    let keyViews: Int
  }

  static func render(_ label: String) async throws -> Published {
    let focus = SettingsMapRenderingTests.FocusSink()
    let stops = SettingsMapRenderingTests.TabStopSink()
    let rendered = try await SettingsMapRenderingTests.$focusSink.withValue(focus) {
      try await SettingsMapRenderingTests.$tabStopSink.withValue(stops) {
        try await SettingsMapRenderingTests.render(label)
      }
    }
    return Published(
      kinds: focus.kinds, registered: Set(SettingsMapRenderingTests.mapped(rendered.list)),
      keyViews: stops.keyViews)
  }

  /// Written from what each control IS on the page (a toggle, a picker, a button, a text field,
  /// a heading), not read from the adapters.
  static let expectations: [(label: String, controls: [SettingsMapID], readOnly: [SettingsMapID])] = [
    ("appSettings.appearance", [.theme, .appLanguage, .showInDock, .updateAlertInMenuBar], [.sectionAppearance]),
    (
      "aiPolish.openAI.savedKey",
      [.apiKeyOpenAI, .apiKeySave, .apiKeyClear, .apiKeyGetKeyLink, .enableAIPolish, .aiPolishProvider, .polishModel],
      [.sectionAiPolishModel, .aiPolishProviderSection]
    ),
    ("snippets", [.snippetKeyword, .snippetsAdd, .snippetsSearch], [.snippets]),
    ("keybinds", [.recordKeybind, .recordingMode, .escapeRecovery], [.sectionKeybindsRecording]),
    ("dictation.microphone", [.inputDevice, .micReadiness, .bluetoothGuideLearnMore], [.sectionMicrophone, .bluetoothGuide]),
    (
      "dictation.engine.switchesOn",
      [.stopOnSilence, .pauseDuration, .unloadModelAfter, .transcriptionEngine, .startWordField],
      [.currentEngineSection, .sectionTranscriptionEngine]
    ),
    ("dictation.chimes", [.recordingChimes, .recordingChimeAirGlint], [.sectionChimes, .recordingChime]),
    ("dictation.pill", [.pillPosition, .pillStyle], [.sectionPill]),
    ("dictionary.learnFrom", [.selfLearningDictionary, .contactsSyncOnLaunch, .importContacts], [.learnFrom]),
    ("appSettings.permissions", [], [.sectionPermissions]),
    ("transcribeFile", [], [.transcribeFileSteps]),
  ]

  /// Real controls the per-page lists above leave out: the tab strips, per-row buttons, links,
  /// toggles and pickers, and the chime cards. Each is a button, toggle, picker or link on screen.
  /// A panel or heading must never appear here.
  static let otherRealControls: Set<String> = [
    "appSettings.tab.appearance", "appSettings.tab.licenses", "appSettings.tab.permissions",
    "appSettings.tab.privacy", "dictation.tab.chimes", "dictation.tab.clipboard",
    "dictation.tab.engine", "dictation.tab.livePreview", "dictation.tab.microphone",
    "dictation.tab.pill", "aiPolish.link.openAIRateLimits", "apiKey.reveal", "polishModel.refresh",
    "snippets.export", "snippets.import", "cancelKeybind", "copyLastKeybind", "pasteLastKeybind",
    "quickAddKeybind", "mediaDuringDictation", "autoDetectLanguage",
    "autoDetectLanguage.resetSuggestions", "fasterTranscription", "fillerRemoval",
    "lockedLanguage.change", "spokenEmoji", "spokenPunctuation", "startWord.reset", "startWord.save",
    "startWordLanguage", "transcriptionEngine.change", "transcriptionEngine.recheckFast",
    "recordingChime.cloudPop", "recordingChime.dustMote", "recordingChime.lowNod",
    "recordingChime.mutedConfirm", "recordingChime.paperTap", "recordingChime.roundPebble",
    "recordingChime.satinShift", "recordingChime.softHush", "recordingChime.velvetHush",
    "recordingChime.velvetTap", "recordingChime.whisperTick", "pillStyle.configureLivePreview",
    "selfLearningDictionary.learnMore",
  ]

  @Test("each page's toggles, pickers, buttons and text fields are controls; its headings are not")
  func pagesPublishTheRightAdapters() async throws {
    for expected in Self.expectations {
      let page = try await Self.render(expected.label)
      for id in expected.controls {
        #expect(page.kinds[id] == .control, "\(expected.label): \(id.rawValue) is \(String(describing: page.kinds[id]))")
      }
      for id in expected.readOnly {
        #expect(page.kinds[id] == .readOnly, "\(expected.label): \(id.rawValue) is \(String(describing: page.kinds[id]))")
      }
      // The whole set, not a subset: a panel must not be published as a control because an unrelated
      // button inside it inherited the panel's place (a Learn From panel's Import button).
      let published = Set(page.kinds.filter { $0.value == .control }.keys)
      let extra = published.subtracting(expected.controls).filter { !Self.otherRealControls.contains($0.rawValue) }
      #expect(extra.isEmpty, "\(expected.label): unexpected controls \(extra.map(\.rawValue).sorted())")
      // An adapter can only be asked for a place the page registers.
      let strays = Set(page.kinds.keys).subtracting(page.registered)
      #expect(strays.isEmpty, "\(expected.label): adapters for unregistered places \(strays.map(\.rawValue))")
    }
  }

  /// The Learn From row offers an action button only while its model is missing, a state the default
  /// `.unwired` picture never shows. That button opts out of the panel's place; if it did not, the
  /// whole panel would publish as a control and a search result for it would land on the button.
  @Test("the Learn From panel stays read-only while its row offers an action button")
  func learnFromActionButtonDoesNotClaimThePanel() async throws {
    let page = try await Self.render("dictionary.learnFrom.download")
    #expect(page.kinds[.learnFrom] == .readOnly, "the panel is published as \(String(describing: page.kinds[.learnFrom]))")
    let controls: Set<SettingsMapID> = [.selfLearningDictionary, .contactsSyncOnLaunch, .importContacts]
    let published = Set(page.kinds.filter { $0.value == .control }.keys)
    let extra = published.subtracting(controls).filter { !Self.otherRealControls.contains($0.rawValue) }
    #expect(extra.isEmpty, "unexpected controls \(extra.map(\.rawValue).sorted())")
  }

  // MARK: - No new tab stops

  /// AppKit views that can become key views on each page, counted by the same counter on commit
  /// 7f9d24c6, before any focus adapter existed (the baseline worktree ran this exact count).
  static let baselineKeyViews: [String: Int] = [
    "appSettings.appearance": 0, "aiPolish.openAI.savedKey": 1, "snippets": 2, "keybinds": 0,
    "dictation.microphone": 0, "dictation.engine.switchesOn": 1, "dictation.chimes": 0,
    "dictation.pill": 0, "dictionary.learnFrom": 0, "appSettings.privacy": 0,
  ]

  @Test("no page gains a key view (a tab stop) from the adapters")
  func noNewKeyViews() async throws {
    for (label, before) in Self.baselineKeyViews.sorted(by: { $0.key < $1.key }) {
      let page = try await Self.render(label)
      #expect(page.keyViews == before, "\(label): \(page.keyViews) key views, \(before) before")
    }
  }

  @Test("the adapters bind focus state; they never make a view focusable")
  func adaptersAddNoFocusability() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(
        "Sources/EnviousWisprAppKit/Views/Settings/SettingsArrivalFocus.swift"), encoding: .utf8)
    let tree = Parser.parse(source: source)
    let names = Set(
      tree.tokens(viewMode: .sourceAccurate).compactMap { token -> String? in
        if case .identifier(let text) = token.tokenKind { return text }
        return nil
      })
    // The positive control: the names this file is supposed to use are seen.
    #expect(names.isSuperset(of: ["focused", "accessibilityFocused", "FocusState"]), "\(names)")
    // The ways SwiftUI makes a view a keyboard stop.
    for forbidden in ["focusable", "focusSection", "focusEffectDisabled", "defaultFocus"] {
      #expect(names.contains(forbidden) == false, "SettingsArrivalFocus.swift uses \(forbidden)")
    }
  }
}
