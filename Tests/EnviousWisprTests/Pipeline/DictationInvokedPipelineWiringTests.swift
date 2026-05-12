import Foundation
import Testing

struct DictationInvokedPipelineWiringTests {
  @Test("AppState does not own dictation.invoked telemetry")
  func appStateDoesNotEmitDictationInvoked() throws {
    let source = try Self.read("Sources/EnviousWispr/App/AppState.swift")

    #expect(!source.contains("dictationInvoked("))
    #expect(!source.contains("emitDictationInvoked"))
  }

  @Test("session config carries input mode into pipeline start")
  func sessionConfigCarriesInputMode() throws {
    let configSource = try Self.read("Sources/EnviousWisprCore/DictationSessionConfig.swift")
    let appStateSource = try Self.read("Sources/EnviousWispr/App/AppState.swift")

    #expect(configSource.contains("public let inputMode: RecordingMode"))
    #expect(appStateSource.contains("inputMode: settings.recordingMode"))
  }

  @Test("Parakeet emits dictation.invoked after capture enters recording")
  func parakeetPipelineEmitsAfterRecordingStarts() throws {
    let source = try Self.read("Sources/EnviousWisprPipeline/TranscriptionPipeline.swift")
    let body = try Self.slice(
      source,
      from: "public func startRecording(config: DictationSessionConfig) async {",
      to: "/// Stop recording"
    )

    let stateIndex = try Self.require("state = .recording", in: body)
    let telemetryIndex = try Self.require("TelemetryService.shared.dictationInvoked(", in: body)

    #expect(stateIndex < telemetryIndex)
    #expect(body.contains("triggerSource: config.inputMode.rawValue"))
    #expect(body.contains("inputMode: config.inputMode.rawValue"))
    #expect(body.contains("targetApp: targetApp?.localizedName"))
  }

  @Test("WhisperKit emits dictation.invoked after capture enters recording")
  func whisperKitPipelineEmitsAfterRecordingStarts() throws {
    let source = try Self.read("Sources/EnviousWisprPipeline/WhisperKitPipeline.swift")
    let body = try Self.slice(
      source,
      from: "public func startRecording(config: DictationSessionConfig) async {",
      to: "public func requestStop() async {"
    )

    let stateIndex = try Self.require("state = .recording", in: body)
    let telemetryIndex = try Self.require("TelemetryService.shared.dictationInvoked(", in: body)

    #expect(stateIndex < telemetryIndex)
    #expect(body.contains("triggerSource: config.inputMode.rawValue"))
    #expect(body.contains("inputMode: config.inputMode.rawValue"))
    #expect(body.contains("targetApp: targetApp?.localizedName"))
  }

  private static func read(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
  }

  private static func slice(_ source: String, from start: String, to end: String) throws -> String {
    guard let startRange = source.range(of: start) else {
      throw TestFailure("Missing start marker: \(start)")
    }
    guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
      throw TestFailure("Missing end marker: \(end)")
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
  }

  @discardableResult
  private static func require(_ needle: String, in haystack: String) throws -> String.Index {
    guard let range = haystack.range(of: needle) else {
      throw TestFailure("Missing expected text: \(needle)")
    }
    return range.lowerBound
  }

  private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
      self.description = description
    }
  }
}
