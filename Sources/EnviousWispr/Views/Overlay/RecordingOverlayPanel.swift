import AppKit
import SwiftUI

// MARK: - RecordingOverlayPanel

/// Floating overlay panel that shows recording and polishing status.
/// Uses NSPanel with .nonactivatingPanel behavior so it floats above all apps
/// without stealing focus.
@MainActor
final class RecordingOverlayPanel {
    private var panel: NSPanel?

    func show(audioLevelProvider: @escaping () -> Float) {
        guard panel == nil else { return }

        // Delay creation to the next run loop cycle.
        // When triggered from an NSStatusItem menu action, the menu dismiss
        // animation is still in progress. Creating an NSHostingView during
        // that animation causes a re-entrant NSWindow layout cycle (SIGABRT).
        Task { @MainActor [weak self] in
            self?.createPanel(audioLevelProvider: audioLevelProvider)
        }
    }

    /// Show a "Polishing..." overlay during LLM processing.
    func showPolishing() {
        guard panel == nil else {
            // If recording overlay is showing, transition to polishing
            transitionToPolishing()
            return
        }

        Task { @MainActor [weak self] in
            self?.createPolishingPanel()
        }
    }

    private func createPanel(audioLevelProvider: @escaping () -> Float) {
        guard panel == nil else { return }

        let overlayView = RecordingOverlayView(audioLevelProvider: audioLevelProvider)
            .frame(width: 185, height: 44)
        showPanel(content: overlayView, width: 185)
    }

    private func createPolishingPanel() {
        guard panel == nil else { return }

        showPanel(content: PolishingOverlayView().frame(width: 152, height: 44), width: 152)
    }

    /// Transition an existing panel from recording to polishing mode.
    private func transitionToPolishing() {
        guard let existingPanel = panel else { return }
        let y = existingPanel.frame.origin.y

        existingPanel.close()
        panel = nil

        // Defer to the next run loop cycle so the close animation completes
        // before the new panel appears, preventing a visual flash.
        Task { @MainActor [weak self] in
            self?.showPanel(content: PolishingOverlayView().frame(width: 152, height: 44), width: 152, y: y)
        }
    }

    /// Create and show a floating overlay panel with the given SwiftUI content.
    private func showPanel<V: View>(content: V, width: CGFloat, y: CGFloat? = nil) {
        let size = NSRect(x: 0, y: 0, width: width, height: 44)

        let p = NSPanel(
            contentRect: size,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.hasShadow = true

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = size
        p.contentView = hostingView

        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let x = targetScreen.visibleFrame.midX - width / 2
        let panelY = y ?? (targetScreen.visibleFrame.maxY - 60)
        p.setFrameOrigin(NSPoint(x: x, y: panelY))

        p.orderFrontRegardless()
        self.panel = p
    }

    func hide() {
        panel?.close()
        panel = nil
    }
}

// MARK: - SpectrumWheelIcon

/// 12 rainbow-colored bars arranged radially, spinning slowly.
struct SpectrumWheelIcon: View {
    @State private var rotation: Double = 0
    let size: CGFloat

    private let bars: [(deg: Double, yOffset: CGFloat, height: CGFloat, color: Color)] = [
        (0,   4,  14, Color(red: 1.0, green: 0.176, blue: 0.333)),
        (30,  7,  10, Color(red: 1.0, green: 0.624, blue: 0.039)),
        (60,  5,  12, Color(red: 1.0, green: 0.839, blue: 0.039)),
        (90,  8,  9,  Color(red: 0.188, green: 0.82, blue: 0.345)),
        (120, 4,  14, Color(red: 0.204, green: 0.78, blue: 0.349)),
        (150, 6,  11, Color(red: 0.196, green: 0.847, blue: 0.745)),
        (180, 5,  13, Color(red: 0.392, green: 0.824, blue: 1.0)),
        (210, 8,  9,  Color(red: 0.039, green: 0.518, blue: 1.0)),
        (240, 4,  14, Color(red: 0.369, green: 0.361, blue: 0.902)),
        (270, 6,  12, Color(red: 0.749, green: 0.353, blue: 0.949)),
        (300, 7,  10, Color(red: 1.0, green: 0.176, blue: 0.333)),
        (330, 5,  13, Color(red: 1.0, green: 0.624, blue: 0.039))
    ]

    var body: some View {
        // Scale factor: SVG viewBox is 64x64, we map to `size`
        let scale = size / 64.0
        ZStack {
            ForEach(0..<bars.count, id: \.self) { i in
                let bar = bars[i]
                RoundedRectangle(cornerRadius: 2 * scale)
                    .fill(bar.color)
                    .frame(width: 4 * scale, height: bar.height * scale)
                    .offset(y: -(32 * scale - bar.yOffset * scale - bar.height * scale / 2))
                    .rotationEffect(.degrees(bar.deg))
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(rotation))
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - RainbowLipsIcon

/// Lip/spectrum bar brand icon with per-bar bounce animation during recording.
/// Each of the 18 bars (9 upper + 9 lower) independently stretches and compresses
/// vertically at a staggered speed, creating an organic "speaking" motion.
struct RainbowLipsIcon: View {
    let size: CGFloat
    @State private var animate = false

    private let upperBars: [(x: CGFloat, y: CGFloat, h: CGFloat, color: Color)] = [
        (4,  22.25,   5,  Color(red: 1.0,   green: 0.165, blue: 0.251)),
        (10, 17.6375, 8,  Color(red: 1.0,   green: 0.549, blue: 0.0)),
        (16, 12.04,   12, Color(red: 1.0,   green: 0.843, blue: 0.0)),
        (22, 16.96,   9,  Color(red: 0.678, green: 1.0,   blue: 0.184)),
        (28, 21.5575, 6,  Color(red: 0.0,   green: 0.98,  blue: 0.604)),
        (34, 16.96,   9,  Color(red: 0.0,   green: 1.0,   blue: 1.0)),
        (40, 12.04,   12, Color(red: 0.118, green: 0.565, blue: 1.0)),
        (46, 17.6375, 8,  Color(red: 0.255, green: 0.412, blue: 0.882)),
        (52, 22.25,   5,  Color(red: 0.541, green: 0.169, blue: 0.886))
    ]

    private let lowerBars: [(x: CGFloat, y: CGFloat, h: CGFloat, color: Color)] = [
        (4,  30.25,   5,  Color(red: 0.255, green: 0.412, blue: 0.882)),
        (10, 28.6375, 9,  Color(red: 0.118, green: 0.565, blue: 1.0)),
        (16, 27.04,   12, Color(red: 0.0,   green: 1.0,   blue: 1.0)),
        (22, 28.96,   15, Color(red: 0.0,   green: 0.98,  blue: 0.604)),
        (28, 30.5575, 17, Color(red: 0.678, green: 1.0,   blue: 0.184)),
        (34, 28.96,   15, Color(red: 1.0,   green: 0.843, blue: 0.0)),
        (40, 27.04,   12, Color(red: 1.0,   green: 0.549, blue: 0.0)),
        (46, 28.6375, 9,  Color(red: 1.0,   green: 0.165, blue: 0.251)),
        (52, 30.25,   5,  Color(red: 0.541, green: 0.169, blue: 0.886))
    ]

    // Minimum scaleY for each bar index 0-8 (edge bars move less, center more).
    private let minScales: [CGFloat] = [0.65, 0.70, 0.62, 0.75, 0.60, 0.75, 0.62, 0.70, 0.65]

    // Maximum scaleY for each bar index 0-8 (center bars have larger amplitude).
    private let maxScales: [CGFloat] = [1.25, 1.35, 1.42, 1.38, 1.50, 1.38, 1.42, 1.35, 1.25]

    // Animation duration (seconds) per bar — staggered so no two bars move in sync.
    private let durations: [Double] = [0.50, 0.62, 0.45, 0.70, 0.55, 0.68, 0.47, 0.60, 0.52]

    var body: some View {
        let scale = size / 64.0
        ZStack {
            ForEach(0..<upperBars.count, id: \.self) { i in
                let bar = upperBars[i]
                RoundedRectangle(cornerRadius: 1.5 * scale)
                    .fill(bar.color)
                    .frame(width: 4.5 * scale, height: bar.h * scale)
                    .scaleEffect(
                        y: animate ? maxScales[i] : minScales[i],
                        anchor: .center
                    )
                    .position(x: (bar.x + 2.25) * scale, y: (bar.y + bar.h / 2) * scale)
                    .animation(
                        .easeInOut(duration: durations[i])
                            .repeatForever(autoreverses: true),
                        value: animate
                    )
            }
            ForEach(0..<lowerBars.count, id: \.self) { i in
                let bar = lowerBars[i]
                RoundedRectangle(cornerRadius: 1.5 * scale)
                    .fill(bar.color)
                    .frame(width: 4.5 * scale, height: bar.h * scale)
                    .scaleEffect(
                        // Lower bars use the mirror index so they bounce in
                        // counterpoint to the upper bars — outer bars move less.
                        y: animate ? maxScales[8 - i] : minScales[8 - i],
                        anchor: .center
                    )
                    .position(x: (bar.x + 2.25) * scale, y: (bar.y + bar.h / 2) * scale)
                    .animation(
                        // Offset the duration slightly from the upper bar above it
                        // so they don't perfectly cancel each other out.
                        .easeInOut(duration: durations[8 - i] * 1.15)
                            .repeatForever(autoreverses: true),
                        value: animate
                    )
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            animate = true
        }
        .accessibilityHidden(true)
    }
}

// MARK: - OverlayCapsuleBackground

/// Shared capsule background with warmer dark fill, subtle border, and a
/// rainbow gradient line pulsing along the bottom edge.
private struct OverlayCapsuleBackground: View {
    @State private var glowOpacity: Double = 0.3

    var body: some View {
        Capsule()
            .fill(Color(red: 0.078, green: 0.078, blue: 0.11).opacity(0.82))
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
            )
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        .clear,
                        Color(red: 1.0,   green: 0.165, blue: 0.251), // #ff2a40 red
                        Color(red: 1.0,   green: 0.549, blue: 0.0),   // #ff8c00 orange
                        Color(red: 1.0,   green: 0.843, blue: 0.0),   // #ffd700 yellow
                        Color(red: 0.678, green: 1.0,   blue: 0.184), // #adff2f yellow-green
                        Color(red: 0.0,   green: 0.98,  blue: 0.604), // #00fa9a mint
                        Color(red: 0.0,   green: 1.0,   blue: 1.0),   // #00ffff cyan
                        Color(red: 0.118, green: 0.565, blue: 1.0),   // #1e90ff dodger blue
                        Color(red: 0.255, green: 0.412, blue: 0.882), // #4169e1 royal blue
                        Color(red: 0.541, green: 0.169, blue: 0.886), // #8a2be2 purple
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
                .opacity(glowOpacity)
                .padding(.horizontal, 20)
                .offset(y: -1)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                    glowOpacity = 0.65
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - RecordingOverlayView

/// Compact recording indicator overlay.
struct RecordingOverlayView: View {
    let audioLevelProvider: () -> Float
    @State private var audioLevel: Float = 0
    @State private var elapsed: TimeInterval = 0

    private let startTime = Date()

    var body: some View {
        HStack(spacing: 10) {
            // Rainbow lips icon — audio-reactive during recording
            RainbowLipsIcon(size: 24)

            // Mini waveform (5 bars)
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(0.9))
                        .frame(width: 3, height: barHeight(for: i))
                }
            }
            .frame(height: 20)

            // Duration timer
            Text(FormattingConstants.formatDuration(elapsed))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(OverlayCapsuleBackground())
        .task {
            while !Task.isCancelled {
                audioLevel = audioLevelProvider()
                elapsed = Date().timeIntervalSince(startTime)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let normalized = CGFloat(audioLevel)
        let center: CGFloat = 2.0
        let distance = abs(CGFloat(index) - center) / center
        let base: CGFloat = 2
        let maxH: CGFloat = 22
        return base + (maxH - base) * normalized * (1.0 - distance * 0.5)
    }
}

// MARK: - PolishingOverlayView

/// Compact polishing indicator overlay shown during LLM processing.
struct PolishingOverlayView: View {
    var body: some View {
        HStack(spacing: 10) {
            // Spinning spectrum wheel icon — polishing/processing state
            SpectrumWheelIcon(size: 24)

            Text("Polishing...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(OverlayCapsuleBackground())
    }
}
