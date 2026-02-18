import AppKit
import SwiftUI

// MARK: - RecordingOverlayPanel

/// Floating overlay panel that shows recording status.
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
        DispatchQueue.main.async { [weak self] in
            self?.createPanel(audioLevelProvider: audioLevelProvider)
        }
    }

    private func createPanel(audioLevelProvider: @escaping () -> Float) {
        guard panel == nil else { return }

        let size = NSRect(x: 0, y: 0, width: 180, height: 44)

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

        // Fix content size to prevent NSHostingView from triggering
        // animated window resizes that cause layout cycle exceptions.
        let overlayView = RecordingOverlayView(audioLevelProvider: audioLevelProvider)
            .frame(width: 180, height: 44)
        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = size
        p.contentView = hostingView

        // Position at top-center of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 90
            let y = screenFrame.maxY - 60
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        p.orderFrontRegardless()
        self.panel = p
    }

    func hide() {
        panel?.close()
        panel = nil
    }

    var isVisible: Bool { panel != nil }
}

// MARK: - RecordingOverlayView

/// Compact recording indicator overlay.
struct RecordingOverlayView: View {
    let audioLevelProvider: () -> Float
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
            Text(formatDuration(elapsed))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
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

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
