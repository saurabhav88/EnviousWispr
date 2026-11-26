import SwiftUI

/// EnviousMeet's mark (#4346, founder 2026-11-02): the sidebar's two-people glyph
/// (`person.2.wave.2`) in the lips' rainbow. It plays Apple's iterative variable-color wave
/// twice each time it appears, then rests on the still rainbow glyph (#4987: a forever effect
/// kept an M1 busy); Reduce Motion and the design harness show only the still glyph.
struct MeetingRainbowLogo: View {
  var size: CGFloat = 28
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.holdsAnimatedMarksStill) private var holdsStill
  /// #4987: bumped once per appearance; the wave plays `Self.plays` times, then the glyph rests.
  @State private var appearances = 0

  /// #4987: a forever effect kept an M1's main thread waiting on the window server about 37% of
  /// the time while any EnviousMeet page was open (0% with the still glyph).
  static let plays = 2

  var body: some View {
    ZStack {
      if reduceMotion || holdsStill {
        glyph
      } else {
        glyph.symbolEffect(
          .variableColor.iterative, options: .repeat(Self.plays), value: appearances)
      }
    }
    .onAppear { if !reduceMotion && !holdsStill { appearances += 1 } }
    .accessibilityHidden(true)
  }

  private var glyph: some View {
    Image(systemName: "person.2.wave.2")
      .font(.system(size: size, weight: .semibold))
      .foregroundStyle(Color.obRainbow)
  }
}

extension EnvironmentValues {
  /// #4506 (founder 2026-11-11): the design render harness sets this so an animated mark draws its
  /// still Reduce Motion picture and two renders of a page match pixel for pixel. Nothing in the
  /// app sets it.
  @Entry var holdsAnimatedMarksStill = false
}

/// The BETA tag on EnviousMeet (#4346 plan §3.5): setup heading, completed settings heading and
/// the sidebar row. Text stays at the Settings 14-point floor.
struct BetaBadge: View {
  /// On the sidebar's selected (purple) row the tag turns white on a light veil.
  var onSelectedRow = false
  /// The sidebar's narrower tag, so "EnviousMeet" and the tag fit one 184-point row.
  var compact = false

  static let text = String(
    localized: "BETA", comment: "EnviousMeet: the tag that says the feature is still being built.")
  static let spoken = String(
    localized: "Beta", comment: "EnviousMeet: VoiceOver word for the BETA tag, read after the name."
  )

  var body: some View {
    Text(Self.text)
      .font(.system(size: 14, weight: .bold))
      .tracking(compact ? 0 : 0.6)
      .foregroundStyle(onSelectedRow ? Color.white : Color(red: 0.10, green: 0.06, blue: 0.20))
      .padding(.horizontal, compact ? 5 : 7)
      .padding(.vertical, compact ? 0 : 1)
      .background(
        Capsule().fill(
          onSelectedRow
            ? AnyShapeStyle(Color.white.opacity(0.18))
            : AnyShapeStyle(
              LinearGradient(
                colors: [
                  Color(red: 0.992, green: 0.902, blue: 0.541),
                  Color(red: 0.976, green: 0.659, blue: 0.831),
                ], startPoint: .leading, endPoint: .trailing)))
      )
      .fixedSize()
      .accessibilityHidden(true)
  }
}

/// Logo, name and BETA on one line: the setup heading and the completed settings heading.
struct MeetingBrandHeading: View {
  var logoSize: CGFloat = 28
  var nameSize: CGFloat = 20

  var body: some View {
    HStack(spacing: 10) {
      MeetingRainbowLogo(size: logoSize)
      Text(verbatim: "EnviousMeet")
        .font(.system(size: nameSize, weight: .bold))
        .foregroundStyle(Color.obTextPrimary)
      BetaBadge()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: "EnviousMeet, \(BetaBadge.spoken)"))
    .accessibilityAddTraits(.isHeader)
  }
}
