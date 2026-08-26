import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

// MARK: - What a design tells the recording leaf to draw

/// Which ink a piece of the recording pill is painted in (#2376 Phase 4, C2).
///
/// **An enum, not a `Color`, and the reason is that ONE INK HAS TWO ROLES.** An
/// earlier version of this comment said a `Color` would leave the treatment
/// unassertable; that is false and worth stating plainly, because SwiftUI's
/// `Color` is both `Equatable` and `Sendable` and a stored one would compare
/// fine. The real reason is structural: a design's ink has to answer for the
/// #1060 notice AND for the reading well's text in two dimming states, so a
/// `Color` field could not carry it without two or three fields that are free to
/// disagree about which palette this pill is in. A case names the palette once.
///
/// Resolved to a `Color` here, once per case, so the capsule's frozen notice
/// literal keeps its single occurrence across the two files
/// `CapsuleBackgroundFreezeTests.capsuleSourcePaths` names.
enum PillInk: Equatable, Sendable {
  /// The capsule's own white, as every without-words pill has always drawn it.
  case capsuleWhite
  /// The light reading-well palette (#2204).
  case previewPalette

  /// The #1060 in-panel notice's colour.
  var notice: Color {
    switch self {
    case .capsuleWhite: return Color.white.opacity(0.95)
    case .previewPalette: return PreviewPillPalette.notice
    }
  }

  /// The reading well's text colour, which has a dimmed variant for the
  /// "listening" and "unavailable" states.
  func well(dimmed: Bool) -> Color {
    switch self {
    case .capsuleWhite: return .white.opacity(dimmed ? 0.5 : 0.92)
    case .previewPalette: return dimmed ? PreviewPillPalette.textDimmed : PreviewPillPalette.text
    }
  }
}

/// Whether the container animates when the audio level ticks.
///
/// **A case rather than an `Animation?`, and NOT because `Animation` cannot be
/// compared — it is `Equatable` and `Sendable`.** The reason is that a stored
/// `nil` says nothing: it records that this design animates nothing and loses
/// WHY, which here is a measured constraint rather than a taste. A case carries
/// the policy and its reason to every design that selects it.
enum PillLevelAnimation: Equatable, Sendable {
  /// No container animation on the level. The reading well selects this: the
  /// level is repolled every 50 ms, so a container animation fires ~20 times a
  /// second and animates whatever else changed in the same update — including
  /// the preview text, and therefore the pill's HEIGHT (#2201).
  case none
  /// The capsule's shipped 80 ms ease-out.
  case capsuleEaseOut

  var resolved: Animation? {
    switch self {
    case .none: return nil
    case .capsuleEaseOut: return .easeOut(duration: 0.08)
    }
  }
}

/// Everything about the recording pill's appearance that varies by DESIGN.
///
/// **This replaces eighteen reads of a `usesPreviewLayout` boolean**, which
/// expressed exactly two designs and would have needed a branch per design for a
/// third — and every one of those branches is a place where one design can be
/// wrong in isolation while the others look fine. The leaf is now HANDED what to
/// draw and reads no capability of its own.
///
/// **`canHoldWords` is NOT here and must never be.** It is a capability fact the
/// director reads to decide whether to install a live-preview provider at all
/// (`OverlayRenderModel.setRecordingProviders`); it is not a look. Whether the
/// well has any words in it is decided upstream, and this value only says what
/// the well looks like when it does.
///
/// Every field is a per-design literal except `isContentSizedVertically`, whose
/// derivation is documented at its own declaration.
struct RecordingPillChrome: Equatable, Sendable {

  /// What sits above the preview area.
  enum Header: Equatable, Sendable {
    /// The rainbow-lips mark beside the clock, the clock hidden when locked.
    case mark
    /// The ruled strip: clock, live meter, mode badge (#2202).
    case meterStrip
    /// The clock beside a full-width level rail, with the clock visible in BOTH
    /// lock states (#2376 C5). That is the founder call already recorded for the
    /// reading well's header: hands-free is the mode that runs for minutes, so it
    /// is the one that needs a clock.
    case clockAndRail
  }

  let header: Header
  /// #2202 row 1 of the shared-root table: the capsule wants 6pt between its
  /// stacked pieces; the preview puts a ruled header directly against its
  /// reading well and supplies its own spacing inside each section.
  let stackSpacing: CGFloat
  /// #2202 row 8. The capsule keeps its uniform inset; the preview zeroes it and
  /// each section supplies its own, because a header strip over a reading well
  /// does not want one rectangle of padding wrapped around both.
  let rootInsets: EdgeInsets
  let cornerStyle: OverlayCapsuleBackground.CornerStyle
  let levelAnimation: PillLevelAnimation
  /// #2202: the preview layout's header already says `Listening`, so repeating
  /// the sentence in the well would greet a first-time user with the same word
  /// twice in one small box. The capsule has no header, so it keeps it.
  let showsListeningSentence: Bool
  /// #2204: the notice is rendered by every layout from one `Text`, and white is
  /// invisible on a light pill.
  let noticeInk: PillInk
  /// `nil` means the notice may use the pill's full width. 170pt suits the 185pt
  /// capsule; the reading well is 400pt wide, so the same cap would wrap a
  /// one-line warning into three inside a box with room to spare.
  let noticeMaxWidth: CGFloat?
  /// #2202 row 4. The notice's ONLY inset came from the shared root padding,
  /// which the preview zeroes — without a replacement it sits flush against the
  /// pill's bottom edge.
  let noticeInsets: EdgeInsets
  /// #2202: the well's own inset, replacing what the shared root padding used to
  /// give it.
  let wellInsets: EdgeInsets
  let wellInk: PillInk
  /// #2203: fade the well's top edge when something is scrolling off it.
  let fadesWhenWellIsFull: Bool
  /// #2201: whether the root stack reports its IDEAL height whatever it is
  /// offered, so the pill's height is a function of what it is SHOWING rather
  /// than of how tall it happens to be already.
  ///
  /// **DERIVED from the design's own `reservedHeight`, never typed twice.** A
  /// design that reserves a fixed box is not content-sized by definition, and the
  /// two answers disagreeing is how a pill comes to be measured inside the panel
  /// that is being sized from that measurement — the loop #2201 settled.
  let isContentSizedVertically: Bool
}

extension RecordingPillDesign {

  /// What this design tells the leaf to draw.
  ///
  /// **Every value was read off the base revision's own branches, not designed
  /// here.** `.classic` is the `false` side of all eighteen `usesPreviewLayout`
  /// reads and `.readingWell` the `true` side, so this table is the shipped
  /// behaviour written down — which is what makes the C1 frozen rows a real
  /// receipt rather than an agreement between two things I wrote today.
  var chrome: RecordingPillChrome {
    switch self {
    case .classic:
      return RecordingPillChrome(
        header: .mark,
        stackSpacing: 6,
        rootInsets: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14),
        cornerStyle: .capsule,
        levelAnimation: .capsuleEaseOut,
        showsListeningSentence: true,
        noticeInk: .capsuleWhite,
        noticeMaxWidth: 170,
        noticeInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
        wellInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
        wellInk: .capsuleWhite,
        fadesWhenWellIsFull: false,
        isContentSizedVertically: reservedHeight == nil)

    case .levelRail:
      // Every value here is `.classic`'s, except the header and the notice cap.
      // That is deliberate rather than lazy: this is a without-words capsule, so
      // it inherits the group's insets, corner, ink, animation and notice budget,
      // and differs only in what it DRAWS. A design that also moved its paddings
      // would be changing two things at once with one of them unmotivated.
      return RecordingPillChrome(
        header: .clockAndRail,
        stackSpacing: 6,
        rootInsets: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14),
        cornerStyle: .capsule,
        levelAnimation: .none,
        showsListeningSentence: false,
        noticeInk: .capsuleWhite,
        // 288 less the 14pt root inset either side. Stated as the arithmetic it
        // is, because a bare 260 beside a 288-wide design reads as a second
        // measurement nobody took.
        //
        // **This is the site the round-5 width change nearly missed.** Nothing
        // fails if it keeps the old 232 — notices would just wrap 28pt early,
        // for ever, with no test red anywhere. It was found by grepping the
        // VALUE rather than the symbol, which is the only thing that reaches a
        // number carrying someone else's arithmetic.
        noticeMaxWidth: 260,
        noticeInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
        wellInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
        wellInk: .capsuleWhite,
        fadesWhenWellIsFull: false,
        isContentSizedVertically: reservedHeight == nil)

    case .readingWell:
      return RecordingPillChrome(
        header: .meterStrip,
        stackSpacing: 0,
        rootInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
        cornerStyle: .rounded,
        levelAnimation: .none,
        showsListeningSentence: false,
        noticeInk: .previewPalette,
        noticeMaxWidth: nil,
        noticeInsets: EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16),
        wellInsets: EdgeInsets(top: 12, leading: 16, bottom: 15, trailing: 16),
        wellInk: .previewPalette,
        fadesWhenWellIsFull: true,
        isContentSizedVertically: reservedHeight == nil)
    }
  }
}

// MARK: - RecordingOverlayView

/// How the recording poll waits between reads (#2377 Phase 5, C5).
///
/// **A seam because the alternative is a timed wait, and the question is about
/// what the poll does over TIME.** `testing-philosophy.md`
/// RULE: never-guess-when-the-subject-is-finished forbids inferring that a
/// subject is finished from elapsed time; with this, a test learns the loop has
/// parked from a signal the loop sends, and releases it itself.
///
/// **Available in Release, not `#if DEBUG`.** Phase 5's proofs must execute in
/// both configurations, and a DEBUG-only seam forecloses that.
struct RecordingPollCadence: Sendable {

  /// Returns when it is time to read the providers again.
  let wait: @Sendable () async -> Void

  /// 50 ms, which is what shipped and what `RainbowLevelMeter`'s history depth
  /// is scaled to.
  ///
  /// **`try?` here does NOT swallow cancellation into another read.** A cancelled
  /// sleep returns immediately and the loop's own `while !Task.isCancelled` is
  /// what ends it, so a cancelled poll performs no further provider read.
  static let live = RecordingPollCadence {
    try? await Task.sleep(for: .milliseconds(50))
  }
}

/// Compact recording indicator overlay.
struct RecordingOverlayView: View {
  let audioLevelProvider: () -> Float
  /// #1393: monotonic elapsed recording time, read from the shared kernel
  /// source of truth instead of a per-view-instance stamp — a panel-recreate
  /// (e.g. transitionToRecording) must not reset the displayed timer.
  let recordingElapsedProvider: () -> TimeInterval?
  /// #1988: what the live preview should show. Polled on the same 50 ms loop as
  /// audio level and elapsed time rather than on a publisher, because that loop
  /// already exists and coalesces naturally: Apple emits updates every ~210-290 ms,
  /// so a push-based feed would redraw more often than the eye can read without
  /// showing anything more.
  let livePreviewProvider: () -> LivePreviewDisplay
  /// #1988: reports the capsule's measured height so the panel can follow it as the
  /// preview grows.
  ///
  /// **No default, deliberately** (#2376 C2). A property default plus an init
  /// default leaves NO TOKEN at the call site, so a caller that meant to pass one
  /// and did not compiles and ships a pill whose window never follows its
  /// content. `OverlayRenderModel` already substitutes a no-op for a design that
  /// cannot grow, which is the one place that decision belongs.
  let onContentHeightChange: (CGFloat) -> Void
  /// What this pill DRAWS, handed in by the root from the resolved design.
  ///
  /// **This replaces `usesPreviewLayout`, and the replacement is a value rather
  /// than a wider boolean** (#2376 C2). The old flag was read eighteen times and
  /// branched on nearly all of them; a third design would have made every one of
  /// those a place where one design could be wrong while the others looked right. It was
  /// also passed in rather than derived from the display state — which remains
  /// `.off` until the polling task first runs and would flash the capsule shape
  /// before that first read — and that reasoning transfers unchanged: the chrome
  /// is decided upstream and this view never asks what the pill is capable of.
  let chrome: RecordingPillChrome

  /// Hands-free lock, and the #1060 in-panel notice's already-resolved copy.
  ///
  /// Plain immutable inputs, arriving in the same frame as the providers and the
  /// chrome, so this leaf cannot draw a new presentation beside a previous pill's
  /// lock or banner.
  ///
  /// `noticeText` is COPY, already resolved by the publisher. This view renders
  /// a string and asks nobody what it should say.
  let isLocked: Bool
  let noticeText: String?

  /// How long the poll waits between reads. Production never passes this.
  let cadence: RecordingPollCadence
  @State private var audioLevel: Float = 0

  /// Counts polls, not level changes. #2216: the meter's history needs a sample
  /// every tick INCLUDING the silent ones, and consecutive silent samples are
  /// bit-identical, so `audioLevel` alone cannot drive it.
  @State private var audioTick: Int = 0
  @State private var elapsed: TimeInterval = 0
  @State private var preview: LivePreviewDisplay

  /// Seeds `preview` so a size test can measure a KNOWN display state on the
  /// first layout pass instead of waiting for the 50 ms poll to publish one.
  ///
  /// **The seam exists because the alternative is a timed wait, and this view's
  /// whole defect is about what its height does over time.** `preview` is
  /// `@State`, so nothing outside can set it; without this a test would have to
  /// pump a run loop until the polling task happened to run, which is the
  /// guess-when-the-subject-is-finished shape testing-philosophy.md forbids.
  ///
  /// Production never passes it. The poll is the only writer it needs, and it
  /// overwrites this on the first tick regardless — so a wrong value here cannot
  /// survive into a real recording, which is what makes the seam cheap.
  init(
    audioLevelProvider: @escaping () -> Float,
    recordingElapsedProvider: @escaping () -> TimeInterval? = { nil },
    livePreviewProvider: @escaping () -> LivePreviewDisplay,
    onContentHeightChange: @escaping (CGFloat) -> Void,
    chrome: RecordingPillChrome,
    isLocked: Bool,
    noticeText: String?,
    initialPreview: LivePreviewDisplay = .off,
    cadence: RecordingPollCadence = .live
  ) {
    self.audioLevelProvider = audioLevelProvider
    self.recordingElapsedProvider = recordingElapsedProvider
    self.livePreviewProvider = livePreviewProvider
    self.onContentHeightChange = onContentHeightChange
    self.chrome = chrome
    self.isLocked = isLocked
    self.noticeText = noticeText
    self.cadence = cadence
    _preview = State(initialValue: initialPreview)
  }

  /// #2202: the preview pill's header — timer hard left, live meter beside it,
  /// recording mode on the right.
  ///
  /// **The badge buys CLARITY, not height stability — the first version of this
  /// comment claimed the wrong thing.** It said the capsule's 2x mark was "the
  /// single biggest height jump anywhere in the pill". It is not a height jump at
  /// all: `scaleEffect` is a rendering transform and does not participate in
  /// layout. Measured — an `HStack` holding a 24pt box reports `fittingSize`
  /// 95x44 at `scaleEffect(1.0)` and 95x44 at `scaleEffect(2.0)`. The capsule is
  /// already height-neutral across modes; the 2x mark overflows its own slot
  /// visually and nothing resizes.
  ///
  /// What the badge actually fixes: a size change is a signal you can only read
  /// by COMPARISON — you notice it only if you saw the other size a moment
  /// earlier — while a badge naming the mode works the first time you see it.
  /// This header is height-neutral across modes too, which is a property to KEEP
  /// rather than one this chunk introduces.
  ///
  /// **The timer renders in both modes.** The capsule hides it when locked, which
  /// is backwards: hands-free is the mode that runs for minutes, so it is the one
  /// that needs a clock. Founder decision, 2026-08-19.
  @ViewBuilder
  private var previewHeader: some View {
    HStack(spacing: 12) {
      Text(FormattingConstants.formatDuration(elapsed))
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .foregroundStyle(PreviewPillPalette.timer)

      RainbowLevelMeter(audioLevel: audioLevel, tick: audioTick)

      Spacer(minLength: 8)

      if isLocked {
        // A filled badge, because the mode it announces persists until the user
        // presses again. A size change is a weak signal — you only notice it if
        // you saw the other size a second earlier.
        HStack(spacing: 6) {
          Circle()
            .fill(PreviewPillPalette.badgeText)
            .frame(width: 5, height: 5)
          Text(LivePreviewCopy.handsFreeMode)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(PreviewPillPalette.badgeText)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(PreviewPillPalette.badgeFill))
        .transition(.opacity)
      } else {
        Text(LivePreviewCopy.listeningMode)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(PreviewPillPalette.modeQuiet)
          .transition(.opacity)
      }
    }
    .textCase(.uppercase)
    .padding(.horizontal, 16)
    .padding(.top, 9)
    .padding(.bottom, 8)
    .frame(height: Self.previewHeaderHeight)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(PreviewPillPalette.divider)
        .frame(height: 0.5)
    }
  }

  /// Fixed, so the header cannot change height between modes. Read by a test.
  static let previewHeaderHeight: CGFloat = 34

  var body: some View {
    // #2202 row 1 of the shared-root table: the capsule wants 6pt between its
    // stacked pieces; the preview puts a ruled header directly against its
    // reading well and supplies its own spacing inside each section.
    VStack(spacing: chrome.stackSpacing) {
      // EXHAUSTIVE over the chrome's header, with no `default:`. A default here
      // would let a header added later render as whichever neighbour the compiler
      // happened to fall through to, which is this phase's named regression
      // wearing a new case.
      switch chrome.header {
      case .meterStrip:
        previewHeader
      case .clockAndRail:
        HStack(spacing: 10) {
          // The clock in BOTH lock states, unlike the capsule which hides it when
          // locked. Same treatment as the capsule's own clock so the two designs
          // are not gratuitously different where they agree.
          Text(FormattingConstants.formatDuration(elapsed))
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
          // Taller and wider-barred than the reading well's, so the rail rather
          // than the clock is what the eye lands on. No lips mark: the rail IS
          // the audio-reactive element, and two of them would compete.
          RainbowLevelMeter(
            audioLevel: audioLevel, tick: audioTick, height: 24, barWidth: 3, spacing: 2)

          // **The hands-free badge, and without it this design was the one that
          // never said the microphone stays open** (#2376 Phase 4, cloud review
          // round 5, P1). Every other visual property here is independent of
          // `isLocked`, so the container's animation had nothing to
          // animate and the locked pill was pixel-identical to the unlocked one.
          // The cost is not cosmetic: hands-free keeps recording after the key is
          // released, so a user with no confirmation can leave a capture running.
          //
          // Treatment is the reading well's, verbatim, for the reason recorded
          // there: a filled badge because the mode PERSISTS, where a size change
          // is only legible to someone who saw the other size a second earlier.
          //
          // **INLINE rather than on a row of its own, and the reserved-box guard is
          // what decided that.** A second row put the pill at 104pt with a #1060
          // banner also showing, against the 92pt box this design reserves — and a
          // without-words pill is handed a no-op growth callback, so that overflow
          // is CLIPPED with nothing reporting it. The box is the inherited notice
          // budget rather than a number this phase gets to pick, so the badge
          // gives up the row instead.
          //
          // No leading dot, unlike the reading well's: this row is a ~45pt clock
          // plus 24 bars at 3pt-and-2pt, and the dot is 11pt of the margin that
          // keeps the rail from being squeezed. Measured locked: 279pt of content,
          // which is what moved this design's width to 288.
          if isLocked {
            Text(LivePreviewCopy.handsFreeMode)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(PreviewPillPalette.badgeText)
              .padding(.horizontal, 9)
              .padding(.vertical, 3)
              .background(Capsule().fill(PreviewPillPalette.badgeFill))
              .transition(.opacity)
          }
        }

      case .mark:
        HStack(spacing: 10) {
          // Rainbow lips icon — audio-reactive during recording.
          // Scales to 2x in hands-free (locked) mode.
          RainbowLipsIcon(size: 24, audioLevel: audioLevel)
            .scaleEffect(isLocked ? 2.0 : 1.0)

          if !isLocked {
            Text(FormattingConstants.formatDuration(elapsed))
              .font(.system(size: 13, weight: .medium, design: .monospaced))
              .foregroundStyle(.white)
              .transition(.opacity)
          }
        }
      }

      // #1988: the live preview. Display only — the pasted text comes from the
      // normal transcription path after the key is released.
      livePreviewBody

      // #1060: approaching-cap warning banner. Appears inside the same capsule
      // (no panel rebuild), wraps within the pill width, auto-clears.
      if let notice = noticeText {
        Text(notice)
          .font(.system(size: 11, weight: .medium))
          // #2204: the notice is rendered by BOTH layouts from this one `Text`,
          // and white is invisible on a light pill. Gated rather than made
          // dynamic, so the capsule's paint is unchanged to the byte.
          .foregroundStyle(chrome.noticeInk.notice)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          // 170pt suits the 185pt capsule. The preview pill is 400pt wide, so the
          // same cap would wrap a one-line warning into three inside a box with
          // room to spare.
          .frame(maxWidth: chrome.noticeMaxWidth ?? .infinity)
          // #2202 row 4 of the shared-root table. The notice is rendered by BOTH
          // layouts and its ONLY inset came from the shared root padding, which
          // the preview now zeroes — so without this it sits flush against the
          // pill's bottom edge. The header and the reading well each received
          // replacement padding; this is the third section and it was missed.
          .padding(chrome.noticeInsets)
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.3), value: isLocked)
    // Single container animation prevents animation stacking: N per-element
    // modifiers × update rate creates exponential state transitions (gotchas.md).
    //
    // #2201: the PREVIEW layout selects no animation here. `audioLevel` is
    // repolled every 50 ms, so this fires ~20 times a second, and a container
    // animation animates whatever else changed in the same update — including the
    // preview text, and therefore the capsule's HEIGHT. That turned each genuine
    // resize into a smoothly animated one and drove `setFrame` once per frame.
    //
    // The trigger VALUE is kept rather than deleted, so the capsule's animation is
    // visibly untouched. **There is no branch here any more** (#2376 C2): the
    // policy is a field on the design's chrome, so each design states its own
    // answer once instead of both answers sitting inline. Audio-reactive PAINT is
    // unaffected either way: `RainbowLipsIcon` reads `audioLevel` directly and
    // redraws without needing this.
    //
    // Not a violation of swift-patterns.md RULE: animate-the-container-not-children
    // — that forbids per-child `.animation(value:)`, and this adds none. The
    // container keeps its lock and notice triggers in both layouts.
    .animation(chrome.levelAnimation.resolved, value: audioLevel)
    .animation(.easeInOut(duration: 0.25), value: noticeText)
    // #2202 row 8 of the shared-root table. The capsule keeps its uniform inset;
    // the preview zeroes it and each section supplies its own, because a header
    // strip over a reading well does not want one rectangle of padding wrapped
    // around both. Migrated ATOMICALLY with the section padding above and below:
    // split across two commits, whatever shipped in between would have had no
    // insets at all.
    .padding(chrome.rootInsets)
    // #2201: the preview pill's height must be a function of what it is SHOWING,
    // never of how tall it happens to be already.
    //
    // Without this the capsule is free to stretch into whatever room the panel
    // offers, because `previewText`'s `.frame(maxHeight:)` grows to its cap under
    // a large proposal. The panel is then sized FROM that measurement
    // (`onContentHeightChange` -> resizeRecordingPanel) while the measurement is
    // taken INSIDE the panel, so the pair has no single solution: measured on the
    // real view, one line of text reported 65pt in a 65pt panel and 125pt in a
    // 125pt one. Nothing in the loop pulls the height back down either, so a box
    // that grew for a long sentence stayed at the cap when the recognizer revised
    // the sentence shorter.
    //
    // `fixedSize` makes the stack report its IDEAL height whatever it is offered,
    // which is the same question `showPanel(fitToContent:)` asks at creation — so
    // the two sizing paths finally agree. Growth is unaffected: the ideal height
    // still tracks the text (65 -> 80 -> 125 across one, three and six-plus lines).
    //
    // **Gated, because every modifier on this root is rendered by BOTH layouts.**
    // The 185pt capsule sits inside a fixed 92pt frame and is out of scope for
    // #2198; `vertical: false` leaves it exactly as it was.
    //
    // **Order is load-bearing:** after the root inset, before both backgrounds.
    // (It was "after both paddings" while the root applied a horizontal and a
    // vertical modifier separately; #2376 C2 collapsed those into one
    // `EdgeInsets`, and the ordering constraint is unchanged.) The
    // measurement is taken on the padded stack, so moving this either side of it
    // measures a different view than the one that was proven.
    .fixedSize(horizontal: false, vertical: chrome.isContentSizedVertically)
    .background(OverlayCapsuleBackground(cornerStyle: chrome.cornerStyle))
    // #1988: report the capsule's real height so the panel can follow it. Measured
    // on the capsule rather than computed from a line count, because only the text
    // engine knows how many lines a sentence wraps to at this width in this script.
    .background(
      GeometryReader { geo in
        Color.clear
          .onAppear { onContentHeightChange(geo.size.height) }
          .onChange(of: geo.size.height) { _, height in onContentHeightChange(height) }
      }
    )
    .task {
      while !Task.isCancelled {
        audioLevel = audioLevelProvider()
        audioTick &+= 1
        elapsed = recordingElapsedProvider() ?? 0
        preview = livePreviewProvider()
        await cadence.wait()
      }
    }
  }

  /// The preview area.
  ///
  /// **The tail is produced by `.truncationMode(.head)`, not by counting characters
  /// and not by clipping an oversized box.** A character budget is a guess about how
  /// many glyphs fit, and that guess is wrong by a factor of two for CJK and wrong
  /// again for any proportional font. Clipping was tried first and shipped two
  /// visible defects that a screenshot caught immediately: `fixedSize` makes a Text
  /// render at its ideal height regardless of the frame around it, so three lines of
  /// text spilled out of the capsule background entirely and the top line was sliced
  /// through the middle of its glyphs. Letting the text engine drop the head gives
  /// the same "newest words win" result, correct in every script, with a leading
  /// ellipsis that reads as continuation rather than as a rendering fault.
  @ViewBuilder
  private var livePreviewBody: some View {
    switch preview {
    case .off:
      EmptyView()
    case .waiting:
      // One line, so the pill starts compact and the growth the user sees is their
      // own words arriving rather than space that was always reserved.
      //
      // #2202: in the PREVIEW layout the header already says `Listening`, so
      // repeating it here would greet a first-time user with the same word twice
      // in one small box — worse than either alone. The well shows nothing and
      // the pill stays one header tall until real words arrive. The capsule has
      // no header, so it keeps the sentence.
      //
      // #2222: `EmptyView()`, NOT `previewText("")`. An empty string still built a
      // `PreviewWellText`, which applies the well's own 12/15pt inset and an empty
      // `Text`'s line box unconditionally — so the state documented above as "one
      // header tall" measured 75pt against the header's 34pt, three points short of
      // a pill with words in it. Every dictation passes through here before the
      // first word, so every user saw the pill resize before saying anything.
      //
      // The inset lives on `PreviewWellText` and is correct for every state that
      // HAS a well; the defect was asking for a well to hold nothing. Fixed at the
      // call site rather than by making the shared padding conditional, which would
      // put an emptiness test inside a view that should not care.
      if chrome.showsListeningSentence {
        previewText(LivePreviewCopy.listening, dimmed: true, lines: 1)
      } else {
        EmptyView()
      }
    case .unavailable(let reason):
      // Say why rather than sitting blank. A blank preview reads as "it did not
      // hear me", which is the exact anxiety this feature exists to remove. Two
      // lines because some of these sentences wrap.
      previewText(reason, dimmed: true, lines: 2)
    case .text(let text):
      previewText(text, dimmed: false, lines: Self.previewMaxLines)
    }
  }

  /// One builder for all three states, so the pill cannot change alignment as it
  /// moves between "Listening...", real words, and a reason it cannot run.
  ///
  /// **No fixed height.** The text takes exactly the lines it needs, the capsule
  /// grows with it, and the panel follows via `onContentHeightChange`. At the cap
  /// the text keeps laying out in full but the box stops growing and pins the text
  /// to its BOTTOM, so the overflow leaves at the top and the newest words stay
  /// where the eye already is.
  ///
  /// **`.lineLimit(n)` + `.truncationMode(.head)` does NOT do this, despite
  /// reading as though it should.** Measured by rendering this exact modifier
  /// stack over 60 numbered words: it keeps the OLDEST four lines and truncates
  /// only the LAST one, so a long dictation showed `word1...word32`, then a jump
  /// to `...word53 word60` — the middle silently gone and four fifths of the pill
  /// frozen on the opening words. Review caught it; the screenshot that had
  /// "verified" the behaviour showed a transcript at exactly five lines, which
  /// never exercises overflow at all.
  ///
  /// Bottom-pinned clipping is the literal reading of "scrolls off the top", and
  /// needs no ScrollView (which brings scrollers, elasticity and its own
  /// scroll-to-bottom timing into a borderless overlay) and no manual text
  /// measurement.
  private func previewText(_ message: String, dimmed: Bool, lines: Int) -> some View {
    PreviewWellText(
      message: message, dimmed: dimmed, lines: lines,
      insets: chrome.wellInsets, ink: chrome.wellInk,
      fadesWhenFull: chrome.fadesWhenWellIsFull)
  }

  /// #2203: ONE authority for preview typography. The `Text` and the cap both read
  /// these, so a change to the type size cannot leave the two disagreeing.
  ///
  /// **The previous version's doc comment claimed the cap "tracks the type size"
  /// and it did not.** It built `NSFont.systemFont(ofSize: 12)` from its own
  /// hardcoded 12, independent of the `Text`'s own `.font(.system(size: 12))`
  /// twenty lines away. Two literals that had to agree, with a comment asserting
  /// they could not drift — which is worse than no comment, because it stops the
  /// next reader checking.
  static let previewFontSize: CGFloat = 14
  static let previewLineSpacing: CGFloat = 4

  /// #2203: how much of the reading well's height the top fade occupies.
  ///
  /// Deliberately small. The fade exists to say "there is more above this", not to
  /// hide a line — at the cap the oldest visible line is still readable, just
  /// clearly on its way out. A larger value starts costing the user words they
  /// have not finished reading.
  static let previewFadeFraction: CGFloat = 0.22

  /// Height of `lines` lines of the preview font, INCLUDING the gaps between them.
  ///
  /// **Counting the gaps is not a refinement, it is the difference between five
  /// lines and four.** SwiftUI adds `lineSpacing` BETWEEN lines, so five lines
  /// occupy five glyph heights plus four gaps. A cap that counts only the glyphs
  /// under-measures by 4 x `previewLineSpacing` and clips the fifth line partway.
  ///
  /// An exact multiple still matters: the clip lands on a line boundary, so no row
  /// is cut through the middle of its glyphs.
  static func previewHeight(lines: Int) -> CGFloat {
    let font = NSFont.systemFont(ofSize: previewFontSize)
    let glyphHeight = ceil(font.ascender - font.descender + font.leading)
    let gaps = max(lines - 1, 0)
    return glyphHeight * CGFloat(lines) + previewLineSpacing * CGFloat(gaps)
  }

  /// Five lines, matching the shape the founder tested against Spokenly: the pill
  /// grows a line at a time up to this, then holds its size and scrolls.
  static let previewMaxLines = 5
}

/// #2203: the reading well's text, and the one part of the pill that has to know
/// whether it is FULL.
///
/// Split out of `RecordingOverlayView` only because the fade decision needs
/// `@State`, and a function returning a view cannot hold one.
struct PreviewWellText: View {
  let message: String
  let dimmed: Bool
  let lines: Int
  /// The three chrome values this view needs, handed down rather than a copy of
  /// the whole thing. **It used to carry `usesPreviewLayout` itself**, which made
  /// it a second style authority one level below the leaf: the same boolean, read
  /// again, free to disagree.
  let insets: EdgeInsets
  let ink: PillInk
  let fadesWhenFull: Bool

  /// Whether the well is at its cap, and so whether anything is scrolling off the
  /// top. Written from a `GeometryReader` in the BACKGROUND of the capped frame,
  /// which does not participate in layout, and it feeds only the mask, which does
  /// not either — so it cannot reach the panel-resize loop #2201 settled.
  /// `RecordingOverlayPreviewSizingTests` is the check on that claim rather than
  /// this sentence.
  @State private var wellIsFull = false

  private var cap: CGFloat { RecordingOverlayView.previewHeight(lines: lines) }

  var body: some View {
    Text(message)
      .font(.system(size: RecordingOverlayView.previewFontSize))
      .lineSpacing(RecordingOverlayView.previewLineSpacing)
      .foregroundStyle(ink.well(dimmed: dimmed))
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      // `maxHeight` CAPS without fixing: below the cap the box is the text's own
      // height, which is what lets the pill still grow a line at a time.
      .frame(maxHeight: cap, alignment: .bottom)
      .background(
        GeometryReader { geo in
          Color.clear
            .onAppear { updateFullness(geo.size.height) }
            .onChange(of: geo.size.height) { _, height in updateFullness(height) }
        }
      )
      .clipped()
      // #2203: fade the top edge ONLY when something is actually above it.
      //
      // **Cloud review caught this applying unconditionally.** The capped frame
      // takes the TEXT's height while the text is short, so the gradient mapped
      // onto the first line of a one-line transcript and dimmed words the user
      // still had to read. A fade means "there is more above this"; saying that
      // when there is not is worse than not saying it at all.
      //
      // Doing it with a mask rather than per-line opacity remains the point:
      // dimming older LINES needs to know where the text engine broke them, which
      // is the knowledge this file records as unavailable — a character budget is
      // wrong by 2x for CJK and wrong again for any proportional font. A gradient
      // needs no line information and behaves identically in every script, because
      // older words are higher up by construction.
      //
      // KNOWN LIMIT, recorded rather than hidden: a transcript landing at EXACTLY
      // the cap fades slightly with nothing yet above it. Separating that from a
      // genuine overflow needs the text's unclipped intrinsic height, which costs a
      // second layout of the same string for a one-frame cosmetic difference at the
      // moment the well is about to overflow anyway.
      .mask(fadeMask)
      // #2202: the well's own inset, replacing what the shared root padding used
      // to give it. **Outside the cap, deliberately.** Padding inserted before
      // `.frame(maxHeight:)` is subtracted from the five-line viewport, so the
      // box would clip at four-and-a-bit lines and the founder's five-line rule
      // would quietly stop holding — a number that looks like it means lines
      // while meaning something else.
      .padding(insets)
  }

  @ViewBuilder
  private var fadeMask: some View {
    if fadesWhenFull && wellIsFull {
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0),
          .init(color: .white, location: RecordingOverlayView.previewFadeFraction),
          .init(color: .white, location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom)
    } else {
      Rectangle()
    }
  }

  /// The capped frame reports the TEXT's height below the cap and the CAP once the
  /// text exceeds it, so "is it at the cap" is the overflow signal without
  /// measuring the string ourselves.
  private func updateFullness(_ height: CGFloat) {
    let full = Self.wellIsFull(measuredHeight: height, cap: cap)
    if full != wellIsFull { wellIsFull = full }
  }

  /// The fade decision, extracted so it can be asserted directly.
  ///
  /// A mask does not participate in layout, so no height test can see whether the
  /// fade is applied — the same reason `RecordingOverlayPanel`'s inherited-geometry
  /// arithmetic is pinned as a pure function rather than driven through a panel.
  /// Cloud review found this applying unconditionally; a decision worth fixing is
  /// worth pinning.
  ///
  /// The half-point tolerance absorbs the rounding between a laid-out frame and a
  /// computed cap. Without it a well that is full to the pixel reports empty and
  /// the fade flickers off at exactly the moment it is needed.
  static func wellIsFull(measuredHeight: CGFloat, cap: CGFloat) -> Bool {
    measuredHeight >= cap - 0.5
  }

}
