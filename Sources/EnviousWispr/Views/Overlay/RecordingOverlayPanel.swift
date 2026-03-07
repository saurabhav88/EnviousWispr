import AppKit
import SwiftUI

// MARK: - RecordingOverlayPanel

/// Floating overlay panel that shows recording and polishing status.
/// Uses NSPanel with .nonactivatingPanel behavior so it floats above all apps
/// without stealing focus.
@MainActor
final class RecordingOverlayPanel {
    private var panel: NSPanel?

    /// Monotonically-increasing generation token. Incremented on every show/hide
    /// call. The DispatchQueue.main.async closures capture their token at dispatch
    /// time and bail out silently if a newer operation has superseded them before
    /// they run. This eliminates all "async outlives state" races (H8, H9).
    private var generation: UInt64 = 0

    /// Pending deferred panel-creation work item. Stored so hide() can cancel
    /// it before it fires — this is stronger than the generation check alone,
    /// because it prevents the closure from running at all even when ESC is
    /// pressed within a single run-loop cycle of show().
    private var pendingCreateWork: DispatchWorkItem?

    /// Last intent shown — guards against redundant show calls that would
    /// close and recreate the panel for the same visual state (flicker).
    private var currentIntent: OverlayIntent = .hidden

    // MARK: - Intent-driven API

    /// Unified entry point: render the overlay for the given intent.
    /// Guards against identical intents to prevent flicker.
    func show(intent: OverlayIntent, audioLevelProvider: @escaping () -> Float = { 0 }) {
        guard intent != currentIntent else { return }
        currentIntent = intent
        switch intent {
        case .hidden:
            hide()
        case .recording:
            show(audioLevelProvider: audioLevelProvider)
        case .processing(let label):
            showPolishing(label: label)
        }
    }

    // MARK: - Legacy API (internal)

    func show(audioLevelProvider: @escaping () -> Float) {
        if panel != nil {
            // A panel already exists (e.g., "Starting..." polishing panel).
            // Transition to recording — mirrors transitionToPolishing() in reverse.
            transitionToRecording(audioLevelProvider: audioLevelProvider)
            return
        }
        // Cancel any lingering deferred work from a prior session that wasn't
        // cleaned up (e.g., if a VAD self-cancel left pendingCreateWork set but
        // panel still nil). This is defensive — normally hide() clears it.
        pendingCreateWork?.cancel()
        pendingCreateWork = nil
        generation &+= 1
        let token = generation

        // Delay creation to the next run loop cycle.
        // When triggered from an NSStatusItem menu action, the menu dismiss
        // animation is still in progress. Creating an NSHostingView during
        // that animation causes a re-entrant NSWindow layout cycle (SIGABRT).
        // NOTE: Do NOT replace with Task { @MainActor } — DispatchQueue.main.async
        // guarantees next-run-loop-cycle deferral; Task may execute immediately
        // if already on the main actor.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.pendingCreateWork = nil
            self.createPanel(audioLevelProvider: audioLevelProvider)
        }
        pendingCreateWork = work
        DispatchQueue.main.async(execute: work)
    }

    /// Show a processing overlay with a custom label during model loading, transcription, or LLM polishing.
    func showPolishing(label: String = "Polishing...") {
        guard panel == nil else {
            // If recording overlay is showing, transition to polishing
            transitionToPolishing(label: label)
            return
        }
        // Cancel any prior deferred work defensively before queuing new work.
        pendingCreateWork?.cancel()
        pendingCreateWork = nil
        generation &+= 1
        let token = generation

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.pendingCreateWork = nil
            self.createPolishingPanel(label: label)
        }
        pendingCreateWork = work
        DispatchQueue.main.async(execute: work)
    }

    private func createPanel(audioLevelProvider: @escaping () -> Float, y: CGFloat? = nil) {
        guard panel == nil else { return }

        let overlayView = RecordingOverlayView(audioLevelProvider: audioLevelProvider)
            .frame(width: 185, height: 44)
        showPanel(content: overlayView, width: 185, y: y)
    }

    private func createPolishingPanel(label: String = "Polishing...") {
        guard panel == nil else { return }

        showPanel(content: PolishingOverlayView(label: label).frame(width: 185, height: 44), width: 185)
    }

    /// Transition an existing panel from recording to polishing mode.
    private func transitionToPolishing(label: String = "Polishing...") {
        guard let existingPanel = panel else { return }
        let y = existingPanel.frame.origin.y

        panel = nil
        // Cancel any pre-existing deferred work before queuing new work. Without
        // this, a stale DispatchWorkItem could hold a reference that the new token
        // won't invalidate until it actually runs on the next drain cycle.
        pendingCreateWork?.cancel()
        pendingCreateWork = nil
        // Flush pending CA frames before closing — same use-after-free guard as hide().
        CATransaction.flush()
        existingPanel.close()

        generation &+= 1
        let token = generation

        // Defer to the next run loop cycle so the close animation completes
        // before the new panel appears, preventing a visual flash.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.pendingCreateWork = nil
            self.showPanel(content: PolishingOverlayView(label: label).frame(width: 185, height: 44), width: 185, y: y)
        }
        pendingCreateWork = work
        DispatchQueue.main.async(execute: work)
    }

    /// Transition an existing panel from polishing/processing to recording mode.
    /// Mirrors transitionToPolishing() — tears down the current panel and creates
    /// a recording panel at the same position on the next run loop cycle.
    private func transitionToRecording(audioLevelProvider: @escaping () -> Float) {
        guard let existingPanel = panel else { return }
        let y = existingPanel.frame.origin.y

        panel = nil
        pendingCreateWork?.cancel()
        pendingCreateWork = nil
        CATransaction.flush()
        existingPanel.close()

        generation &+= 1
        let token = generation

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.pendingCreateWork = nil
            self.createPanel(audioLevelProvider: audioLevelProvider, y: y)
        }
        pendingCreateWork = work
        DispatchQueue.main.async(execute: work)
    }

    /// Create and show a floating overlay panel with the given SwiftUI content.
    private func showPanel<V: View>(content: V, width: CGFloat, y: CGFloat? = nil) {
        // Guard against the edge case where no screen is available (C3).
        guard let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main
                ?? NSScreen.screens.first else { return }

        let size = NSRect(x: 0, y: 0, width: width, height: 44)

        let p = NSPanel(
            contentRect: size,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.hasShadow = true

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = size
        p.contentView = hostingView

        let x = targetScreen.visibleFrame.midX - width / 2
        let panelY = y ?? (targetScreen.visibleFrame.maxY - 60)
        p.setFrameOrigin(NSPoint(x: x, y: panelY))

        p.orderFrontRegardless()
        self.panel = p
    }

    func hide() {
        currentIntent = .hidden
        generation &+= 1
        // Cancel any pending deferred panel creation so it never fires.
        // This handles the rapid-ESC race: if hide() is called before the
        // DispatchQueue.main.async closure from show() has had a chance to run,
        // cancelling the work item prevents the panel from being created at all.
        // The generation counter check inside the closure is a secondary guard.
        pendingCreateWork?.cancel()
        pendingCreateWork = nil

        guard let panelToClose = panel else { return }
        panel = nil

        // Flush pending CA transactions before releasing the panel.
        // RecordingOverlayView has a running .task loop updating audioLevel every 50ms
        // and OverlayCapsuleBackground has a repeatForever animation. When close() fires,
        // CA may have a pending implicit transaction trying to render a final frame of
        // the now-deallocating NSHostingView backing layer. Flushing here ensures that
        // frame is committed while the view graph is still alive, preventing the
        // _DictionaryStorage use-after-free in CA::Transaction::commit.
        //
        // We must flush BEFORE close() (not after), because close() begins view teardown.
        // The local `panelToClose` retain keeps the panel alive through the flush.
        CATransaction.flush()
        panelToClose.close()
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
        Canvas { context, size in
            let cx = size.width / 2
            let cy = size.height / 2
            for bar in bars {
                let barW = 4.0 * scale
                let barH = bar.height * scale
                // Bar rect centered on the canvas, offset upward by yOffset so
                // its visual center sits at the correct radial distance.
                let distFromCenter = 32.0 * scale - bar.yOffset * scale - barH / 2
                let rect = CGRect(
                    x: -barW / 2,
                    y: -distFromCenter - barH / 2,
                    width: barW,
                    height: barH
                )
                let cornerRadius = 2.0 * scale
                let barPath = Path(roundedRect: rect, cornerRadius: cornerRadius)
                // Rotate around canvas center by bar's degree offset (converted to radians).
                let angle = bar.deg * .pi / 180.0
                let transform = CGAffineTransform(translationX: cx, y: cy)
                    .rotated(by: angle)
                let rotatedPath = barPath.applying(transform)
                context.fill(rotatedPath, with: .color(bar.color))
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

/// Lip/spectrum bar brand icon driven by real-time audio level during recording.
/// Each of the 18 bars (9 upper + 9 lower) scales vertically in response to
/// `audioLevel` (0.0–1.0). Per-bar variation factors make the motion organic
/// rather than all bars moving in lockstep.
///
/// Scale formula (matches MenuBarIconAnimator.renderRecordingLips):
///   scaleY = silenceScale + (peakScale - silenceScale) * level * perBarFactor
///
/// At silence (level ≈ 0) bars sit at their minimum compressed state (lips closed).
/// At peak (level = 1.0) center bars reach maximum expansion (lips open/talking).
struct RainbowLipsIcon: View {
    let size: CGFloat
    /// Normalised audio level 0.0–1.0, updated every ~50 ms by the parent view.
    let audioLevel: Float

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

    // Per-bar sensitivity multipliers (index 0-8).
    // Center bars (index 4) react most; edge bars react least — mirrors the
    // centerDistance weighting used in MenuBarIconAnimator.renderRecordingLips.
    private let sensitivity: [CGFloat] = [0.70, 0.80, 0.90, 0.95, 1.00, 0.95, 0.90, 0.80, 0.70]

    // Baseline scaleY when audio level is zero (lips lightly closed).
    private let silenceScale: CGFloat = 0.55

    // Maximum additional scaleY headroom above silence (reached at level = 1.0
    // for the most-sensitive bar). Chosen so peak scaleY ≈ 1.45 for center bars.
    private let peakRange: CGFloat = 0.90

    /// Compute the Y scale for a given bar index and the current audio level.
    /// Upper and lower bars share the same formula; the caller may pass a
    /// mirrored index to create counterpoint movement between the two lip halves.
    private func yScale(for barIndex: Int, level: CGFloat) -> CGFloat {
        silenceScale + peakRange * level * sensitivity[barIndex]
    }

    var body: some View {
        let scale = size / 64.0
        let level = CGFloat(min(max(audioLevel, 0), 1))
        Canvas { context, canvasSize in
            // maxSeparation: maximum vertical translation (in points) applied to
            // each lip half at peak audio level. Scaled proportionally with icon size.
            let maxSeparation = 3.5 * scale
            let barW = 4.5 * scale
            let cornerRadius = 1.5 * scale

            // Upper bars — each bar scales from its bottom edge upward and
            // translates upward, giving the upper lip a "rising" motion.
            for i in 0..<upperBars.count {
                let bar = upperBars[i]
                let s = yScale(for: i, level: level)
                let scaledH = bar.h * scale * s
                // Bottom edge of the bar sits at the unscaled bottom position.
                // Original bar bottom (in canvas coords) = (bar.y + bar.h) * scale.
                // Upper-lip separation: shift upward proportional to level.
                let separation = -maxSeparation * level * sensitivity[i]
                let barBottom = (bar.y + bar.h) * scale + separation
                let rect = CGRect(
                    x: bar.x * scale,
                    y: barBottom - scaledH,
                    width: barW,
                    height: scaledH
                )
                let barPath = Path(roundedRect: rect, cornerRadius: cornerRadius)
                context.fill(barPath, with: .color(bar.color))
            }

            // Lower bars — each bar scales from its top edge downward and
            // translates downward, giving the lower lip a "dropping" motion.
            for i in 0..<lowerBars.count {
                let bar = lowerBars[i]
                let s = yScale(for: 8 - i, level: level)
                let scaledH = bar.h * scale * s
                // Top edge of the bar sits at the unscaled top position.
                // Original bar top (in canvas coords) = bar.y * scale.
                // Lower-lip separation: shift downward proportional to level.
                let separation = maxSeparation * level * sensitivity[8 - i]
                let barTop = bar.y * scale + separation
                let rect = CGRect(
                    x: bar.x * scale,
                    y: barTop,
                    width: barW,
                    height: scaledH
                )
                let barPath = Path(roundedRect: rect, cornerRadius: cornerRadius)
                context.fill(barPath, with: .color(bar.color))
            }
        }
        .frame(width: size, height: size)
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
            RainbowLipsIcon(size: 24, audioLevel: audioLevel)

            // Duration timer
            Text(FormattingConstants.formatDuration(elapsed))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
        }
        // Single container animation prevents animation stacking: N per-element
        // modifiers × update rate creates exponential state transitions (gotchas.md).
        .animation(.easeOut(duration: 0.08), value: audioLevel)
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

}

// MARK: - PolishingOverlayView

/// Compact polishing indicator overlay shown during LLM processing.
struct PolishingOverlayView: View {
    var label: String = "Polishing..."

    var body: some View {
        HStack(spacing: 10) {
            // Spinning spectrum wheel icon — polishing/processing state
            SpectrumWheelIcon(size: 24)

            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(OverlayCapsuleBackground())
    }
}

