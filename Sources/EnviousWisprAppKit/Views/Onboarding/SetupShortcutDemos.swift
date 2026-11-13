import SwiftUI

/// Both demos share one clock. Phase ranges come from obKeyHold, obKeyDouble, obBarsHold
/// and obBarsDouble in the approved mockup.
struct SetupShortcutDemos: View {
  let label: String
  let rehearsal: SetupShortcutRehearsal
  let reduceMotion: Bool
  @State private var started = Date()

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { tick in
      let seconds = reduceMotion ? 0 : max(0, tick.date.timeIntervalSince(started))
      HStack(spacing: DesignSpacing.md) {
        demo(.hold, tried: rehearsal.triedHold, seconds: seconds)
        demo(.doublePress, tried: rehearsal.triedDoublePress, seconds: seconds)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("How to dictate")
  }

  private func demo(_ gesture: Gesture, tried: Bool, seconds: TimeInterval) -> some View {
    let phase = seconds.truncatingRemainder(dividingBy: 3) / 3
    let pressure = gesture.pressure(at: phase)
    let shape = RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
    return VStack(spacing: DesignSpacing.sm) {
      HStack(spacing: DesignSpacing.md) {
        Text(verbatim: label)
          .font(.firstRunCaption.weight(.semibold))
          .foregroundStyle(pressure > 0 ? Color.obAccent : Color.obTextPrimary)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .padding(.horizontal, DesignSpacing.md)
          .frame(minWidth: 30)
          .frame(height: 26)
          .background(Color.obCardBg, in: shape)
          .overlay {
            shape.strokeBorder(
              pressure > 0 ? Color.obAccent : Color.firstRunRule, lineWidth: DesignSpacing.xxs)
          }
          .shadow(color: .firstRunRule, radius: 0, y: DesignSpacing.xxs * (1 - pressure))
          .offset(y: DesignSpacing.xxs * pressure)
        HStack(spacing: 3) {
          ForEach(Self.barDelays, id: \.self) { delay in
            Capsule()
              .fill(Color.obAccent)
              .frame(width: 3, height: 18)
              .scaleEffect(y: Self.barScale(seconds: seconds, delay: delay))
          }
        }
        .frame(height: 20)
        .opacity(gesture.bars(at: phase))
      }
      .frame(height: 30)
      .accessibilityHidden(true)
      Text(gesture.title)
        .font(.firstRunCaption.weight(.semibold))
        .foregroundStyle(Color.obTextPrimary)
        .multilineTextAlignment(.center)
    }
    .padding(.vertical, DesignSpacing.lg)
    .padding(.horizontal, DesignSpacing.md)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.obSurface, in: RoundedRectangle(cornerRadius: DesignRadius.xl))
    .overlay(alignment: .topTrailing) {
      if tried {
        Image(systemName: "checkmark.circle.fill")
          .font(.firstRunSay)
          .symbolRenderingMode(.palette)
          .foregroundStyle(Color.white, Color.obSuccess)
          .padding(DesignSpacing.sm)
          .modifier(SetupPop(delay: 0, reduceMotion: reduceMotion))  // mockup obPop 0.4 s
          .accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(gesture.instruction)
    .accessibilityValue(tried ? Text("Tried") : Text(verbatim: ""))
  }

  private static let barDelays: [TimeInterval] = [0, 0.15, 0.30, 0.10]

  private static func barScale(seconds: TimeInterval, delay: TimeInterval) -> CGFloat {
    let beat = max(0, seconds - delay).truncatingRemainder(dividingBy: 0.9)
    let progress = beat <= 0.45 ? beat / 0.45 : (0.9 - beat) / 0.45
    // Mockup obBarBob: ease-in-out between the ends, so the bars turn softly.
    return 0.35 + 0.65 * (1 - cos(.pi * progress)) / 2
  }

  private enum Gesture {
    case hold, doublePress

    var title: LocalizedStringKey {
      switch self {
      case .hold: "Hold to dictate"
      case .doublePress: "Double-press for hands-free"
      }
    }

    var instruction: LocalizedStringKey {
      switch self {
      case .hold: "Hold the key to dictate, release to transcribe"
      case .doublePress: "Double-press the key to dictate hands-free"
      }
    }

    func pressure(at phase: Double) -> CGFloat {
      switch self {
      case .hold: Self.ramp(phase, in: 0.08...0.14, out: 0.64...0.70)
      case .doublePress:
        max(
          Self.ramp(phase, in: 0.08...0.11, out: 0.11...0.15),
          Self.ramp(phase, in: 0.15...0.19, out: 0.19...0.23))
      }
    }

    func bars(at phase: Double) -> Double {
      switch self {
      case .hold: Self.ramp(phase, in: 0.12...0.16, out: 0.64...0.70)
      case .doublePress: Self.ramp(phase, in: 0.22...0.26, out: 0.88...0.94)
      }
    }

    private static func ramp(
      _ phase: Double, in rising: ClosedRange<Double>, out falling: ClosedRange<Double>
    ) -> Double {
      let rise = (phase - rising.lowerBound) / (rising.upperBound - rising.lowerBound)
      let fall = (falling.upperBound - phase) / (falling.upperBound - falling.lowerBound)
      return max(0, min(1, rise, fall))
    }
  }
}
