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
        .id(model.state.step)
        .transition(reduceMotion ? .opacity : .setupScreenIn)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(.horizontal, SetupLayout.contentPadding)
    .padding(.top, SetupLayout.stripTop)
    .padding(.bottom, SetupLayout.contentPadding)
    .frame(width: SetupLayout.windowWidth, height: SetupLayout.contentHeight)
    .background(Color.obCardBg)
    .foregroundStyle(Color.obTextPrimary)
    .animation(Self.screenAnimation(reduceMotion: reduceMotion), value: model.state.step)
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
  private weak var coordinator: OnboardingCoordinator?

  init(coordinator: OnboardingCoordinator) {
    self.coordinator = coordinator
    state = coordinator.state
    isPracticeUsable = coordinator.isPracticeUsable
    coordinator.onChange = { [weak self] in self?.refresh() }
  }

  /// Re-reads the coordinator (its `onChange` fires after every published change).
  func refresh() {
    guard let coordinator else { return }
    state = coordinator.state
    isPracticeUsable = coordinator.isPracticeUsable
  }

  /// Stops mirroring. Only this model's subscription is removed.
  func detach() {
    coordinator?.onChange = nil
    coordinator = nil
  }
}

// MARK: - Router

/// Every presentable step has exactly one branch; `done` closes Setup and is never shown. A
/// branch reports a real presentation (telemetry M67) only once its screen exists; the D0
/// placeholders report nothing.
struct SetupScreenRouter: View {
  let model: SetupScreenModel

  var body: some View {
    switch model.state.step {
    case .welcome: SetupPlaceholder(step: .welcome, chunk: "D1")
    case .language: SetupPlaceholder(step: .language, chunk: "D1")
    case .speechPick: SetupPlaceholder(step: .speechPick, chunk: "D2")
    case .speechCompare: SetupPlaceholder(step: .speechCompare, chunk: "D2")
    case .polishIntro: SetupPlaceholder(step: .polishIntro, chunk: "D3a")
    case .polishPick: SetupPlaceholder(step: .polishPick, chunk: "D3a")
    case .polishSeeAll: SetupPlaceholder(step: .polishSeeAll, chunk: "D3a/D3b")
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
