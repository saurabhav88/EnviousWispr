import AppKit

/// Manages animated menu bar icon states using Core Graphics rendering.
///
/// Five states: idle (static grey lips), recording (static rainbow lips),
/// processing (rotating rainbow spectrum wheel), error (static red lips),
/// updatePending (grey lips with a gold wave travelling outward — the
/// "update waiting" cue, #1019), meeting (#4116: grey lips with a rainbow wave moving
/// left to right; one still half-coloured frame under Reduce Motion). Recording is
/// static, not audio-reactive — the on-screen recording overlay already shows a legible
/// audio-reactive meter; at menu-bar-icon size that reactivity only read as the icon
/// randomly looking smaller.
@MainActor
final class MenuBarIconAnimator {

  enum IconState: Equatable {
    case idle
    case recording
    case processing
    case error
    /// #1019: an update is downloaded/available and waiting to install. An
    /// idle-with-update display variant — the controller selects it only inside
    /// the idle branch of its icon-state mapping, so it never overrides
    /// recording / processing / error / warning.
    case updatePending
    /// #3972: a meeting is recording. The only always-visible sign of it: grey lips with a
    /// rainbow wave (#4116, founder 2026-10-26; replaced R47's monochrome halo), no pill or window.
    case meeting
  }

  private weak var button: NSStatusBarButton?
  private var idleImage: NSImage?
  private var recordingImage: NSImage?
  private var errorImage: NSImage?
  private var animationTimer: Timer?
  private(set) var currentState: IconState = .idle

  // Processing rotation angle (degrees)
  private var rotationAngle: Double = 0

  // #1019: update-pending gold-wave phase (0…1 per loop).
  private var wavePhase: Double = 0
  // #4116: meeting wave phase (0…1 per sweep).
  private var meetingPhase: Double = 0
  private var reduceMotionObserver: NSObjectProtocol?

  /// #ffd700 — the "pending" semantic gold.
  private static let goldColor = (r: CGFloat(1.0), g: CGFloat(0.843), b: CGFloat(0.0))
  /// Mid-grey base the gold washes through.
  private static let greyColor = (r: CGFloat(0.5), g: CGFloat(0.5), b: CGFloat(0.5))

  // MARK: - Configuration

  /// Call once from setupStatusItem() after creating the button.
  func configure(button: NSStatusBarButton) {
    self.button = button
    self.idleImage = renderIdleLips()
    self.recordingImage = renderRecordingLips()
    self.errorImage = renderErrorLips()
    button.image = self.idleImage

    // #1019: re-render the update-pending cue when the system reduce-motion
    // setting changes live (AppKit-native — the SwiftUI `@Environment` key does
    // not reach this AppKit class).
    reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        switch self.currentState {
        case .updatePending: self.restartUpdatePendingForReduceMotionChange()
        case .meeting:
          self.stopTimer()
          self.meetingPhase = 0
          self.startMeetingWave()
        case .idle, .recording, .processing, .error: return
        }
      }
    }
  }

  // MARK: - State Transitions

  /// Transition to a new icon state. Guards against redundant transitions.
  func transition(to newState: IconState) {
    guard newState != currentState else { return }
    stopTimer()
    currentState = newState

    switch newState {
    case .idle:
      button?.image = idleImage
    case .recording:
      button?.image = recordingImage
    case .processing:
      rotationAngle = 0
      startProcessingAnimation()
    case .error:
      button?.image = errorImage
    case .updatePending:
      wavePhase = 0
      startUpdatePendingAnimation()
    case .meeting:
      meetingPhase = 0
      startMeetingWave()
    }
  }

  /// Re-apply the update-pending cue when reduce-motion toggles while it is the
  /// current state (the new transition guard would otherwise no-op a same-state
  /// re-entry).
  private func restartUpdatePendingForReduceMotionChange() {
    stopTimer()
    wavePhase = 0
    startUpdatePendingAnimation()
  }

  // MARK: - Timer Management

  private func stopTimer() {
    animationTimer?.invalidate()
    animationTimer = nil
  }

  // MARK: - Processing Animation (spectrum wheel, rotating, ~15fps)

  private func startProcessingAnimation() {
    button?.image = renderProcessingWheel()

    animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let button = self.button else { return }
        self.rotationAngle += 3.0  // 360° / 8s / 15fps = 3° per frame
        if self.rotationAngle >= 360 { self.rotationAngle -= 360 }
        button.image = self.renderProcessingWheel()
      }
    }
  }

  // MARK: - Update-pending Animation (gold wave through grey lips, ~20fps)

  /// #1019: grey lips with a fast, near-together gold wave sweeping outward from
  /// the center column. Reduce-motion users get a static gold-tinted frame
  /// instead of the loop.
  private func startUpdatePendingAnimation() {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      button?.image = renderUpdatePendingStatic()
      return
    }
    button?.image = renderUpdatePendingLips(phase: wavePhase)

    animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let button = self.button else { return }
        // ~1.3s loop at 20fps → 26 frames per loop.
        self.wavePhase += 1.0 / 26.0
        if self.wavePhase >= 1.0 { self.wavePhase -= 1.0 }
        button.image = self.renderUpdatePendingLips(phase: self.wavePhase)
      }
    }
  }

  // MARK: - Meeting wave (#4116, ~20fps, one sweep every 2 s)

  /// Per-column rainbow colours, shared by the recording lips and the meeting wave. They match
  /// RainbowLipsIcon in `App/Brand/RainbowLipsIcon.swift`.
  private static let upperLipRainbow: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
    (1.0, 0.165, 0.251), (1.0, 0.549, 0.0), (1.0, 0.843, 0.0),
    (0.678, 1.0, 0.184), (0.0, 0.98, 0.604), (0.0, 1.0, 1.0),
    (0.118, 0.565, 1.0), (0.255, 0.412, 0.882), (0.541, 0.169, 0.886),
  ]
  private static let lowerLipRainbow: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
    (0.255, 0.412, 0.882), (0.118, 0.565, 1.0), (0.0, 1.0, 1.0),
    (0.0, 0.98, 0.604), (0.678, 1.0, 0.184), (1.0, 0.843, 0.0),
    (1.0, 0.549, 0.0), (1.0, 0.165, 0.251), (0.541, 0.169, 0.886),
  ]

  /// Reduce Motion: every bar half way between grey and its rainbow colour.
  static let meetingStillIntensity: CGFloat = 0.5

  /// How far column `column` (0…8) has moved from grey toward its rainbow colour at `phase`
  /// (0…1 per sweep). Squared so the lit band is narrow and the wave reads as moving right.
  static func meetingWaveIntensity(column: Int, phase: Double) -> CGFloat {
    let value = 0.5 + 0.5 * sin(2 * .pi * (Double(column) / 9 - phase))
    return CGFloat(value * value)
  }

  /// One meeting frame; the live wave and its Reduce Motion still frame both come from here.
  static func meetingWaveFrame(phase: Double, reduceMotion: Bool) -> NSImage {
    let intensities = (0..<9).map {
      reduceMotion ? meetingStillIntensity : meetingWaveIntensity(column: $0, phase: phase)
    }
    return renderMeetingWave(intensities: intensities)
  }

  private func startMeetingWave() {
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    button?.image = Self.meetingWaveFrame(phase: meetingPhase, reduceMotion: reduceMotion)
    guard !reduceMotion else { return }

    animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) {
      [weak self] timer in
      let drew = MainActor.assumeIsolated { () -> Bool in
        guard let self, let button = self.button else { return false }
        // 2 s sweep at 20fps → 40 frames per sweep.
        self.meetingPhase += 1.0 / 40.0
        if self.meetingPhase >= 1.0 { self.meetingPhase -= 1.0 }
        button.image = Self.meetingWaveFrame(phase: self.meetingPhase, reduceMotion: false)
        return true
      }
      // The owner or its button is gone: stop the wave instead of ticking forever.
      if !drew { timer.invalidate() }
    }
  }

  /// The meeting wave: grey lips, each bar blended toward its rainbow colour by its intensity.
  /// Not a template: the update cue's mid-grey is what keeps it readable on light and dark bars.
  static func renderMeetingWave(intensities: [CGFloat]) -> NSImage {
    renderRainbowLips(intensities: intensities, alpha: 0.95)
  }

  // MARK: - Core Graphics Rendering

  /// Render rainbow lip bars at full height (static — see class doc for why
  /// this isn't audio-reactive). Bar geometry and colors match RainbowLipsIcon
  /// in `App/Brand/RainbowLipsIcon.swift`.
  private func renderRecordingLips() -> NSImage {
    Self.renderRainbowLips(intensities: Array(repeating: 1, count: 9), alpha: 1)
  }

  /// Shared rainbow renderer: column `i`'s upper and lower bar are filled with the mid-grey
  /// blended toward their rainbow colours by `intensities[i]` (1 = the full rainbow).
  private static func renderRainbowLips(intensities: [CGFloat], alpha: CGFloat) -> NSImage {
    precondition(intensities.count == 9)
    return NSImage(size: NSSize(width: 22, height: 22), flipped: true) { rect in
      guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
      let scale = rect.width / 64.0
      let barWidth: CGFloat = 4.5 * scale
      let cornerRadius: CGFloat = 1.5 * scale
      ctx.translateBy(x: 0, y: Self.lipsVerticalCenteringOffset * scale)

      for (bars, colours) in [
        (Self.upperLipBars, Self.upperLipRainbow), (Self.lowerLipBars, Self.lowerLipRainbow),
      ] {
        for (i, bar) in bars.enumerated() {
          let colour = colours[i]
          let t = intensities[i]
          ctx.setFillColor(
            CGColor(
              red: Self.greyColor.r + (colour.r - Self.greyColor.r) * t,
              green: Self.greyColor.g + (colour.g - Self.greyColor.g) * t,
              blue: Self.greyColor.b + (colour.b - Self.greyColor.b) * t,
              alpha: alpha))
          let barRect = CGRect(
            x: bar.x * scale, y: bar.y * scale, width: barWidth, height: bar.h * scale)
          ctx.addPath(
            CGPath(
              roundedRect: barRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
              transform: nil))
          ctx.fillPath()
        }
      }
      return true
    }
  }

  /// Render idle lips — same 9+9 bar geometry as recording/error lips, but monochrome.
  /// Uses black at 0.65 alpha so macOS template rendering inverts correctly for dark/light mode.
  private func renderIdleLips() -> NSImage {
    let size = NSSize(width: 22, height: 22)
    let image = NSImage(size: size, flipped: true) { rect in
      guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

      let scale = rect.width / 64.0
      let barWidth: CGFloat = 4.5 * scale
      let cornerRadius: CGFloat = 1.5 * scale
      let fill = CGColor(red: 0, green: 0, blue: 0, alpha: 0.65)
      ctx.translateBy(x: 0, y: Self.lipsVerticalCenteringOffset * scale)

      let upperBars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
        (4, 22.25, 5), (10, 17.6375, 8), (16, 12.04, 12),
        (22, 16.96, 9), (28, 21.5575, 6), (34, 16.96, 9),
        (40, 12.04, 12), (46, 17.6375, 8), (52, 22.25, 5),
      ]

      let lowerBars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
        (4, 30.25, 5), (10, 28.6375, 9), (16, 27.04, 12),
        (22, 28.96, 15), (28, 30.5575, 17), (34, 28.96, 15),
        (40, 27.04, 12), (46, 28.6375, 9), (52, 30.25, 5),
      ]

      ctx.setFillColor(fill)

      for bar in upperBars {
        let barRect = CGRect(
          x: bar.x * scale, y: bar.y * scale, width: barWidth, height: bar.h * scale)
        let path = CGPath(
          roundedRect: barRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
          transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
      }

      for bar in lowerBars {
        let barRect = CGRect(
          x: bar.x * scale, y: bar.y * scale, width: barWidth, height: bar.h * scale)
        let path = CGPath(
          roundedRect: barRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
          transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
      }

      return true
    }
    image.isTemplate = true
    return image
  }

  /// Render error lips — same geometry as recording but all bars in red.
  private func renderErrorLips() -> NSImage {
    let size = NSSize(width: 22, height: 22)
    return NSImage(size: size, flipped: true) { rect in
      guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

      let scale = rect.width / 64.0
      let barWidth: CGFloat = 4.5 * scale
      let cornerRadius: CGFloat = 1.5 * scale
      let red = CGColor(red: 1.0, green: 0.165, blue: 0.251, alpha: 0.9)  // #ff2a40 at 0.9 opacity
      ctx.translateBy(x: 0, y: Self.lipsVerticalCenteringOffset * scale)

      let upperBars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
        (4, 22.25, 5), (10, 17.6375, 8), (16, 12.04, 12),
        (22, 16.96, 9), (28, 21.5575, 6), (34, 16.96, 9),
        (40, 12.04, 12), (46, 17.6375, 8), (52, 22.25, 5),
      ]

      let lowerBars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
        (4, 30.25, 5), (10, 28.6375, 9), (16, 27.04, 12),
        (22, 28.96, 15), (28, 30.5575, 17), (34, 28.96, 15),
        (40, 27.04, 12), (46, 28.6375, 9), (52, 30.25, 5),
      ]

      ctx.setFillColor(red)

      for bar in upperBars {
        let barRect = CGRect(
          x: bar.x * scale, y: bar.y * scale, width: barWidth, height: bar.h * scale)
        let path = CGPath(
          roundedRect: barRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
          transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
      }

      for bar in lowerBars {
        let barRect = CGRect(
          x: bar.x * scale, y: bar.y * scale, width: barWidth, height: bar.h * scale)
        let path = CGPath(
          roundedRect: barRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
          transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
      }

      return true
    }
  }

  /// Render the processing spectrum wheel at the current rotation angle.
  /// Bar geometry and colors match SpectrumWheelIcon in `App/Brand/SpectrumWheelIcon.swift`.
  private func renderProcessingWheel() -> NSImage {
    let size = NSSize(width: 22, height: 22)
    let angle = rotationAngle
    return NSImage(size: size, flipped: false) { rect in
      guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

      let scale = rect.width / 64.0
      let barWidth: CGFloat = 4 * scale
      let cornerRadius: CGFloat = 2 * scale
      let center = rect.width / 2.0

      // 12 radial bars — from SpectrumWheelIcon.bars
      let bars:
        [(deg: Double, yOffset: CGFloat, height: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat)] = [
          (0, 4, 14, 1.0, 0.176, 0.333),
          (30, 7, 10, 1.0, 0.624, 0.039),
          (60, 5, 12, 1.0, 0.839, 0.039),
          (90, 8, 9, 0.188, 0.82, 0.345),
          (120, 4, 14, 0.204, 0.78, 0.349),
          (150, 6, 11, 0.196, 0.847, 0.745),
          (180, 5, 13, 0.392, 0.824, 1.0),
          (210, 8, 9, 0.039, 0.518, 1.0),
          (240, 4, 14, 0.369, 0.361, 0.902),
          (270, 6, 12, 0.749, 0.353, 0.949),
          (300, 7, 10, 1.0, 0.176, 0.333),
          (330, 5, 13, 1.0, 0.624, 0.039),
        ]

      let rotationRad = angle * .pi / 180.0

      for bar in bars {
        ctx.saveGState()

        // Translate to center, apply rotation, then bar's own angle
        ctx.translateBy(x: center, y: center)
        ctx.rotate(by: CGFloat(rotationRad + bar.deg * .pi / 180.0))

        // Bar extends upward from center: offset from center by yOffset, height is bar.height
        let barH = bar.height * scale
        let barY = bar.yOffset * scale
        let barRect = CGRect(x: -barWidth / 2, y: -(center - barY), width: barWidth, height: barH)

        ctx.setFillColor(CGColor(red: bar.r, green: bar.g, blue: bar.b, alpha: 1))
        let path = CGPath(
          roundedRect: barRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
          transform: nil)
        ctx.addPath(path)
        ctx.fillPath()

        ctx.restoreGState()
      }

      return true
    }
  }

  // Shared 9+9 lip geometry (viewBox 0 0 64 64), column index 0…8.
  private static let upperLipBars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
    (4, 22.25, 5), (10, 17.6375, 8), (16, 12.04, 12),
    (22, 16.96, 9), (28, 21.5575, 6), (34, 16.96, 9),
    (40, 12.04, 12), (46, 17.6375, 8), (52, 22.25, 5),
  ]
  private static let lowerLipBars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
    (4, 30.25, 5), (10, 28.6375, 9), (16, 27.04, 12),
    (22, 28.96, 15), (28, 30.5575, 17), (34, 28.96, 15),
    (40, 27.04, 12), (46, 28.6375, 9), (52, 30.25, 5),
  ]

  /// The 9+9 bar geometry's own ink (y 12.04…47.5575 of the 0…64 viewBox) sits
  /// above the viewBox's vertical center (32), so the drawn icon reads as
  /// sitting slightly high in its menu-bar cell. Shift every draw down by this
  /// much (in viewBox units) to recenter the ink, not the geometry itself —
  /// the overlay's own lip geometry (RecordingOverlayPanel) stays unchanged.
  private static let lipsVerticalCenteringOffset: CGFloat = 2.2

  /// Gold intensity (0…1) for a bar at column index `i` of `count` columns,
  /// given the wave front position. Distance is normalized (0 center, 1 edge);
  /// a narrow band → "near-together" wave; the front overshoots to 1.25 so
  /// there is a brief all-grey gap before the next sweep ("fast").
  private static func waveIntensity(columnIndex i: Int, of count: Int, phase: Double) -> CGFloat {
    let center = CGFloat(count - 1) / 2.0  // 4.0 for 9 columns
    let distance = abs(CGFloat(i) - center) / center
    let front = CGFloat(phase) * 1.25
    let band: CGFloat = 0.22
    return max(0, 1 - abs(distance - front) / band)
  }

  /// Render the gold-wave frame for `phase`. Grey lips with gold washing
  /// outward from the center column.
  private func renderUpdatePendingLips(phase: Double) -> NSImage {
    let upper = Self.upperLipBars.indices.map {
      Self.waveIntensity(columnIndex: $0, of: Self.upperLipBars.count, phase: phase)
    }
    let lower = Self.lowerLipBars.indices.map {
      Self.waveIntensity(columnIndex: $0, of: Self.lowerLipBars.count, phase: phase)
    }
    return renderLips(upperIntensities: upper, lowerIntensities: lower)
  }

  /// Reduce-motion fallback: a static, clearly-gold lips (uniform mid blend) so
  /// the "update waiting" meaning still reads without any animation.
  private func renderUpdatePendingStatic() -> NSImage {
    let upper = Self.upperLipBars.map { _ in CGFloat(0.6) }
    let lower = Self.lowerLipBars.map { _ in CGFloat(0.6) }
    return renderLips(upperIntensities: upper, lowerIntensities: lower)
  }

  private static func blendGoldOverGrey(_ t: CGFloat) -> CGColor {
    let r = greyColor.r + (goldColor.r - greyColor.r) * t
    let g = greyColor.g + (goldColor.g - greyColor.g) * t
    let b = greyColor.b + (goldColor.b - greyColor.b) * t
    return CGColor(red: r, green: g, blue: b, alpha: 0.95)
  }

  /// Shared lips renderer: fills the 9+9 bar geometry, coloring each bar by its
  /// precomputed gold intensity. Only `[CGFloat]` (Sendable) crosses into the
  /// drawing block — colors are built inside it.
  private func renderLips(upperIntensities: [CGFloat], lowerIntensities: [CGFloat]) -> NSImage {
    let size = NSSize(width: 22, height: 22)
    return NSImage(size: size, flipped: true) { rect in
      guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
      let scale = rect.width / 64.0
      let barWidth: CGFloat = 4.5 * scale
      let cornerRadius: CGFloat = 1.5 * scale
      ctx.translateBy(x: 0, y: Self.lipsVerticalCenteringOffset * scale)

      for (i, bar) in Self.upperLipBars.enumerated() {
        ctx.setFillColor(Self.blendGoldOverGrey(upperIntensities[i]))
        let barRect = CGRect(
          x: bar.x * scale, y: bar.y * scale, width: barWidth, height: bar.h * scale)
        ctx.addPath(
          CGPath(
            roundedRect: barRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
            transform: nil))
        ctx.fillPath()
      }
      for (i, bar) in Self.lowerLipBars.enumerated() {
        ctx.setFillColor(Self.blendGoldOverGrey(lowerIntensities[i]))
        let barRect = CGRect(
          x: bar.x * scale, y: bar.y * scale, width: barWidth, height: bar.h * scale)
        ctx.addPath(
          CGPath(
            roundedRect: barRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
            transform: nil))
        ctx.fillPath()
      }
      return true
    }
  }
}
