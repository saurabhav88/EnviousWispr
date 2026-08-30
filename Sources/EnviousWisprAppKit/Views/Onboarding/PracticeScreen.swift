import AppKit
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

// MARK: - Screen 5: Try it out (#2196)

/// The last screen of setup, and the whole point of #2196: a real text box with
/// the cursor already in it, so a first dictation has somewhere to land.
///
/// WHY THE BOX IS THE ENTIRE FIX. `PasteCascadeExecutor` classifies the focused
/// element by AX role and `PasteService.textRoles` accepts `AXTextField`,
/// `AXTextArea`, `AXComboBox`, `AXSearchField` (`PasteService.swift:70-75`). A
/// focused SwiftUI `TextEditor` is backed by `NSTextView` and presents as
/// `AXTextArea`, which is in that set. The refusal this feature exists to fix
/// happens BECAUSE the classification is `.nonText` — our own window offered
/// nothing to type into — so supplying a text-role element removes the
/// precondition for the refusal rather than special-casing around it. Nothing in
/// the cascade special-cases our bundle: `isExpectedNonTextRefusal` special-cases
/// `com.apple.loginwindow` and nothing else (`PasteCascadeExecutor.swift:915-930`).
///
/// So this file adds NO pipeline code, no delivery route, and no new setting. It
/// adds a target.
struct PracticeScreenV2: View {
  var viewModel: OnboardingV2ViewModel

  /// Fired when the person is finished, however they got there.
  let onFinish: () -> Void

  @Environment(SettingsManager.self) private var settings
  /// Whether a take produced anything at all. Focus says where words WOULD go;
  /// only this says whether any existed (cloud review).
  @Environment(TranscriptCoordinator.self) private var transcripts
  @Environment(PermissionsService.self) private var permissions
  /// The SUBJECT's own in-flight signal: true while either pipeline is
  /// recording, transcribing or polishing. The screen was previously blind to a
  /// take entirely, which is what let Skip pull the target away mid-dictation
  /// and let a silent take go unacknowledged (local Codex chunk-2 review).
  @Environment(LiveRecordingState.self) private var live

  @FocusState private var boxFocused: Bool

  /// A take is in flight, so both BUTTONS are held. Leaving by button now would
  /// close the window the ordinary cascade is about to type into, and the words
  /// would land on the clipboard behind the same notice this feature removes.
  ///
  /// KNOWN LIMIT, named rather than implied (cloud review): this holds the
  /// buttons, NOT the window. The close control and Command-W still work,
  /// because the window coordinator observes `willClose` and does not veto it.
  /// Someone determined can still leave mid-take. What that costs is now
  /// bounded rather than wrong: the abandon path emits, and `runWarmingGate`'s
  /// visit-alive guard means the late outcome reports nothing and stores
  /// nothing. So the DATA stays honest and the words behave exactly as they do
  /// when anyone closes any window mid-dictation anywhere else in the app.
  /// Vetoing a window close is a bigger change than this screen justifies.
  private var takeInFlight: Bool { live.isDictationActive }

  /// FOUNDER, 2026-08-24: "this page should remind people what keybind they
  /// set". They chose it on the previous screen seconds ago, and "hold your
  /// shortcut" assumes they remember which one — the assumption is hardest on
  /// exactly the person this feature exists for. Same formatter the keycap on
  /// that screen uses, so the two can never disagree about the name.
  private var shortcutName: String {
    if ModifierKeyCodes.isModifierOnly(settings.toggleKeyCode), settings.toggleModifiers.isEmpty {
      return KeySymbols.formatModifierOnly(
        settings.toggleModifiers, keyCode: settings.toggleKeyCode)
    }
    return KeySymbols.format(keyCode: settings.toggleKeyCode, modifiers: settings.toggleModifiers)
  }

  private var cannotHear: Bool {
    if case .cannotHear = viewModel.practiceState { return true }
    return false
  }

  private func grantPermission(reason: String) async {
    if reason == "mic_denied" {
      // `AVCaptureDevice.requestAccess` only presents the prompt from the
      // UNDETERMINED state. After a prior denial it returns false immediately
      // and nothing appears, so the button did nothing at all and the recovery
      // path read as broken (cloud review). Send them where the switch is.
      if permissions.microphonePermissionIsDenied {
        if let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        {
          NSWorkspace.shared.open(url)
        }
      } else {
        _ = await permissions.requestMicrophoneAccess()
      }
    } else {
      _ = permissions.requestAccessibilityAccess()
    }
    refreshPosture()
  }

  /// `hasMicrophonePermission` reads a CACHED snapshot taken at construction,
  /// so a microphone revoked while the app kept running still reads authorized
  /// (cloud review). `microphonePermissionIsDenied` reads LIVE, which is the
  /// whole reason #1558 added it.
  private func refreshPosture() {
    permissions.refreshAccessibilityStatus()
    viewModel.applyPracticePosture(
      micGranted: !permissions.microphonePermissionIsDenied,
      accessibilityGranted: permissions.accessibilityGranted)
  }

  private var headline: String {
    switch viewModel.practiceState {
    case .cannotHear: return "We cannot hear you"
    case .listening: return "Listening…"
    case .somethingBroke: return "That did not work"
    case .missedTheBox: return "Click the box first"
    case .saidNothing: return "All quiet"
    case .worked: return "That is it. You are set."
    case .waiting: return viewModel.practiceSucceeded ? "That is it. You are set." : "Time for your first dictation!"
    }
  }

  private var subhead: String {
    switch viewModel.practiceState {
    case .cannotHear(let reason, _):
      return reason == "mic_denied"
        ? "EnviousWispr needs permission to use your microphone.\nYou can turn it on and come back, or skip ahead."
        : "EnviousWispr needs Accessibility permission to type for you.\nYou can turn it on and come back, or skip ahead."
    case .listening:
      return "Go ahead. Let go of \(shortcutName) when you are done."
    case .somethingBroke:
      // Takes the blame explicitly. Someone told "we did not hear anything"
      // tries harder at a thing that is broken; someone told it was us tries
      // once more and then moves on, which is the honest ask.
      return "Something went wrong on our side, not yours.\nTry once more, or skip ahead and dictate anywhere."
    case .missedTheBox:
      // Says what happened and what to do, and takes the blame off them. The
      // words are genuinely on the clipboard, so telling them that is useful
      // rather than a consolation.
      return "We heard you. The box was not selected, so your words went to the clipboard.\nClick inside the box, then hold \(shortcutName) again."
    case .saidNothing:
      // Not an error, and never worded as one: the microphone worked, there
      // was simply nothing to hear. The prompt is drawn from the persona banks
      // so it sounds like something a person would actually say.
      return "Your microphone is working. We just did not hear anything.\nTry holding \(shortcutName) and saying: tell grandma I will call Sunday."
    case .worked:
      return "Those are your words, typed for you.\nIn any other app, click into a text box first."
    case .waiting:
      return viewModel.practiceSucceeded
        ? "Those are your words, typed for you.\nIn any other app, click into a text box first."
        : "Hold \(shortcutName) and say something.\nLet go when you are done."
    }
  }

  private var footnote: String {
    if cannotHear { return " " }
    if viewModel.practiceSucceeded { return " " }
    return "Your recording indicator appears while you hold the key."
  }

  var body: some View {
    VStack(spacing: 0) {
      RainbowLipsView(animationState: viewModel.lipsState, size: 108)
        .padding(.bottom, 14)

      Text(headline)
        .font(.system(size: 26, weight: .heavy, design: .rounded))
        .foregroundStyle(Color.obTextPrimary)
        .kerning(-0.4)
        .multilineTextAlignment(.center)
        .padding(.bottom, 6)

      Text(subhead)
      .font(.obBody)
      .foregroundStyle(Color.obTextSecondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 18)

      // The target. Focused on appear, because an unfocused box is exactly the
      // state this whole feature exists to remove.
      TextEditor(text: viewModel.practiceTextBinding)
        .font(.system(size: 14))
        .scrollContentBackground(.hidden)
        .padding(10)
        .frame(width: 404, height: 132)
        .background(Color.obSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
              viewModel.practiceSucceeded ? Color.obSuccess.opacity(0.55) : Color.obAccent.opacity(0.35),
              lineWidth: boxFocused ? 2 : 1)
        )
        .focused($boxFocused)
        .accessibilityLabel("Your first dictation")

      // Deliberately quiet while recording: the pill is NOT suppressed during
      // onboarding (nothing under App/Overlay/ reads `onboardingState`), so it
      // appears over this window and carries the recording state — which is what
      // this person will see in every other app forever after. A second waveform
      // here would teach them a UI that only exists during setup.
      Text(footnote)
        .font(.obCaptionSmall)
        .foregroundStyle(Color.obTextTertiary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 10)

      // The route out. `PermissionsService` exposes request methods rather
      // than a settings opener, and the request is the better offer anyway: an
      // undetermined permission is granted in place, and a denied one lands the
      // person on the right pane instead of the top of System Settings.
      // SCOPE, corrected after founder UAT 2026-08-24 and stated so nobody reads
      // the near-zero count as the feature working: on a FIRST RUN this state is
      // UNREACHABLE. The permissions step upstream disables Continue until both
      // microphone and Accessibility are granted, with no skip
      // (`OnboardingV2View.swift`, `.disabled(!bothGranted)`), and the founder
      // confirmed that gate stays — "we aren't going to let people continue
      // without granting us the basic permissions needed".
      //
      // It is reachable on exactly one path, which is real but rare: finish
      // setup, later have a permission revoked, then reopen setup from the menu.
      // That reopen resolves straight to `.ready` and never revisits
      // permissions, so this screen is the first thing that would notice, and
      // macOS does revoke Accessibility on its own after some app updates.
      // A safety net for that path, not part of the first-run experience.
      if case .cannotHear(let reason, _) = viewModel.practiceState {
        Button {
          Task { await grantPermission(reason: reason) }
        } label: {
          Text(reason == "mic_denied" ? "Turn on the microphone" : "Turn on Accessibility")
            .font(.obCaption)
            .foregroundStyle(Color.obAccent)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
      }

      Spacer()

      Button(action: onFinish) {
        Text("FINISH SETUP")
          .font(.system(size: 15, weight: .heavy))
          .kerning(0.3)
          .foregroundStyle(.white)
          .frame(maxWidth: 360)
          .padding(.vertical, 13)
          .background(
            viewModel.practiceSucceeded ? Color.obButtonFill : Color.obButtonFill.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 12))
      }
      .buttonStyle(.plain)
      .disabled(!viewModel.practiceSucceeded || takeInFlight)
      .keyboardShortcut(.defaultAction)

      Button(action: onFinish) {
        Text(takeInFlight ? "One moment, still working on that" : "Skip this step")
          .font(.obCaption)
          .foregroundStyle(takeInFlight ? Color.obTextTertiary : Color.obAccent)
      }
      .buttonStyle(.plain)
      .disabled(takeInFlight)
      .padding(.top, 12)
    }
    .onAppear {
      // A reopened window keeps the retained view model, and the open bridge
      // only starts a fresh `OnboardingProgress` session — it never resets this
      // screen. Without this, someone who closed the window here and came back
      // would find a previous visit's words already in the box and FINISH SETUP
      // already lit (cloud review). Same class as the warm gate's reopen guard.
      viewModel.beginPracticeIfNewVisit()
      boxFocused = true
      // A take can ALREADY be running when this view mounts — press the
      // shortcut during the warming transition and `isDictationActive` is true
      // before the observer below exists. `onChange` has no initial callback,
      // so without this the take is never opened and its end is dropped by the
      // `.listening` guard (cloud review).
      if live.isDictationActive {
        // `boxFocused: false`, and the hardcoded `true` here was the SAME
        // mistake a third time: this take began before this view existed, so
        // the pipeline captured its paste target when there was no box on
        // screen. Claiming focus would send a take that DID produce words into
        // `saidNothing` — "All quiet" about someone we heard perfectly, which
        // is the founder's original defect once more. False is not a guess
        // here, it is the fact: the box could not have been the target.
        viewModel.practiceTakeStarted(
          boxFocused: false, transcriptCount: transcripts.transcriptCount)
      }
      refreshPosture()
    }
    // The take's own edges, from the subject rather than from a timer.
    // Accessibility cannot be observed by notification and
    // `requestAccessibilityAccess()` returns the instant the system prompt
    // opens, so a person who grants it in System Settings and comes back would
    // sit on `cannotHear` until they pressed the button again. The permissions
    // phase upstream solved this with a 2s poll; ported wholesale, scoped to
    // the blocked state so it costs nothing on the ordinary path.
    .task(id: cannotHear) {
      guard cannotHear else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        refreshPosture()
        if !cannotHear { return }
      }
    }
    .onChange(of: live.isDictationActive) { _, active in
      if active {
        // Whether the box holds focus RIGHT NOW is half of what separates "we
        // heard nothing" from "we heard you and it went to the clipboard"; the
        // transcript count is the other half.
        viewModel.practiceTakeStarted(
          boxFocused: boxFocused, transcriptCount: transcripts.transcriptCount)
      } else {
        // A pipeline FAILURE outranks silence, and `PipelineState` already
        // separates our failure (`.error`) from "the microphone delivered
        // nothing usable" (`.advisory`, #1891).
        var failed = false
        if case .error = live.pipelineState { failed = true }
        viewModel.practiceTakeEnded(
          transcriptCount: transcripts.transcriptCount, pipelineFailed: failed)
        // Put the cursor back, so the next attempt cannot repeat the miss for
        // the same reason. Founder-found in Live UAT: the advice is useless if
        // acting on it needs a click they were not told about.
        if viewModel.practiceState == .missedTheBox { boxFocused = true }
      }
    }
    .animation(.easeInOut(duration: 0.3), value: viewModel.practiceState)
  }
}
