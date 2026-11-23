import SwiftUI

/// #4611 D3: the transcript pane's settings button (two sliders, founder 2026-11-17) that holds Follow playback and
/// Timestamps, which used to sit in the page header. A nil binding leaves that switch out.
struct MeetingTranscriptSettingsButton: View {
  let follow: Binding<Bool>?
  let timestamps: Binding<Bool>?
  /// #4611 T8 (transcript page): with no binding, a reason shows the switch greyed out and off
  /// with that line under it, instead of leaving it out. The meeting page passes none.
  var followUnavailable: Text? = nil
  var timestampsUnavailable: Text? = nil
  @State private var open = false

  var body: some View {
    Button {
      open.toggle()
    } label: {
      // Founder 2026-11-17: two sliders. The system has no two-slider symbol, so it is drawn.
      TwoSlidersGlyph()
        .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
        .modifier(EnviousButtonFace(emphasis: .quiet, shape: .roundedRect, size: .medium))
    }
    .buttonStyle(.plain)
    .fixedSize()
    .help(Self.title)
    .accessibilityLabel(Self.title)
    .popover(isPresented: $open, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        if let follow {
          row(Self.followTitle, isOn: follow)
        } else if let followUnavailable {
          unavailableRow(Self.followTitle, reason: followUnavailable)
        }
        if let timestamps {
          row(Self.timestampsTitle, isOn: timestamps)
        } else if let timestampsUnavailable {
          unavailableRow(Self.timestampsTitle, reason: timestampsUnavailable)
        }
      }
      .padding(DesignSpacing.lg)
      .frame(minWidth: 220)
    }
  }

  private func row(_ label: Text, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) {
      label
        .font(.stRowLabel)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .toggleStyle(BrandedToggleStyle(onColor: .stAccentSolid))
  }

  /// A switch that cannot be used here: greyed out, off, with why under its name.
  private func unavailableRow(_ label: Text, reason: Text) -> some View {
    Toggle(isOn: .constant(false)) {
      VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
        label.font(.stRowLabel)
        reason.font(.stHelper).foregroundStyle(.stTextSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .toggleStyle(BrandedToggleStyle(onColor: .stAccentSolid))
    .disabled(true)
  }

  private static let followTitle = Text(
    "Follow playback",
    comment: "History meeting: the transcript scrolls along with the playing recording.")
  private static let timestampsTitle = Text(
    "Timestamps",
    comment: "History transcript and meeting pages: shows or hides each turn's start time.")

  private static let title = Text(
    "Transcript settings", comment: "History meeting: the transcript pane's settings button.")
}

/// Two horizontal lines, each with a round knob: the upper one toward the right, the lower one
/// toward the left. Lines stop at each knob's edge.
struct TwoSlidersGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let radius = rect.height * 0.16
    for (y, knobX) in [(0.3, 0.68), (0.72, 0.32)] {
      let lineY = rect.minY + rect.height * y
      let centerX = rect.minX + rect.width * knobX
      path.move(to: CGPoint(x: rect.minX, y: lineY))
      path.addLine(to: CGPoint(x: centerX - radius, y: lineY))
      path.move(to: CGPoint(x: centerX + radius, y: lineY))
      path.addLine(to: CGPoint(x: rect.maxX, y: lineY))
      path.addEllipse(
        in: CGRect(x: centerX - radius, y: lineY - radius, width: radius * 2, height: radius * 2))
    }
    return path
  }
}
