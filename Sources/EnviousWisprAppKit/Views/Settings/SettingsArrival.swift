import SwiftUI

// Arrival after a search navigation (#3482 plan §3.4): scroll the chosen place into view, draw
// a ring around it for a few seconds, say where the person landed, then acknowledge the reveal
// so a remount never replays it. Selecting a result only navigates and reveals; nothing here
// changes a setting.

/// Where each registered control is, by map id, in the scroll owner's coordinate space.
struct SettingsRevealAnchorKey: PreferenceKey {
  static let defaultValue: [SettingsMapID: Anchor<CGRect>] = [:]
  static func reduce(
    value: inout [SettingsMapID: Anchor<CGRect>], nextValue: () -> [SettingsMapID: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { first, _ in first }
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
  /// Whether a reveal's destination (page, tab, Dictionary tab) is the one on screen now.
  @Entry var settingsRevealIsShowing: @MainActor (SettingsReveal) -> Bool = { _ in false }
}

extension View {
  /// The geometry and scroll identity search arrival uses, published with every mapped
  /// registration (SettingsMapRegistration.swift).
  func settingsRevealAnchor(_ id: SettingsMapID) -> some View {
    self.id(SettingsRevealScrollID(id: id))
      .anchorPreference(key: SettingsRevealAnchorKey.self, value: .bounds) { [id: $0] }
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

/// One scroll owner's arrival: decides on appear, reveal change and control-inventory change;
/// scrolls, rings, announces and acknowledges. `materialize` scrolls lazy content to its top
/// before a fallback is ever chosen.
struct SettingsArrivalModifier: ViewModifier {
  let proxy: ScrollViewProxy
  /// The scroll id at the top of lazy content (Dictionary), or nil for an eager page.
  var topScrollID: AnyHashable?
  /// Whether the reveal's destination is the one on screen (page, tab, Dictionary tab).
  let showing: @MainActor (SettingsReveal) -> Bool

  @Environment(\.settingsReveal) private var reveal
  @Environment(\.settingsRevealAcknowledge) private var acknowledge
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var mounted: Set<SettingsMapID> = []
  /// Controls wholly inside the visible scroll area: arrival does not scroll for these (a pinned
  /// header control, or one already on screen, stays where the person sees it).
  @State private var fullyVisible: Set<SettingsMapID> = []
  @State private var handledToken: Int?
  @State private var materializedToken: Int?
  @State private var ring: (id: SettingsMapID, token: Int)?
  @State private var ringExpiry: Task<Void, Never>?
  @State private var deciding = false

  static let ringDuration: Duration = .seconds(8)

  func body(content: Content) -> some View {
    content
      .onPreferenceChange(SettingsRevealAnchorKey.self) { anchors in
        mounted = Set(anchors.keys)
      }
      .overlayPreferenceValue(SettingsRevealAnchorKey.self) { anchors in
        GeometryReader { geometry in
          let visible = CGRect(origin: .zero, size: geometry.size)
          let inside = Set(anchors.compactMap { visible.contains(geometry[$0.value]) ? $0.key : nil })
          Color.clear.onChange(of: inside, initial: true) { _, now in fullyVisible = now }
          if let ring, let anchor = anchors[ring.id] {
            let rect = geometry[anchor]
            if rect.intersects(visible) {
              SettingsArrivalRing(rect: rect)
            } else {
              // Scrolled out of view by the person: the ring has done its job.
              Color.clear.onAppear { dismissRing() }
            }
          }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
      // A later tap in the page dismisses the ring without consuming the tap.
      .simultaneousGesture(TapGesture().onEnded { dismissRing() })
      .onAppear { reconcile() }
      .onChange(of: reveal) { _, _ in reconcile() }
      .onChange(of: mounted) { _, _ in reconcile() }
      .onDisappear { dismissRing() }
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
      if let topScrollID { proxy.scrollTo(topScrollID, anchor: .top) }
      reconcile()
    case .arrive(let target, let isFallback):
      handledToken = current.token
      scroll(to: target)
      showRing(target, token: current.token)
      announce(entryID: current.entryID, landed: isFallback ? target : nil)
      acknowledge(current.token)
    case .fault:
      handledToken = current.token
      SettingsMap.wiringFault(
        "Settings search: no arrival for \(current.entryID) (anchor \(current.anchor.rawValue), fallbacks \(current.fallbacks.map(\.rawValue)))"
      )
      acknowledge(current.token)
    }
  }

  private func scroll(to target: SettingsMapID) {
    guard !fullyVisible.contains(target) else { return }
    let id = SettingsRevealScrollID(id: target)
    if reduceMotion {
      proxy.scrollTo(id, anchor: .center)
    } else {
      withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
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
