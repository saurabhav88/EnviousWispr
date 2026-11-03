import SwiftUI

/// EnviousMeet's mark (#4346, founder 2026-11-02): the sidebar's two-people glyph
/// (`person.2.wave.2`) in the lips' rainbow, animated with Apple's iterative variable-color
/// effect; Reduce Motion shows the still rainbow glyph. Which layers animate on macOS 14 is
/// verified in the #4346 UAT, not assumed here.
struct MeetingRainbowLogo: View {
  var size: CGFloat = 28
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Image(systemName: "person.2.wave.2")
      .font(.system(size: size, weight: .semibold))
      .foregroundStyle(Color.obRainbow)
      .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
      .accessibilityHidden(true)
  }
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
