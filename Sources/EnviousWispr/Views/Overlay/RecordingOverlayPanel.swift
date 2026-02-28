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
            .frame(width: 220, height: 44)
        showPanel(content: overlayView, width: 220)
    }

    private func createPolishingPanel() {
        guard panel == nil else { return }

        showPanel(content: PolishingOverlayView().frame(width: 160, height: 44), width: 160)
    }

    /// Transition an existing panel from recording to polishing mode.
    private func transitionToPolishing() {
        guard let existingPanel = panel else { return }
        let y = existingPanel.frame.origin.y

        existingPanel.close()
        panel = nil

        showPanel(content: PolishingOverlayView().frame(width: 160, height: 44), width: 160, y: y)
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

// MARK: - RecordingOverlayView

/// Compact recording indicator overlay.
struct RecordingOverlayView: View {
    let audioLevelProvider: () -> Float
    let modeLabel: String
    @State private var audioLevel: Float = 0
    @State private var elapsed: TimeInterval = 0
    @State private var pulseAnimation = false

    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private let startTime = Date()

    var body: some View {
        HStack(spacing: 8) {
            // Pulsing red dot
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .scaleEffect(pulseAnimation ? 1.2 : 0.8)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulseAnimation)

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

            // Mode separator + label
            Rectangle()
                .fill(.white.opacity(0.3))
                .frame(width: 1, height: 16)

            Text(modeLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.black.opacity(0.75))
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                )
        )
        .onAppear { pulseAnimation = true }
        .onReceive(timer) { _ in
            audioLevel = audioLevelProvider()
            elapsed = Date().timeIntervalSince(startTime)
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let normalized = CGFloat(audioLevel)
        let center: CGFloat = 2.0
        let distance = abs(CGFloat(index) - center) / center
        let base: CGFloat = 3
        let maxH: CGFloat = 18
        return base + (maxH - base) * normalized * (1.0 - distance * 0.5)
    }

}

// MARK: - PolishingOverlayView

/// Compact polishing indicator overlay shown during LLM processing.
struct PolishingOverlayView: View {
    @State private var pulseAnimation = false

    var body: some View {
        HStack(spacing: 8) {
            // Pulsing blue dot
            Circle()
                .fill(.blue)
                .frame(width: 10, height: 10)
                .scaleEffect(pulseAnimation ? 1.2 : 0.8)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulseAnimation)

            Text("Polishing...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.black.opacity(0.75))
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                )
        )
        .onAppear { pulseAnimation = true }
    }
}
