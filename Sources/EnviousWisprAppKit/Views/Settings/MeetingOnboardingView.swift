import SwiftUI

/// EnviousMeet's setup, shown on the EnviousMeet page until it is finished (#4017 O1, O2, O3):
/// Get Started, the consent promise, three permissions, then "You're all set". It sits inside
/// the EnviousMeet page's panel like every settings page: left-aligned, logo heading, step dots
/// (#4346); the page frame scrolls.
struct MeetingOnboardingView: View {
  @Environment(MeetingOnboardingModel.self) private var model

  var body: some View {
    // Every column has a largest width, never a fixed one, so a narrow window narrows it.
    VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: 14) {
        MeetingBrandHeading()
        MeetingSetupStepDots(step: model.screen)
      }
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

/// #4346: the welcome is the pitch, then Get Started at once, then what EnviousMeet does. Copy
/// is the founder-approved preview's (issue #4346, 2026-11-02), checked against the app by Codex.
private struct MeetingSetupWelcome: View {
  @Environment(MeetingOnboardingModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  struct Tile {
    let icon: String
    let title: LocalizedStringResource
    let line: LocalizedStringResource
  }

  static let tiles: [Tile] = [
    Tile(
      icon: "person.2.slash",
      title: LocalizedStringResource(
        "No bot in your call", comment: "EnviousMeet setup: welcome tile title."),
      line: LocalizedStringResource(
        "It records from your Mac, so nobody sees a notetaker join.",
        comment: "EnviousMeet setup: welcome tile line under No bot in your call.")),
    Tile(
      icon: "lock.shield",
      title: LocalizedStringResource(
        "Transcribed on your Mac", comment: "EnviousMeet setup: welcome tile title."),
      line: LocalizedStringResource(
        "Your audio never leaves your Mac.",
        comment: "EnviousMeet setup: welcome tile line under Transcribed on your Mac.")),
    Tile(
      icon: "list.bullet.rectangle",
      title: LocalizedStringResource(
        "Summaries your way", comment: "EnviousMeet setup: welcome tile title."),
      line: LocalizedStringResource(
        "Offline with a model on your Mac, or with your own AI key.",
        comment: "EnviousMeet setup: welcome tile line under Summaries your way.")),
    Tile(
      icon: "waveform",
      title: LocalizedStringResource(
        "Live transcript", comment: "EnviousMeet setup: welcome tile title."),
      line: LocalizedStringResource(
        "Watch the words appear while people talk.",
        comment: "EnviousMeet setup: welcome tile line under Live transcript.")),
    Tile(
      icon: "person.text.rectangle",
      title: LocalizedStringResource(
        "Real speaker names", comment: "EnviousMeet setup: welcome tile title."),
      line: LocalizedStringResource(
        "Names from Zoom, Teams and Meet calls, when available.",
        comment: "EnviousMeet setup: welcome tile line under Real speaker names. App names are not translated.")),
    Tile(
      icon: "phone",
      title: LocalizedStringResource(
        "Notices your calls", comment: "EnviousMeet setup: welcome tile title."),
      line: LocalizedStringResource(
        "It can offer to record Zoom, Meet and Teams calls. When it detects a call ending, it shows a stop countdown or asks whether to keep recording.",
        comment: "EnviousMeet setup: welcome tile line under Notices your calls. App names are not translated.")),
    Tile(
      icon: "play.circle",
      title: LocalizedStringResource(
        "Play back any moment", comment: "EnviousMeet setup: welcome tile title."),
      line: LocalizedStringResource(
        "Play back the audio, with a timestamp on every passage.",
        comment: "EnviousMeet setup: welcome tile line under Play back any moment.")),
    Tile(
      icon: "arrow.clockwise",
      title: LocalizedStringResource(
        "Transcribe again", comment: "EnviousMeet setup: welcome tile title."),
      line: LocalizedStringResource(
        "Keep the recording and run it again with another engine.",
        comment: "EnviousMeet setup: welcome tile line under Transcribe again.")),
    Tile(
      icon: "heart",
      title: LocalizedStringResource(
        "Free and open source", comment: "EnviousMeet setup: welcome tile title."),
      line: LocalizedStringResource(
        "No account, no subscription. The code is public (GPLv3).",
        comment: "EnviousMeet setup: welcome tile line under Free and open source. GPLv3 is a license name.")),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(
        "Meeting notes, transcribed on your Mac.", comment: "EnviousMeet setup: welcome title.")
        .font(.setupTitle)
        .foregroundStyle(Color.obTextPrimary)
        .kerning(-0.3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 8)
      Text(
        "A premium meeting notetaker, with summaries that can run offline on your Mac.",
        comment: "EnviousMeet setup: welcome line under the title."
      )
      .font(.setupLead)
      .foregroundStyle(Color.obTextSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 18)

      Button {
        model.getStarted()
      } label: {
        Text("Get Started", comment: "EnviousMeet setup: the welcome screen's button.")
      }
      .buttonStyle(OnboardingButtonStyle())
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("meetings.setup.getStarted")
      .padding(.bottom, 24)

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)],
        alignment: .leading, spacing: 12
      ) {
        ForEach(Array(Self.tiles.enumerated()), id: \.offset) { index, tile in
          MeetingSetupFeatureTile(tile: tile)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .animation(
              reduceMotion ? nil : .easeOut(duration: 0.35).delay(0.05 + Double(index) * 0.04),
              value: appeared)
        }
      }
    }
    .frame(maxWidth: 760, alignment: .leading)
    .onAppear { appeared = true }
  }
}

/// One welcome tile: icon, title, one line (#4346).
private struct MeetingSetupFeatureTile: View {
  let tile: MeetingSetupWelcome.Tile

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: tile.icon)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color.obAccent)
        .frame(width: 34, height: 34)
        .background(Color.obAccentSoft, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(tile.title).font(.setupRowTitle).foregroundStyle(Color.obTextPrimary)
        Text(tile.line)
          .font(.setupRowLine)
          .foregroundStyle(Color.obTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.obTextTertiary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12).strokeBorder(Color.obTextTertiary.opacity(0.18), lineWidth: 1)
    )
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Consent

/// #4346: a friendly heads-up with three short rows; the legal text stays, as fine print.
private struct MeetingSetupConsent: View {
  @Environment(MeetingOnboardingModel.self) private var model

  private static let rows: [(icon: String, title: LocalizedStringResource, line: LocalizedStringResource)] = [
    (
      "bubble.left",
      LocalizedStringResource("Ask first.", comment: "EnviousMeet setup: consent row title."),
      LocalizedStringResource(
        "Say you are recording when the call starts.",
        comment: "EnviousMeet setup: consent row line under Ask first.")
    ),
    (
      "globe",
      LocalizedStringResource(
        "Rules change by place.", comment: "EnviousMeet setup: consent row title."),
      LocalizedStringResource(
        "Some places need everyone in the call to agree.",
        comment: "EnviousMeet setup: consent row line under Rules change by place.")
    ),
    (
      "checkmark",
      LocalizedStringResource(
        "Your call, your choice.",
        comment: "EnviousMeet setup: consent row title; a play on words (call = phone call and decision)."),
      LocalizedStringResource(
        "You get consent where the law needs it.",
        comment: "EnviousMeet setup: consent row line under Your call, your choice.")
    ),
  ]

  var body: some View {
    @Bindable var model = model
    VStack(alignment: .leading, spacing: 0) {
      Text(
        "Good meetings start with a heads-up.",
        comment: "EnviousMeet setup: the consent screen's title."
      )
      .font(.setupTitle)
      .foregroundStyle(Color.obTextPrimary)
      .kerning(-0.4)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 8)
      Text(
        "A quick \"mind if I record?\" keeps everyone comfortable. In some places, the law also requires it.",
        comment: "EnviousMeet setup: the line under the consent title."
      )
      .font(.setupLead)
      .foregroundStyle(Color.obTextSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 20)

      VStack(alignment: .leading, spacing: 14) {
        ForEach(Self.rows.indices, id: \.self) { index in
          let row = Self.rows[index]
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.icon)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(Color.obAccent)
              .frame(width: 34, height: 34)
              .background(Color.obAccentSoft, in: RoundedRectangle(cornerRadius: 9))
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
              Text(row.title).font(.setupRowTitle).foregroundStyle(Color.obTextPrimary)
              Text(row.line)
                .font(.setupRowLine)
                .foregroundStyle(Color.obTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .accessibilityElement(children: .combine)
        }
      }
      .padding(.bottom, 20)

      // The legal text (#4017 O4, shared with the settings page) as fine print, at the floor.
      VStack(alignment: .leading, spacing: 6) {
        ForEach(MeetingConsentCopy.paragraphs.indices, id: \.self) { index in
          Text(MeetingConsentCopy.paragraphs[index])
            .font(.setupRowLine)
            .foregroundStyle(Color.obTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.top, 14)
      .overlay(alignment: .top) { Divider().opacity(0.6) }
      .padding(.bottom, 20)

      Toggle(isOn: $model.consented) {
        Text(MeetingConsentCopy.promise)
          .font(.setupRowTitle)
          .foregroundStyle(Color.obTextPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .toggleStyle(.checkbox)
      .accessibilityIdentifier("meetings.setup.consent")
      .padding(.bottom, 24)

      HStack(spacing: 16) {
        Button {
          model.accept()
        } label: {
          Text("Let's go", comment: "EnviousMeet setup: accepts the consent promise.")
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
    .frame(maxWidth: 600, alignment: .leading)
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
    "Got it. I'll get consent where the law needs it.",
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
      Group {
        if model.callSoundRequired {
          Text(
            "EnviousMeet needs the microphone and call sound to record. Calendar is optional.",
            comment: "EnviousMeet setup: the line under the permissions title.")
        } else {
          Text(
            "EnviousMeet needs the microphone to record. Calendar is optional.",
            comment: "EnviousMeet setup: the line under the permissions title on a Mac that cannot record the call sound (below macOS 14.2).")
        }
      }
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
        if model.callSoundRequired {
          // #4346: required, so no Not now.
          MeetingSetupPermissionRow(
            icon: "speaker.wave.2.fill",
            title: LocalizedStringResource(
              "Call sound", comment: "EnviousMeet setup: a permission name."),
            line: LocalizedStringResource(
              "To hear the other people, also with AirPods. Only the sound, never your screen.",
              comment: "EnviousMeet setup: why the call sound."),
            state: model.callSound, busy: model.asking,
            allow: { Task { await model.allowCallSound() } }, skip: nil,
            openSettings: { model.openCallSoundSettings() })
        } else {
          MeetingSetupOlderMacNote()
        }
        MeetingSetupPermissionRow(
          icon: "calendar",
          title: LocalizedStringResource(
            "Calendar", comment: "EnviousMeet setup: a permission name."),
          line: LocalizedStringResource(
            "To name each meeting after its event and note who was invited. macOS asks for full access; EnviousMeet looks for a matching event when a meeting starts and never changes your calendar.",
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
      .buttonStyle(
        OnboardingButtonStyle(color: model.canContinue ? .obButtonFill : .obButtonFill.opacity(0.4))
      )
      .disabled(!model.canContinue)
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("meetings.setup.continue")

      if let blocked = blockedReason {
        Text(blocked)
          .font(.setupRowLine)
          .foregroundStyle(Color.obTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 10)
      }
    }
    .frame(maxWidth: 600, alignment: .leading)
  }

  /// Why Continue is off (#4346 plan §8), or nil when it is on.
  private var blockedReason: LocalizedStringResource? {
    if model.microphone == .unavailable {
      return LocalizedStringResource(
        "This Mac does not allow the microphone, so EnviousMeet cannot record here.",
        comment: "EnviousMeet setup: under Continue when a device profile blocks the microphone.")
    }
    switch (model.microphoneSatisfied, model.callSoundSatisfied) {
    case (true, true): return nil
    case (false, false):
      return LocalizedStringResource(
        "Allow the microphone and call sound to continue.",
        comment: "EnviousMeet setup: under Continue while both required permissions are missing.")
    case (false, true):
      return LocalizedStringResource(
        "Allow the microphone to continue.",
        comment: "EnviousMeet setup: under Continue while the microphone is missing.")
    case (true, false):
      return LocalizedStringResource(
        "Allow call sound to continue.",
        comment: "EnviousMeet setup: under Continue while the call sound is missing.")
    }
  }
}

/// Below macOS 14.2 the Mac cannot record the call sound, so setup shows this note in place of
/// the call-sound row (#4346 plan §3.3).
private struct MeetingSetupOlderMacNote: View {
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "info.circle")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color.obTextSecondary)
        .frame(width: 34, height: 34)
        .background(Color.obAccentSoft, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
      Text(
        "Noticing calls needs macOS 14.2 or later. You can still start recordings from the menu bar.",
        comment: "EnviousMeet setup: in place of the call-sound row below macOS 14.2.")
        .font(.setupRowLine)
        .foregroundStyle(Color.obTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
    }
    .padding(.vertical, 16)
    .overlay(alignment: .top) { Divider().opacity(0.6) }
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
      Text("You're all set.", comment: "EnviousMeet setup: the last screen's title.")
        .font(.setupTitle)
        .foregroundStyle(Color.obTextPrimary)
        .padding(.bottom, 8)
      Text(
        "Here is how EnviousMeet works. Use the arrow keys or the buttons to flip through.",
        comment: "EnviousMeet setup: the line above the how-it-works cards on the last screen."
      )
      .font(.setupLead)
      .foregroundStyle(Color.obTextSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 16)

      // #4346 plan §3.4: six how-it-works cards.
      MeetingSetupHowTo()
        .padding(.bottom, model.unresolved.isEmpty && !model.callSoundMayAskLater ? 24 : 14)

      // #4346 §16.2: shown independently of the Calendar line; both can show.
      if model.callSoundMayAskLater {
        Text(
          "macOS may ask about call sound the first time you record.",
          comment: "EnviousMeet setup: last screen, when macOS could not confirm the call-sound answer yet."
        )
        .font(.setupRowLine)
        .foregroundStyle(Color.obTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, model.unresolved.isEmpty ? 18 : 8)
      }

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
    .frame(maxWidth: 760, alignment: .leading)
  }
}
