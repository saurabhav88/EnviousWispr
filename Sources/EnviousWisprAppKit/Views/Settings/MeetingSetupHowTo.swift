import EnviousWisprCore
import SwiftUI

/// The carousel's state (#4346 plan §3.4): which card shows, whether auto-advance is paused,
/// and one auto-advance step. The view runs `autoAdvance` in a task keyed by card, pause and
/// Reduce Motion, so any change cancels the wait and starts a fresh 8-second interval.
@MainActor
@Observable
final class MeetingSetupHowToModel {
  static let cardCount = 6
  static let interval: Duration = .seconds(8)

  private(set) var index = 0
  private(set) var paused = false
  /// Test seam: the wait between cards. Production sleeps the real interval.
  @ObservationIgnored let sleep: @Sendable (Duration) async throws -> Void

  init(
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.sleep = sleep
  }

  /// Both ends wrap, like the approved preview.
  func next() { index = (index + 1) % Self.cardCount }
  func previous() { index = (index + Self.cardCount - 1) % Self.cardCount }
  func togglePause() { paused.toggle() }
  /// Reduce Motion starts paused.
  func pause() { paused = true }

  /// Waits one interval, then shows the next card, unless paused, Reduce Motion is on, or the
  /// wait was cancelled (the card, pause or Reduce Motion changed, or the view went away).
  func autoAdvance(reduceMotion: Bool) async {
    guard !paused, !reduceMotion else { return }
    do { try await sleep(Self.interval) } catch { return }
    guard !Task.isCancelled, !paused else { return }
    next()
  }
}

/// "How EnviousMeet works": six cards on the last setup screen (#4346 plan §3.4, founder
/// design 2026-11-02). One card shows; Back, dots, Pause or Play, Next; arrow keys flip cards.
struct MeetingSetupHowTo: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var model = MeetingSetupHowToModel()
  @FocusState private var focused: Bool

  private struct TaskKey: Equatable {
    let index: Int
    let paused: Bool
    let reduceMotion: Bool
  }

  /// The carousel's width, measured; every card is laid out for it.
  @State private var width: CGFloat = 0

  var body: some View {
    VStack(spacing: 0) {
      // The row is as tall as its tallest card, so a narrow window grows it instead of clipping.
      // Every card is always drawn, so the row has a size before its width is known; a row
      // that waited for the width stayed 0 points tall and never measured it (#4346 UAT).
      // Each card sits one row-width to the side of the shown one, outside the clip.
      ZStack(alignment: .topLeading) {
        ForEach(0..<MeetingSetupHowToModel.cardCount, id: \.self) { index in
          MeetingSetupHowToCard(index: index, isVisible: index == model.index, width: width)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .offset(x: CGFloat(index - model.index) * width)
            // Until the width is known every card would sit in the same place.
            .opacity(width > 0 || index == model.index ? 1 : 0)
            .accessibilityHidden(index != model.index)
        }
      }
      .animation(
        reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.9), value: model.index)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .clipped()
      .background(
        GeometryReader { geo in
          Color.clear
            .onAppear { width = geo.size.width }
            .onChange(of: geo.size.width) { _, value in width = value }
        })

      // One row with the dots on the card's centre line while Back and Pause plus Next both fit
      // beside them; otherwise (German at the narrowest window) the dots get a row of their own
      // above the buttons, so they are never pushed off centre or covered.
      ViewThatFits(in: .horizontal) {
        MeetingHowToFooterLayout(spacing: 10) {
          backButton
          dots
          HStack(spacing: 10) {
            pauseButton
            nextButton
          }
        }
        VStack(spacing: 10) {
          dots
          HStack(spacing: 10) {
            backButton
            Spacer(minLength: 0)
            pauseButton
            nextButton
          }
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, MeetingSetupHowToCard.padding)
      .padding(.bottom, 12)
      .padding(.top, 4)
    }
    .background(Color.obTextTertiary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    .overlay(
      RoundedRectangle(cornerRadius: 14).strokeBorder(
        Color.obTextTertiary.opacity(0.18), lineWidth: 1)
    )
    // Arrow keys flip cards while the carousel has focus; buttons keep their own focus.
    .focusable()
    .focused($focused)
    .focusEffectDisabled()
    .onKeyPress(.leftArrow) {
      model.previous()
      return .handled
    }
    .onKeyPress(.rightArrow) {
      model.next()
      return .handled
    }
    .onAppear { if reduceMotion { model.pause() } }
    .onChange(of: reduceMotion) { _, on in if on { model.pause() } }
    .task(id: TaskKey(index: model.index, paused: model.paused, reduceMotion: reduceMotion)) {
      await model.autoAdvance(reduceMotion: reduceMotion)
    }
  }

  private var backButton: some View {
    SettingsActionButton(
      title: LocalizedStringResource(
        "Back", comment: "EnviousMeet setup: shows the previous how-it-works card."),
      isEnabled: true, emphasis: .quiet, size: .medium
    ) {
      model.previous()
    }
    .fixedSize()
  }

  private var pauseButton: some View {
    SettingsActionButton(
      title: model.paused
        ? LocalizedStringResource(
          "Play",
          comment: "EnviousMeet setup: turns the how-it-works cards' auto-advance back on.")
        : LocalizedStringResource(
          "Pause",
          comment: "EnviousMeet setup: stops the how-it-works cards from moving on by themselves."),
      isEnabled: true, emphasis: .quiet, size: .medium
    ) {
      model.togglePause()
    }
    .fixedSize()
  }

  private var nextButton: some View {
    SettingsActionButton(
      title: LocalizedStringResource(
        "Next", comment: "EnviousMeet setup: shows the next how-it-works card."),
      isEnabled: true, emphasis: .quiet, size: .medium
    ) {
      model.next()
    }
    .fixedSize()
  }

  private var dots: some View {
    HStack(spacing: 6) {
      ForEach(0..<MeetingSetupHowToModel.cardCount, id: \.self) { index in
        Circle()
          .fill(index == model.index ? Color.obAccent : Color.obTextTertiary.opacity(0.35))
          .frame(width: 7, height: 7)
      }
    }
    .fixedSize()
    .accessibilityHidden(true)
  }
}

/// The carousel's footer row: the first view at the leading edge, the second on the centre
/// line, the third at the trailing edge. Its ideal width leaves each side room for the wider
/// of the two outer views, so `ViewThatFits` drops to the stacked footer before the centre
/// view would have to move or overlap.
struct MeetingHowToFooterLayout: Layout {
  var spacing: CGFloat

  private func needed(_ subviews: Subviews) -> (width: CGFloat, height: CGFloat) {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    guard sizes.count == 3 else {
      return (sizes.map(\.width).reduce(0, +), sizes.map(\.height).max() ?? 0)
    }
    let side = max(sizes[0].width, sizes[2].width)
    return (2 * side + sizes[1].width + 2 * spacing, sizes.map(\.height).max() ?? 0)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let need = needed(subviews)
    return CGSize(width: max(need.width, proposal.width ?? 0), height: need.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let anchors: [(CGFloat, UnitPoint)] = [
      (bounds.minX, .leading), (bounds.midX, .center), (bounds.maxX, .trailing),
    ]
    for (subview, (x, anchor)) in zip(subviews, anchors) {
      subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: anchor, proposal: .unspecified)
    }
  }
}

/// One card: number, title and line beside an inert illustration, or above it when the
/// carousel is narrow (the 750-point minimum window leaves about 424 points, #4346 r4).
struct MeetingSetupHowToCard: View {
  let index: Int
  let isVisible: Bool
  /// The carousel's width; the card decides side by side or stacked from it.
  let width: CGFloat

  static let padding: CGFloat = 20
  static let gap: CGFloat = 20
  /// The real call card is 340 points plus 20 of padding each side (CallPromptView), unscaled.
  static let wideIllustration: CGFloat = 380
  /// Narrower than this and the text column would drop below 220 points: stack instead.
  static func isStacked(width: CGFloat) -> Bool {
    width < 2 * padding + gap + wideIllustration + 220
  }
  /// The illustration's width: fixed beside the text, the card's inner width when stacked.
  static func illustrationWidth(width: CGFloat) -> CGFloat {
    isStacked(width: width) ? max(0, min(width - 2 * padding, 400)) : wideIllustration
  }

  var body: some View {
    let card = MeetingSetupHowToCopy.cards[index]
    let stacked = Self.isStacked(width: width)
    let layout =
      stacked
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: Self.gap))
      : AnyLayout(HStackLayout(alignment: .top, spacing: Self.gap))
    layout {
      VStack(alignment: .leading, spacing: 8) {
        Text(
          "\(index + 1) of \(MeetingSetupHowToModel.cardCount)",
          comment: "EnviousMeet setup: which how-it-works card shows, e.g. 2 of 6."
        )
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color.obTextTertiary)
        Text(card.title)
          .font(.system(size: 18, weight: .bold))
          .foregroundStyle(Color.obTextPrimary)
          .fixedSize(horizontal: false, vertical: true)
        Text(card.line)
          .font(.system(size: 14))
          .foregroundStyle(Color.obTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      illustration
        .frame(width: Self.illustrationWidth(width: width))
        .frame(minHeight: 200)
        .background(Color.obTextTertiary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        // Pictures of the real controls, not controls: no clicks, no keyboard focus, one label.
        // Not `.disabled`: that greys the example buttons, so they would not look like the real
        // card (the example card's actions are empty anyway).
        .allowsHitTesting(false)
        .focusable(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(card.illustration))
    }
    .padding(Self.padding)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      Text(
        "Card \(index + 1) of \(MeetingSetupHowToModel.cardCount): \(String(localized: card.title))",
        comment: "EnviousMeet setup, VoiceOver: the how-it-works card's position and title."))
  }

  private var illustration: some View { Self.illustration(index: index, isVisible: isVisible) }

  /// The card's picture alone, so the layout test can measure its natural width.
  @ViewBuilder static func illustration(index: Int, isVisible: Bool) -> some View {
    switch index {
    case 0: MeetingHowToApps()
    case 1: MeetingHowToCallCard()
    case 2: MeetingHowToMenu()
    case 3: MeetingHowToQuiet(isVisible: isVisible)
    case 4: MeetingHowToHistory()
    default: MeetingHowToSummaries()
    }
  }
}

/// The cards' words (founder-approved, #4346; checked against the app by Codex).
enum MeetingSetupHowToCopy {
  struct Card {
    let title: LocalizedStringResource
    let line: LocalizedStringResource
    let illustration: LocalizedStringResource
  }

  static let cards: [Card] = [
    Card(
      title: LocalizedStringResource(
        "EnviousMeet notices your calls", comment: "EnviousMeet setup: how-it-works card 1 title."),
      line: LocalizedStringResource(
        "It works with the apps you already use. When one of them starts a call, EnviousMeet can notice it and offer to record. Noticing calls needs macOS 14.2 or later.",
        comment: "EnviousMeet setup: how-it-works card 1 line."),
      illustration: LocalizedStringResource(
        "The call apps EnviousMeet works with: Zoom, Microsoft Teams, Google Meet, FaceTime, Slack huddles, Webex and Jitsi, also in a web browser.",
        comment:
          "EnviousMeet setup, VoiceOver: what card 1's picture shows. App names are not translated."
      )),
    Card(
      title: LocalizedStringResource(
        "When a call starts, you'll see this card",
        comment: "EnviousMeet setup: how-it-works card 2 title."),
      line: LocalizedStringResource(
        "Click Start recording to take notes, or Not now to skip this call.",
        comment:
          "EnviousMeet setup: how-it-works card 2 line. Start recording and Not now are the card's buttons."
      ),
      illustration: LocalizedStringResource(
        "Example: the card under the menu bar asks, Take notes on this Zoom call?",
        comment: "EnviousMeet setup, VoiceOver: what card 2's picture shows.")),
    Card(
      title: LocalizedStringResource(
        "Or start it yourself", comment: "EnviousMeet setup: how-it-works card 3 title."),
      line: LocalizedStringResource(
        "Click the lips in the menu bar, then Start Meeting Recording. Use it for calls in any app, or a meeting in the room.",
        comment: "EnviousMeet setup: how-it-works card 3 line."),
      illustration: LocalizedStringResource(
        "Example: the menu bar menu with Start Meeting Recording selected.",
        comment: "EnviousMeet setup, VoiceOver: what card 3's picture shows.")),
    Card(
      title: LocalizedStringResource(
        "It works quietly", comment: "EnviousMeet setup: how-it-works card 4 title."),
      line: LocalizedStringResource(
        "No bot joins your call. A short card confirms the recording started, then only the lips in the menu bar show it is running.",
        comment: "EnviousMeet setup: how-it-works card 4 line."),
      illustration: LocalizedStringResource(
        "Example: grey lips in the menu bar with a rainbow wave moving left to right while a meeting records.",
        comment: "EnviousMeet setup, VoiceOver: what card 4's picture shows.")),
    Card(
      title: LocalizedStringResource(
        "Watch the live transcript in History",
        comment: "EnviousMeet setup: how-it-works card 5 title."),
      line: LocalizedStringResource(
        "First turn on Live Preview in EnviousMeet settings under Models. Then open History and click M: the meeting you are recording shows its words as people talk.",
        comment: "EnviousMeet setup: how-it-works card 5 line. M is History's Meetings tab letter."),
      illustration: LocalizedStringResource(
        "Example: History's Meetings tab with a recording in progress and its words appearing.",
        comment: "EnviousMeet setup, VoiceOver: what card 5's picture shows.")),
    Card(
      title: LocalizedStringResource(
        "Summarize with the AI you choose", comment: "EnviousMeet setup: how-it-works card 6 title."
      ),
      line: LocalizedStringResource(
        "Pick a model on your Mac, or bring your own key. Change it anytime in EnviousMeet settings.",
        comment: "EnviousMeet setup: how-it-works card 6 line."),
      illustration: LocalizedStringResource(
        "The AI engines that can write meeting summaries, grouped as in EnviousMeet settings.",
        comment: "EnviousMeet setup, VoiceOver: what card 6's picture shows.")),
  ]
}

// MARK: - Illustrations

/// A strip that looks like the Mac menu bar, with the EnviousWispr icon.
private struct MeetingHowToMenuBar<Icon: View>: View {
  var highlighted = false
  /// The icon's slot and the strip's height; card 4 draws them larger so its lips read.
  var iconSize = CGSize(width: 30, height: 20)
  var barHeight: CGFloat = 28
  @ViewBuilder let icon: () -> Icon

  var body: some View {
    HStack(spacing: 14) {
      Spacer()
      icon()
        .frame(width: iconSize.width, height: iconSize.height)
        .background(
          highlighted ? Color.white.opacity(0.22) : Color.clear,
          in: RoundedRectangle(cornerRadius: 6))
      Image(systemName: "wifi").font(.system(size: 14, weight: .semibold))
      Image(systemName: "battery.75percent").font(.system(size: 14))
    }
    .foregroundStyle(Color.white)
    .padding(.horizontal, 12)
    .frame(height: barHeight)
    .background(
      LinearGradient(
        colors: [
          Color(red: 0.12, green: 0.16, blue: 0.54), Color(red: 0.17, green: 0.12, blue: 0.48),
        ],
        startPoint: .leading, endPoint: .trailing),
      in: RoundedRectangle(cornerRadius: 8))
  }
}

/// The menu bar's idle EnviousWispr lips, drawn monochrome like the real template icon.
private struct MeetingHowToIdleLips: View {
  var body: some View {
    WisprLogoMark().saturation(0).brightness(0.3).frame(width: 20, height: 18)
  }
}

private struct MeetingHowToApps: View {
  private static let families: [CallAppFamily] = [
    .zoom, .teams, .googleMeet, .facetime, .slack, .webex, .jitsi,
  ]

  var body: some View {
    VStack(spacing: 10) {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4), spacing: 10)
      {
        ForEach(Self.families, id: \.self) { family in
          VStack(spacing: 5) {
            CallServiceMark(family: family, size: 36)
            Text(Self.label(family))
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(Color.obTextSecondary)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        // The eighth tile: the same calls in a web browser, so the 4-wide grid has no gap.
        // Chrome's own icon when it is installed (founder 2026-11-03); a globe otherwise.
        VStack(spacing: 5) {
          browserMark
          Text(
            "Browser",
            comment:
              "EnviousMeet setup: the last tile beside the call app logos; EnviousMeet also notices calls in a web browser."
          )
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.obTextSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      Text(
        "Also Whereby, Dialpad, Gather, Lark and VooV.",
        comment: "EnviousMeet setup: under the call app logos and the browser tile. App names are not translated."
      )
      .font(.system(size: 14))
      .foregroundStyle(Color.obTextTertiary)
      .multilineTextAlignment(.center)
    }
    .padding(14)
  }

  @ViewBuilder private var browserMark: some View {
    if let chrome = CallAppIcon.icon(bundleID: "com.google.Chrome") {
      Image(nsImage: chrome).resizable().aspectRatio(contentMode: .fit)
        .frame(width: 36, height: 36)
    } else {
      Image(systemName: "globe")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(Color.stAccentSolid)
        .frame(width: 36, height: 36)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
  }

  private static func label(_ family: CallAppFamily) -> String {
    family == .slack
      ? String(
        localized: "Slack huddles",
        comment: "EnviousMeet setup: under the Slack logo; EnviousMeet notices Slack huddles.")
      : family.displayName
  }
}

private struct MeetingHowToCallCard: View {
  /// A card model of its own: never the real panel's, never shown as a window.
  @State private var prompt: CallPromptModel = {
    let model = CallPromptModel()
    model.content = .ask(.app(.zoom, bundleID: nil))
    return model
  }()

  var body: some View {
    VStack(spacing: 0) {
      MeetingHowToMenuBar { MeetingHowToIdleLips() }
        .padding(.horizontal, 12)
        .padding(.top, 12)
      CallPromptView(model: prompt, reduceMotionOverride: true)
      Spacer(minLength: 0)
    }
  }
}

private struct MeetingHowToMenu: View {
  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      MeetingHowToMenuBar(highlighted: true) { MeetingHowToIdleLips() }
      VStack(alignment: .leading, spacing: 2) {
        row(
          String(
            localized: "Open \(AppConstants.appName)",
            comment:
              "Menu bar menu: opens the app's main window on History. %@ is the app name, EnviousWispr."
          ))
        Divider().padding(.vertical, 3)
        row(String(localized: "Start Recording", comment: "Menu bar menu: starts a dictation."))
        row(
          String(
            localized: "Transcribe a File...", comment: "Menu bar menu: opens Transcribe a File."))
        row(MeetingsPresentation.control(.idle).title, selected: true)
        Divider().padding(.vertical, 3)
        row(MenuBarController.addToDictionaryTitle)
      }
      .padding(6)
      .frame(width: 250, alignment: .leading)
      .background(Color(red: 0.16, green: 0.14, blue: 0.22), in: RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
    .padding(12)
  }

  private func row(_ title: String, selected: Bool = false) -> some View {
    Text(title)
      .font(.system(size: 14))
      .foregroundStyle(selected ? Color.white : Color.white.opacity(0.9))
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(selected ? Color.obAccent : Color.clear, in: RoundedRectangle(cornerRadius: 6))
  }
}

/// The real meeting wave from `MenuBarIconAnimator` (#4116): one sweep every 2 seconds, drawn
/// only while this card shows and never under Reduce Motion.
private struct MeetingHowToQuiet: View {
  let isVisible: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var start = Date()

  var body: some View {
    VStack(spacing: 14) {
      MeetingHowToMenuBar(iconSize: CGSize(width: 84, height: 44), barHeight: 56) {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion || !isVisible)) {
          context in
          let phase = (context.date.timeIntervalSince(start) / 2).truncatingRemainder(dividingBy: 1)
          Image(
            nsImage: MenuBarIconAnimator.meetingWaveFrame(phase: phase, reduceMotion: reduceMotion)
          )
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
        }
      }
      Text(
        "Grey lips with a rainbow wave mean a meeting is recording.",
        comment: "EnviousMeet setup: under the menu bar picture on card 4."
      )
      .font(.system(size: 14))
      .foregroundStyle(Color.obTextSecondary)
      .multilineTextAlignment(.center)
    }
    .padding(14)
  }
}

private struct MeetingHowToHistory: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        ForEach(HistoryFilter.allCases, id: \.self) { filter in
          Text(filter.shortTitle)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(filter == .recordings ? Color.white : Color.obTextSecondary)
            .frame(width: 26, height: 22)
            .background(
              filter == .recordings ? Color.obAccent : Color.obTextTertiary.opacity(0.15),
              in: RoundedRectangle(cornerRadius: 6))
        }
      }
      HStack(spacing: 8) {
        Circle().fill(Color(red: 1, green: 0.353, blue: 0.416)).frame(width: 8, height: 8)
        Text(CallAppFamily.zoom.displayName).font(.system(size: 14, weight: .semibold))
        Spacer()
        Text(MeetingsPresentation.clock(ms: 192_000))
          .font(.system(size: 14).monospacedDigit())
          .foregroundStyle(Color.obTextSecondary)
        Text("Stop Recording", comment: "EnviousMeet: the button that stops the meeting recording.")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.white)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
      }
      .padding(8)
      .background(Color.obTextTertiary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      line(
        .microphone, 182_000,
        LocalizedStringResource(
          "Can we move the launch to the 17th?",
          comment: "EnviousMeet setup: example live words on card 5."))
      line(
        .callSound, 185_000,
        LocalizedStringResource(
          "Yes, I'll tell support today.",
          comment: "EnviousMeet setup: example live words on card 5."))
      line(
        .callSound, 189_000,
        LocalizedStringResource(
          "And I'll update the",
          comment:
            "EnviousMeet setup: example live words on card 5, cut off mid-sentence while someone is still talking."
        ),
        unsure: true)
    }
    .padding(14)
  }

  private func line(
    _ track: MeetingTrackKind, _ ms: Int, _ words: LocalizedStringResource, unsure: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(
        verbatim:
          "\(MeetingsPresentation.liveSpeaker(track)) · \(MeetingsPresentation.clock(ms: ms))"
      )
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(Color.obTextSecondary)
      Text(words)
        .font(.system(size: 14))
        .italic(unsure)
        .foregroundStyle(unsure ? Color.obTextSecondary : Color.obTextPrimary)
    }
  }
}

private struct MeetingHowToSummaries: View {
  private var groups: [(heading: String, names: [String])] {
    PolishRailGroup.allCases.compactMap { group in
      // The short brand name on this small card (founder 2026-11-03): Gemini, not Google Gemini.
      let names = MeetingSummaryEngineChoices.providers.filter { $0.group == group }.map {
        $0.provider == .gemini ? "Gemini" : $0.name
      }
      return names.isEmpty ? nil : (group.heading, names)
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      ForEach(groups, id: \.heading) { group in
        VStack(alignment: .leading, spacing: 6) {
          // Every heading keeps two lines' room, so the names below start on one line.
          Text(group.heading)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.obTextSecondary)
            .lineLimit(2, reservesSpace: true)
          ForEach(group.names, id: \.self) { name in
            Text(verbatim: name)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(Color.obTextPrimary)
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.obTextTertiary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
      }
    }
    // The columns share the tallest one's height, and no more: not the picture box's.
    .fixedSize(horizontal: false, vertical: true)
    .padding(12)
  }
}
