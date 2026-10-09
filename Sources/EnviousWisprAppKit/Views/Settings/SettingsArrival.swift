import AppKit
import EnviousWisprCore
import SwiftUI

// Arrival after a search navigation (#3482 plan §3.4): scroll the chosen place into view, draw
// a ring around it for a few seconds, say where the person landed, then acknowledge the reveal
// so a remount never replays it. Selecting a result only navigates and reveals; nothing here
// changes a setting.

/// Where a registered control is, the scroll view it sits in (nil: fixed on the page, such as
/// a tab strip or a pinned heading), and the content it was drawn in (#3545): carried in the same
/// value, so the arrival owner never pairs controls with a separately cached page or tab.
struct SettingsRevealPlace: Equatable {
  let bounds: Anchor<CGRect>
  let viewport: SettingsArrivalViewportID?
  let content: SettingsArrivalContent?
}

/// The rendered content a control belongs to: its page, and its tab where the page has tabs
/// (#3545). Set by `page { }` for the page and by each tabbed page around the tab it renders.
struct SettingsArrivalContent: Hashable, Sendable {
  let page: SettingsPage
  let dictationTab: DictationTab?
  let appSettingsTab: AppSettingsTab?
  let dictionaryTab: DictionaryTab?

  init(
    page: SettingsPage, dictationTab: DictationTab? = nil, appSettingsTab: AppSettingsTab? = nil,
    dictionaryTab: DictionaryTab? = nil
  ) {
    self.page = page
    self.dictationTab = dictationTab
    self.appSettingsTab = appSettingsTab
    self.dictionaryTab = dictionaryTab
  }

  /// The content a map destination is drawn in. A Dictionary entry without a tab is page-level.
  init(destination: SettingsDestination, dictionaryTab: DictionaryTab?) {
    switch destination {
    case .dictation(let tab): self.init(page: .dictation, dictationTab: tab)
    case .appSettings(let tab): self.init(page: .appSettings, appSettingsTab: tab)
    case .dictionary: self.init(page: .dictionary, dictionaryTab: dictionaryTab)
    default: self.init(page: destination.page)
    }
  }

  /// The page without any tab: what fixed controls (tab strips, fixed headings) carry.
  var pageOnly: SettingsArrivalContent { SettingsArrivalContent(page: page) }
}

/// The top of a page's lazy content and the content it belongs to (#3545), so arrival scrolls
/// there only for the destination's own lazy content.
struct SettingsArrivalLazyTop: Equatable {
  let scrollID: String
  let content: SettingsArrivalContent
}

/// Where each registered control is, by map id; the page's one arrival owner reads it.
struct SettingsRevealAnchorKey: PreferenceKey {
  static let defaultValue: [SettingsMapID: SettingsRevealPlace] = [:]
  static func reduce(
    value: inout [SettingsMapID: SettingsRevealPlace],
    nextValue: () -> [SettingsMapID: SettingsRevealPlace]
  ) {
    value.merge(nextValue()) { first, _ in first }
  }
}

/// One scroll view on a page that holds registered controls.
struct SettingsArrivalViewportID: Hashable {
  fileprivate let id = UUID()
}

/// The visible frame of each marked scroll view, so a control scrolled out of its scroll view is
/// not counted as on screen just because it is still inside the page.
struct SettingsArrivalViewportKey: PreferenceKey {
  static let defaultValue: [SettingsArrivalViewportID: Anchor<CGRect>] = [:]
  static func reduce(
    value: inout [SettingsArrivalViewportID: Anchor<CGRect>],
    nextValue: () -> [SettingsArrivalViewportID: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { first, _ in first }
  }
}

/// The scroll id at the top of a page's lazy content (Dictionary), so arrival can scroll there to
/// make lazy rows exist before it gives up on them. nil: the page has no lazy content.
struct SettingsArrivalLazyTopKey: PreferenceKey {
  static let defaultValue: SettingsArrivalLazyTop? = nil
  static func reduce(value: inout SettingsArrivalLazyTop?, nextValue: () -> SettingsArrivalLazyTop?) {
    value = value ?? nextValue()
  }
}

/// The scroll identity of a registered control: its own wrapper type, so no existing `.id`
/// meaning changes.
struct SettingsRevealScrollID: Hashable {
  let id: SettingsMapID
}

extension EnvironmentValues {
  /// Tells the window that the arrival for a token finished. Supplied by the window's `page { }`.
  @Entry var settingsRevealAcknowledge: @MainActor (Int) -> Void = { _ in }
  /// Increments on every committed navigation and on window close; an arrival in flight for an
  /// older navigation ends, and so does its ring.
  @Entry var settingsNavigationEpoch: Int = 0
  /// Whether an arrival that already finished (its reveal acknowledged) still belongs to what the
  /// window shows: no newer search, no navigation
  /// since it was committed, and its page and tab on screen
  /// (`SettingsNavigationState.arrivalIsCurrent`). Read live from the window's state, never from a copy of this view's
  /// environment, which a queued closure may hold from an earlier pass.
  @Entry var settingsArrivalStillCurrent: @MainActor (SettingsReveal) -> Bool = { _ in false }
  /// The marked scroll view around a registration, nil outside every marked scroll view.
  @Entry var settingsArrivalViewport: SettingsArrivalViewportID? = nil
  /// The rendered content around a registration (#3545): the page from `page { }`, overridden by
  /// a tabbed page around the tab it draws.
  @Entry var settingsArrivalContent: SettingsArrivalContent? = nil
  /// Told every decision the arrival owner makes, with the inputs it decided on (#3545). No-op in
  /// the app; hosted tests wait on the owner's own decisions through it.
  @Entry var settingsArrivalDecided: @MainActor (SettingsArrivalDecision) -> Void = { _ in }
  /// Told where the ring is drawn: the place, its frame and its clip, in the owner's space
  /// (#3545). No-op in the app; hosted tests read the paint at that frame.
  @Entry var settingsArrivalRingDrawn: @MainActor (SettingsMapID, CGRect, CGRect) -> Void = {
    _, _, _ in
  }
  /// Reduce Motion, when a test pins it; nil reads the system setting, which is get-only. The app
  /// never sets it.
  @Entry var settingsArrivalReduceMotion: Bool? = nil
}

extension View {
  /// The geometry and scroll identity search arrival uses, published with every mapped
  /// registration (SettingsMapRegistration.swift).
  func settingsRevealAnchor(_ id: SettingsMapID) -> some View {
    modifier(SettingsRevealAnchorModifier(id: id))
  }

  /// Marks a page scroll view that holds registered controls (SettingsArrival.swift).
  func settingsArrivalViewport() -> some View {
    modifier(SettingsArrivalViewportModifier())
  }
}

private struct SettingsRevealAnchorModifier: ViewModifier {
  let id: SettingsMapID
  @Environment(\.settingsArrivalViewport) private var viewport
  @Environment(\.settingsArrivalContent) private var drawnIn

  func body(content: Content) -> some View {
    // Plain values read here, in `body`, for the escaping transform below.
    let id = id
    let viewport = viewport
    let drawnIn = drawnIn
    return content.id(SettingsRevealScrollID(id: id))
      // A transform, not `.anchorPreference(value:)`: a set value replaces what the views inside
      // published, so a row inside a registered card was never a place to arrive at and choosing
      // it was a wiring fault (#3545, measured with a probe).
      .transformAnchorPreference(key: SettingsRevealAnchorKey.self, value: .bounds) { value, bounds in
        if value[id] == nil {
          value[id] = SettingsRevealPlace(bounds: bounds, viewport: viewport, content: drawnIn)
        }
      }
  }
}

private struct SettingsArrivalViewportModifier: ViewModifier {
  @State private var id = SettingsArrivalViewportID()

  func body(content: Content) -> some View {
    content
      .environment(\.settingsArrivalViewport, id)
      // A transform for the same reason: a marked scroll view inside this one keeps its frame.
      .transformAnchorPreference(key: SettingsArrivalViewportKey.self, value: .bounds) { value, bounds in
        value[id] = bounds
      }
  }
}

/// Which registered controls are on screen: a control inside a marked scroll view counts only
/// within that scroll view's visible frame; any other control counts within the page.
enum SettingsArrivalVisibility {
  /// The area a control can be seen in: the page, cut down to its scroll view when it has one.
  /// A scroll view that has not published its frame yet hides its controls (an empty area).
  static func clip(
    page: CGRect, viewport: SettingsArrivalViewportID?,
    viewports: [SettingsArrivalViewportID: CGRect]
  ) -> CGRect {
    guard let viewport else { return page }
    guard let frame = viewports[viewport] else { return .null }
    return page.intersection(frame)
  }

  static func fully(_ rect: CGRect, in clip: CGRect) -> Bool {
    !clip.isNull && clip.contains(rect)
  }

  static func partly(_ rect: CGRect, in clip: CGRect) -> Bool {
    !clip.isNull && clip.intersects(rect)
  }
}

/// One decision of the arrival owner and the inputs it read (#3545): `action` nil when the owner
/// did not decide at all (page gone, no scroll owner, no reveal, or the arrival is no longer
/// current).
struct SettingsArrivalDecision {
  let reveal: SettingsReveal?
  let action: SettingsArrivalPlanner.Action?
  let places: [SettingsMapID: SettingsArrivalContent?]
  let lazyTop: SettingsArrivalLazyTop?
  /// Whether the decision scrolled, and how: true animated, false without animation (Reduce
  /// Motion), nil when it did not scroll (no arrival, or the place was already in full view).
  var scrolledAnimated: Bool? = nil
}

/// The arrival decision, pure so every case is tested without a window (#3545 plan §3.2).
enum SettingsArrivalPlanner {
  enum Action: Equatable {
    /// Nothing to do: no reveal, or this token was already arrived at.
    case none
    /// The destination's content has not rendered yet; decide again when it has.
    case wait
    /// The destination's lazy content may hold the target: scroll to its top once, then decide.
    case materialize
    /// Arrive at this rung of the entry's ladder.
    case arrive(SettingsMapID, kind: SettingsArrivalLandingKind)
  }

  /// - Parameters:
  ///   - places: every published control and the content it was drawn in.
  ///   - lazyTop: the top of lazy content on the page, tagged with its content.
  ///   - handledToken: the token this owner already arrived at, if any.
  ///   - materializedToken: the token this owner already scrolled lazy content for, if any.
  static func decide(
    reveal: SettingsReveal?, places: [SettingsMapID: SettingsArrivalContent?],
    lazyTop: SettingsArrivalLazyTop?, handledToken: Int?, materializedToken: Int?
  ) -> Action {
    guard let reveal, reveal.token != handledToken else { return .none }
    let destination = reveal.content
    let pageOnly = destination.pageOnly
    // Controls of the destination's content, and the page's fixed controls (tab strip, fixed
    // headings). A previous tab's controls, even with the same ids, are neither.
    let eligible = Set(places.compactMap { $0.value == destination || $0.value == pageOnly ? $0.key : nil })
    let contentReady = places.values.contains { $0 == destination }
    let ladder = reveal.ladder
    let firstMounted = ladder.first { eligible.contains($0.id) }
    let lazyIsDestination = lazyTop?.content == destination
    // 1. A fixed target (a tab, a fixed heading) needs no tab content.
    if let target = ladder.first, places[target.id] == .some(pageOnly) {
      return .arrive(target.id, kind: .target)
    }
    // 2. No tab content yet.
    if !contentReady {
      guard lazyIsDestination else { return .wait }
      if materializedToken != reveal.token { return .materialize }
      // The destination's lazy content is identified and was materialized once.
      return firstMounted.map { .arrive($0.id, kind: $0.kind) } ?? .wait
    }
    // 3. Lazy content may still hold the target.
    if let target = ladder.first, !eligible.contains(target.id), lazyIsDestination,
      materializedToken != reveal.token
    {
      return .materialize
    }
    // 4. The ladder over eligible places. Its last rung, the tab or page landing, is fixed, so it
    // is mounted whenever the page is.
    return firstMounted.map { .arrive($0.id, kind: $0.kind) } ?? .wait
  }
}

/// The ring around an arrived control: 2 pt stAccent with a soft stAccentLight fill, pulsing
/// twice (steady under Reduce Motion), never hit-testable or visible to VoiceOver.
struct SettingsArrivalRing: View {
  let rect: CGRect
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.settingsArrivalReduceMotion) private var pinnedReduceMotion
  private var reduceMotion: Bool { pinnedReduceMotion ?? systemReduceMotion }
  @State private var pulse = false

  var body: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(Color.stAccentLight.opacity(0.35))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Color.stAccent, lineWidth: 2)
      )
      .opacity(pulse ? 0.45 : 1)
      .frame(width: rect.width + 8, height: rect.height + 8)
      .position(x: rect.midX, y: rect.midY)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.35).repeatCount(4, autoreverses: true)) {
          pulse = true
        }
        // Two full pulses (four half-cycles) end bright: settle on the steady ring.
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(1_450))
          pulse = false
        }
      }
  }
}

/// The page's one arrival owner (the window's `page { }`): decides on appear, reveal change and
/// control-inventory change; scrolls, rings, announces and acknowledges. It sits above every
/// scroll view, so controls outside them (tab strips, pinned headings) are reachable too.
/// `materialize` scrolls lazy content to its top before a fallback is ever chosen.
struct SettingsArrivalModifier: ViewModifier {
  @Environment(\.settingsReveal) private var reveal
  @Environment(\.settingsRevealAcknowledge) private var acknowledge
  @Environment(\.settingsArrivalReleaseSearchFocus) private var releaseSearchFocus
  @Environment(\.settingsNavigationEpoch) private var navigationEpoch
  @Environment(\.settingsArrivalStillCurrent) private var stillCurrent
  @Environment(\.settingsArrivalDecided) private var decided
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.settingsArrivalReduceMotion) private var pinnedReduceMotion
  @Environment(\.settingsArrivalRingDrawn) private var ringDrawn
  private var reduceMotion: Bool { pinnedReduceMotion ?? systemReduceMotion }
  @State private var proxy: ScrollViewProxy?
  /// The scroll id at the top of the page's lazy content (Dictionary), nil for an eager page.
  /// The top of the page's lazy content (Dictionary) and its content, nil for an eager page.
  @State private var lazyTop: SettingsArrivalLazyTop?
  @State private var viewportAnchors: [SettingsArrivalViewportID: Anchor<CGRect>] = [:]
  /// Every published control and the content it was drawn in.
  @State private var places: [SettingsMapID: SettingsArrivalContent?] = [:]
  /// The reveal, mirrored from the environment on every change. A queued decision reads this, never
  /// the environment value its closure captured when it was queued (#3545: that copy was stale and
  /// a reveal committed while a decision was queued was decided as nil).
  @State private var liveReveal: SettingsReveal?
  /// The page is on screen. Cleared before disappearance cleanup, so a decision queued before the
  /// page left never acts (#3545).
  @State private var isMounted = false
  /// Controls wholly inside the visible area: arrival does not scroll for these (a pinned header
  /// control, or one already on screen, stays where the person sees it).
  @State private var fullyVisible: Set<SettingsMapID> = []
  /// Controls at least partly inside the visible area.
  @State private var partlyVisible: Set<SettingsMapID> = []
  @State private var handledToken: Int?
  @State private var materializedToken: Int?
  /// An arrival scrolled toward but not yet seen on screen: the ring is not dismissed for being
  /// out of view while the reveal scroll runs.
  @State private var arriving: Arriving?
  /// An arrival that landed below its target and may still move up once (#3545 plan §3.3): while
  /// its ring is up and before any tap or key in the page. Never moves focus: focus stays where
  /// the arrival put it, so an upgrade cannot take focus from the person.
  @State private var upgrade: Upgrade?
  @State private var ring: (id: SettingsMapID, token: Int)?
  @State private var ringExpiry: Task<Void, Never>?
  @State private var deciding = false
  /// A change arrived while a decision was queued: decide once more after it, never drop it.
  @State private var decideAgain = false
  /// The adapters the page has published, and the focus move in flight (one shot).
  @State private var focusKinds: [SettingsMapID: SettingsArrivalFocusKind] = [:]
  @State private var focusRequest: SettingsArrivalFocusRequest?
  /// The arrival `focusRequest` belongs to, judged again when an adapter is about to act.
  @State private var focusReveal: SettingsReveal?
  @State private var pendingFocus: (reveal: SettingsReveal, target: SettingsMapID)?
  @State private var focusExpiry: Task<Void, Never>?

  /// A focus request nobody took (no adapter mounted for it) is dropped, so a control that mounts
  /// much later is never given focus by an arrival that is long over.
  static let focusRequestLifetime: Duration = .seconds(1)

  struct Upgrade: Equatable {
    let reveal: SettingsReveal
    /// The ladder position the arrival landed on; only a higher rung upgrades.
    let landedIndex: Int
  }

  struct Arriving: Equatable {
    let target: SettingsMapID
    let kind: SettingsArrivalLandingKind
    let reveal: SettingsReveal
  }

  static let ringDuration: Duration = .seconds(8)

  func body(content: Content) -> some View {
    ScrollViewReader { reader in
      arrival(content).onAppear {
        isMounted = true
        proxy = reader
        reconcile()
      }
    }
  }

  private func arrival(_ content: Content) -> some View {
    content
      .onPreferenceChange(SettingsRevealAnchorKey.self) { anchors in
        places = anchors.mapValues(\.content)
      }
      .onPreferenceChange(SettingsArrivalLazyTopKey.self) { lazyTop = $0 }
      .onPreferenceChange(SettingsArrivalFocusKey.self) { focusKinds = $0 }
      .environment(\.settingsArrivalFocusRequest, focusRequest)
      .environment(\.settingsArrivalFocusTaken) { taken in
        if focusRequest == taken { dropFocusRequest() }
      }
      .environment(\.settingsArrivalFocusIsCurrent) { request in
        guard request == focusRequest, let focusReveal else { return false }
        return stillCurrent(focusReveal)
      }
      // Kept in state: an overlay reads one preference, and the controls' places need the
      // scroll views' frames beside them.
      .onPreferenceChange(SettingsArrivalViewportKey.self) { viewportAnchors = $0 }
      .overlayPreferenceValue(SettingsRevealAnchorKey.self) { anchors in
        visibilityAndRing(anchors: anchors, viewportAnchors: viewportAnchors)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      // A later tap or key in the page dismisses the ring without consuming it.
      .simultaneousGesture(
        TapGesture().onEnded {
          personActed()
          dismissRing()
        })
      // Any key in this window, seen before any control handles it (a text field or a picker
      // consumes keys an `onKeyPress` here would never see): the person is acting, so arrival
      // stops moving the ring or focus for them, even while the reveal scroll still runs.
      .background(
        SettingsArrivalKeyWatcher {
          personActed()
          if arriving == nil { dismissRing() }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true))
      .onAppear { reconcile() }
      .onChange(of: reveal, initial: true) { _, new in
        liveReveal = new
        reconcile()
      }
      // Tags are part of the value, so a tab switch whose controls share ids still reconciles.
      .onChange(of: places) { _, _ in reconcile() }
      .onChange(of: lazyTop) { _, _ in reconcile() }
      // Any other navigation, or the window closing, ends this arrival and its ring.
      .onChange(of: navigationEpoch) { _, _ in
        // A focus move still queued, or asked and not yet taken, belongs to an older navigation.
        pendingFocus = nil
        dropFocusRequest()
        if let arriving, stillCurrent(arriving.reveal) { return }
        arriving = nil
        dismissRing()
      }
      .onDisappear {
        isMounted = false
        upgrade = nil
        liveReveal = nil
        proxy = nil
        decideAgain = false
        arriving = nil
        dismissRing()
        pendingFocus = nil
        dropFocusRequest()
      }
  }

  /// Tracks which controls are on screen and draws the ring, clipped to the ring's scroll view so
  /// it never paints over a tab strip or heading outside it.
  private func visibilityAndRing(
    anchors: [SettingsMapID: SettingsRevealPlace],
    viewportAnchors: [SettingsArrivalViewportID: Anchor<CGRect>]
  ) -> some View {
    GeometryReader { geometry in
      let page = CGRect(origin: .zero, size: geometry.size)
      let viewports = viewportAnchors.mapValues { geometry[$0] }
      let placed = anchors.mapValues { place in
        (
          rect: geometry[place.bounds],
          clip: SettingsArrivalVisibility.clip(
            page: page, viewport: place.viewport, viewports: viewports)
        )
      }
      let inside = Set(
        placed.compactMap { SettingsArrivalVisibility.fully($0.value.rect, in: $0.value.clip) ? $0.key : nil })
      let touching = Set(
        placed.compactMap { SettingsArrivalVisibility.partly($0.value.rect, in: $0.value.clip) ? $0.key : nil })
      Color.clear
        .onChange(of: inside, initial: true) { _, now in fullyVisible = now }
        .onChange(of: touching, initial: true) { _, now in
          partlyVisible = now
          completeArrivalIfVisible()
        }
      if let ring, let place = placed[ring.id] {
        if SettingsArrivalVisibility.partly(place.rect, in: place.clip) {
          SettingsArrivalRing(rect: place.rect)
            .onChange(of: place.rect, initial: true) { _, rect in
              ringDrawn(ring.id, rect, place.clip)
            }
            .mask {
              // The ring's own 4pt outset, and no further: it never paints past the scroll view.
              let edge = place.clip.insetBy(dx: -4, dy: -4)
              Rectangle().frame(width: edge.width, height: edge.height)
                .position(x: edge.midX, y: edge.midY)
            }
        } else if arriving == nil {
          // Scrolled out of view by the person: the ring has done its job.
          Color.clear.onAppear { dismissRing() }
        }
      }
    }
  }

  private func reconcile() {
    guard !deciding else {
      decideAgain = true
      return
    }
    deciding = true
    // Coalescing only: the decision reads live state (`liveReveal`, `places`, `lazyTop`), and the
    // content tags, not this hop, say whether the destination has rendered.
    DispatchQueue.main.async {
      deciding = false
      decideNow()
      if decideAgain {
        decideAgain = false
        reconcile()
      }
    }
  }

  private func decideNow() {
    // The inputs this decision reads, frozen at entry and reported once it has acted.
    var observedReveal = liveReveal
    let observedPlaces = places
    let observedLazyTop = lazyTop
    var observedAction: SettingsArrivalPlanner.Action?
    var observedScroll: Bool?
    defer {
      decided(
        SettingsArrivalDecision(
          reveal: observedReveal, action: observedAction, places: observedPlaces,
          lazyTop: observedLazyTop, scrolledAnimated: observedScroll))
    }
    // A landed arrival whose reveal has been acknowledged may still move up once.
    if let pending = upgrade, observedReveal == nil || observedReveal?.token == pending.reveal.token {
      // The window cleared the reveal at acknowledgement; this decision is still that reveal's.
      observedReveal = pending.reveal
      (observedAction, observedScroll) = considerUpgrade(pending, places: observedPlaces)
      return
    }
    // No scroll owner yet: deciding now would arrive without scrolling. The reader's onAppear
    // reconciles again once it is stored.
    // A decision queued before the page left, or before a newer navigation, never acts.
    guard isMounted, proxy != nil, let current = observedReveal, stillCurrent(current) else {
      return
    }
    let action = SettingsArrivalPlanner.decide(
      reveal: current, places: observedPlaces, lazyTop: observedLazyTop,
      handledToken: handledToken, materializedToken: materializedToken)
    observedAction = action
    switch action {
    case .none, .wait:
      break
    case .materialize:
      materializedToken = current.token
      if let observedLazyTop { proxy?.scrollTo(observedLazyTop.scrollID, anchor: .top) }
      reconcile()
    case .arrive(let target, let kind):
      handledToken = current.token
      #if DEBUG
        let message = "arrival landed=\(kind) entry=\(current.entryID) at=\(target.rawValue)"
        Task { await AppLogger.shared.log(message, level: .info, category: "SettingsMap") }
      #endif
      dropFocusRequest()
      arriving = Arriving(target: target, kind: kind, reveal: current)
      upgrade =
        kind == .target
        ? nil
        : current.ladder.firstIndex { $0.id == target }.map {
          Upgrade(reveal: current, landedIndex: $0)
        }
      observedScroll = scroll(to: target)
      showRing(target, token: current.token)
      // Announced and acknowledged now (#3545 plan §3.4), not when the place becomes visible:
      // scrolling and the ring follow visibility; finishing the arrival never waits on it.
      announce(entryID: current.entryID, landed: kind == .target ? nil : target)
      acknowledge(current.token)
      startFocus(current, target: target)
      completeArrivalIfVisible()
    }
  }

  /// The person tapped or pressed a key in the page: arrival no longer moves focus or the ring for
  /// them. A focus move still queued, or asked of the adapters and not yet taken, is dropped.
  private func personActed() {
    upgrade = nil
    pendingFocus = nil
    dropFocusRequest()
  }

  /// Moves a landed arrival up once to a higher rung that has since mounted (a late row), while its
  /// ring is up, the page is here and no navigation has happened. Returns the upgrade it made, or
  /// nil when none was possible yet. The ring keeps its original deadline; focus does not move.
  private func considerUpgrade(
    _ pending: Upgrade, places: [SettingsMapID: SettingsArrivalContent?]
  ) -> (SettingsArrivalPlanner.Action?, scrolledAnimated: Bool?) {
    guard isMounted, proxy != nil, stillCurrent(pending.reveal),
      ring?.token == pending.reveal.token
    else {
      upgrade = nil
      return (nil, nil)
    }
    let destination = pending.reveal.content
    let higher = pending.reveal.ladder.prefix(pending.landedIndex).first { rung in
      places[rung.id] == .some(destination) || places[rung.id] == .some(destination.pageOnly)
    }
    guard let higher else { return (nil, nil) }
    upgrade = nil
    #if DEBUG
      let message =
        "arrival landed=\(higher.kind) entry=\(pending.reveal.entryID) at=\(higher.id.rawValue) upgrade=true"
      Task { await AppLogger.shared.log(message, level: .info, category: "SettingsMap") }
    #endif
    arriving = Arriving(target: higher.id, kind: higher.kind, reveal: pending.reveal)
    let scrolled = scroll(to: higher.id)
    // The same ring, moved: its deadline is the original arrival's.
    ring = (higher.id, pending.reveal.token)
    if higher.kind == .target { announce(entryID: pending.reveal.entryID, landed: nil) }
    completeArrivalIfVisible()
    return (.arrive(higher.id, kind: higher.kind), scrolled)
  }

  /// The arrival's place is on screen: the reveal scroll is over, so the ring may now be dismissed
  /// when the person scrolls it away.
  private func completeArrivalIfVisible() {
    guard let pending = arriving, partlyVisible.contains(pending.target) else { return }
    arriving = nil
  }

  /// Focus follows the arrival by one layout pass, and is judged again then: a newer arrival, or a
  /// change to another page or tab in between, cancels it.
  private func startFocus(_ reveal: SettingsReveal, target: SettingsMapID) {
    pendingFocus = (reveal, target)
    DispatchQueue.main.async { moveFocus() }
  }

  private func moveFocus() {
    guard let pending = pendingFocus else { return }
    pendingFocus = nil
    // The reveal was acknowledged just before this pass, so `showing` no longer applies; the
    // window answers live whether the arrival still holds (no newer search or navigation).
    guard
      SettingsArrivalFocusPlanner.mayMove(
        pendingToken: pending.reveal.token, handledToken: handledToken,
        showing: stillCurrent(pending.reveal))
    else { return }
    let move = SettingsArrivalFocusPlanner.plan(
      target: pending.target, token: pending.reveal.token, kinds: focusKinds)
    if move.releaseSearch { releaseSearchFocus() }
    guard let request = move.request else { return }
    focusReveal = pending.reveal
    focusRequest = request
    focusExpiry?.cancel()
    focusExpiry = Task { @MainActor in
      try? await Task.sleep(for: Self.focusRequestLifetime)
      guard !Task.isCancelled, focusRequest == request else { return }
      focusRequest = nil
    }
  }

  private func dropFocusRequest() {
    focusExpiry?.cancel()
    focusExpiry = nil
    focusRequest = nil
    focusReveal = nil
  }

  /// Scrolls the place into view unless it already is; returns whether it animated, nil when it
  /// did not scroll.
  @discardableResult
  private func scroll(to target: SettingsMapID) -> Bool? {
    guard !fullyVisible.contains(target) else { return nil }
    let id = SettingsRevealScrollID(id: target)
    if reduceMotion {
      proxy?.scrollTo(id, anchor: .center)
      return false
    }
    withAnimation(.easeInOut(duration: 0.3)) { proxy?.scrollTo(id, anchor: .center) }
    return true
  }

  private func showRing(_ target: SettingsMapID, token: Int) {
    ringExpiry?.cancel()
    ring = (target, token)
    ringExpiry = Task { @MainActor in
      try? await Task.sleep(for: Self.ringDuration)
      guard !Task.isCancelled, ring?.token == token else { return }
      ring = nil
      upgrade = nil
    }
  }

  private func dismissRing() {
    ringExpiry?.cancel()
    ringExpiry = nil
    ring = nil
    upgrade = nil
  }

  /// "Showing Pause duration", or with a fallback "Showing Stop recording on silence for
  /// Pause duration": the chosen entry and where the person actually landed.
  private func announce(entryID: String, landed: SettingsMapID?) {
    guard let chosen = SettingsMapID(rawValue: entryID) else { return }
    let chosenTitle = SettingsSearchPresentation.title(of: chosen)
    let message =
      landed.map {
        SettingsSearchCopy.arrivedAtFallback(
          landed: SettingsSearchPresentation.title(of: $0), chosen: chosenTitle)
      } ?? SettingsSearchCopy.arrived(chosenTitle)
    AccessibilityNotification.Announcement(message).post()
  }
}

/// Calls `onKey` for every key pressed in the window it is in, before the window dispatches it to
/// any control, and passes the key on unchanged (#3545). A local event monitor, installed while
/// the view is in a window and removed when it leaves.
struct SettingsArrivalKeyWatcher: NSViewRepresentable {
  let onKey: @MainActor () -> Void

  final class WatcherView: NSView {
    var onKey: (@MainActor () -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        MainActor.assumeIsolated {
          if let self, event.window === self.window { self.onKey?() }
        }
        return event
      }
    }

    override func removeFromSuperview() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      super.removeFromSuperview()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  func makeNSView(context: Context) -> WatcherView {
    let view = WatcherView()
    view.onKey = onKey
    return view
  }

  func updateNSView(_ view: WatcherView, context: Context) { view.onKey = onKey }
}
