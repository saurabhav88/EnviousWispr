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

  #if DEBUG
  @MainActor final class DelayedAdmission {
    var reads = 0
    var reply: CheckedContinuation<Bool, Never>?
    let arrived = FastAdmissionReadSignals()
    func read() async -> Bool {
      reads += 1
      if reads == 1 { return false } // initial page probe finishes normally
      return await withCheckedContinuation { continuation in
        reply = continuation
        // Releasable and arrived together, in the same MainActor turn.
        arrived.record(false)
      }
    }
    func release() { reply?.resume(returning: true); reply = nil }
  }

  @Test("the real manual re-check drops a delayed reply after switching engines; the same reply applies while Fast stays selected",
    arguments: [true, false])
  func delayedReplyHonoursEngineSwitch(switchEngine: Bool) async throws {
    let defaults = try #require(TestDefaults.suite("ew.fastReply.\(UUID().uuidString)"))
    let settings = SettingsManager(defaults: defaults)
    settings.selectedBackend = .parakeet
    let setup = SetupCoordinator(asrManager: RouterTestASRManager(),
      whisperKitSetup: WhisperKitSetupService(engineMutationScope: .alwaysAllowedForTesting,
        readAvailability: { .notDownloaded }),
      setupStateReader: { .notDownloaded }, preloadAction: {}, ollamaStatusProbe: { _ in })
    let presenter = LanguageSuggestionPresenter(overlay: DictationSettingsRenderHarness.NoOverlay(),
      onLanguageAccepted: { _ in }, defaults: defaults)
    let home = try ModelDeliveryHomeTests.fastRenderFixture().home
    let delayed = DelayedAdmission()
    let finished = FastAdmissionReadSignals()
    final class ActionBox { var recheck: (@MainActor @Sendable () -> Void)? }
    let action = ActionBox()
    let page = SpeechEngineSettingsView()
      .environment(settings).environment(setup).environment(presenter).environment(home)
      .environment(\.fastAdmissionTestHooks, FastAdmissionTestHooks(
        read: { await delayed.read() }, onFinished: { finished.record($0) },
        captureRecheck: { action.recheck = $0 }))
      .frame(width: 508, height: 1250)
    let host = NSHostingView(rootView: page)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 508, height: 1250),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { delayed.release(); window.contentView = nil }
    host.layoutSubtreeIfNeeded()
    try #require(await finished.wait(after: 0), "initial page admission did not finish")
    #expect(finished.values == [false])
    let manual = try #require(action.recheck, "the real Button handler was not captured")
    let baseline = finished.count
    manual() // same handler as the actual button, deliberately not a view-bound Task
    try #require(await delayed.arrived.wait(after: 0), "manual check never parked")
    if switchEngine {
      settings.selectedBackend = .whisperKit
      host.layoutSubtreeIfNeeded()
    }
    delayed.release()
    try #require(await finished.wait(after: baseline), "delayed reply never completed reconciliation")
    let reconciled = try #require(finished.values.last)
    #expect(reconciled == (switchEngine ? nil : true))
    print("DELAYED-FAST switch=\(switchEngine) selected=\(settings.selectedBackend) result=\(String(describing: reconciled)) reads=\(delayed.reads)")
  }
  #endif
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
