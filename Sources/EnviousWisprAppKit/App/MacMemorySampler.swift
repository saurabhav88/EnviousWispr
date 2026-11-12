import Foundation
import Observation

/// #4525: the live "memory in use" figure behind the EG-1 size cards' bar and heading.
///
/// Owned as `@State` by the view that draws both the heading and the cards, and driven by that
/// view's `.task`, so it samples only while the EG-1 section is mounted and stops when SwiftUI
/// cancels the task (plan #4525 §3.2). One read immediately, then one every two seconds, the
/// cadence Activity Monitor and Stats use. A hidden window (occluded or minimized) skips the
/// read but keeps the wake-up, and reads at once on the first tick it is visible again.
///
/// It publishes only when the displayed value (0.1 GB, binary) changes or the read starts or
/// stops failing, so a quiet Mac causes no redraw.
@MainActor
@Observable
final class MacMemorySampler {
  static let interval: Duration = .seconds(2)

  /// Bytes in use now; nil before the first read or when the last read failed.
  private(set) var usedBytes: UInt64?

  @ObservationIgnored private let read: @MainActor () -> UInt64?
  @ObservationIgnored private let isVisible: @MainActor () -> Bool
  @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

  init(
    read: @escaping @MainActor () -> UInt64? = { MacMemoryReader.usedBytes() },
    isVisible: @escaping @MainActor () -> Bool,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.read = read
    self.isVisible = isVisible
    self.sleep = sleep
  }

  /// One step: read if visible, publish if the shown value changed.
  func tick() {
    guard isVisible() else { return }
    let bytes = read()
    switch (usedBytes, bytes) {
    case (nil, nil):
      return
    case (.some(let old), .some(let new)) where Self.shown(old) == Self.shown(new):
      return
    default:
      usedBytes = bytes
    }
  }

  /// Ticks now, then every `interval`, until the calling task is cancelled.
  func run() async {
    while !Task.isCancelled {
      tick()
      do { try await sleep(Self.interval) } catch { return }
    }
  }

  /// The value the card shows, in tenths of a binary gigabyte.
  nonisolated static func shown(_ bytes: UInt64) -> Int {
    Int((Double(bytes) / Double(1 << 30) * 10).rounded())
  }
}
