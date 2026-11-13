import AVFoundation
import EnviousWisprCore
import EnviousWisprServices
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
  /// Downloads is the CURRENT mounted route AND the window is on screen (plan M83): the runtime's
  /// countdown runs only then. The presenter binds it to `OnboardingRuntime.setDownloadsScreenVisible`.
  @ObservationIgnored var onDownloadsVisible: ((Bool) -> Void)?
  @ObservationIgnored private var downloadsVisible = false

  private func updateDownloadsVisibility() {
    let visible = isWindowVisible && mountedEpoch == routeEpoch && state.step == .downloads
    guard visible != downloadsVisible else { return }
    downloadsVisible = visible
    onDownloadsVisible?(visible)
  }
  /// The steps that have a real screen so far (D1 to D3a).
  static let realScreens: Set<OnboardingStep> = [
    .welcome, .language, .speechPick, .speechCompare, .polishIntro, .polishPick, .polishSeeAll,
    .permissions, .key,
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
    updateDownloadsVisibility()
  }

  /// A real screen mounted for route `epoch` (its `onAppear`). The one presentation producer:
  /// a row is reported only for the CURRENT route's mounted real screen while the window is
  /// visible, so a step skipped between two renders never reports (M75 review r1).
  func screenMounted(_ step: OnboardingStep, epoch: Int) {
    guard epoch == routeEpoch, step == state.step else { return }
    mountedEpoch = epoch
    reportIfShown()
    updateDownloadsVisibility()
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
    updateDownloadsVisibility()
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
    updateDownloadsVisibility()
    onDownloadsVisible = nil
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
  /// The shortcut screen's owners (D5); nil renders the shipped shortcut with no live listener.
  var shortcut: SetupShortcutSources?
  /// The permissions screen's owners (D4b); nil renders "not asked" with inert actions.
  var permissions: SetupPermissionsSources?
  /// Downloads and Getting ready's picture of the current picks (D4a, M83), read live in the
  /// view body so owner changes redraw it.
  var downloads: (@MainActor () -> OnboardingDownloadsPresentation)?
  /// Downloads and Getting ready actions, all through the coordinator (D4a, M83).
  var downloadActions = SetupDownloadActions()
}

/// The two permissions' owners for Setup's Permissions screen (#4528 D4b, plan M81).
struct SetupPermissionsSources {
  /// `PermissionsService.microphoneStatusLive` (the DEBUG simulation answers here too).
  var microphone: @MainActor () -> AVAuthorizationStatus
  /// `PermissionsService.accessibilityGrantedLive`.
  var accessibilityAllowed: @MainActor () -> Bool
  /// The dictation key's spoken name for the Accessibility card ("Right Option").
  var dictationKey: @MainActor () -> String
  var actions: SetupPermissionsActions
}

/// The coordinator's own actions for Downloads and Getting ready (plan M83). Views never call a
/// delivery or engine owner directly.
struct SetupDownloadActions {
  /// Both current downloads again (clears a block; rechecks disk).
  var retryDownloads: @MainActor () -> Void = {}
  /// Both current downloads stopped (the owners' explicit cancels).
  var cancelDownloads: @MainActor () -> Void = {}
  var retryWarmup: @MainActor () -> Void = {}
  var retryPolish: @MainActor () -> Void = {}
}

/// The record shortcut's owners for Setup's key screen (#4528 D5, plan M80).
struct SetupShortcutSources {
  /// The saved record shortcut, read live (`SettingsManager.shortcutBindings.record`).
  var binding: @MainActor () -> ShortcutBinding
  /// The checked save (`ShortcutSettings.assign(_:to: .record, in:)`); a refusal writes nothing.
  var change: @MainActor (ShortcutBinding) -> ShortcutRefusal?
  /// Every required download for the current picks is installed (the runtime's own reading).
  var downloadsComplete: @MainActor () -> Bool
  var monitor: any SetupShortcutMonitoring
  /// `DictationRuntime.suspendHotkeys()/resumeHotkeys()`; the screen balances them.
  var suspendHotkeys: @MainActor () -> Void
  var resumeHotkeys: @MainActor () -> Void
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
    case .permissions: SetupPermissionsRoute(model: model, epoch: model.routeEpoch)
    case .key: SetupKeyRoute(model: model, epoch: model.routeEpoch)
    case .gettingReady: SetupPlaceholder(step: .gettingReady, chunk: "D4a")
    case .practice: SetupPlaceholder(step: .practice, chunk: "D6b")
    case .film: SetupPlaceholder(step: .film, chunk: "E")
    case .done: EmptyView()
    }
  }
}

/// The permissions step: the D4b screen over the injected owners. The states are read on every
/// render; the coordinator's readiness changes (the runtime observes both permissions) re-render it,
/// and the flow's own auto-advance moves on once both are on. Sends only `next` and `back`.
private struct SetupPermissionsRoute: View {
  let model: SetupScreenModel
  let epoch: Int

  var body: some View {
    let sources = model.sources.permissions
    // Reading the flow's grants subscribes this route to them, so a change re-renders it with
    // fresh live states (the screen keeps its own waiting rows and bounce).
    let _ = (model.state.readiness.microphoneGranted, model.state.readiness.accessibilityGranted)
    SetupPermissionsScreen(
      microphone: .init(sources?.microphone() ?? .notDetermined),
      accessibilityAllowed: sources?.accessibilityAllowed() ?? false,
      dictationKey: sources?.dictationKey() ?? "",
      actions: sources?.actions ?? SetupPermissionsActions(microphone: {}, accessibility: { _ in }),
      onContinue: { if model.state.step == .permissions { model.send(.next) } },
      onBack: { if model.state.step == .permissions { model.send(.back) } }
    )
    .onAppear { model.screenMounted(.permissions, epoch: epoch) }
  }
}

/// The key step: the D5 shortcut screen over the injected owners; it reports its presentation and
/// sends only `next` and `back`.
private struct SetupKeyRoute: View {
  let model: SetupScreenModel
  let epoch: Int

  var body: some View {
    let sources = model.sources.shortcut
    SetupShortcutScreen(
      binding: sources?.binding() ?? ShortcutBindings.shipped.record,
      downloadsComplete: sources?.downloadsComplete() ?? false,
      changeShortcut: { sources?.change($0) },
      onContinue: { if model.state.step == .key { model.send(.next) } },
      onBack: { if model.state.step == .key { model.send(.back) } },
      monitor: sources?.monitor,
      suspendHotkeys: { sources?.suspendHotkeys() },
      resumeHotkeys: { sources?.resumeHotkeys() }
    )
    .onAppear { model.screenMounted(.key, epoch: epoch) }
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
