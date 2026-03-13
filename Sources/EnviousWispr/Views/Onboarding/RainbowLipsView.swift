import SwiftUI
import EnviousWisprCore

// MARK: - LipsAnimationState

enum LipsAnimationState: Equatable {
    case idle        // Gentle breathing scaleY — Step 1 default, Step 4 waiting
    case denied      // Sad/shrunk, desaturated — Step 1 mic denied
    case happy       // Bounce — Step 1 mic granted (one-shot)
    case equalizer   // Audio equalizer bars — Step 2 downloading
    case wave        // Wave propagation — Step 2 download complete (one-shot)
    case drooping    // Droopy, desaturated — Step 2 download failed
    case shimmer     // Brightness pulse — Step 3 AI polish
    case recording   // Fast vigorous equalizer — Step 4 recording
    case pulse       // Gentle synchronized wave — Step 4 processing
    case smile       // Curved smile shape — Step 4 result success
    case triumph     // Explosive bounce + glow — Step 5 all set (one-shot then continuous)
    case heart       // Heart shape + heartbeat pulse — Ready screen
}

// MARK: - Bar Data

private struct LipsBar {
    let index: Int
    let x: CGFloat
    let y: CGFloat
    let height: CGFloat
    let color: Color
    let opacity: Double
    let isUpper: Bool
}

private struct EqBarConfig {
    let minScale: CGFloat
    let maxScale: CGFloat
    let duration: Double
    let delay: Double
}

// MARK: - Static Data

private enum LipsData {
    static let upperBars: [LipsBar] = [
        LipsBar(index: 0, x: 16,  y: 84.2,  height: 20, color: Color(hex: "#ff2a40"), opacity: 0.92, isUpper: true),
        LipsBar(index: 1, x: 40,  y: 65.75, height: 32, color: Color(hex: "#ff8c00"), opacity: 0.92, isUpper: true),
        LipsBar(index: 2, x: 64,  y: 43.36, height: 48, color: Color(hex: "#ffd700"), opacity: 0.92, isUpper: true),
        LipsBar(index: 3, x: 88,  y: 63.04, height: 36, color: Color(hex: "#adff2f"), opacity: 0.92, isUpper: true),
        LipsBar(index: 4, x: 112, y: 81.43, height: 24, color: Color(hex: "#00fa9a"), opacity: 0.92, isUpper: true),
        LipsBar(index: 5, x: 136, y: 63.04, height: 36, color: Color(hex: "#00ffff"), opacity: 0.92, isUpper: true),
        LipsBar(index: 6, x: 160, y: 43.36, height: 48, color: Color(hex: "#1e90ff"), opacity: 0.92, isUpper: true),
        LipsBar(index: 7, x: 184, y: 65.75, height: 32, color: Color(hex: "#4169e1"), opacity: 0.92, isUpper: true),
        LipsBar(index: 8, x: 208, y: 84.2,  height: 20, color: Color(hex: "#8a2be2"), opacity: 0.92, isUpper: true),
    ]

    static let lowerBars: [LipsBar] = [
        LipsBar(index: 0, x: 16,  y: 125.8,  height: 20, color: Color(hex: "#4169e1"), opacity: 0.88, isUpper: false),
        LipsBar(index: 1, x: 40,  y: 119.35, height: 36, color: Color(hex: "#1e90ff"), opacity: 0.88, isUpper: false),
        LipsBar(index: 2, x: 64,  y: 112.96, height: 48, color: Color(hex: "#00ffff"), opacity: 0.88, isUpper: false),
        LipsBar(index: 3, x: 88,  y: 120.64, height: 60, color: Color(hex: "#00fa9a"), opacity: 0.88, isUpper: false),
        LipsBar(index: 4, x: 112, y: 127.03, height: 68, color: Color(hex: "#adff2f"), opacity: 0.88, isUpper: false),
        LipsBar(index: 5, x: 136, y: 120.64, height: 60, color: Color(hex: "#ffd700"), opacity: 0.88, isUpper: false),
        LipsBar(index: 6, x: 160, y: 112.96, height: 48, color: Color(hex: "#ff8c00"), opacity: 0.88, isUpper: false),
        LipsBar(index: 7, x: 184, y: 119.35, height: 36, color: Color(hex: "#ff2a40"), opacity: 0.88, isUpper: false),
        LipsBar(index: 8, x: 208, y: 125.8,  height: 20, color: Color(hex: "#8a2be2"), opacity: 0.88, isUpper: false),
    ]

    static let allBars: [LipsBar] = upperBars + lowerBars

    // Idle: per-bar delay
    static let idleDelays: [Double] = [0.0, 0.1, 0.2, 0.15, 0.05, 0.25, 0.3, 0.1, 0.2]

    // Equalizer configs (energetic — wider range, faster cycles)
    static let eqConfigs: [EqBarConfig] = [
        EqBarConfig(minScale: 0.35, maxScale: 1.25, duration: 0.36, delay: 0.0),
        EqBarConfig(minScale: 0.25, maxScale: 1.20, duration: 0.42, delay: 0.07),
        EqBarConfig(minScale: 0.50, maxScale: 1.35, duration: 0.30, delay: 0.14),
        EqBarConfig(minScale: 0.30, maxScale: 1.25, duration: 0.48, delay: 0.05),
        EqBarConfig(minScale: 0.40, maxScale: 1.30, duration: 0.35, delay: 0.11),
        EqBarConfig(minScale: 0.35, maxScale: 1.20, duration: 0.45, delay: 0.03),
        EqBarConfig(minScale: 0.55, maxScale: 1.25, duration: 0.33, delay: 0.18),
        EqBarConfig(minScale: 0.30, maxScale: 1.25, duration: 0.39, delay: 0.08),
        EqBarConfig(minScale: 0.35, maxScale: 1.25, duration: 0.43, delay: 0.13),
    ]

    // Recording configs (fast, wide range)
    static let recConfigs: [EqBarConfig] = [
        EqBarConfig(minScale: 0.4,  maxScale: 1.3,  duration: 0.22, delay: 0.0),
        EqBarConfig(minScale: 0.3,  maxScale: 1.2,  duration: 0.27, delay: 0.03),
        EqBarConfig(minScale: 0.6,  maxScale: 1.4,  duration: 0.19, delay: 0.07),
        EqBarConfig(minScale: 0.4,  maxScale: 1.3,  duration: 0.31, delay: 0.02),
        EqBarConfig(minScale: 0.5,  maxScale: 1.35, duration: 0.24, delay: 0.05),
        EqBarConfig(minScale: 0.35, maxScale: 1.25, duration: 0.28, delay: 0.01),
        EqBarConfig(minScale: 0.65, maxScale: 1.3,  duration: 0.21, delay: 0.09),
        EqBarConfig(minScale: 0.4,  maxScale: 1.2,  duration: 0.25, delay: 0.04),
        EqBarConfig(minScale: 0.45, maxScale: 1.25, duration: 0.29, delay: 0.06),
    ]

    // Shimmer: per-bar delay (symmetric, edges to center)
    static let shimmerDelays: [Double] = [0.0, 0.2, 0.4, 0.6, 0.8, 0.6, 0.4, 0.2, 0.0]

    // Pulse: per-bar delay (symmetric, edges to center)
    static let pulseDelays: [Double] = [0.0, 0.06, 0.12, 0.18, 0.22, 0.18, 0.12, 0.06, 0.0]

    // Wave: per-bar delay (edges fire first, center last)
    static let waveDelays: [Double] = [0.0, 0.06, 0.12, 0.18, 0.24, 0.18, 0.12, 0.06, 0.0]

    // Happy: per-bar delay (symmetric from edges)
    static let happyDelays: [Double] = [0.0, 0.04, 0.08, 0.06, 0.02, 0.06, 0.08, 0.04, 0.0]

    // Triumph: per-bar delay (symmetric from edges)
    static let triumphDelays: [Double] = [0.0, 0.05, 0.1, 0.15, 0.18, 0.15, 0.1, 0.05, 0.0]

    // Smile: static scale multipliers
    static let smileUpperScales: [CGFloat] = [1.3, 1.1, 1.0, 1.0, 0.6, 1.0, 1.0, 1.1, 1.3]
    static let smileLowerScales: [CGFloat] = [0.5, 1.0, 1.0, 1.3, 1.3, 1.3, 1.0, 1.0, 0.5]

    // Heart: upper bars form two humps (♥ top), lower bars form V-point (♥ bottom)
    static let heartUpperScales: [CGFloat] = [0.3, 1.0, 1.4, 1.0, 0.4, 1.0, 1.4, 1.0, 0.3]
    static let heartLowerScales: [CGFloat] = [0.15, 0.4, 0.7, 1.1, 1.5, 1.1, 0.7, 0.4, 0.15]
}

// MARK: - RainbowLipsView

struct RainbowLipsView: View {
    var animationState: LipsAnimationState = .idle
    private var expression: LipsAnimationState { animationState }
    var size: CGFloat = 70.0

    // Captured when expression changes — for one-shot animations
    @State private var expressionStartTime: Date = Date()
    // Global desaturation/brightness for denied/drooping
    @State private var globalSaturation: Double = 1.0
    @State private var globalBrightness: Double = 0.0
    // Glow state for triumph
    @State private var glowOpacity: Double = 0.0
    @State private var glowRadius: Double = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let elapsed = timeline.date.timeIntervalSince(expressionStartTime)

            ZStack {
                // Glow layer (blurred duplicate) — triumph and ambient
                if glowOpacity > 0 {
                    drawLipsCanvas(t: t, elapsed: elapsed)
                        .blur(radius: CGFloat(glowRadius))
                        .opacity(glowOpacity * 0.5)
                }

                // Sharp foreground layer
                drawLipsCanvas(t: t, elapsed: elapsed)
            }
            .saturation(globalSaturation)
            .brightness(globalBrightness)
            .shadow(
                color: Color(hex: "#7c3aed").opacity(glowOpacity * 0.4),
                radius: CGFloat(glowRadius)
            )
        }
        .frame(width: size, height: size)
        .onAppear {
            expressionStartTime = Date()
            applyGlobalModifiers(for: animationState)
        }
        .onChange(of: animationState) { _, newExpression in
            expressionStartTime = Date()
            glowOpacity = 0.0
            glowRadius = 0.0
            applyGlobalModifiers(for: newExpression)

            // Heart gets a warm glow immediately
            if newExpression == .heart {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        glowOpacity = 0.45
                        glowRadius = 10.0
                    }
                }
            }

            // Schedule triumph glow phase after the one-shot bounce completes
            if newExpression == .triumph {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        glowOpacity = 0.5
                        glowRadius = 8.0
                    }
                }
            }
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private func drawLipsCanvas(t: Double, elapsed: Double) -> some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 256.0
            context.translateBy(x: 8 * scale, y: 13 * scale)

            for bar in LipsData.allBars {
                let scaleY = computeScale(for: bar, t: t, elapsed: elapsed)
                let shimmerVals = computeShimmer(for: bar, t: t)

                let rectX = bar.x * scale
                let rectY = bar.y * scale
                let rectW: CGFloat = 14 * scale
                let rectH = bar.height * scale
                let rect = CGRect(x: rectX, y: rectY, width: rectW, height: rectH)

                // Transform anchor: upper bars from bottom, lower bars from top
                let anchorY: CGFloat = bar.isUpper ? (rectY + rectH) : rectY

                context.drawLayer { ctx in
                    ctx.translateBy(x: rectX + rectW / 2, y: anchorY)
                    ctx.scaleBy(x: 1.0, y: scaleY)
                    ctx.translateBy(x: -(rectX + rectW / 2), y: -anchorY)

                    let path = Path(roundedRect: rect, cornerRadius: 5 * scale)
                    let opacity = bar.opacity * shimmerVals.opacity
                    ctx.fill(path, with: .color(bar.color.opacity(opacity)))

                    // Simulate brightness increase via white overlay
                    if shimmerVals.brightness > 0 {
                        let brightOverlay = Color.white.opacity(shimmerVals.brightness * 0.35)
                        ctx.fill(path, with: .color(brightOverlay))
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Scale Computation (time-math, no per-bar @State)

    private func computeScale(for bar: LipsBar, t: Double, elapsed: Double) -> CGFloat {
        let i = bar.index
        switch expression {

        case .idle:
            let delay = LipsData.idleDelays[i]
            let phase = ((t - delay).truncatingRemainder(dividingBy: 2.8)) / 2.8
            // 1.0 → 0.78 → 1.0, using abs(sin) for a smooth V-shaped oscillation
            return 1.0 - 0.22 * CGFloat(abs(sin(phase * .pi)))

        case .denied:
            // Upper: oscillate 0.45 ↔ 0.38, Lower: 0.35 ↔ 0.28
            let phase = t.truncatingRemainder(dividingBy: 3.0) / 3.0
            let osc = CGFloat(abs(sin(phase * .pi)))
            return bar.isUpper ? (0.45 - 0.07 * osc) : (0.35 - 0.07 * osc)

        case .happy:
            let delay = LipsData.happyDelays[i]
            let localT = max(0, elapsed - delay)
            return oneShotBounce(localT: localT, duration: 0.6, peakScale: bar.isUpper ? 1.25 : 1.2)

        case .equalizer:
            // DNA double helix: two waves sweep across bars in opposite phase.
            // ~1.5 visible wavelengths across 9 bars + fast sweep = clear propagation.
            let spatialFreq = 3.0 * .pi / 9.0   // 1.5 wavelengths across 9 bars
            let temporalFreq = 5.0                // fast sweep — clearly visible motion
            let phaseOffset: Double = bar.isUpper ? 0 : .pi  // upper/lower 180° out of phase
            let sinVal = sin(Double(i) * spatialFreq - t * temporalFreq + phaseOffset)
            let minScale: CGFloat = 0.15
            let maxScale: CGFloat = 1.45
            return minScale + (maxScale - minScale) * CGFloat(0.5 + 0.5 * sinVal)

        case .wave:
            let delay = LipsData.waveDelays[i]
            let localT = max(0, elapsed - delay)
            return oneShotWave(localT: localT)

        case .drooping:
            let phase = t.truncatingRemainder(dividingBy: 2.5) / 2.5
            return 0.3 - 0.05 * CGFloat(abs(sin(phase * .pi)))

        case .shimmer:
            // No scale change — bars hold static shape, only brightness/opacity varies
            return 1.0

        case .recording:
            let cfg = LipsData.recConfigs[i]
            let phase = ((t - cfg.delay).truncatingRemainder(dividingBy: cfg.duration)) / cfg.duration
            return cfg.minScale + (cfg.maxScale - cfg.minScale) * CGFloat(0.5 + 0.5 * sin(phase * .pi * 2))

        case .pulse:
            let delay = LipsData.pulseDelays[i]
            let phase = ((t - delay).truncatingRemainder(dividingBy: 1.1)) / 1.1
            // 0.7 ↔ 1.1
            return 0.7 + 0.4 * CGFloat(0.5 + 0.5 * sin(phase * .pi * 2))

        case .smile:
            let phase = t.truncatingRemainder(dividingBy: 2.2) / 2.2
            let animatedScale = 0.9 + 0.15 * CGFloat(0.5 + 0.5 * sin(phase * .pi * 2))
            let staticScale = bar.isUpper
                ? LipsData.smileUpperScales[i]
                : LipsData.smileLowerScales[i]
            return staticScale * animatedScale

        case .heart:
            // Heart shape with "lub-dub" heartbeat pulse (1.2s cycle)
            let baseScale = bar.isUpper
                ? LipsData.heartUpperScales[i]
                : LipsData.heartLowerScales[i]
            let cycle = 1.2
            let phase = t.truncatingRemainder(dividingBy: cycle)
            let beat: CGFloat
            if phase < 0.08 {
                // "Lub" — quick scale up
                beat = 1.0 + 0.20 * CGFloat(easeOut(phase / 0.08))
            } else if phase < 0.18 {
                // Return with slight undershoot
                beat = 1.20 - 0.25 * CGFloat(easeInOut((phase - 0.08) / 0.10))
            } else if phase < 0.30 {
                // Settle back
                beat = 0.95 + 0.05 * CGFloat(easeInOut((phase - 0.18) / 0.12))
            } else if phase < 0.38 {
                // "Dub" — small secondary pulse
                beat = 1.0 + 0.10 * CGFloat(easeOut((phase - 0.30) / 0.08))
            } else if phase < 0.48 {
                // Return to rest
                beat = 1.10 - 0.10 * CGFloat(easeInOut((phase - 0.38) / 0.10))
            } else {
                // Rest
                beat = 1.0
            }
            return baseScale * beat

        case .triumph:
            let delay = LipsData.triumphDelays[i]
            let localT = max(0, elapsed - delay)
            if localT >= 0.9 {
                // Settled into celebratory breath at 1.1
                let settledPhase = (localT - 0.9).truncatingRemainder(dividingBy: 2.0) / 2.0
                return 1.1 + 0.10 * CGFloat(sin(settledPhase * .pi * 2))
            }
            return oneShotTriumph(localT: localT)
        }
    }

    // MARK: - Shimmer

    private struct ShimmerVals {
        var opacity: Double
        var brightness: Double
    }

    private func computeShimmer(for bar: LipsBar, t: Double) -> ShimmerVals {
        guard expression == .shimmer else { return ShimmerVals(opacity: 1.0, brightness: 0.0) }
        let delay = LipsData.shimmerDelays[bar.index]
        let phase = ((t - delay).truncatingRemainder(dividingBy: 1.8)) / 1.8
        let sinVal = sin(phase * .pi * 2)
        let brightness = sinVal > 0 ? sinVal * 0.4 : 0.0  // 0.0 → +0.4 peak
        let opacity = 0.92 + sinVal * 0.08                // 0.92 → 1.0 peak
        return ShimmerVals(opacity: max(0.82, opacity), brightness: brightness)
    }

    // MARK: - Global Modifiers

    private func applyGlobalModifiers(for expr: LipsAnimationState) {
        switch expr {
        case .denied:
            withAnimation(.easeInOut(duration: 0.5)) {
                globalSaturation = 0.25
                globalBrightness = -0.15
            }
        case .drooping:
            withAnimation(.easeInOut(duration: 0.7)) {
                globalSaturation = 0.2
                globalBrightness = -0.25
            }
        default:
            withAnimation(.easeInOut(duration: 0.4)) {
                globalSaturation = 1.0
                globalBrightness = 0.0
            }
        }
    }

    // MARK: - One-Shot Easing Helpers

    /// Bounce: 1.0 → peakScale (overshoot) → 0.95 → 1.1 → 1.0
    private func oneShotBounce(localT: Double, duration: Double, peakScale: CGFloat) -> CGFloat {
        let p = min(localT / duration, 1.0)
        switch p {
        case ..<0.30:
            return 1.0 + (peakScale - 1.0) * CGFloat(easeOut(p / 0.30))
        case ..<0.55:
            return peakScale - (peakScale - 0.95) * CGFloat(easeInOut((p - 0.30) / 0.25))
        case ..<0.75:
            return 0.95 + 0.15 * CGFloat(easeInOut((p - 0.55) / 0.20))
        default:
            return 1.10 - 0.10 * CGFloat(easeInOut((p - 0.75) / 0.25))
        }
    }

    /// Wave: 0.4 → 1.2 (overshoot) → 0.9 → 1.0
    private func oneShotWave(localT: Double) -> CGFloat {
        let p = min(localT / 0.8, 1.0)
        switch p {
        case ..<0.40:
            return 0.4 + 0.8 * CGFloat(easeOut(p / 0.40))
        case ..<0.70:
            return 1.2 - 0.3 * CGFloat(easeInOut((p - 0.40) / 0.30))
        default:
            return 0.9 + 0.1 * CGFloat(easeInOut((p - 0.70) / 0.30))
        }
    }

    /// Triumph: 0.5 → 1.35 → 1.05 → 1.2 → 1.1
    private func oneShotTriumph(localT: Double) -> CGFloat {
        let p = min(localT / 0.9, 1.0)
        switch p {
        case ..<0.40:
            return 0.5 + 0.85 * CGFloat(easeOut(p / 0.40))
        case ..<0.65:
            return 1.35 - 0.30 * CGFloat(easeInOut((p - 0.40) / 0.25))
        case ..<0.80:
            return 1.05 + 0.15 * CGFloat(easeInOut((p - 0.65) / 0.15))
        default:
            return 1.20 - 0.10 * CGFloat(easeInOut((p - 0.80) / 0.20))
        }
    }

    private func easeOut(_ t: Double) -> Double {
        1.0 - pow(1.0 - t, 3.0)
    }

    private func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
