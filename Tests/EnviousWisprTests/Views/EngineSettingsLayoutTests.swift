import AppKit
import EnviousWisprCore
@testable import EnviousWisprASR
@testable import EnviousWisprServices
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #3385: when this fails, a long Engine row moves its switch below its siblings,
/// a Ready badge certifies a missing language, or Reset loses its full explanation.
@MainActor
@Suite("Engine settings layout and readiness", .tags(.productOutcome))
struct EngineSettingsLayoutTests {
  init() { _ = NSApplication.shared }

  @Test("small controls stay trailing even when the Engine short line wraps")
  func compactSwitchStaysTrailing() throws {
    for width: CGFloat in [432, 502, 982] {
      let frame = try LivePreviewSettingsLayoutTests.frame(width: width) { probe in
        SettingsRow(fixtureTitle: "Convert spoken emoji (e.g. thumbs up emoji)", icon: "face.smiling",
          resolvedShort: "Say a phrase followed by emoji to get its symbol. This longer translation must wrap.",
          resolvedHelp: "Bare words never convert.") {
          Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(BrandedToggleStyle()).fixedSize()
            .background(probe)
        }
      }
      print("ENGINE-SWITCH width=\(width) visible=true frame=\(frame)")
      #expect(abs(frame.maxX - width) < 1)
      #expect(frame.width > 20 && frame.width < 80)
    }
  }

  @Test("Fast readiness follows the current admission result, including unknown")
  func fastReadiness() {
    #expect(EngineSummaryPresentation.fastModelStatus(admitted: true).label == "Model ready")
    #expect(EngineSummaryPresentation.fastModelStatus(admitted: false).tone == .needsSetup)
    #expect(EngineSummaryPresentation.fastModelStatus(admitted: nil).tone == .unavailable)
  }

  @Test("Apple Ready needs current language capability, no stale value and no running install")
  func previewReadiness() {
    let ready = LivePreviewStatusMapping.summary(isEnabled: true, engine: .apple,
      appleSupported: true, universalExists: false, universalState: .notReady,
      heartIsStreaming: false, active: .ready(tag: "de-DE", name: "German"))
    #expect(EngineSummaryPresentation.previewStatus(ready).label == "Ready")
    for blocked in [
      LivePreviewStatusMapping.summary(isEnabled: true, engine: .apple, appleSupported: true,
        universalExists: false, universalState: .notReady, heartIsStreaming: false,
        active: .needsDownload(name: "German")),
      LivePreviewStatusMapping.summary(isEnabled: true, engine: .apple, appleSupported: true,
        universalExists: false, universalState: .notReady, heartIsStreaming: false,
        active: .ready(tag: "de-DE", name: "German"), anInstallIsInFlight: true),
      LivePreviewStatusMapping.summary(isEnabled: true, engine: .apple, appleSupported: true,
        universalExists: false, universalState: .notReady, heartIsStreaming: false,
        active: .ready(tag: "de-DE", name: "German"), activeDescribesAnotherLanguage: true),
    ] {
      #expect(EngineSummaryPresentation.previewStatus(blocked).tone != .ready)
      #expect(EngineSummaryPresentation.showsDetail(blocked))
    }
  }

}

/// A completion signal from the real page. The five-second bound is the existing
/// PipelineStateWaiter/TelemetryEventWaiter hang net, not a settle or latency target.
@MainActor
final class FastAdmissionReadSignals {
  private struct Pending {
    let id: UUID
    let target: Int
    let continuation: CheckedContinuation<Bool, Never>
  }
  private var pending: Pending?
  private(set) var values: [Bool?] = []
  var count: Int { values.count }

  func record(_ value: Bool?) {
    values.append(value)
    guard let pending, count >= pending.target else { return }
    self.pending = nil
    pending.continuation.resume(returning: true)
  }
  func wait(after baseline: Int, timeout: Duration = .seconds(5)) async -> Bool {
    if count > baseline { return true }
    let id = UUID()
    let timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: timeout) // deadline-fallback: bound a missing subject completion
      self?.expire(id)
    }
    let result = await withCheckedContinuation { continuation in
      pending = Pending(id: id, target: baseline + 1, continuation: continuation)
    }
    timeoutTask.cancel()
    return result
  }
  private func expire(_ id: UUID) {
    guard let pending, pending.id == id else { return }
    self.pending = nil
    pending.continuation.resume(returning: false)
  }
}

#if DEBUG
@MainActor
@Suite("Fast admission completion signal", .tags(.harnessContract))
struct FastAdmissionSignalHarnessTests {
  @Test("a missing signal gives up, while a prior signal is consumed immediately")
  func missingSignalIsBounded() async {
    let signal = FastAdmissionReadSignals()
    #expect(await signal.wait(after: 0, timeout: .milliseconds(1)) == false)
    signal.record(true)
    #expect(await signal.wait(after: 0))
  }
}


#endif
