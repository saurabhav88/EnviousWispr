import CryptoKit
import Darwin
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
