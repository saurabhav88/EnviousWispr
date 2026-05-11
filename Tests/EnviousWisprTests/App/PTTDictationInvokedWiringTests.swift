import Foundation
import Testing

@Suite("PTT dictation invoked wiring")
struct PTTDictationInvokedWiringTests {

  @Test("PTT start emits dictation invoked after active guard and before prewarm")
  func pttStartEmitsAfterActiveGuardBeforePrewarm() throws {
    let body = try Self.slice(
      source: Self.appStateSource(),
      from: "hotkeyService.onStartRecording = { [weak self] in",
      to: "} catch is CancellationError"
    )

    let emit = try Self.require("self.emitDictationInvoked()", in: body)
    let activeGuard = try Self.require(
      "let isWhisperKit = self.asrManager.activeBackendType", in: body)
    let prewarm = try Self.require(".preWarm", in: body)

    #expect(activeGuard.lowerBound < emit.lowerBound)
    #expect(emit.lowerBound < prewarm.lowerBound)
  }

  @Test("toggle path emits only inside the existing start guard")
  func togglePathKeepsStartOnlyTelemetry() throws {
    let body = try Self.slice(
      source: Self.appStateSource(),
      from: "func toggleRecording() async {",
      to: "try? await active.handle(event: .toggleRecording(makeDictationSessionConfig()))"
    )

    let guardRange = try Self.require("if !alreadyActive {", in: body)
    let emit = try Self.require("emitDictationInvoked()", in: body)

    #expect(guardRange.lowerBound < emit.lowerBound)
  }

  @Test("PTT stop callback does not emit a new invoke event")
  func pttStopDoesNotEmitInvoke() throws {
    let body = try Self.slice(
      source: Self.appStateSource(),
      from: "hotkeyService.onStopRecording = { [weak self] in",
      to: "hotkeyService.onCancelRecording = { [weak self] in"
    )

    #expect(!body.contains("emitDictationInvoked"))
    #expect(!body.contains("dictationInvoked"))
  }

  @Test("shared helper owns the existing telemetry event call")
  func helperCallsTelemetryService() throws {
    let body = try Self.slice(
      source: Self.appStateSource(),
      from: "private func emitDictationInvoked() {",
      to: "private func makeDictationSessionConfig()"
    )

    #expect(body.contains("TelemetryService.shared.dictationInvoked("))
    #expect(body.contains("triggerSource: settings.recordingMode.rawValue"))
    #expect(body.contains("inputMode: settings.recordingMode.rawValue"))
    #expect(body.contains("NSWorkspace.shared.frontmostApplication?.localizedName"))
  }

  private static func appStateSource() throws -> String {
    try String(contentsOf: appStateURL(), encoding: .utf8)
  }

  private static func appStateURL() -> URL {
    let here = URL(fileURLWithPath: #filePath)
    return
      here
      .deletingLastPathComponent()  // App/
      .deletingLastPathComponent()  // EnviousWisprTests/
      .deletingLastPathComponent()  // Tests/
      .deletingLastPathComponent()  // <repo root>/
      .appendingPathComponent("Sources/EnviousWispr/App/AppState.swift")
  }

  private static func slice(source: String, from start: String, to end: String) throws -> String {
    guard let startRange = source.range(of: start) else {
      throw WiringError.markerNotFound(start)
    }
    guard let endRange = source[startRange.upperBound...].range(of: end) else {
      throw WiringError.markerNotFound(end)
    }
    return String(source[startRange.upperBound..<endRange.lowerBound])
  }

  private static func require(_ needle: String, in source: String) throws -> Range<String.Index> {
    guard let range = source.range(of: needle) else {
      throw WiringError.markerNotFound(needle)
    }
    return range
  }

  enum WiringError: Error {
    case markerNotFound(String)
  }
}
