import EnviousWisprASR
import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #2648 — the whole file-import path on a REAL recording, through the SHIPPED engine.
///
/// **What the user sees when this fails:** they pick a recording they already have and get nothing back,
/// or get somebody's words mangled, or get a document that silently stops partway.
///
/// **Why this exists alongside the unit rows.** Every other suite in this feature drives fakes: a decode
/// closure that returns a constant, a part processor that echoes. They prove the wiring. None of them
/// proves that a real file, decoded by the real decoder, transcribed by the real model, splits into the
/// parts the design promises. This is the only row where the audio, the decoder, the engine and the
/// splitter are all the shipped ones.
///
/// **It is gated on the shipped model being installed and reports SKIPPED otherwise**, which is what the
/// hosted runner does. A skipped receipt is not a passed receipt: the evidence for this row is the
/// dev-machine run.
@Suite("File import on a real recording", .serialized, .tags(.productOutcome))
struct FileImportRealBoundaryTests {

  private enum Fixture {
    static var installDirectory: URL {
      ParakeetInstallLocation.directory(dataDirectory: StorageRoot.live.dataDirectory)
    }

    static var shippedModelIsInstalled: Bool {
      AsrModels.modelsExist(at: installDirectory, version: .v3)
    }

    /// Written at test time with the system voice rather than committed as a binary. Three minutes of
    /// real speech, and deliberately more than 500 words, because a recording that fits in one part
    /// would prove nothing about splitting.
    static func writeSpokenRecording() throws -> (url: URL, wordCount: Int) {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("file-import-real-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

      let sentences = [
        "Good morning everyone, thanks for joining the weekly product review.",
        "The first item is the transcription latency work that landed last week.",
        "We measured the median at just under a second on the reference machine.",
        "The second item is the file import feature that we are testing right now.",
        "A user records a lecture on their phone and wants clean text out of it.",
        "Each part goes through the same chain a normal dictation goes through.",
        "If one part fails to clean up we still show the raw words for that passage.",
        "The third item is the engine lock that stops two jobs using one model at once.",
        "Now the record button politely refuses and tells you what is running.",
      ]
      var script: [String] = []
      var index = 0
      while script.joined(separator: " ").split(separator: " ").count < 560 {
        script.append(sentences[index % sentences.count])
        index += 1
      }
      let text = script.joined(separator: " ")

      let scriptURL = dir.appendingPathComponent("script.txt")
      try text.write(to: scriptURL, atomically: true, encoding: .utf8)
      let audioURL = dir.appendingPathComponent("recording.aiff")

      let say = Process()
      say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
      say.arguments = ["-o", audioURL.path, "-f", scriptURL.path]
      try say.run()
      say.waitUntilExit()
      guard say.terminationStatus == 0 else {
        throw NSError(domain: "FileImportRealBoundary", code: Int(say.terminationStatus))
      }
      return (audioURL, text.split(separator: " ").count)
    }
  }

  @Test(
    "a real multi-minute recording decodes, transcribes, and splits into parts",
    .enabled(if: Fixture.shippedModelIsInstalled),
    .tags(.realBoundary)
  )
  func aRealRecordingBecomesParts() async throws {
    let (audioURL, spokenWords) = try Fixture.writeSpokenRecording()
    defer { try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent()) }

    // 1. The real decoder, on a real file it has never seen.
    let samples = try await AudioFileDecoder.decode(url: audioURL)
    let seconds = Double(samples.count) / AudioConstants.sampleRate
    #expect(seconds > 60, "the fixture is meant to be minutes long; got \(seconds)s")

    // 2. The shipped model, reading cache only so this row can never download or repair bytes.
    let backend = ParakeetBackend()
    let transcript: String
    do {
      try await backend.prepare(
        cacheOnly: true, modelDirectory: Fixture.installDirectory, progressCallback: nil)
      transcript = try await backend.transcribe(audioSamples: samples, options: .default).text
      await backend.unload()
    } catch {
      await backend.unload()
      throw error
    }

    // The engine heard SPEECH, not silence. A loose floor on purpose: this row is about the path, and
    // pinning the exact words would make it a test of the recogniser instead.
    let heardWords = transcript.split(whereSeparator: { $0.isWhitespace }).count
    #expect(
      heardWords > spokenWords / 2,
      "the engine returned \(heardWords) words for \(spokenWords) spoken: \(transcript.prefix(200))"
    )

    // 3. The real splitter, on the engine's real output.
    let parts = TranscriptSplitter.split(transcript)
    #expect(parts.count >= 2, "a \(heardWords)-word transcript should not fit in one part")
    for (index, part) in parts.enumerated() {
      let count = TranscriptSplitter.wordCount(in: part)
      #expect(
        count >= 1 && count <= TranscriptSplitter.maximumWordsPerPart,
        "part \(index) holds \(count) words, outside 1...500")
    }
    // Nothing lost and nothing duplicated, on words a person actually said rather than on a fixture.
    let partWords: [String] = parts.flatMap { part -> [String] in
      part.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
    let transcriptWords: [String] = transcript
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    #expect(partWords == transcriptWords, "the parts are not the transcript's words in order")
  }
}
