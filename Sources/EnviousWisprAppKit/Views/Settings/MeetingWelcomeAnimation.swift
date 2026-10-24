import SwiftUI

/// The "how it works" scene on EnviousMeet's welcome screen (#4017 O7): a call window, the
/// "Record this call?" question, then the transcript filling in under the speakers' names. It
/// stands in for the rendered video until that file ships; with Reduce Motion it shows the
/// finished scene, still.
struct MeetingWelcomeAnimation: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var start = Date()

  /// One loop, in seconds.
  private static let loop = 9.0

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { context in
      let phase =
        reduceMotion
        ? 0.95
        : context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: Self.loop)
          / Self.loop
      scene(phase: phase)
    }
    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.obBorder, lineWidth: 1))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .accessibilityElement()
    .accessibilityLabel(
      Text(
        "A call starts, EnviousWispr asks whether to record it, and the transcript fills in with who said what.",
        comment: "EnviousMeet setup: describes the welcome animation for VoiceOver."))
  }

  private func scene(phase: Double) -> some View {
    HStack(alignment: .top, spacing: 12) {
      callWindow(phase: phase)
        .frame(width: 210)
      VStack(alignment: .leading, spacing: 6) {
        speaker("Priya", color: Color.obSuccess)
        bar(width: grow(phase, from: 0.60, to: 0.70) * 0.84)
        bar(width: grow(phase, from: 0.68, to: 0.78) * 0.62)
        speaker(
          String(
            localized: "You", comment: "EnviousMeet setup animation: the user's speaker label."),
          color: Color.obAccent
        )
        .padding(.top, 4)
        bar(width: grow(phase, from: 0.78, to: 0.88) * 0.70)
      }
      .padding(.top, 36)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(12)
    .overlay(alignment: .topTrailing) {
      recordQuestion
        .opacity(window(phase, rise: 0.18, holdUntil: 0.52, fall: 0.06))
        .offset(y: (1 - window(phase, rise: 0.18, holdUntil: 0.52, fall: 0.06)) * -6)
        .padding(8)
    }
  }

  private func callWindow(phase: Double) -> some View {
    VStack(spacing: 0) {
      Text(verbatim: "Zoom")
        .font(.system(size: 10))
        .foregroundStyle(Color.obTextSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(Color.white.opacity(0.06))
      LazyVGrid(
        columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5
      ) {
        tile("Priya", Color(red: 0.18, green: 0.23, blue: 0.29), talking: phase > 0.55)
        tile("Marcus", Color(red: 0.23, green: 0.18, blue: 0.29), talking: false)
        tile("Diana", Color(red: 0.18, green: 0.29, blue: 0.24), talking: false)
        tile(
          String(
            localized: "You", comment: "EnviousMeet setup animation: the user's speaker label."),
          Color(red: 0.29, green: 0.23, blue: 0.18), talking: false)
      }
      .padding(6)
    }
    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
  }

  private func tile(_ name: String, _ color: Color, talking: Bool) -> some View {
    RoundedRectangle(cornerRadius: 5)
      .fill(color)
      .frame(height: 52)
      .overlay(alignment: .bottomLeading) {
        Text(verbatim: name).font(.system(size: 9)).foregroundStyle(.white.opacity(0.9)).padding(4)
      }
      .overlay(
        RoundedRectangle(cornerRadius: 5).stroke(Color.obSuccess, lineWidth: talking ? 2 : 0))
  }

  private var recordQuestion: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Record this call?", comment: "EnviousMeet: the question asked when a call starts.")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.obTextPrimary)
      HStack(spacing: 5) {
        Text("Yes", comment: "EnviousMeet: answer to Record this call?")
          .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
          .frame(maxWidth: .infinity).padding(.vertical, 3)
          .background(Color.obButtonFill, in: RoundedRectangle(cornerRadius: 6))
        Text("No", comment: "EnviousMeet: answer to Record this call?")
          .font(.system(size: 10)).foregroundStyle(Color.obTextPrimary)
          .frame(maxWidth: .infinity).padding(.vertical, 3)
          .background(Color.obSurface, in: RoundedRectangle(cornerRadius: 6))
      }
    }
    .padding(8)
    .frame(width: 150)
    .background(Color.obCardBg, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.obBorder, lineWidth: 1))
  }

  private func speaker(_ name: String, color: Color) -> some View {
    Text(verbatim: name).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
  }

  private func bar(width fraction: Double) -> some View {
    GeometryReader { proxy in
      RoundedRectangle(cornerRadius: 3)
        .fill(Color.obTextTertiary.opacity(0.6))
        .frame(width: proxy.size.width * fraction, height: 6)
    }
    .frame(height: 6)
  }

  /// 0 before `from`, 1 after `to`, eased between.
  private func grow(_ phase: Double, from: Double, to: Double) -> Double {
    let t = min(1, max(0, (phase - from) / (to - from)))
    return 1 - pow(1 - t, 3)
  }

  /// Fades in at `rise`, holds to `holdUntil`, fades out over `fall`.
  private func window(_ phase: Double, rise: Double, holdUntil: Double, fall: Double) -> Double {
    if phase < rise { return 0 }
    if phase < rise + 0.06 { return (phase - rise) / 0.06 }
    if phase < holdUntil { return 1 }
    return max(0, 1 - (phase - holdUntil) / fall)
  }
}
