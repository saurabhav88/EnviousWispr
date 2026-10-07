import SwiftUI

// Arrival after a search navigation (#3482 plan §3.4): scroll the chosen place into view, draw
// a ring around it for a few seconds, say where the person landed, then acknowledge the reveal
// so a remount never replays it. Selecting a result only navigates and reveals; nothing here
// changes a setting.

/// Where a registered control is, and the scroll view it sits in (nil: fixed on the page, such as
/// a tab strip or a pinned heading).
struct SettingsRevealPlace: Equatable {
  let bounds: Anchor<CGRect>
  let viewport: SettingsArrivalViewportID?
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
  static let defaultValue: String? = nil
  static func reduce(value: inout String?, nextValue: () -> String?) {
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
  /// Whether a reveal's destination (page, tab, Dictionary tab) is the one on screen now.
  @Entry var settingsRevealIsShowing: @MainActor (SettingsReveal) -> Bool = { _ in false }
  /// Whether an arrival that already finished (its reveal acknowledged, so `settingsRevealIsShowing`
  /// no longer applies) still belongs to what the window shows: no newer search, no navigation
  /// since it was committed, and its page and tab on screen
  /// (`SettingsNavigationState.arrivalIsCurrent`). Read live from the window's state, never from a copy of this view's
  /// environment, which a queued closure may hold from an earlier pass.
  @Entry var settingsArrivalStillCurrent: @MainActor (SettingsReveal) -> Bool = { _ in false }
  /// The marked scroll view around a registration, nil outside every marked scroll view.
  @Entry var settingsArrivalViewport: SettingsArrivalViewportID? = nil
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

  func body(content: Content) -> some View {
    content.id(SettingsRevealScrollID(id: id))
      .anchorPreference(key: SettingsRevealAnchorKey.self, value: .bounds) {
        [id: SettingsRevealPlace(bounds: $0, viewport: viewport)]
      }
  }
}

private struct SettingsArrivalViewportModifier: ViewModifier {
  @State private var id = SettingsArrivalViewportID()

  func body(content: Content) -> some View {
    content
      .environment(\.settingsArrivalViewport, id)
      .anchorPreference(key: SettingsArrivalViewportKey.self, value: .bounds) { [id: $0] }
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

/// The arrival decision, pure so every case is tested without a window.
enum SettingsArrivalPlanner {
  enum Action: Equatable {
    /// Nothing to do: no reveal, already handled, or it belongs to another page or tab.
    case none
    /// The page has not published its controls yet; decide again when it has.
    case wait
    /// Lazy content may hold the target: scroll to the top first, then decide again.
    case materialize
    /// Arrive at this control (the reveal's own anchor or a declared fallback).
    case arrive(SettingsMapID, isFallback: Bool)
    /// Neither the anchor nor any fallback is on the page: an implementation failure.
    case fault
  }

  /// - Parameters:
  ///   - showing: whether the reveal's destination (page, tab, Dictionary tab) is on screen now.
  ///   - mounted: the mapped controls the page has published.
  ///   - handledToken: the token this scroll owner already arrived at, if any.
  ///   - canMaterialize: the page has lazy content and has not yet been scrolled to its top for
  ///     this token.
  static func decide(
    reveal: SettingsReveal?, showing: Bool, mounted: Set<SettingsMapID>, handledToken: Int?,
    canMaterialize: Bool
  ) -> Action {
    guard let reveal, reveal.token != handledToken, showing else { return .none }
    // The initial empty inventory is "not ready yet", never "hidden".
    guard !mounted.isEmpty else { return .wait }
    // Lazy content may hold the chosen control off screen: reach it before any fallback.
    if canMaterialize && !mounted.contains(reveal.anchor) { return .materialize }
    if let target = reveal.arrival(mounted: mounted) {
      return .arrive(target, isFallback: target != reveal.anchor)
    }
    return canMaterialize ? .materialize : .fault
  }
}

/// The ring around an arrived control: 2 pt stAccent with a soft stAccentLight fill, pulsing
/// twice (steady under Reduce Motion), never hit-testable or visible to VoiceOver.
struct SettingsArrivalRing: View {
  let rect: CGRect
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
  /// Whether the reveal's destination is the one on screen (page, tab, Dictionary tab).
  @Environment(\.settingsRevealIsShowing) private var showing
  @Environment(\.settingsRevealAcknowledge) private var acknowledge
  @Environment(\.settingsArrivalReleaseSearchFocus) private var releaseSearchFocus
  @Environment(\.settingsNavigationEpoch) private var navigationEpoch
  @Environment(\.settingsArrivalStillCurrent) private var stillCurrent
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var proxy: ScrollViewProxy?
  /// The scroll id at the top of the page's lazy content (Dictionary), nil for an eager page.
  @State private var topScrollID: String?
  @State private var viewportAnchors: [SettingsArrivalViewportID: Anchor<CGRect>] = [:]
  @State private var mounted: Set<SettingsMapID> = []
  /// Controls wholly inside the visible area: arrival does not scroll for these (a pinned header
  /// control, or one already on screen, stays where the person sees it).
  @State private var fullyVisible: Set<SettingsMapID> = []
  /// Controls at least partly inside the visible area.
  @State private var partlyVisible: Set<SettingsMapID> = []
  @State private var handledToken: Int?
  @State private var materializedToken: Int?
  /// An arrival scrolled toward but not yet seen on screen: it completes (announcement and
  /// acknowledgement) only once its control is visible, and the ring is not dismissed for being
  /// out of view while the reveal scroll runs.
  @State private var arriving: Arriving?
  @State private var ring: (id: SettingsMapID, token: Int)?
  @State private var ringExpiry: Task<Void, Never>?
  @State private var deciding = false
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

  struct Arriving: Equatable {
    let target: SettingsMapID
    let isFallback: Bool
    let reveal: SettingsReveal
  }

  static let ringDuration: Duration = .seconds(8)

  func body(content: Content) -> some View {
    ScrollViewReader { reader in
      arrival(content).onAppear {
        proxy = reader
        reconcile()
      }
    }
  }

  private func arrival(_ content: Content) -> some View {
    content
      .onPreferenceChange(SettingsRevealAnchorKey.self) { anchors in
        mounted = Set(anchors.keys)
      }
      .onPreferenceChange(SettingsArrivalLazyTopKey.self) { topScrollID = $0 }
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
      .simultaneousGesture(TapGesture().onEnded { dismissRing() })
      .onKeyPress(phases: .down) { _ in
        if arriving == nil { dismissRing() }
        return .ignored
      }
      .onAppear { reconcile() }
      .onChange(of: reveal) { _, _ in reconcile() }
      .onChange(of: mounted) { _, _ in reconcile() }
      // Any other navigation, or the window closing, ends this arrival and its ring.
      .onChange(of: navigationEpoch) { _, _ in
        // A focus move still queued, or asked and not yet taken, belongs to an older navigation.
        pendingFocus = nil
        dropFocusRequest()
        if let arriving, showing(arriving.reveal) { return }
        arriving = nil
        dismissRing()
      }
      .onDisappear {
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
    guard !deciding else { return }
    deciding = true
    // One layout pass after the change, so the inventory describes the committed page.
    DispatchQueue.main.async {
      deciding = false
      decideNow()
    }
  }

  private func decideNow() {
    // No scroll owner yet: deciding now would arrive without scrolling. The reader's onAppear
    // reconciles again once it is stored.
    guard proxy != nil else { return }
    let current = reveal
    let action = SettingsArrivalPlanner.decide(
      reveal: current, showing: current.map(showing) ?? false, mounted: mounted,
      handledToken: handledToken,
      canMaterialize: topScrollID != nil && materializedToken != current?.token)
    guard let current else { return }
    switch action {
    case .none, .wait:
      break
    case .materialize:
      materializedToken = current.token
      if let topScrollID { proxy?.scrollTo(topScrollID, anchor: .top) }
      reconcile()
    case .arrive(let target, let isFallback):
      handledToken = current.token
      dropFocusRequest()
      arriving = Arriving(target: target, isFallback: isFallback, reveal: current)
      scroll(to: target)
      showRing(target, token: current.token)
      completeArrivalIfVisible()
    case .fault:
      handledToken = current.token
      SettingsMap.wiringFault(
        "Settings search: no arrival for \(current.entryID) (anchor \(current.anchor.rawValue), fallbacks \(current.fallbacks.map(\.rawValue)))"
      )
      acknowledge(current.token)
    }
  }

  /// The arrival is done once its control is on screen and the reveal still applies: announce
  /// where the person landed, then acknowledge the token.
  private func completeArrivalIfVisible() {
    guard let pending = arriving, partlyVisible.contains(pending.target) else { return }
    arriving = nil
    guard reveal?.token == pending.reveal.token, showing(pending.reveal) else {
      dismissRing()
      return
    }
    announce(entryID: pending.reveal.entryID, landed: pending.isFallback ? pending.target : nil)
    startFocus(pending.reveal, target: pending.target)
    acknowledge(pending.reveal.token)
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

  private func scroll(to target: SettingsMapID) {
    guard !fullyVisible.contains(target) else { return }
    let id = SettingsRevealScrollID(id: target)
    if reduceMotion {
      proxy?.scrollTo(id, anchor: .center)
    } else {
      withAnimation(.easeInOut(duration: 0.3)) { proxy?.scrollTo(id, anchor: .center) }
    }
  }

  private func showRing(_ target: SettingsMapID, token: Int) {
    ringExpiry?.cancel()
    ring = (target, token)
    ringExpiry = Task { @MainActor in
      try? await Task.sleep(for: Self.ringDuration)
      guard !Task.isCancelled, ring?.token == token else { return }
      ring = nil
    }
  }

  private func dismissRing() {
    ringExpiry?.cancel()
    ringExpiry = nil
    ring = nil
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
