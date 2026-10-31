import CryptoKit
import Darwin
import EnviousWisprAudio
import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing
import os

@testable import EnviousWisprASR
@testable import EnviousWisprTranscribeCpp

/// #3735 chunk 0: the transcribe.cpp dependency proof through the real Xcode test target.
/// Decodes committed speech with the exact whisper-large-v3-turbo Q8_0 candidate on Metal,
/// and exercises both fork APIs (language log-probability, seek progress) on real audio.
///
/// The model is the #3705 evaluation copy until chunk 2 delivers it to the app's install
/// directory. Override from the shell with `TEST_RUNNER_EW_TRANSCRIBECPP_TURBO_GGUF` (Xcode strips
/// the forwarding prefix, so the test reads `EW_TRANSCRIBECPP_TURBO_GGUF`). Pinned by size, then
/// by sha256 inside each test.
private enum TranscribeCppRealBoundaryFixture {
  static let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()  // EnviousWisprASRTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  static let audioURL = repoRoot.appending(path: "scripts/freeze-suite/clips/normal-speech.wav")

  /// sha256 b2e30cc286bc9f3aba4db9099fc7403543497c05ce7100d0d83091ddfd25a183 (#3705).
  static let expectedModelBytes: UInt64 = 886_381_760

  /// The #3705 evaluation copy (gitignored `artifacts/`), looked up in this checkout and
  /// then in the main checkout beside it (worktrees live next to it).
  static var modelPath: String {
    if let override = ProcessInfo.processInfo.environment["EW_TRANSCRIBECPP_TURBO_GGUF"] {
      return override
    }
    let relative = "artifacts/issue-3705-transcribecpp-eval/models/whisper-large-v3-turbo-Q8_0.gguf"
    let candidates = [
      repoRoot.appending(path: relative),
      repoRoot.deletingLastPathComponent().appending(path: "EnviousWispr").appending(path: relative),
    ]
    return (candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]).path
  }

  /// Binds the run to the approved #3705 turbo Q8_0 candidate, not merely a same-size file.
  static func requireExpectedModel() throws {
    try #require(try modelDigestMatches(), "requires the approved turbo Q8_0 model")
  }

  /// The identity check alone, for a child process that must not record test issues (#3849).
  static func modelDigestMatches(at path: String = modelPath) throws -> Bool {
    let data = try Data(contentsOf: URL(filePath: path), options: .mappedIfSafe)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return digest == "b2e30cc286bc9f3aba4db9099fc7403543497c05ce7100d0d83091ddfd25a183"
  }

  static let expectedWords =
    "the quick brown fox jumps over the lazy dog while the morning sun rises slowly above the quiet hills"

  /// #3849: true whenever a file is there, right or wrong, so a truncated or wrong model reaches
  /// the identity check and fails instead of skipping. Only a missing file skips.
  static var modelFileExists: Bool { FileManager.default.fileExists(atPath: modelPath) }

  static var modelIsPresent: Bool {
    let size = (try? FileManager.default.attributesOfItem(atPath: modelPath)[.size]) as? NSNumber
    return size?.uint64Value == expectedModelBytes
  }
}

/// **What the user sees when this fails:** dictation in a language Parakeet does not cover
/// produces no text, because the transcribe.cpp engine cannot load or decode in the app.
@Suite("transcribe.cpp native boundary (real model, Metal)", .serialized, .tags(.productOutcome))
struct TranscribeCppRealBoundaryTests {

  @Test(
    "the turbo Q8_0 model decodes committed English speech, detects English, and reports bounded monotonic progress",
    .enabled(if: TranscribeCppRealBoundaryFixture.modelIsPresent),
    .tags(.realBoundary), .realBoundaryRun
  )
  func decodesDetectsAndReportsProgress() throws {
    let samples = try AudioConverter().resampleAudioFile(
      path: TranscribeCppRealBoundaryFixture.audioURL.path)
    #expect(samples.count > 16_000)

    try TranscribeCppRealBoundaryFixture.requireExpectedModel()
    let session = try TranscribeCppSession(modelPath: TranscribeCppRealBoundaryFixture.modelPath)
    defer { session.close() }

    // Fork API 1: language log-probability on real audio.
    let observation = try session.detectLanguage(samples: samples)
    #expect(observation.code == "en")
    #expect(observation.logProb.isFinite)
    #expect(observation.logProb <= 0)
    #expect(exp(observation.logProb) > 0.5)

    // Fork API 2: seek progress, observed on a real auto-detect run.
    let recorder = ProgressRecorder()
    let result = try session.run(samples: samples, language: nil) { advanced, total in
      recorder.record(advanced: advanced, total: total)
    }
    let calls = recorder.snapshot()
    #expect(!calls.isEmpty, "no native progress callback was observed")
    var previous: Int64 = -1
    for call in calls {
      #expect(call.advanced >= previous, "progress went backwards")
      #expect(call.advanced <= call.total, "progress exceeded its total")
      previous = call.advanced
    }
    #expect(calls.last.map { $0.advanced == $0.total } == true)
    // Completion is reported once, and only after the run finished: every earlier call
    // stays below the total (seek can pass the real end while padded frames decode).
    #expect(calls.dropLast().allSatisfy { $0.advanced < $0.total })
    // The denominator is the clip's REAL mel frames (100,224 samples -> 626), not the
    // 3,000-frame padded window.
    for call in calls {
      #expect(call.total == 626)
      #expect(call.advanced >= 0)
    }

    // Real transcript content, native detection reported, segments timed.
    let words = result.text.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .joined(separator: " ")
    #expect(
      words
        == "the quick brown fox jumps over the lazy dog while the morning sun rises slowly above the quiet hills"
    )
    #expect(result.detectedLanguage == "en")
    #expect(!result.segments.isEmpty)
    #expect(result.segments.allSatisfy { $0.endMs >= $0.startMs })
  }

  @Test(
    "a forced language returns no native detected language and still decodes",
    .enabled(if: TranscribeCppRealBoundaryFixture.modelIsPresent),
    .tags(.realBoundary), .realBoundaryRun
  )
  func forcedLanguageReportsNoDetection() throws {
    let samples = try AudioConverter().resampleAudioFile(
      path: TranscribeCppRealBoundaryFixture.audioURL.path)
    try TranscribeCppRealBoundaryFixture.requireExpectedModel()
    let session = try TranscribeCppSession(modelPath: TranscribeCppRealBoundaryFixture.modelPath)
    defer { session.close() }

    let result = try session.run(samples: samples, language: "en")
    #expect(result.detectedLanguage == nil)
    #expect(!result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  @Test(
    "an abort requested before the run stops it with the aborted status",
    .enabled(if: TranscribeCppRealBoundaryFixture.modelIsPresent),
    .tags(.realBoundary), .realBoundaryRun
  )
  func abortStopsTheRun() throws {
    let samples = try AudioConverter().resampleAudioFile(
      path: TranscribeCppRealBoundaryFixture.audioURL.path)
    try TranscribeCppRealBoundaryFixture.requireExpectedModel()
    let session = try TranscribeCppSession(modelPath: TranscribeCppRealBoundaryFixture.modelPath)
    defer { session.close() }

    // A stopped run never announces native entry: neither an abort requested before the run
    // nor a caller cancelled after admission and preparation.
    var entries = 0
    session.requestAbort()
    #expect {
      _ = try session.run(samples: samples, language: "en", onInferenceEntered: { entries += 1 })
    } throws: { error in
      (error as? TranscribeCppError)?.isAborted == true
    }
    session.clearAbort()
    #expect {
      _ = try session.run(
        samples: samples, language: nil, onInferenceEntered: { entries += 1 },
        shouldStop: { true })
    } throws: { error in
      (error as? TranscribeCppError)?.isAborted == true
    }
    #expect(entries == 0)
    let result = try session.run(
      samples: samples, language: "en", onInferenceEntered: { entries += 1 },
      shouldStop: { false })
    #expect(!result.text.isEmpty)
    #expect(entries == 1)
  }
}

/// #3735 plan §3.2a on real bytes: the same native work routed through the executor.
@Suite("transcribe.cpp executor on the real model (Metal)", .serialized, .tags(.productOutcome))
struct TranscribeCppExecutorRealBoundaryTests {
  @Test(
    "the executor loads the turbo model, detects English, transcribes with progress, survives a cancel and is reused",
    .enabled(if: TranscribeCppRealBoundaryFixture.modelIsPresent),
    .tags(.realBoundary), .realBoundaryRun
  )
  func executorRoutesRealWork() async throws {
    try TranscribeCppRealBoundaryFixture.requireExpectedModel()
    let samples = try AudioConverter().resampleAudioFile(
      path: TranscribeCppRealBoundaryFixture.audioURL.path)
    let executor = TranscribeCppExecutor()
    let model = try await executor.load(
      modelPath: TranscribeCppRealBoundaryFixture.modelPath, lane: .heart)

    let observation = try await executor.detectLanguage(model, samples: samples, lane: .heart)
    #expect(observation.code == "en")
    #expect(observation.logProb.isFinite && observation.logProb <= 0)

    let recorder = ProgressRecorder()
    let result = try await executor.transcribe(
      model, samples: samples, language: nil, lane: .heart
    ) { advanced, total in recorder.record(advanced: advanced, total: total) }
    let words = result.text.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    #expect(
      words
        == "the quick brown fox jumps over the lazy dog while the morning sun rises slowly above the quiet hills"
    )
    #expect(recorder.snapshot().last.map { $0.advanced == $0.total } == true)

    // A cancelled request ends as cancelled; the model is then reused cleanly.
    let cancelled = Task { try await executor.transcribe(model, samples: samples, language: "en", lane: .heart) }
    cancelled.cancel()
    await #expect(throws: TranscribeCppExecutor.ExecutorError.cancelled) { try await cancelled.value }
    let again = try await executor.transcribe(model, samples: samples, language: "en", lane: .heart)
    #expect(!again.text.isEmpty)

    await executor.unload(model)
    #expect(await executor.counters.freed == 1)
  }

  /// #4254 Q-a: the native decoder's own copy of a meeting's decode input. One hour of real
  /// speech (the committed clip repeated, worst case all speech) through the executor on the
  /// real model, with the process footprint sampled before the load, after it, and while the
  /// decode runs. Prints one `QA-NATIVE` line for the #4254 receipt.
  @Test(
    "#4254 Q-a: peak footprint of an hour-long real decode",
    .enabled(if: TranscribeCppRealBoundaryFixture.modelIsPresent),
    .tags(.realBoundary), .timeLimit(.minutes(15)), .realBoundaryRun
  )
  func hourDecodeFootprint() async throws {
    try TranscribeCppRealBoundaryFixture.requireExpectedModel()
    let clip = try AudioConverter().resampleAudioFile(
      path: TranscribeCppRealBoundaryFixture.audioURL.path)
    let hour = 3_600 * 16_000
    var samples: [Float] = []
    samples.reserveCapacity(hour)
    while samples.count < hour { samples.append(contentsOf: clip.prefix(hour - samples.count)) }
    let beforeLoad = Self.footprintMB()
    let executor = TranscribeCppExecutor()
    let model = try await executor.load(
      modelPath: TranscribeCppRealBoundaryFixture.modelPath, lane: .heart)
    let loaded = Self.footprintMB()
    let peak = OSAllocatedUnfairLock(initialState: loaded)
    // detached: samples the process from outside the decode being measured.
    let sampler = Task.detached {
      while !Task.isCancelled {
        let now = Self.footprintMB()
        peak.withLock { $0 = max($0, now) }
        try? await Task.sleep(for: .milliseconds(50))  // test-fixture-timer: sampling period
      }
    }
    let start = ContinuousClock.now
    let result = try await executor.transcribe(model, samples: samples, language: "en", lane: .heart)
    let elapsed = ContinuousClock.now - start
    sampler.cancel()
    _ = await sampler.value
    let after = Self.footprintMB()
    await executor.unload(model)
    let unloaded = Self.footprintMB()
    #expect(!result.text.isEmpty)
    print(
      "QA-NATIVE hour_decode input_samples=\(samples.count) input_mb=\(samples.count * 4 / 1_048_576) footprint_mb before_load=\(Int(beforeLoad)) loaded=\(Int(loaded)) peak_during_decode=\(Int(peak.withLock { $0 })) after_decode=\(Int(after)) after_unload=\(Int(unloaded)) decode_s=\(elapsed.components.seconds)"
    )
  }

  private static func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
  }

  /// #3849 plan §11 item 2: the crash on quit itself. A child process loads the real model,
  /// decodes, keeps the model loaded, runs the quit release, and then calls the normal `exit(0)`,
  /// which runs the static ggml Metal device destructor that asserted while a session was alive.
  /// The child's receipt is written only after every check passed, and the parent also requires
  /// a normal status-zero termination, so a check that failed, a crash in the destructor, or a
  /// child that never ran all fail this test.
  @Test(
    "a real model freed by the quit release lets the process exit normally (#3849)",
    .enabled(if: TranscribeCppRealBoundaryFixture.modelFileExists),
    .tags(.realBoundary), .timeLimit(.minutes(3)), .realBoundaryRun
  )
  func realModelReleaseSurvivesNormalExit() async throws {
    let token = UUID().uuidString
    let modelPath = TranscribeCppRealBoundaryFixture.modelPath
    let audioPath = TranscribeCppRealBoundaryFixture.audioURL.path
    let observed = await #expect(
      processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]
    ) {
      [token = token as String, modelPath = modelPath as String, audioPath = audioPath as String]
      in
      await Self.releaseThenExitChild(token: token, modelPath: modelPath, audioPath: audioPath)
    }
    let result = try #require(observed)
    let lines = String(decoding: result.standardOutputContent, as: UTF8.self)
      .split(separator: "\n").map(String.init)
    #expect(
      lines.filter { $0.hasPrefix("release-receipt ") } == ["release-receipt \(token)"],
      "stderr: \(String(decoding: result.standardErrorContent, as: UTF8.self))")
  }

  /// The child body. Records no test issues: any failed check writes its step to stderr and
  /// ends with a nonzero status, never `exit(0)`.
  private static func releaseThenExitChild(token: String, modelPath: String, audioPath: String)
    async
  {
    // Owned bound: a hung child ends itself rather than outliving the parent's wait.
    DispatchQueue.global().asyncAfter(deadline: .now() + 120) { childFail("watchdog") }
    guard (try? TranscribeCppRealBoundaryFixture.modelDigestMatches(at: modelPath)) == true else {
      childFail("model identity")
    }
    guard let samples = try? AudioConverter().resampleAudioFile(path: audioPath) else {
      childFail("clip")
    }
    let executor = TranscribeCppExecutor()
    guard let model = try? await executor.load(modelPath: modelPath, lane: .heart) else {
      childFail("load")
    }
    guard
      let run = try? await executor.transcribe(model, samples: samples, language: nil, lane: .heart)
    else { childFail("decode") }
    let words = run.text.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    guard words == TranscribeCppRealBoundaryFixture.expectedWords else { childFail("words") }
    // The model stays loaded: the quit release must free it.
    guard case .released(sessions: 1, _) = executor.releaseAllForTermination(timeout: .seconds(2))
    else { childFail("release") }
    FileHandle.standardOutput.write(Data("release-receipt \(token)\n".utf8))
    exit(0)
  }
}

/// A child-process check failed: names the step on stderr and ends with status 1, so the
/// parent's success condition can never be met after it (#3849).
func childFail(_ step: String) -> Never {
  FileHandle.standardError.write(Data("child failed: \(step)\n".utf8))
  _exit(1)
}

/// #3735 plan §3.2 on real bytes: the Whisper backend through the live executor driver.
@Suite("transcribe.cpp Whisper backend on the real model (Metal)", .serialized, .tags(.productOutcome))
struct TranscribeCppWhisperBackendRealBoundaryTests {
  @Test(
    "the backend loads and warms the turbo model, transcribes auto and forced, runs LID, reports progress, survives a cancel and unloads",
    .enabled(if: TranscribeCppRealBoundaryFixture.modelIsPresent),
    .tags(.realBoundary), .realBoundaryRun
  )
  func backendRoutesRealWork() async throws {
    try TranscribeCppRealBoundaryFixture.requireExpectedModel()
    let samples = try AudioConverter().resampleAudioFile(
      path: TranscribeCppRealBoundaryFixture.audioURL.path)
    let path = TranscribeCppRealBoundaryFixture.modelPath
    let backend = TranscribeCppWhisperBackend(
      driver: LiveWhisperExecutorDriver(), modelVariant: "whisper-large-v3-turbo-Q8_0",
      admittedModelPath: { path })
    try await backend.prepare()
    #expect(await backend.isReady)
    #expect((await backend.lastWarmupInferenceMs ?? -1) >= 0, "the warm-up decode completed")

    let expected =
      "the quick brown fox jumps over the lazy dog while the morning sun rises slowly above the quiet hills"
    func words(_ text: String) -> String {
      text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    // Auto language, with progress and the native-entry signal counted once.
    let progress = ProgressFractions()
    await backend.setTranscriptionProgressObserver { progress.record($0) }
    let entries = ProgressFractions()
    let auto = try await backend.transcribe(
      audioSamples: samples, options: TranscriptionOptions(language: nil, enableTimestamps: true),
      onInferenceEntered: { entries.record(1) })
    #expect(words(auto.text) == expected)
    #expect(auto.language == "en")
    #expect(entries.snapshot().count == 1)
    let fractions = progress.snapshot()
    #expect(!fractions.isEmpty && fractions == fractions.sorted() && fractions.last == 1.0)
    let timings = try #require(auto.segmentTimings)
    #expect(!timings.isEmpty)
    let audioMs = Int(Double(samples.count) / 16.0)
    for timing in timings {
      #expect(timing.range.upperBound <= auto.text.utf16.count)
      if let start = timing.startMs, let end = timing.endMs {
        #expect(0 <= start && start <= end && end <= audioMs)
      }
    }

    // Forced language reports the hint.
    let forced = try await backend.transcribe(
      audioSamples: samples, options: TranscriptionOptions(language: "en"), onInferenceEntered: nil)
    #expect(forced.language == "en")
    #expect(words(forced.text) == expected)

    // LID through the fork's language-probability API.
    guard case .observations(let observations) = await backend.observeLID(samples: samples, maxWindows: 4)
    else {
      Issue.record("expected LID observations")
      return
    }
    #expect(observations.allSatisfy { $0.argmaxLang == "en" && $0.logProb <= 0 && $0.logProb.isFinite })

    // A cancelled take ends as a cancellation; the model is then reused cleanly.
    let cancelled = Task {
      try await backend.transcribe(
        audioSamples: samples, options: TranscriptionOptions(language: "en"), onInferenceEntered: nil)
    }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    let again = try await backend.transcribe(
      audioSamples: samples, options: TranscriptionOptions(language: "en"), onInferenceEntered: nil)
    #expect(words(again.text) == expected)

    await backend.unload()
    #expect(await backend.isReady == false)
    await #expect(throws: (any Error).self) {
      _ = try await backend.transcribe(
        audioSamples: samples, options: .default, onInferenceEntered: nil)
    }
  }
}

/// #3735 Chunk 9 on real bytes: the Universal preview runtime on whisper-small Q8_0, sharing the
/// live executor with the heart's turbo model, as the app runs them.
///
/// **What the user sees when this fails:** the Universal preview shows nothing, dictation waits
/// on the preview, or the preview model stays in memory after the preview is turned off.
@Suite("Universal preview runtime on the real model (Metal)", .serialized, .tags(.productOutcome))
struct TranscribeCppPreviewRealBoundaryTests {
  /// sha256 9b9c8811bbcc82a7766f0fb0925614bdacb0923b2cc630daeac17108b655b860 (#3705), the file
  /// `whisper-preview-delivery-manifest.json` admits.
  static let smallBytes: UInt64 = 269_751_136

  /// Beside the turbo evaluation copy; override with `TEST_RUNNER_EW_TRANSCRIBECPP_SMALL_GGUF`.
  static var smallPath: String {
    if let override = ProcessInfo.processInfo.environment["EW_TRANSCRIBECPP_SMALL_GGUF"] {
      return override
    }
    return URL(filePath: TranscribeCppRealBoundaryFixture.modelPath).deletingLastPathComponent()
      .appending(path: "whisper-small-Q8_0.gguf").path
  }

  static var modelsArePresent: Bool {
    let size = (try? FileManager.default.attributesOfItem(atPath: smallPath)[.size]) as? NSNumber
    return TranscribeCppRealBoundaryFixture.modelIsPresent && size?.uint64Value == smallBytes
  }

  static func words(_ text: String) -> String {
    text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
  }

  /// Audio revealed on the recording clock from the moment the session starts.
  static func recording(_ audio: [Float]) -> @Sendable () async -> (samples: [Float], count: Int) {
    let start = ContinuousClock.now
    return {
      let heard = Int(Double((ContinuousClock.now - start) / .milliseconds(1)) * 16)
      return (audio, min(audio.count, heard))
    }
  }

  @Test(
    "an unadmitted model is never loaded; the admitted one publishes English text, yields to a heart decode, is reused and is freed on release",
    .enabled(if: TranscribeCppPreviewRealBoundaryTests.modelsArePresent),
    .tags(.realBoundary), .realBoundaryRun
  )
  func previewPublishesYieldsAndFrees() async throws {
    try TranscribeCppRealBoundaryFixture.requireExpectedModel()
    let data = try Data(contentsOf: URL(filePath: Self.smallPath), options: .mappedIfSafe)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try #require(
      digest == "9b9c8811bbcc82a7766f0fb0925614bdacb0923b2cc630daeac17108b655b860",
      "requires the approved whisper-small Q8_0 model")
    let clip = try AudioConverter().resampleAudioFile(
      path: TranscribeCppRealBoundaryFixture.audioURL.path)
    let take = Array([[Float]](repeating: clip, count: 4).joined())  // about 25 s of speech
    let expected =
      "the quick brown fox jumps over the lazy dog while the morning sun rises slowly above the quiet hills"

    // Admission is asked before anything touches the file.
    let refusedResidency = TranscribeCppPreviewResidency()
    let refused = TranscribeCppPreviewRuntime(
      driver: LiveWhisperExecutorDriver(), modelPath: Self.smallPath, isAdmitted: { false },
      residency: refusedResidency)
    await #expect(throws: TranscribeCppPreviewRuntime.LoadFailure.notAdmitted) {
      try await refused.ensureLoaded()
    }
    #expect(refusedResidency.loadedCount == 0)

    let turbo = TranscribeCppRealBoundaryFixture.modelPath
    let heart = TranscribeCppWhisperBackend(
      driver: LiveWhisperExecutorDriver(), modelVariant: "whisper-large-v3-turbo-Q8_0",
      admittedModelPath: { turbo })
    try await heart.prepare()

    let residency = TranscribeCppPreviewResidency()
    var runtime: TranscribeCppPreviewRuntime? = TranscribeCppPreviewRuntime(
      driver: LiveWhisperExecutorDriver(), modelPath: Self.smallPath, isAdmitted: { true },
      residency: residency)
    try await runtime?.ensureLoaded()
    #expect(residency.loadedCount == 1)

    // Each take's session holds the runtime while it can decode, so each lives in its own
    // scope: the release below must be the LAST holder going, as when the app drops the engine.
    // First take: English text appears while the audio is still arriving.
    let shown = ShownTexts()
    do {
      let first = try #require(
        try await runtime?.makeSession(
          language: "en", hypothesisRetentionLimit: 2_000, onHypothesis: shown.append,
          onAudioReleased: { _ in }))
      await first.start(audioSamplesProvider: Self.recording(take))
      await TranscribeCppRollingSessionTests.within("the first preview text", seconds: 60) {
        await shown.reach(1)
    }
    #expect(Self.words(shown.all.first ?? "").contains("the quick brown fox"))

    // The heart's decode runs while the preview keeps decoding, and its text is exact.
    let beforeHeart = shown.all.count
    let heartResult = try await heart.transcribe(
      audioSamples: clip, options: TranscriptionOptions(language: "en"), onInferenceEntered: nil)
    #expect(Self.words(heartResult.text) == expected)
    await TranscribeCppRollingSessionTests.within("a preview text after the heart", seconds: 60) {
      await shown.reach(beforeHeart + 1)
    }
    #expect(shown.all.allSatisfy { $0.count <= 2_000 })
    #expect(await TranscribeCppExecutor.shared.counters.peakOccupancy == 1, "never two native runs")
    await first.cancel()
    }

    // Second take on the same loaded model.
    let again = ShownTexts()
    do {
      let second = try #require(
        try await runtime?.makeSession(
          language: "en", hypothesisRetentionLimit: 2_000, onHypothesis: again.append,
          onAudioReleased: { _ in }))
      await second.start(audioSamplesProvider: Self.recording(clip))
      await TranscribeCppRollingSessionTests.within("the reused model's text", seconds: 60) {
        await again.reach(1)
    }
    #expect(Self.words(again.all.first ?? "").contains("the quick brown fox"))
    await second.cancel()
    }
    #expect(residency.loadedCount == 1, "one load served both takes")

    // Every holder let go: the preview model is freed.
    runtime = nil
    await TranscribeCppRollingSessionTests.within("the released preview model's free") {
      await residency.waitUntilNoneLoaded()
    }
    #expect(residency.loadedCount == 0)
    await heart.unload()
  }
}

/// Texts the preview handed over, with a wait for a count.
private final class ShownTexts: @unchecked Sendable {
  private let lock = NSLock()
  private var texts: [String] = []
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
  var all: [String] { lock.withLock { texts } }
  func append(_ text: String) {
    let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      texts.append(text)
      let met = waiters.filter { $0.0 <= texts.count }.map(\.1)
      waiters.removeAll { $0.0 <= texts.count }
      return met
    }
    for waiter in ready { waiter.resume() }
  }
  func reach(_ count: Int) async {
    await withCheckedContinuation { c in
      let now = lock.withLock { () -> Bool in
        if texts.count >= count { return true }
        waiters.append((count, c))
        return false
      }
      if now { c.resume() }
    }
  }
}

/// Fractions arrive on the native running thread; record under a lock.
private final class ProgressFractions: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Double] = []
  func record(_ value: Double) { lock.withLock { values.append(value) } }
  func snapshot() -> [Double] { lock.withLock { values } }
}

/// Progress arrives on the native running thread; record under a lock.
private final class ProgressRecorder: @unchecked Sendable {
  struct Call {
    let advanced: Int64
    let total: Int64
  }
  private let lock = NSLock()
  private var calls: [Call] = []
  func record(advanced: Int64, total: Int64) {
    lock.lock()
    calls.append(Call(advanced: advanced, total: total))
    lock.unlock()
  }
  func snapshot() -> [Call] {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }
}

/// Records each native decode's input length, then forwards to the real executor.
private struct CountingDriver: WhisperExecutorDriving {
  typealias Handle = TranscribeCppExecutor.ModelHandle
  let live = LiveWhisperExecutorDriver()
  let inputs = OSAllocatedUnfairLock<[Int]>(initialState: [])

  func load(modelPath: String, lane: TranscribeCppExecutor.Lane) async throws -> Handle {
    try await live.load(modelPath: modelPath, lane: lane)
  }
  func detectLanguage(_ handle: Handle, samples: [Float], lane: TranscribeCppExecutor.Lane)
    async throws -> TranscribeCppLanguageObservation
  {
    try await live.detectLanguage(handle, samples: samples, lane: lane)
  }
  func transcribe(
    _ handle: Handle, samples: [Float], language: String?, lane: TranscribeCppExecutor.Lane,
    onInferenceEntered: (@Sendable () -> Void)?, onProgress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws -> TranscribeCppRunResult {
    inputs.withLock { $0.append(samples.count) }
    return try await live.transcribe(
      handle, samples: samples, language: language, lane: lane,
      onInferenceEntered: onInferenceEntered, onProgress: onProgress)
  }
  func waitForDrain(_ handle: Handle) async { await live.waitForDrain(handle) }
  func unload(_ handle: Handle) async { await live.unload(handle) }
  func awaitSettled(openedOn lane: TranscribeCppExecutor.Lane) async -> Int {
    await live.awaitSettled(openedOn: lane)
  }
}

/// #4254 on the real models: the pinned Silero detector through its production loader (from a
/// fixture bundle holding the checked-in asset) and the approved turbo Q8_0 decoder.
private enum MeetingVADFixture {
  static var modelBundle: Bundle {
    get throws {
      let model = TranscribeCppRealBoundaryFixture.repoRoot.appending(
        path: "Sources/EnviousWispr/Resources/VAD/\(MeetingSpeechDetector.modelVersion).mlmodelc")
      try #require(FileManager.default.fileExists(atPath: model.path), "pinned VAD model missing")
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingVADFixture-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("\(MeetingSpeechDetector.modelVersion).mlmodelc"),
        withDestinationURL: model)
      return try #require(Bundle(path: root.path))
    }
  }

  /// The committed clip's words, the literal reference.
  static let script = TranscribeCppRealBoundaryFixture.expectedWords

  /// A second, different committed clip and its script (`scripts/freeze-suite/mumbled-speech.txt`).
  static let otherURL = TranscribeCppRealBoundaryFixture.repoRoot.appending(
    path: "scripts/freeze-suite/clips/mumbled-speech.wav")
  static var otherScript: String {
    get throws {
      try String(
        contentsOf: TranscribeCppRealBoundaryFixture.repoRoot.appending(
          path: "scripts/freeze-suite/mumbled-speech.txt"), encoding: .utf8)
    }
  }

  static func words(_ text: String) -> [String] {
    text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
  }
}

@Suite("Meeting Whisper speech detection on the real models (#4254)", .serialized, .tags(.productOutcome))
struct MeetingWhisperVADRealBoundaryTests {
  @Test(
    "speech, 20 s of silence, speech: only speech is decoded, both sides survive, times come back",
    .enabled(if: TranscribeCppRealBoundaryFixture.modelIsPresent),
    .tags(.realBoundary), .timeLimit(.minutes(5)), .realBoundaryRun
  )
  func protectedSpeechOnRealModels() async throws {
    try TranscribeCppRealBoundaryFixture.requireExpectedModel()
    let bundle = try MeetingVADFixture.modelBundle
    let clip = try AudioConverter().resampleAudioFile(
      path: TranscribeCppRealBoundaryFixture.audioURL.path)
    let other = try AudioConverter().resampleAudioFile(path: MeetingVADFixture.otherURL.path)
    let gap = 20 * 16_000
    let run = clip + [Float](repeating: 0, count: gap) + other
    let driver = CountingDriver()
    let detectorRuns = OSAllocatedUnfairLock(initialState: 0)
    let engine = MeetingWhisperEngine(driver: driver) { samples in
      detectorRuns.withLock { $0 += 1 }
      return try await MeetingSpeechDetector.spans(in: samples, modelBundle: bundle)
    }
    try await engine.load(modelPath: TranscribeCppRealBoundaryFixture.modelPath)
    let result = try await engine.transcribe(samples: run, language: "en")
    await engine.unload()

    #expect(detectorRuns.withLock { $0 } == 1)
    #expect(result.meetingSpeechPreparation == .protectedSpeech, "the detector really ran")
    let decoded = try #require(driver.inputs.withLock { $0 }.first)
    #expect(decoded < run.count, "the silent gap never reached the decoder: \(decoded) of \(run.count)")
    let words = MeetingVADFixture.words(result.text)
    let script = MeetingVADFixture.words(MeetingVADFixture.script)
    #expect(Array(words.prefix(script.count)) == script, "the first side, whole: \(result.text)")
    #expect(words.contains("dinner"), "the second side survives: \(result.text)")
    #expect(!words.contains("thank"), "nothing invented over the gap: \(result.text)")
    let clipMs = clip.count * 1000 / 16_000
    let timed = (result.segmentTimings ?? []).compactMap { t in t.startMs.map { ($0, t.endMs ?? $0) } }
    #expect(timed.contains { $0.0 < clipMs }, "a line in the first spoken side")
    #expect(timed.contains { $0.0 >= clipMs + 20_000 - 200 }, "a line restored past the gap: \(timed)")
    #expect(timed.allSatisfy { $0.1 <= run.count * 1000 / 16_000 })
  }

  @Test(
    "30 s of exact zeros: confirmed silence, empty, and the decoder is never entered",
    .enabled(if: TranscribeCppRealBoundaryFixture.modelIsPresent),
    .tags(.realBoundary), .timeLimit(.minutes(3)), .realBoundaryRun
  )
  func confirmedSilenceOnRealModels() async throws {
    try TranscribeCppRealBoundaryFixture.requireExpectedModel()
    let bundle = try MeetingVADFixture.modelBundle
    let driver = CountingDriver()
    let engine = MeetingWhisperEngine(driver: driver) { samples in
      try await MeetingSpeechDetector.spans(in: samples, modelBundle: bundle)
    }
    try await engine.load(modelPath: TranscribeCppRealBoundaryFixture.modelPath)
    let result = try await engine.transcribe(
      samples: [Float](repeating: 0, count: 30 * 16_000), language: "en")
    await engine.unload()
    #expect(result.meetingSpeechPreparation == .confirmedSilence)
    #expect(result.text.isEmpty)
    #expect(driver.inputs.withLock { $0 }.isEmpty, "no native call")
  }

  /// The Q-b failures as regression cases through the production decode (plan §17): each
  /// input's literal ordered reference, zero edits, nothing invented over silence, and each
  /// second sentence placed within 0.5 s of when it was spoken.
  @Test(
    "speech groups keep every word: repeated, independently repeated, distinct, long gap, room tone below the gap",
    .enabled(if: TranscribeCppRealBoundaryFixture.modelIsPresent),
    .tags(.realBoundary), .timeLimit(.minutes(10)), .realBoundaryRun
  )
  func groupedDecodeRegressions() async throws {
    try TranscribeCppRealBoundaryFixture.requireExpectedModel()
    let bundle = try MeetingVADFixture.modelBundle
    let rate = 16_000
    let clipA = try AudioConverter().resampleAudioFile(
      path: TranscribeCppRealBoundaryFixture.audioURL.path)
    let clipB = try AudioConverter().resampleAudioFile(path: MeetingVADFixture.otherURL.path)
    let room = try AudioConverter().resampleAudioFile(
      path: TranscribeCppRealBoundaryFixture.repoRoot.appending(
        path: "scripts/freeze-suite/clips/background-noise.wav").path)
    let scriptA = MeetingVADFixture.words(MeetingVADFixture.script)
    let scriptB = MeetingVADFixture.words(try MeetingVADFixture.otherScript)
    let takeURL = FileManager.default.temporaryDirectory.appendingPathComponent("grp-take-\(UUID().uuidString).wav")
    let say = Process()
    say.executableURL = URL(filePath: "/usr/bin/say")
    say.arguments = ["-o", takeURL.path, "--file-format=WAVE", "--data-format=LEI16@16000", MeetingVADFixture.script]
    try say.run()
    say.waitUntilExit()
    try #require(say.terminationStatus == 0, "local voice for the independent take")
    let takeA2 = try AudioConverter().resampleAudioFile(path: takeURL.path)
    func zeros(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Double(rate))) }
    var roomTone: [Float] = []
    while roomTone.count < Int(7.5 * Double(rate)) { roomTone += room }
    roomTone = Array(roomTone.prefix(Int(7.5 * Double(rate))))
    let cases: [(String, [Float], [String], Int)] = [
      ("repeat_exact", zeros(3) + clipA + zeros(13.5) + clipA, scriptA + scriptA, 3 * rate + clipA.count + Int(13.5 * Double(rate))),
      ("repeat_take2", zeros(3) + clipA + zeros(13.5) + takeA2, scriptA + scriptA, 3 * rate + clipA.count + Int(13.5 * Double(rate))),
      ("repeat_close", zeros(3) + clipA + zeros(1) + takeA2, scriptA + scriptA, 3 * rate + clipA.count + rate),
      ("distinct", zeros(3) + clipA + zeros(8.3) + clipB, scriptA + scriptB, 3 * rate + clipA.count + Int(8.3 * Double(rate))),
      ("control60", clipA + zeros(60) + clipA, scriptA + scriptA, clipA.count + 60 * rate),
      ("room_tone_7_5s", zeros(1) + clipA + roomTone + clipB, scriptA + scriptB, rate + clipA.count + roomTone.count),
    ]
    let driver = CountingDriver()
    let engine = MeetingWhisperEngine(driver: driver) { samples in
      try await MeetingSpeechDetector.spans(in: samples, modelBundle: bundle)
    }
    try await engine.load(modelPath: TranscribeCppRealBoundaryFixture.modelPath)
    var failures: [String] = []
    for (name, samples, reference, secondStart) in cases {
      let before = driver.inputs.withLock { $0.count }
      let result = try await engine.transcribe(samples: samples, language: "en")
      let calls = driver.inputs.withLock { $0.count } - before
      let words = MeetingVADFixture.words(result.text)
      let edits = WordDiff.edits(reference: reference, hypothesis: words)
      let starts = (result.segmentTimings ?? []).compactMap(\.startMs)
      let secondMs = secondStart * 1000 / rate
      let placed = starts.contains { abs($0 - secondMs) <= 500 }
      print("GRP case=\(name) calls=\(calls) provenance=\(String(describing: result.meetingSpeechPreparation)) words=\(words.count)/\(reference.count) edits=\(edits.isEmpty ? "none" : edits.joined(separator: ";")) second_spoken_ms=\(secondMs) starts=\(starts) placed=\(placed)")
      #expect(result.meetingSpeechPreparation == .protectedSpeech, "\(name)")
      // repeat_close keeps its 1 s pause inside one group: it is decoded exactly as spoken, so
      // its words are the as-spoken baseline (reported, not a VAD outcome).
      guard name != "repeat_close" else { continue }
      if !edits.isEmpty { failures.append("\(name): \(edits)") }
      #expect(edits.isEmpty, "\(name): \(result.text)")
      #expect(placed, "\(name): second sentence within 0.5 s of \(secondMs) ms: \(starts)")
    }
    await engine.unload()
    print("GRP failures=\(failures.count)")
  }

  /// Plan §17 performance: two hour-scale runs, dense speech and many short groups separated
  /// by gaps above the grouping gap, decoded grouped and without detection. Prints `PERF`
  /// lines: groups, native calls, elapsed seconds and peak footprint.
  @Test(
    "hour-scale cost of grouped decoding: dense speech and many short groups",
    .enabled(if: TranscribeCppRealBoundaryFixture.modelIsPresent),
    .tags(.realBoundary), .timeLimit(.minutes(20)), .realBoundaryRun
  )
  func groupedDecodeHourCost() async throws {
    try TranscribeCppRealBoundaryFixture.requireExpectedModel()
    let bundle = try MeetingVADFixture.modelBundle
    let rate = 16_000
    let clip = try AudioConverter().resampleAudioFile(
      path: TranscribeCppRealBoundaryFixture.audioURL.path)
    let hour = 3_600 * rate
    var dense: [Float] = []
    dense.reserveCapacity(hour)
    while dense.count < hour { dense.append(contentsOf: clip.prefix(hour - dense.count)) }
    var sparse: [Float] = []
    sparse.reserveCapacity(hour)
    while sparse.count < hour {
      sparse.append(contentsOf: clip.prefix(hour - sparse.count))
      sparse.append(contentsOf: repeatElement(0, count: min(10 * rate, max(0, hour - sparse.count))))
    }
    func footprintMB() -> Double {
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
      let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
      }
      return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    struct NoDetector: Error {}
    for (name, samples) in [("dense", dense), ("sparse", sparse)] {
      for (arm, grouped) in [("grouped", true), ("no_vad", false)] {
        let driver = CountingDriver()
        let engine = MeetingWhisperEngine(driver: driver) { input in
          guard grouped else { throw NoDetector() }
          return try await MeetingSpeechDetector.spans(in: input, modelBundle: bundle)
        }
        try await engine.load(modelPath: TranscribeCppRealBoundaryFixture.modelPath)
        let peak = OSAllocatedUnfairLock(initialState: footprintMB())
        // detached: samples the process from outside the decode being measured.
        let sampler = Task.detached {
          while !Task.isCancelled {
            let now = footprintMB()
            peak.withLock { $0 = max($0, now) }
            try? await Task.sleep(for: .milliseconds(100))  // test-fixture-timer: sampling period
          }
        }
        let start = ContinuousClock.now
        let result = try await engine.transcribe(samples: samples, language: "en")
        let elapsed = ContinuousClock.now - start
        sampler.cancel()
        _ = await sampler.value
        await engine.unload()
        let calls = driver.inputs.withLock { $0 }
        print("PERF run=\(name) arm=\(arm) native_calls=\(calls.count) decoded_samples=\(calls.reduce(0, +)) elapsed_s=\(elapsed.components.seconds) peak_mb=\(Int(peak.withLock { $0 })) words=\(MeetingVADFixture.words(result.text).count) provenance=\(String(describing: result.meetingSpeechPreparation))")
        #expect(!calls.isEmpty)
      }
    }
  }

  /// Q-b diagnostic (buddy round 2): where the second of two spoken repetitions is lost, and
  /// how the smallest remedies compare, WITHOUT changing production preparation. Every arm
  /// goes through the same steps as `meetingDecode`: one native decode of the prepared input,
  /// segment times restored onto the ORIGINAL run, the silent-tail filter on the original
  /// samples, binding on the original bounds. Arms: leading-only trimming, gap removal (the
  /// production zero-separator join), a 1 s synthetic separator (mapped as removed time), and
  /// an experimental cap keeping one second of original audio at each edge of every removed
  /// gap. Each arm runs twice. Prints `QB2` lines for the receipt; a PASS here is not a
  /// speech-preservation pass.
  @Test(
    "Q-b diagnostic: where repeated speech is lost; gap removal, separator and capped gap",
    .enabled(if: TranscribeCppRealBoundaryFixture.modelIsPresent),
    .tags(.realBoundary), .timeLimit(.minutes(15)), .realBoundaryRun
  )
  func interiorGapExperiment() async throws {
    try TranscribeCppRealBoundaryFixture.requireExpectedModel()
    let bundle = try MeetingVADFixture.modelBundle
    let rate = 16_000
    let clipA = try AudioConverter().resampleAudioFile(
      path: TranscribeCppRealBoundaryFixture.audioURL.path)
    let clipB = try AudioConverter().resampleAudioFile(path: MeetingVADFixture.otherURL.path)
    let scriptA = MeetingVADFixture.words(MeetingVADFixture.script)
    let scriptB = MeetingVADFixture.words(try MeetingVADFixture.otherScript)
    // An independently spoken take of script A, from the local macOS voice (no network).
    let takeURL = FileManager.default.temporaryDirectory.appendingPathComponent("qb-take-\(UUID().uuidString).wav")
    let say = Process()
    say.executableURL = URL(filePath: "/usr/bin/say")
    say.arguments = ["-o", takeURL.path, "--file-format=WAVE", "--data-format=LEI16@16000", MeetingVADFixture.script]
    try say.run()
    say.waitUntilExit()
    let takeA2: [Float]? = say.terminationStatus == 0
      ? try? AudioConverter().resampleAudioFile(path: takeURL.path) : nil
    print("QB2 take2 available=\(takeA2 != nil) samples=\(takeA2?.count ?? 0) voice=macOS-default")

    func window(_ first: [Float], _ second: [Float], total: Int = 30) -> [Float] {
      let lead = 3 * rate
      let gap = max(rate, total * rate - lead - first.count - second.count - rate)
      return [Float](repeating: 0, count: lead) + first + [Float](repeating: 0, count: gap) + second
        + [Float](repeating: 0, count: rate)
    }
    var inputs: [(name: String, samples: [Float], reference: [String], speech: [Range<Int>])] = []
    func add(_ name: String, _ first: [Float], _ second: [Float], _ reference: [String]) {
      let w = window(first, second)
      let s1 = 3 * rate..<(3 * rate + first.count)
      let s2 = (w.count - rate - second.count)..<(w.count - rate)
      inputs.append((name, w, reference, [s1, s2]))
    }
    add("distinct", clipA, clipB, scriptA + scriptB)
    add("repeat_exact", clipA, clipA, scriptA + scriptA)
    if let takeA2 { add("repeat_take2", clipA, takeA2, scriptA + scriptA) }
    let control = clipA + [Float](repeating: 0, count: 60 * rate) + clipA
    inputs.append(("control60", control, scriptA + scriptA, [0..<clipA.count, (control.count - clipA.count)..<control.count]))

    let driver = LiveWhisperExecutorDriver()
    let handle = try await driver.load(modelPath: TranscribeCppRealBoundaryFixture.modelPath, lane: .preview)
    var armRuns = 0
    for input in inputs {
      let spans = try await MeetingSpeechDetector.spans(in: input.samples, modelBundle: bundle)
      let ms = { (r: Range<Int>) in "\(r.lowerBound * 1000 / rate)-\(r.upperBound * 1000 / rate)" }
      print("QB2 input=\(input.name) seconds=\(input.samples.count / rate) spoken_ms=\(input.speech.map(ms)) detected_ms=\(spans.map(ms)) reference=\(input.reference.count)_words")
      guard let first = spans.first?.lowerBound else { continue }
      // Experimental cap: one second of original audio kept at each edge of every removed gap.
      var capped: [Range<Int>] = []
      for span in spans {
        if let last = capped.last, span.lowerBound - last.upperBound <= 2 * rate {
          capped[capped.count - 1] = last.lowerBound..<span.upperBound
        } else if let last = capped.last {
          capped[capped.count - 1] = last.lowerBound..<(last.upperBound + rate)
          capped.append((span.lowerBound - rate)..<span.upperBound)
        } else {
          capped.append(span)
        }
      }
      let arms: [(String, [Range<Int>], Int)] = [
        ("leading_only", [first..<input.samples.count], 0), ("gap_removed", spans, 0),
        ("separator_1s", spans, rate), ("capped_gap_2s", capped, 0),
      ]
      for (arm, stretches, separator) in arms {
        for repeatIndex in 0..<2 {
          let map = SeparatedMap(stretches: stretches, separator: separator, original: input.samples.count)
          let decoderInput = map.input(from: input.samples, lookAhead: 8_000)
          let native = try await driver.transcribe(
            handle, samples: decoderInput, language: "en", lane: .preview, onInferenceEntered: nil,
            onProgress: nil)
          let restored = map.restore(native)
          let tail = WhisperSilentTailFilter.filter(
            restored, statsSamples: input.samples, segmentOffsetSamples: 0,
            realEndSample: input.samples.count)
          let result = TranscribeCppWhisperBackend<LiveWhisperExecutorDriver>.mapResult(
            tail.result, languageHint: "en", envelope: 0..<input.samples.count,
            originalSampleCount: input.samples.count, processingTime: 0, enableTimestamps: true)
          armRuns += 1
          let finalWords = MeetingVADFixture.words(result.text)
          let edits = WordDiff.edits(reference: input.reference, hypothesis: finalWords)
          print("QB2 arm=\(input.name)/\(arm) repeat=\(repeatIndex) decoder_input_samples=\(decoderInput.count) native_words=\(MeetingVADFixture.words(native.text).count) native_segments_decoder_ms=\(native.segments.map { "\($0.startMs)-\($0.endMs)" }) restored_segments_original_ms=\(restored.segments.map { "\($0.startMs)-\($0.endMs)" }) filter_dropped=\(tail.dropped) final_words=\(finalWords.count) reference=\(input.reference.count) edits=\(edits.isEmpty ? "none" : edits.joined(separator: ";"))")
          if repeatIndex == 0 { print("QB2 text arm=\(input.name)/\(arm) native=\"\(native.text.trimmingCharacters(in: .whitespaces))\" final=\"\(result.text)\"") }
        }
      }
    }
    await driver.unload(handle)
    #expect(armRuns == inputs.count * 4 * 2, "every arm and repetition ran: \(armRuns)")
  }

}

/// Decoder layout for the Q-b diagnostic: stretches joined with `separator` synthetic zeros
/// between them. A decoded start inside a separator belongs to the following stretch, an end
/// to the preceding one; `separator == 0` is the production map (`MeetingWhisperPreparation`).
private struct SeparatedMap {
  let stretches: [Range<Int>]
  let separator: Int
  let original: Int

  var speech: Int { stretches.reduce(0) { $0 + $1.count } + separator * max(0, stretches.count - 1) }

  func input(from samples: [Float], lookAhead: Int) -> [Float] {
    var out: [Float] = []
    out.reserveCapacity(speech + lookAhead)
    for (i, s) in stretches.enumerated() {
      if i > 0 { out.append(contentsOf: repeatElement(0, count: separator)) }
      out.append(contentsOf: samples[s])
    }
    out.append(contentsOf: repeatElement(0, count: lookAhead))
    return out
  }

  func start(_ d: Int) -> Int {
    guard d >= 0 else { return d }
    guard d < speech else { return original + (d - speech) }
    var offset = 0
    for (i, s) in stretches.enumerated() {
      if d < offset + s.count { return s.lowerBound + (d - offset) }
      offset += s.count
      if i + 1 < stretches.count {
        if d < offset + separator { return stretches[i + 1].lowerBound }
        offset += separator
      }
    }
    return original
  }

  func end(_ d: Int) -> Int {
    guard d > 0 else { return d }
    guard d <= speech else { return original + (d - speech) }
    var offset = 0
    for (i, s) in stretches.enumerated() {
      if d <= offset + s.count { return s.lowerBound + (d - offset) }
      offset += s.count
      if i + 1 < stretches.count {
        if d <= offset + separator { return s.upperBound }
        offset += separator
      }
    }
    return original
  }

  func restore(_ run: TranscribeCppRunResult) -> TranscribeCppRunResult {
    let segments = run.segments.map { seg -> TranscribeCppSegment in
      guard seg.startMs >= 0, seg.endMs >= seg.startMs else { return seg }
      let a = start(Int(seg.startMs) * 16)
      let b = max(a, end(Int(seg.endMs) * 16))
      return TranscribeCppSegment(startMs: Int64(a / 16), endMs: Int64(b / 16), text: seg.text)
    }
    return TranscribeCppRunResult(
      text: run.text, detectedLanguage: run.detectedLanguage, segments: segments)
  }
}

/// Ordered word edits between a literal reference and a result (minimum edit distance).
private enum WordDiff {
  static func edits(reference r: [String], hypothesis h: [String]) -> [String] {
    var d = [[Int]](repeating: [Int](repeating: 0, count: h.count + 1), count: r.count + 1)
    for i in 0...r.count { d[i][0] = i }
    for j in 0...h.count { d[0][j] = j }
    if !r.isEmpty && !h.isEmpty {
      for i in 1...r.count {
        for j in 1...h.count {
          d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
        }
      }
    }
    var out: [String] = []
    var i = r.count
    var j = h.count
    while i > 0 || j > 0 {
      if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1) {
        if r[i - 1] != h[j - 1] { out.append("sub@\(i - 1):\(r[i - 1])->\(h[j - 1])") }
        i -= 1
        j -= 1
      } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
        out.append("del@\(i - 1):\(r[i - 1])")
        i -= 1
      } else {
        out.append("ins@\(i):\(h[j - 1])")
        j -= 1
      }
    }
    return out.reversed()
  }
}
