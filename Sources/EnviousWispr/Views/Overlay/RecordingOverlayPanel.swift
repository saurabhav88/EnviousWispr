import AppKit
import SwiftUI

// MARK: - RecordingOverlayPanel

/// Floating overlay panel that shows recording and polishing status.
/// Uses NSPanel with .nonactivatingPanel behavior so it floats above all apps
/// without stealing focus.
@MainActor
final class RecordingOverlayPanel {
    private var panel: NSPanel?

    func show(audioLevelProvider: @escaping () -> Float, modeLabel: String) {
        guard panel == nil else { return }

        // Delay creation to the next run loop cycle.
        // When triggered from an NSStatusItem menu action, the menu dismiss
        // animation is still in progress. Creating an NSHostingView during
        // that animation causes a re-entrant NSWindow layout cycle (SIGABRT).
        DispatchQueue.main.async { [weak self] in
            self?.createPanel(audioLevelProvider: audioLevelProvider, modeLabel: modeLabel)
        }
    }

    /// Show a "Polishing..." overlay during LLM processing.
    func showPolishing() {
        guard panel == nil else {
            // If recording overlay is showing, transition to polishing
            transitionToPolishing()
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.createPolishingPanel()
        }
    }

    private func createPanel(audioLevelProvider: @escaping () -> Float, modeLabel: String) {
        guard panel == nil else { return }

        let overlayView = RecordingOverlayView(audioLevelProvider: audioLevelProvider, modeLabel: modeLabel)
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

        showPanel(content: PolishingOverlayView().frame(width: 152, height: 44), width: 152, y: y)
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

        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - width / 2
            let panelY = y ?? (screen.visibleFrame.maxY - 60)
            p.setFrameOrigin(NSPoint(x: x, y: panelY))
        }

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
    }
}

// MARK: - RainbowLipsIcon

/// Lip/spectrum bar brand icon with a gentle breathe animation.
struct RainbowLipsIcon: View {
    @State private var breathe: CGFloat = 1.0
    let size: CGFloat

    private let upperBars: [(x: CGFloat, y: CGFloat, h: CGFloat, color: Color)] = [
        (4,  14, 14, Color(red: 1.0, green: 0.176, blue: 0.333)),
        (11, 11, 13, Color(red: 1.0, green: 0.624, blue: 0.039)),
        (18, 8,  14, Color(red: 1.0, green: 0.839, blue: 0.039)),
        (25, 12, 10, Color(red: 0.188, green: 0.82, blue: 0.345)),
        (32, 14, 9,  Color(red: 0.204, green: 0.78, blue: 0.349)),
        (39, 11, 11, Color(red: 0.196, green: 0.847, blue: 0.745)),
        (46, 7,  15, Color(red: 0.392, green: 0.824, blue: 1.0)),
        (53, 10, 14, Color(red: 0.039, green: 0.518, blue: 1.0))
    ]

    private let lowerBars: [(x: CGFloat, y: CGFloat, h: CGFloat, color: Color)] = [
        (8,  32, 10, Color(red: 0.369, green: 0.361, blue: 0.902)),
        (15, 30, 14, Color(red: 0.749, green: 0.353, blue: 0.949)),
        (22, 29, 16, Color(red: 1.0, green: 0.176, blue: 0.333)),
        (29, 28, 18, Color(red: 1.0, green: 0.624, blue: 0.039)),
        (36, 29, 16, Color(red: 1.0, green: 0.839, blue: 0.039)),
        (43, 30, 14, Color(red: 0.188, green: 0.82, blue: 0.345)),
        (50, 32, 10, Color(red: 0.204, green: 0.78, blue: 0.349))
    ]

    var body: some View {
        let scale = size / 64.0
        ZStack {
            ForEach(0..<upperBars.count, id: \.self) { i in
                let bar = upperBars[i]
                RoundedRectangle(cornerRadius: 1.5 * scale)
                    .fill(bar.color)
                    .frame(width: 4.5 * scale, height: bar.h * scale)
                    .position(x: (bar.x + 2.25) * scale, y: (bar.y + bar.h / 2) * scale)
            }
            ForEach(0..<lowerBars.count, id: \.self) { i in
                let bar = lowerBars[i]
                RoundedRectangle(cornerRadius: 1.5 * scale)
                    .fill(bar.color)
                    .frame(width: 4.5 * scale, height: bar.h * scale)
                    .position(x: (bar.x + 2.25) * scale, y: (bar.y + bar.h / 2) * scale)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(breathe)
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                breathe = 1.06
            }
        }
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
                        Color(red: 1.0, green: 0.176, blue: 0.333),
                        Color(red: 1.0, green: 0.624, blue: 0.039),
                        Color(red: 1.0, green: 0.839, blue: 0.039),
                        Color(red: 0.188, green: 0.82, blue: 0.345),
                        Color(red: 0.196, green: 0.847, blue: 0.745),
                        Color(red: 0.392, green: 0.824, blue: 1.0),
                        Color(red: 0.039, green: 0.518, blue: 1.0),
                        Color(red: 0.369, green: 0.361, blue: 0.902),
                        Color(red: 0.749, green: 0.353, blue: 0.949),
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
    }
}

// MARK: - RecordingOverlayView

/// Compact recording indicator overlay.
struct RecordingOverlayView: View {
    let audioLevelProvider: () -> Float
    let modeLabel: String
    @State private var audioLevel: Float = 0
    @State private var elapsed: TimeInterval = 0

    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private let startTime = Date()

    var body: some View {
        HStack(spacing: 10) {
            // Spinning spectrum wheel icon
            SpectrumWheelIcon(size: 24)

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
        .onReceive(timer) { _ in
            audioLevel = audioLevelProvider()
            elapsed = Date().timeIntervalSince(startTime)
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
            // Breathing rainbow lips icon
            RainbowLipsIcon(size: 24)

            Text("Polishing...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(OverlayCapsuleBackground())
    }
}
