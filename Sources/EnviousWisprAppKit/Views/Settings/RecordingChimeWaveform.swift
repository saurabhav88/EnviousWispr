import AVFoundation
import EnviousWisprCore
import SwiftUI

/// A small static bar strip on each chime card (#3385, mockup 10): the chime's real shape.
///
/// The founder asked whether the bars were made up (2026-10-03); they were, a hash of the
/// pairing's name. They are now read from the two bundled sounds the card plays, the start
/// chime then the stop chime, so a sharp tick and a slow fade look different. The strip is
/// still static, hidden from VoiceOver and never takes a click.
struct RecordingChimeWaveform: View {
  let pairing: RecordingSoundPairing
  let isSelected: Bool

  static let barCount = 40

  var body: some View {
    let heights = Self.heights(for: pairing)
    let color = isSelected ? Color.stAccent : Color.stTextTertiary.opacity(0.55)
    // Drawn into whatever width the card leaves, so a narrow card never pushes the badge out.
    Canvas { context, size in
      let slot = size.width / CGFloat(heights.count)
      let barWidth = max(1.5, min(3, slot * 0.6))
      for (index, height) in heights.enumerated() {
        let barHeight = 2 + (size.height - 2) * height
        let rect = CGRect(
          x: CGFloat(index) * slot + (slot - barWidth) / 2,
          y: (size.height - barHeight) / 2, width: barWidth, height: barHeight)
        context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
      }
    }
    .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }

  /// Bar heights in 0...1 for the start chime followed by the stop chime, each half of the
  /// strip. Read once per pairing and kept: the files are bundled and never change.
  @MainActor static func heights(for pairing: RecordingSoundPairing) -> [CGFloat] {
    if let cached = cache[pairing] { return cached }
    let half = barCount / 2
    let start = envelope(name: "\(pairing.rawValue)_start", bars: half)
    let stop = envelope(name: "\(pairing.rawValue)_stop", bars: barCount - half)
    let joined = start + stop
    let peak = joined.max() ?? 0
    // A missing or silent file draws a flat line rather than an invented shape.
    let result = peak > 0 ? joined.map { CGFloat($0 / peak) } : Array(repeating: 0, count: barCount)
    cache[pairing] = result
    return result
  }

  @MainActor private static var cache: [RecordingSoundPairing: [CGFloat]] = [:]

  /// Root-mean-square loudness of `bars` equal slices of one bundled WAV; empty slices and a
  /// missing file read as silence.
  static func envelope(name: String, bars: Int, bundle: Bundle = .module) -> [Float] {
    guard bars > 0,
      let url = bundle.url(forResource: name, withExtension: "wav"),
      let file = try? AVAudioFile(forReading: url),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
      (try? file.read(into: buffer)) != nil,
      let samples = buffer.floatChannelData?[0]
    else { return Array(repeating: 0, count: bars) }
    let count = Int(buffer.frameLength)
    return (0..<bars).map { bar in
      let from = count * bar / bars
      let to = count * (bar + 1) / bars
      guard to > from else { return 0 }
      var sum: Float = 0
      for index in from..<to { sum += samples[index] * samples[index] }
      return (sum / Float(to - from)).squareRoot()
    }
  }
}
