import EnviousWisprCore
import Observation
import SwiftUI

/// The new Setup's window content (#4528 chunk D0, plan M74): the coordinator's state rendered
/// through one exhaustive step router. The coordinator is the only navigation authority; this
/// view never moves the flow on its own. Normal launch keeps the old onboarding until D7a.
struct SetupWindowRoot: View {
  let model: SetupScreenModel

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  /// Tests and render fixtures inject Reduce Motion here (the same override the lips read).
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  /// The screen change: the mockup's entrance, or none under Reduce Motion (the step still changes).
  static func screenAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : DesignMotion.firstRunScreenIn
  }

  var body: some View {
    VStack(spacing: 0) {
      SetupStepStrip(step: model.state.step)
        .frame(height: SetupLayout.stripHeight)
      SetupScreenRouter(model: model)
        .id(model.routeEpoch)
        .transition(reduceMotion ? .opacity : .setupScreenIn)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(.horizontal, SetupLayout.contentPadding)
    .padding(.top, SetupLayout.stripTop)
    .padding(.bottom, SetupLayout.contentPadding)
    .frame(width: SetupLayout.windowWidth, height: SetupLayout.contentHeight)
    .background(Color.obCardBg)
    .foregroundStyle(Color.obTextPrimary)
    .animation(Self.screenAnimation(reduceMotion: reduceMotion), value: model.routeEpoch)
  }
}

/// Window measurements from the source-of-truth mockup (`[data-ui="content"]`: 460 wide, 734
/// tall, 28 padding; the step strip sits 8 from the top in a 16-high row).
enum SetupLayout {
  static let windowWidth: CGFloat = 460
  static let contentHeight: CGFloat = 734
  static let contentPadding: CGFloat = 28
  static let stripTop: CGFloat = 8
  static let stripHeight: CGFloat = 16
  static let segmentWidth: CGFloat = 24
  static let segmentHeight: CGFloat = 4
  static let segmentGap: CGFloat = 4
}

/// The mockup's screen entrance (`obIn`): a 16-point slide from the right with a fade.
extension AnyTransition {
  static var setupScreenIn: AnyTransition {
    .asymmetric(
      insertion: .opacity.combined(with: .offset(x: 16)),
      removal: .opacity)
  }
}

// MARK: - Model

/// Mirrors the coordinator's published state for SwiftUI while the window is shown. It is the
/// only subscriber of `OnboardingCoordinator.onChange` and holds no flow state of its own:
/// detaching it leaves the flow, its transfers and its visit untouched.
@MainActor
@Observable
final class SetupScreenModel {
  private(set) var state: OnboardingFlowState
  private(set) var isPracticeUsable: Bool
  /// Changes on EVERY published step change, so a screen left and re-entered between two
  /// renders (a reset from Language straight back to Language) is a new screen with a fresh
  /// draft, never the old view kept alive by an unchanged step.
  private(set) var routeEpoch = 0
  private weak var coordinator: OnboardingCoordinator?
  /// Reports a REAL screen on screen (telemetry M67); the presenter binds it to the session's
  /// observer. Placeholders never call it.
  @ObservationIgnored var onPresented: ((OnboardingStep, _ resumed: Bool) -> Void)?
  /// True only while the window is on screen: a mounted view in a hidden window is not a view.
  @ObservationIgnored private(set) var isWindowVisible = false
  /// The steps that have a real screen so far (D1 to D3a).
  static let realScreens: Set<OnboardingStep> = [
    .welcome, .language, .speechPick, .speechCompare, .polishIntro, .polishPick, .polishSeeAll,
  ]

  /// Speech pick/Compare's pending engine (D2, M76): a UI selection only, alive while the flow
  /// stays on those two screens with the same language; never a choice until "Use <model>".
  private(set) var speechDraft: ASRBackendType?
  /// Owner facts the screens show, injected by the presenter (names, sizes, rechecks).
  @ObservationIgnored var sources = SetupScreenSources()

  func setSpeechDraft(_ engine: ASRBackendType) {
    guard state.step == .speechPick || state.step == .speechCompare else { return }
    speechDraft = engine
  }

  /// AI polish pick/See all's pending model (D3a, M77): a UI selection only, alive while the flow
  /// stays on those two screens with the same language and Apple Intelligence state; never a
  /// choice until "Continue with <model>". Only a model that can be chosen now is accepted.
  private(set) var polishDraft: String?

  func setPolishDraft(_ id: String) {
    guard state.step == .polishPick || state.step == .polishSeeAll,
      SetupPolish.isSelectable(
        id, appleIntelligence: state.recommended.appleIntelligence,
        language: state.choices.languageMode)
    else { return }
    polishDraft = id
  }

  init(coordinator: OnboardingCoordinator) {
    self.coordinator = coordinator
    state = coordinator.state
    isPracticeUsable = coordinator.isPracticeUsable
    coordinator.onChange = { [weak self] in self?.refresh() }
  }

  /// The same events Setup's buttons send; the coordinator alone decides what happens.
  func send(_ event: OnboardingEvent) {
    coordinator?.send(event)
  }

  /// The route epoch of the real screen that last mounted (its `onAppear`).
  @ObservationIgnored private var mountedEpoch: Int?

  /// The window is now on screen (or off). Coming on screen reports the screen already mounted.
  func setWindowVisible(_ visible: Bool) {
    isWindowVisible = visible
    if visible { reportIfShown() }
  }

  /// A real screen mounted for route `epoch` (its `onAppear`). The one presentation producer:
  /// a row is reported only for the CURRENT route's mounted real screen while the window is
  /// visible, so a step skipped between two renders never reports (M75 review r1).
  func screenMounted(_ step: OnboardingStep, epoch: Int) {
    guard epoch == routeEpoch, step == state.step else { return }
    mountedEpoch = epoch
    reportIfShown()
  }

  private func reportIfShown() {
    guard isWindowVisible, mountedEpoch == routeEpoch, Self.realScreens.contains(state.step),
      let coordinator
    else { return }
    onPresented?(state.step, coordinator.resumedFromCheckpoint)
  }

  /// Re-reads the coordinator (its `onChange` fires after every published change).
  func refresh() {
    guard let coordinator else { return }
    let previous = state
    state = coordinator.state
    isPracticeUsable = coordinator.isPracticeUsable
    if state.step != previous.step { routeEpoch &+= 1 }
    let languageChanged = state.choices.languageMode != previous.choices.languageMode
    let onSpeechPair = state.step == .speechPick || state.step == .speechCompare
    if !onSpeechPair || languageChanged { speechDraft = nil }
    let onPolishPair = state.step == .polishPick || state.step == .polishSeeAll
    if !onPolishPair || languageChanged
      || state.recommended.appleIntelligence != previous.recommended.appleIntelligence
    {
      polishDraft = nil
    }
  }

  /// Stops mirroring. Only this model's subscription is removed.
  func detach() {
    isWindowVisible = false
    onPresented = nil
    coordinator?.onChange = nil
    coordinator = nil
  }
}

/// Owner facts the Setup screens show, gathered by the presenter from the session's owners
/// (plan M76, M77). Values and closures only: nothing here stores or decides.
struct SetupScreenSources {
  /// The Parakeet model the Mac presents (`ModelDeliveryHome.parakeetModelLabel`), so the speech
  /// card's name and download size describe the same model. nil: the shipped model's.
  var parakeetModelName: (@MainActor () -> String)?
  /// EG-1's manifest sizes, measured facts and versions (`PolishSetupWiring.egOneSizeCatalog`).
  var egOneSizeCatalog = EGOneSizeCatalog()
  /// S1-mini's manifest total (`OnboardingLiveMapping.s1MiniBundledBytes`).
  var s1MiniDownloadBytes: Int64? = OnboardingLiveMapping.s1MiniBundledBytes
  /// This Mac's installed memory, for the EG-1 tiles' "Tight on this Mac".
  var physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
  /// The runtime's approved Apple Intelligence recheck ("Check again"); nil hides the link.
  var recheckAppleIntelligence: (@MainActor () -> Void)?
}

// MARK: - Router

/// Every presentable step has exactly one branch; `done` closes Setup and is never shown. The
/// model reports a real screen's presentation (telemetry M67) while the window is visible;
/// placeholders report nothing.
struct SetupScreenRouter: View {
  let model: SetupScreenModel

  var body: some View {
    switch model.state.step {
    case .welcome: SetupWelcomeScreen(model: model, epoch: model.routeEpoch)
    case .language: SetupLanguageScreen(model: model, epoch: model.routeEpoch)
    case .speechPick: SetupSpeechScreen(model: model, epoch: model.routeEpoch, comparing: false)
    case .speechCompare: SetupSpeechScreen(model: model, epoch: model.routeEpoch, comparing: true)
    case .polishIntro: SetupPolishIntroScreen(model: model, epoch: model.routeEpoch)
    case .polishPick: SetupPolishScreen(model: model, epoch: model.routeEpoch, seeAll: false)
    case .polishSeeAll: SetupPolishScreen(model: model, epoch: model.routeEpoch, seeAll: true)
    case .downloads: SetupPlaceholder(step: .downloads, chunk: "D4a")
    case .permissions: SetupPlaceholder(step: .permissions, chunk: "D4b")
    case .key: SetupPlaceholder(step: .key, chunk: "D5")
    case .gettingReady: SetupPlaceholder(step: .gettingReady, chunk: "D4a")
    case .practice: SetupPlaceholder(step: .practice, chunk: "D6b")
    case .film: SetupPlaceholder(step: .film, chunk: "E")
    case .done: EmptyView()
    }
  }
}

/// DEBUG-only stand-in until a screen's chunk lands. Not user copy: verbatim text, never in the
/// string catalog, deleted as each screen replaces it.
private struct SetupPlaceholder: View {
  let step: OnboardingStep
  let chunk: String

  var body: some View {
    VStack(spacing: DesignSpacing.md) {
      Spacer()
      Text(verbatim: "Placeholder: \(step.rawValue)")
        .font(.firstRunTitle)
      Text(verbatim: "Screen arrives in chunk \(chunk)")
        .font(.firstRunCaption)
        .foregroundStyle(Color.obTextSecondary)
      Spacer()
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Step strip

/// The six-step progress strip (mockup `stepSegs`): done steps at 72% accent, the current step
/// full accent, later steps the hairline color. Hidden on Welcome, Film and done.
struct SetupStepStrip: View {
  let step: OnboardingStep

  /// Mockup `STEP_OF` / `STEP_NAMES`.
  static func index(of step: OnboardingStep) -> Int? {
    switch step {
    case .language: 0
    case .speechPick, .speechCompare: 1
    case .polishIntro, .polishPick, .polishSeeAll, .downloads: 2
    case .permissions: 3
    case .key: 4
    case .gettingReady, .practice: 5
    case .welcome, .film, .done: nil
    }
  }

  static let count = 6

  var body: some View {
    HStack(spacing: 0) {
      if let current = Self.index(of: step) {
        HStack(spacing: SetupLayout.segmentGap) {
          ForEach(0..<Self.count, id: \.self) { index in
            Capsule()
              .fill(Self.fill(index: index, current: current))
              .frame(width: SetupLayout.segmentWidth, height: SetupLayout.segmentHeight)
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(current: current))
      }
      Spacer(minLength: 0)
    }
  }

  private static func fill(index: Int, current: Int) -> Color {
    if index < current { return Color.obAccent.opacity(0.72) }
    if index == current { return Color.obAccent }
    return Color.firstRunRule
  }

  private static func label(current: Int) -> Text {
    let name: LocalizedStringResource =
      switch current {
      case 0: "Language"
      case 1: "Speech model"
      case 2: "AI polish"
      case 3: "Permissions"
      case 4: "Your key"
      default: "First dictation"
      }
    return Text("Step \(current + 1) of \(count): \(String(localized: name))")
  }
}
