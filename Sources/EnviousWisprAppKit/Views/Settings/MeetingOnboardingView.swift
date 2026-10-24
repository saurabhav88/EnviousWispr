import SwiftUI

/// EnviousMeet's setup, shown on the EnviousMeet page until it is finished (#4017 O1, O2, O3):
/// Get Started, the consent promise, three permissions, then "You're all set". It sits inside
/// the EnviousMeet page's panel like every settings page: left-aligned, step dots, a large
/// welcome video; the page frame scrolls.
struct MeetingOnboardingView: View {
  @Environment(MeetingOnboardingModel.self) private var model

  var body: some View {
    // Every column has a largest width, never a fixed one, so a narrow window narrows it.
    VStack(alignment: .leading, spacing: 22) {
      MeetingSetupStepDots(step: model.screen)
      ZStack(alignment: .topLeading) {
        switch model.screen {
        case .welcome: MeetingSetupWelcome().transition(Self.transition)
        case .legal: MeetingSetupConsent().transition(Self.transition)
        case .permissions: MeetingSetupPermissions().transition(Self.transition)
        case .done: MeetingSetupDone().transition(Self.transition)
        }
      }
      .animation(.easeInOut(duration: 0.35), value: model.screen)
    }
    .padding(.top, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear { model.begin() }
    .onDisappear { model.left() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in model.refresh()
    }
  }

  private static let transition: AnyTransition = .asymmetric(
    insertion: .opacity.combined(with: .offset(y: 20)), removal: .opacity)
}

/// The setup's type sizes: a step title inside the page's panel, then the settings pages'
/// reading sizes (14-point floor).
private extension Font {
  static let setupTitle = Font.system(size: 22, weight: .bold)
  static let setupLead = Font.system(size: 16, weight: .regular)
  static let setupBody = Font.system(size: 15, weight: .regular)
  static let setupRowTitle = Font.system(size: 15, weight: .semibold)
  static let setupRowLine = Font.system(size: 14, weight: .regular)
}

/// Four dots, the current one long: where the user is in setup. Decoration only; each screen's
/// title says where they are.
private struct MeetingSetupStepDots: View {
  let step: MeetingOnboardingModel.Screen
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var index: Int {
    switch step {
    case .welcome: 0
    case .legal: 1
    case .permissions: 2
    case .done: 3
    }
  }

  var body: some View {
    HStack(spacing: 8) {
      ForEach(0..<4, id: \.self) { dot in
        Capsule()
          .fill(dot <= index ? Color.obButtonFill : Color.obTextTertiary.opacity(0.35))
          .frame(width: dot == index ? 28 : 6, height: 6)
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: index)
    .accessibilityHidden(true)
  }
}

// MARK: - Get Started

private struct MeetingSetupWelcome: View {
  @Environment(MeetingOnboardingModel.self) private var model
  @State private var appeared = false

  private static let features: [(icon: String, title: LocalizedStringResource)] = [
    (
      "person.2.slash",
      LocalizedStringResource(
        "No bot joins your call", comment: "EnviousMeet setup: welcome feature title.")
    ),
    (
      "lock.shield",
      LocalizedStringResource(
        "Your audio never leaves your Mac", comment: "EnviousMeet setup: welcome feature title.")
    ),
    (
      "heart",
      LocalizedStringResource(
        "Free and open source", comment: "EnviousMeet setup: welcome feature title.")
    ),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      MeetingWelcomeMedia()
        .aspectRatio(MeetingWelcomeMedia.aspectRatio, contentMode: .fit)
        .frame(maxWidth: 640)
        .padding(.bottom, 22)

      Text("Meeting notes, with no bot in your call.", comment: "EnviousMeet setup: welcome title.")
        .font(.setupTitle)
        .foregroundStyle(Color.obTextPrimary)
        .kerning(-0.3)
        .padding(.bottom, 8)
      Text(
        "EnviousMeet records your calls and meetings, then writes who said what.",
        comment: "EnviousMeet setup: welcome line under the title."
      )
      .font(.setupLead)
      .foregroundStyle(Color.obTextSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 16)

      // In a row when it fits, else stacked.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 18) { features }
        VStack(alignment: .leading, spacing: 8) { features }
      }
      .padding(.bottom, 24)

      Button {
        model.getStarted()
      } label: {
        Text("Get Started", comment: "EnviousMeet setup: the welcome screen's button.")
      }
      .buttonStyle(OnboardingButtonStyle())
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("meetings.setup.getStarted")
    }
    .frame(maxWidth: 640, alignment: .leading)
    .onAppear { appeared = true }
  }

  @ViewBuilder private var features: some View {
        ForEach(Array(Self.features.enumerated()), id: \.offset) { index, feature in
          HStack(spacing: 7) {
            Image(systemName: feature.icon)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(Color.obAccent)
              .accessibilityHidden(true)
            Text(feature.title).font(.setupRowLine).foregroundStyle(Color.obTextPrimary)
          }
          .opacity(appeared ? 1 : 0)
          .offset(y: appeared ? 0 : 8)
          .animation(.easeOut(duration: 0.4).delay(0.1 + Double(index) * 0.08), value: appeared)
          .accessibilityElement(children: .combine)
        }
  }
}

// MARK: - Before you record

private struct MeetingSetupConsent: View {
  @Environment(MeetingOnboardingModel.self) private var model

  var body: some View {
    @Bindable var model = model
    VStack(alignment: .leading, spacing: 0) {
      Text("Before you record", comment: "EnviousMeet setup: the consent screen's title.")
        .font(.setupTitle)
        .foregroundStyle(Color.obTextPrimary)
        .kerning(-0.4)
        .padding(.bottom, 8)
      Text(
        "One promise, then you are ready.",
        comment: "EnviousMeet setup: the line under Before you record."
      )
      .font(.setupLead)
      .foregroundStyle(Color.obTextSecondary)
      .padding(.bottom, 24)

      VStack(alignment: .leading, spacing: 12) {
        ForEach(MeetingConsentCopy.paragraphs.indices, id: \.self) { index in
          Text(MeetingConsentCopy.paragraphs[index])
            .font(.setupBody)
            .lineSpacing(3)
            .foregroundStyle(Color.obTextPrimary.opacity(0.88))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.bottom, 24)

      Toggle(isOn: $model.consented) {
        Text(MeetingConsentCopy.promise)
          .font(.setupRowTitle)
          .foregroundStyle(Color.obTextPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .toggleStyle(.checkbox)
      .accessibilityIdentifier("meetings.setup.consent")
      .padding(.bottom, 28)

      HStack(spacing: 16) {
        Button {
          model.accept()
        } label: {
          Text("Accept and continue", comment: "EnviousMeet setup: accepts the consent promise.")
        }
        .buttonStyle(
          OnboardingButtonStyle(color: model.consented ? .obButtonFill : .obButtonFill.opacity(0.4))
        )
        .disabled(!model.consented)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("meetings.setup.accept")

        Button {
          model.back()
        } label: {
          Text("Back", comment: "EnviousMeet setup: goes to the previous screen.")
        }
        .buttonStyle(.link)
      }
    }
    .frame(maxWidth: 560, alignment: .leading)
  }
}

/// The consent text (#4017 O4), shared by the setup and the settings page.
enum MeetingConsentCopy {
  static let paragraphs: [LocalizedStringResource] = [
    LocalizedStringResource(
      "Recording laws differ by place. In some places, everyone in a call or a room must agree before you record.",
      comment: "EnviousMeet consent text, paragraph 1."),
    LocalizedStringResource(
      "You are responsible for telling people and getting their consent where the law requires it. Envious Labs is not responsible for recordings you make without consent.",
      comment: "EnviousMeet consent text, paragraph 2."),
    LocalizedStringResource(
      "Check the laws that apply to you and to the people you record.",
      comment: "EnviousMeet consent text, paragraph 3."),
  ]
  static let promise = LocalizedStringResource(
    "I understand. I will get consent where the law requires it.",
    comment: "EnviousMeet setup: the consent checkbox.")
}

// MARK: - Permissions

private struct MeetingSetupPermissions: View {
  @Environment(MeetingOnboardingModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(
        "Almost there. Three quick permissions.", comment: "EnviousMeet setup: permissions title."
      )
      .font(.setupTitle)
      .foregroundStyle(Color.obTextPrimary)
      .kerning(-0.4)
      .padding(.bottom, 8)
      Text(
        "You can say no to any of them and turn it on later.",
        comment: "EnviousMeet setup: the line under the permissions title."
      )
      .font(.setupLead)
      .foregroundStyle(Color.obTextSecondary)
      .padding(.bottom, 20)

      VStack(spacing: 0) {
        MeetingSetupPermissionRow(
          icon: "mic.fill",
          title: LocalizedStringResource(
            "Microphone", comment: "EnviousMeet setup: a permission name."),
          line: LocalizedStringResource(
            "To hear your voice.", comment: "EnviousMeet setup: why the microphone."),
          state: model.microphone, busy: model.asking,
          allow: { Task { await model.allowMicrophone() } }, skip: nil, openSettings: { Task { await model.allowMicrophone() } })
        MeetingSetupPermissionRow(
          icon: "speaker.wave.2.fill",
          title: LocalizedStringResource(
            "Call sound", comment: "EnviousMeet setup: a permission name."),
          line: LocalizedStringResource(
            "To hear the other people, also with AirPods. Only the sound, never your screen.",
            comment: "EnviousMeet setup: why the call sound."),
          state: model.callSound, busy: model.asking,
          allow: { Task { await model.allowCallSound() } }, skip: { model.skipCallSound() },
          openSettings: { model.openCallSoundSettings() })
        MeetingSetupPermissionRow(
          icon: "calendar",
          title: LocalizedStringResource(
            "Calendar", comment: "EnviousMeet setup: a permission name."),
          line: LocalizedStringResource(
            "To name each meeting after its event. macOS asks for full access; EnviousMeet only reads event titles, times and meeting links, and never changes your calendar.",
            comment: "EnviousMeet setup: why the calendar."),
          state: model.calendar, busy: model.asking,
          allow: { Task { await model.allowCalendar() } }, skip: { model.skipCalendar() },
          openSettings: { model.openCalendarSettings() })
      }
      .overlay(alignment: .bottom) { Divider().opacity(0.6) }
      .padding(.bottom, 28)

      Button {
        model.continueToDone()
      } label: {
        Text("Continue", comment: "EnviousMeet setup: leaves the permissions screen.")
      }
      .buttonStyle(OnboardingButtonStyle())
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("meetings.setup.continue")
    }
    .frame(maxWidth: 600, alignment: .leading)
  }
}

private struct MeetingSetupPermissionRow: View {
  let icon: String
  let title: LocalizedStringResource
  let line: LocalizedStringResource
  let state: MeetingOnboardingModel.PermissionState
  let busy: Bool
  let allow: () -> Void
  let skip: (() -> Void)?
  let openSettings: (() -> Void)?

  private var allowed: Bool { state == .granted }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(allowed ? Color.obSuccess : Color.obAccent)
        .frame(width: 34, height: 34)
        .background(
          allowed ? Color.obSuccessSoft : Color.obAccentSoft, in: RoundedRectangle(cornerRadius: 9)
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.setupRowTitle).foregroundStyle(Color.obTextPrimary)
        Text(line)
          .font(.setupRowLine)
          .foregroundStyle(Color.obTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
        if let note {
          Text(note).font(.setupRowLine).foregroundStyle(Color.obWarning)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      trailing
    }
    .padding(.vertical, 16)
    .overlay(alignment: .top) { Divider().opacity(0.6) }
    .animation(.easeInOut(duration: 0.3), value: state)
  }

  private var note: LocalizedStringResource? {
    switch state {
    case .skipped:
      return LocalizedStringResource(
        // #4058: "Turn on" no longer fits every row: a skipped call sound is undone by turning
        // Record only my voice off.
        "You can change this later in EnviousMeet settings.",
        comment: "EnviousMeet setup: under a skipped permission or choice.")
    case .requested:
      return LocalizedStringResource(
        "Asked. If you said no, allow it in System Settings.",
        comment: "EnviousMeet setup: macOS was asked for the call sound; its answer cannot be read."
      )
    case .denied:
      return LocalizedStringResource(
        "Turned off. Allow it in System Settings.",
        comment: "EnviousMeet setup: a refused permission.")
    case .unavailable:
      return LocalizedStringResource(
        "Not available on this Mac.", comment: "EnviousMeet setup: a permission a profile blocks.")
    case .askedAtFirstRecording:
      return LocalizedStringResource(
        "macOS asks the first time you record the call sound.",
        comment: "EnviousMeet setup: this Mac cannot ask for the call sound ahead of a recording.")
    case .granted, .notAsked:
      return nil
    }
  }

  @ViewBuilder private var trailing: some View {
    switch state {
    case .granted:
      HStack(spacing: 4) {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.obSuccess)
        Text("Granted", comment: "EnviousMeet setup: a permission that macOS allowed.")
          .font(.obCaptionSmall)
          .foregroundStyle(Color.obSuccessText)
      }
    case .denied, .requested:
      if let openSettings {
        Button(action: openSettings) {
          Text(
            "Open Settings", comment: "EnviousMeet setup: opens System Settings for a permission.")
        }
        .buttonStyle(OnboardingButtonStyle(color: .obAccent))
        .font(.system(size: 12, weight: .semibold))
        .fixedSize()
      }
    case .unavailable, .askedAtFirstRecording:
      EmptyView()
    case .notAsked, .skipped:
      VStack(alignment: .trailing, spacing: 4) {
        Button(action: allow) {
          Text("Allow", comment: "EnviousMeet setup: asks macOS for a permission.")
        }
        .buttonStyle(OnboardingButtonStyle(color: .obAccent))
        .font(.system(size: 12, weight: .semibold))
        .fixedSize()
        .disabled(busy)
        if let skip, state == .notAsked {
          Button(action: skip) {
            Text("Not now", comment: "EnviousMeet setup: skips a permission for now.")
          }
          .buttonStyle(.plain)
          .font(.obCaptionSmall)
          .foregroundStyle(Color.obTextTertiary)
          .disabled(busy)
        }
      }
    }
  }
}

// MARK: - You're all set

private struct MeetingSetupDone: View {
  @Environment(MeetingOnboardingModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack {
        MeetingConfettiBurst()
        RainbowLipsView(animationState: .heart, size: 96)
          .accessibilityHidden(true)
      }
      .frame(width: 160, height: 110)
      .padding(.bottom, 12)
      Text("You're all set!", comment: "EnviousMeet setup: the last screen's title.")
        .font(.setupTitle)
        .foregroundStyle(Color.obTextPrimary)
        .padding(.bottom, 8)
      Text(
        "Start a recording from the menu bar. The lips in the menu bar glow while a meeting records.",
        comment: "EnviousMeet setup: how to record, on the last screen."
      )
      .font(.setupLead)
      .foregroundStyle(Color.obTextPrimary.opacity(0.85))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 6)
      Text(
        "Your recordings appear in History, under Recordings.",
        comment: "EnviousMeet setup: where recordings are, on the last screen."
      )
      .font(.setupBody)
      .foregroundStyle(Color.obTextSecondary)
      .padding(.bottom, model.unresolved.isEmpty ? 28 : 12)

      if !model.unresolved.isEmpty {
        Text(
          "Not allowed yet: \(model.unresolved.formatted(.list(type: .and))). Turn them on later in EnviousMeet settings.",
          comment: "EnviousMeet setup: the permissions still off, as a list, on the last screen."
        )
        .font(.setupRowLine)
        .foregroundStyle(Color.obWarning)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 18)
      }

      Button {
        model.finish()
      } label: {
        Text(
          "Open EnviousMeet", comment: "EnviousMeet setup: finishes setup and shows its settings."
        )
      }
      .buttonStyle(OnboardingButtonStyle())
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("meetings.setup.finish")
    }
    .frame(maxWidth: 560, alignment: .leading)
  }
}

/// A one-time burst of rainbow confetti behind the heart (#4017 O2). Off with Reduce Motion.
private struct MeetingConfettiBurst: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var start = Date()

  private static let colors: [Color] = [
    Color(red: 1.0, green: 0.165, blue: 0.251), Color(red: 1.0, green: 0.549, blue: 0.0),
    Color(red: 1.0, green: 0.843, blue: 0.0), Color(red: 0.678, green: 1.0, blue: 0.184),
    Color(red: 0.0, green: 0.98, blue: 0.604), Color(red: 0.0, green: 1.0, blue: 1.0),
    Color(red: 0.118, green: 0.565, blue: 1.0), Color(red: 0.255, green: 0.412, blue: 0.882),
    Color(red: 0.541, green: 0.169, blue: 0.886),
  ]
  private static let duration = 2.2
  private static let pieces = 42

  var body: some View {
    if reduceMotion {
      EmptyView()
    } else {
      TimelineView(.animation) { context in
        let t = context.date.timeIntervalSince(start)
        Canvas { canvas, size in
          guard t < Self.duration else { return }
          let progress = t / Self.duration
          let center = CGPoint(x: size.width / 2, y: size.height / 2)
          for index in 0..<Self.pieces {
            let angle = Double(index) / Double(Self.pieces) * 2 * .pi
            let reach = 120 + Double(index % 4) * 40
            let eased = 1 - pow(1 - progress, 3)
            let x = center.x + cos(angle) * reach * eased
            let y = center.y + sin(angle) * reach * 0.8 * eased + 90 * progress * progress
            var piece = canvas
            piece.opacity = 1 - progress
            piece.translateBy(x: x, y: y)
            piece.rotate(by: .degrees(Double(index * 47) + progress * 360))
            piece.fill(
              Path(roundedRect: CGRect(x: -4, y: -7, width: 8, height: 14), cornerRadius: 2),
              with: .color(Self.colors[index % Self.colors.count]))
          }
        }
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }
}
