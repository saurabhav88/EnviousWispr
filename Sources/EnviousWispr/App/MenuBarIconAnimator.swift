import AppKit

/// Manages animated menu bar icon states using Core Graphics rendering.
///
/// Four states: idle (static grey lips), recording (rainbow lips reacting to audio),
/// processing (rotating rainbow spectrum wheel), error (static red lips).
@MainActor
final class MenuBarIconAnimator {

    enum IconState: Equatable {
        case idle
        case recording
        case processing
        case error
    }

    private weak var button: NSStatusBarButton?
    private var idleImage: NSImage?
    private var errorImage: NSImage?
    private var animationTimer: Timer?
    private(set) var currentState: IconState = .idle

    /// Closure providing current mic audio level (0.0–1.0).
    var audioLevelProvider: (() -> Float)?

    // Processing rotation angle (degrees)
    private var rotationAngle: Double = 0

    // MARK: - Configuration

    /// Call once from setupStatusItem() after creating the button.
    func configure(button: NSStatusBarButton, idleImage: NSImage?) {
        self.button = button
        self.idleImage = idleImage
        self.errorImage = renderErrorLips()
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
            startRecordingAnimation()
        case .processing:
            rotationAngle = 0
            startProcessingAnimation()
        case .error:
            button?.image = errorImage
        }
    }

    // MARK: - Timer Management

    private func stopTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    // MARK: - Recording Animation (rainbow lips, audio-reactive, ~20fps)

    private func startRecordingAnimation() {
        // Render one frame immediately
        button?.image = renderRecordingLips(audioLevel: audioLevelProvider?() ?? 0)

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let button = self.button else { return }
                let level = self.audioLevelProvider?() ?? 0
                button.image = self.renderRecordingLips(audioLevel: level)
            }
        }
    }

    // MARK: - Processing Animation (spectrum wheel, rotating, ~15fps)

    private func startProcessingAnimation() {
        button?.image = renderProcessingWheel()

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let button = self.button else { return }
                self.rotationAngle += 3.0 // 360° / 8s / 15fps = 3° per frame
                if self.rotationAngle >= 360 { self.rotationAngle -= 360 }
                button.image = self.renderProcessingWheel()
            }
        }
    }

    // MARK: - Core Graphics Rendering

    /// Render rainbow lip bars with heights responding to audio level.
    /// Bar geometry and colors match RainbowLipsIcon in RecordingOverlayPanel.swift.
    private func renderRecordingLips(audioLevel: Float) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let scale = rect.width / 64.0
            let barWidth: CGFloat = 4.5 * scale
            let cornerRadius: CGFloat = 1.5 * scale
            let level = CGFloat(min(max(audioLevel, 0), 1))

            // Upper bars — v2 9-bar lip geometry (viewBox 0 0 64 64)
            let upperBars: [(x: CGFloat, y: CGFloat, h: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat)] = [
                (4,  22.25,   5,  1.0,   0.165, 0.251),
                (10, 17.6375, 8,  1.0,   0.549, 0.0),
                (16, 12.04,   12, 1.0,   0.843, 0.0),
                (22, 16.96,   9,  0.678, 1.0,   0.184),
                (28, 21.5575, 6,  0.0,   0.98,  0.604),
                (34, 16.96,   9,  0.0,   1.0,   1.0),
                (40, 12.04,   12, 0.118, 0.565, 1.0),
                (46, 17.6375, 8,  0.255, 0.412, 0.882),
                (52, 22.25,   5,  0.541, 0.169, 0.886),
            ]

            // Lower bars — v2 9-bar lip geometry (viewBox 0 0 64 64)
            let lowerBars: [(x: CGFloat, y: CGFloat, h: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat)] = [
                (4,  30.25,   5,  0.255, 0.412, 0.882),
                (10, 28.6375, 9,  0.118, 0.565, 1.0),
                (16, 27.04,   12, 0.0,   1.0,   1.0),
                (22, 28.96,   15, 0.0,   0.98,  0.604),
                (28, 30.5575, 17, 0.678, 1.0,   0.184),
                (34, 28.96,   15, 1.0,   0.843, 0.0),
                (40, 27.04,   12, 1.0,   0.549, 0.0),
                (46, 28.6375, 9,  1.0,   0.165, 0.251),
                (52, 30.25,   5,  0.541, 0.169, 0.886),
            ]

            for (i, bar) in upperBars.enumerated() {
                let groupCenter = CGFloat(upperBars.count - 1) / 2.0  // 4.0
                let centerDistance = abs(CGFloat(i) - groupCenter) / groupCenter
                let baseH = bar.h * scale
                let h = baseH * (0.6 + 0.4 * level * (1.0 - centerDistance * 0.5))
                let x = bar.x * scale
                let y = (bar.y + bar.h) * scale - h // anchor at bottom of original bar
                ctx.setFillColor(CGColor(red: bar.r, green: bar.g, blue: bar.b, alpha: 1))
                let barRect = CGRect(x: x, y: y, width: barWidth, height: h)
                let path = CGPath(roundedRect: barRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            }

            for (i, bar) in lowerBars.enumerated() {
                let groupCenter = CGFloat(lowerBars.count - 1) / 2.0  // 4.0
                let centerDistance = abs(CGFloat(i) - groupCenter) / groupCenter
                let baseH = bar.h * scale
                let h = baseH * (0.6 + 0.4 * level * (1.0 - centerDistance * 0.5))
                let x = bar.x * scale
                let y = bar.y * scale
                ctx.setFillColor(CGColor(red: bar.r, green: bar.g, blue: bar.b, alpha: 1))
                let barRect = CGRect(x: x, y: y, width: barWidth, height: h)
                let path = CGPath(roundedRect: barRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            }

            return true
        }
    }

    /// Render error lips — same geometry as recording but all bars in red.
    private func renderErrorLips() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let scale = rect.width / 64.0
            let barWidth: CGFloat = 4.5 * scale
            let cornerRadius: CGFloat = 1.5 * scale
            let red = CGColor(red: 1.0, green: 0.165, blue: 0.251, alpha: 0.9) // #ff2a40 at 0.9 opacity

            let upperBars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
                (4,  22.25,   5),  (10, 17.6375, 8),  (16, 12.04,   12),
                (22, 16.96,   9),  (28, 21.5575, 6),  (34, 16.96,   9),
                (40, 12.04,   12), (46, 17.6375, 8),  (52, 22.25,   5),
            ]

            let lowerBars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
                (4,  30.25,   5),  (10, 28.6375, 9),  (16, 27.04,   12),
                (22, 28.96,   15), (28, 30.5575, 17), (34, 28.96,   15),
                (40, 27.04,   12), (46, 28.6375, 9),  (52, 30.25,   5),
            ]

            ctx.setFillColor(red)

            for bar in upperBars {
                let barRect = CGRect(x: bar.x * scale, y: bar.y * scale, width: barWidth, height: bar.h * scale)
                let path = CGPath(roundedRect: barRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            }

            for bar in lowerBars {
                let barRect = CGRect(x: bar.x * scale, y: bar.y * scale, width: barWidth, height: bar.h * scale)
                let path = CGPath(roundedRect: barRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            }

            return true
        }
    }

    /// Render the processing spectrum wheel at the current rotation angle.
    /// Bar geometry and colors match SpectrumWheelIcon in RecordingOverlayPanel.swift.
    private func renderProcessingWheel() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let angle = rotationAngle
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let scale = rect.width / 64.0
            let barWidth: CGFloat = 4 * scale
            let cornerRadius: CGFloat = 2 * scale
            let center = rect.width / 2.0

            // 12 radial bars — from SpectrumWheelIcon.bars
            let bars: [(deg: Double, yOffset: CGFloat, height: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat)] = [
                (0,   4,  14, 1.0,   0.176, 0.333),
                (30,  7,  10, 1.0,   0.624, 0.039),
                (60,  5,  12, 1.0,   0.839, 0.039),
                (90,  8,  9,  0.188, 0.82,  0.345),
                (120, 4,  14, 0.204, 0.78,  0.349),
                (150, 6,  11, 0.196, 0.847, 0.745),
                (180, 5,  13, 0.392, 0.824, 1.0),
                (210, 8,  9,  0.039, 0.518, 1.0),
                (240, 4,  14, 0.369, 0.361, 0.902),
                (270, 6,  12, 0.749, 0.353, 0.949),
                (300, 7,  10, 1.0,   0.176, 0.333),
                (330, 5,  13, 1.0,   0.624, 0.039),
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
                let path = CGPath(roundedRect: barRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()

                ctx.restoreGState()
            }

            return true
        }
    }
}
