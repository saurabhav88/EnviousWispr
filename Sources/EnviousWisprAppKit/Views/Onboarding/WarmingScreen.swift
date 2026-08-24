import EnviousWisprServices
import SwiftUI

// MARK: - Screen 4: Engine warm gate (#2196)

/// The beat between picking a shortcut and leaving setup. It does not open
/// until the speech engine reports ready.
///
/// Why it exists: a press taken before readiness is REFUSED and mints no
/// session (`RecordingStarter.swift:292-297`, `ColdPressGuard`), so a brand new
/// person's very first press would appear to do nothing and would need a second
/// one. Rather than explain that after the fact, this screen makes it
/// unreachable.
///
/// Readiness is not owned here. The gate is a second CALLER of
/// `DictationRuntime.ensureActiveEngineWarmForOnboarding()` — the same entry the
/// setup checklist already awaits, idempotent and single-flighted, so asking
/// again when the engine is already warm returns `.ready` immediately. No new
/// flag, no second authority.
///
/// The usual case is therefore a sub-second beat. There is deliberately no
/// percentage bar: the progress file is written only while a model load is
/// actually running, so on the overwhelmingly common already-warm path a bar
/// would render either a stale value from the checklist or an empty one, and
/// both are a claim the screen cannot back.
struct WarmingScreenV2: View {
  var viewModel: OnboardingV2ViewModel

  /// Fired once readiness has genuinely landed.
  let onReady: () -> Void

  /// Fired when the person chooses not to wait. A destination distinct from
  /// `onReady` by construction: a skipped gate has proven nothing about the
  /// engine, so a caller must stay free to route the two differently.
  let onSkip: () -> Void

  @Environment(PermissionsService.self) private var permissions

  private var failureMessage: String? {
    if case .failed(let message) = viewModel.warmingOutcome { return message }
    return nil
  }

  var body: some View {
    VStack(spacing: 0) {
      RainbowLipsView(animationState: viewModel.lipsState, size: 122)
      .padding(.bottom, 18)

      Text(failureMessage == nil ? "Warming up" : "Nearly there")
        .font(.system(size: 28, weight: .heavy, design: .rounded))
        .foregroundStyle(Color.obTextPrimary)
        .kerning(-0.4)
        .padding(.bottom, 6)

      Text(
        failureMessage == nil
          ? "Getting the speech engine ready\nso your first go is instant."
          : "The speech engine did not finish waking up."
      )
      .font(.obBody)
      .foregroundStyle(Color.obTextSecondary)
      .multilineTextAlignment(.center)
      .padding(.bottom, 24)

      if let failureMessage {
        failurePanel(failureMessage)
      } else {
        activityRow
      }

      checklist
        .padding(.top, 24)

      Spacer()

      // Local Codex r2: on the failure panel this caption said nothing else was
      // needed while the panel beside it asked for a retry or a skip — two
      // instructions, one of them wrong, at the moment the person is stuck.
      // The panel already carries the honest instruction, so this simply does
      // not render there rather than repeating it in different words.
      if failureMessage == nil {
        Text("This usually takes a moment. Nothing else is needed from you.")
          .font(.obCaption)
          .foregroundStyle(Color.obTextSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity)
          .padding(14)
          .background(Color.obSurface, in: RoundedRectangle(cornerRadius: 12))
      }

      Button(action: onSkip) {
        // Visible from the first frame, never behind a delay or a confirm
        // (plan D4). A gate nobody can leave would be a worse product than the
        // cold press it exists to prevent.
        Text("In a hurry? Skip ahead")
          .font(.obCaption)
          .foregroundStyle(Color.obAccent)
      }
      .buttonStyle(.plain)
      .padding(.top, 14)
    }
    // The subject reports its own outcome; nothing here infers readiness from
    // elapsed time (testing-philosophy.md RULE: never-guess-when-the-subject-
    // is-finished). The `onAppear` arm is not redundant with `onChange`: the
    // parent's `.task` and this view's appearance are not ordered against each
    // other, so an outcome that lands before the observer is installed would be
    // a change `onChange` never sees, and the gate would hold forever. They
    // cannot both fire for one transition, because `onChange` only sees a
    // SUBSEQUENT change.
    //
    // Local Codex review raised a third ordering: the window closed mid-warm-up
    // (the owned task survives, deliberately), the outcome landing with nobody
    // watching, and a reopen that skips `onAppear` leaving nothing to fire.
    // WHAT WAS CHECKED: onboarding is a singleton `Window(id: "onboarding")`
    // scene (`EnviousWisprApp.swift:44`), not a `WindowGroup`, and the evidence
    // the finding itself cites — that a reopen keeps the view model and skips
    // `onAppear` (`OnboardingProgress.swift:40-44`) — is evidence the root view
    // holding that `@State` is RETAINED, which retains this subtree and its
    // `onChange` with it. The finding needs the view discarded and the view
    // model kept at once, and one `@State` cannot outlive its own view.
    // WHAT IS NOT ESTABLISHED: whether SwiftUI re-evaluates a dismissed
    // window's body immediately or defers to reopen. Either is correct here;
    // only "never", which would mean discarding a pending change on a retained
    // view, would strand the gate, and nothing observed says it does that.
    .onAppear { if viewModel.warmingOutcome == .ready { onReady() } }
    .onChange(of: viewModel.warmingOutcome) { _, outcome in
      if outcome == .ready { onReady() }
    }
    .animation(.easeInOut(duration: 0.3), value: viewModel.warmingOutcome)
  }

  private var activityRow: some View {
    HStack(spacing: 9) {
      ProgressView()
        .progressViewStyle(.circular)
        .controlSize(.small)
      Text("Loading the speech model")
        .font(.obLabel)
        .foregroundStyle(Color.obTextSecondary)
    }
  }

  private func failurePanel(_ message: String) -> some View {
    VStack(spacing: 12) {
      Text(message)
        .font(.obCaption)
        .foregroundStyle(Color.obTextSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      Button(action: viewModel.retryWarming) {
        Text("TRY AGAIN")
          .font(.system(size: 14, weight: .heavy))
          .kerning(0.3)
          .foregroundStyle(.white)
          .frame(maxWidth: 260)
          .padding(.vertical, 11)
          .background(Color.obButtonFill, in: RoundedRectangle(cornerRadius: 11))
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.defaultAction)
    }
    .padding(14)
    .background(Color.obErrorSoft, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color.obError.opacity(0.25), lineWidth: 1)
    )
  }

  private var checklist: some View {
    VStack(alignment: .leading, spacing: 12) {
      WarmingChecklistRow(
        title: "Microphone ready",
        state: permissions.hasMicrophonePermission ? .done : .pending)
      WarmingChecklistRow(title: "Your shortcut is set", state: .done)
      WarmingChecklistRow(
        title: "Speech engine",
        state: {
          switch viewModel.warmingOutcome {
          case .ready: return .done
          case .failed: return .pending
          case .waiting: return .working
          }
        }())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct WarmingChecklistRow: View {
  enum Mark { case done, working, pending }

  let title: String
  let state: Mark

  var body: some View {
    HStack(spacing: 10) {
      switch state {
      case .done:
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 17))
          .foregroundStyle(Color.obSuccess)
      case .working:
        ProgressView()
          .progressViewStyle(.circular)
          .controlSize(.small)
          .frame(width: 17, height: 17)
      case .pending:
        Image(systemName: "circle")
          .font(.system(size: 17))
          .foregroundStyle(Color.obTextTertiary.opacity(0.5))
      }
      Text(title)
        .font(.obLabel)
        .foregroundStyle(state == .done ? Color.obTextSecondary : Color.obTextTertiary)
    }
    .accessibilityElement(children: .combine)
  }
}
