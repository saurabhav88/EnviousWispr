import EnviousWisprObservabilityCore
import Foundation
import Sentry
import Testing

@testable import EnviousWisprServices

/// #1095 — redaction tripwire. Asserts that dictation text can never reach the
/// FINAL diagnostic payload, by exercising the EXACT functions the SDK runs:
/// `ObservabilityBootstrap.sanitizeSentryEvent` (the `beforeSend` body) and
/// `sanitizePostHogProperties` (the PostHog `beforeSend` body). Asserting on
/// these — not the pre-SDK `captureErrorDelegate`, which fires BEFORE
/// `beforeSend` — is what makes this a real guarantee instead of theater.
///
/// What the B+ design guarantees, and how each is proven here:
///  1. STRUCTURAL message — the captured `message` is `category: domain#code`,
///     never `error.localizedDescription`, so a transcript can't enter the
///     message surface at ANY length (Layer A; `structuralMessage*`).
///  2. TRANSCRIPT-LENGTH content (the actual shape of dictation — long-form
///     free text) is scrubbed from every event surface by the denylist
///     (`denylistScrubsTranscript*`, `postHog*`).
///  3. NATIVE-CRASH paths — host name cleared, `/Users/<name>/` usernames
///     scrubbed from stack frames and debug images (Layer C; `nativeCrash*`).
///  4. PRODUCERS emit counts/codes, never text — even fed a transcript, the
///     real builder yields only counts (`realBuilder*`).
///
/// Explicit NON-guarantee (deferred option C, documented honestly): an
/// arbitrary SHORT string placed in a hypothetical future rogue key is NOT
/// scrubbed by the denylist. B+ does not claim it is — that's covered instead
/// by guarantee 4 (producers never put transcript text in a field) and would
/// only need the full key-allowlist rebuild if a regulator-grade claim were
/// required. So the sentinel below is transcript-SHAPED for denylist surfaces.

/// File-scope `private` fixture reproducing `EmojiRestoreAnomaly`
/// (`EmojiRestoreStep.swift`)'s pre-#1525-PR-H shape — a file-scope `private`
/// Swift error type (PR H later widened it to `internal` so its pin can be
/// tested directly, `PRHLeftoverErrorsSentryIdentityTests.swift`). Its bridged
/// `NSError.domain` carries the same `(unknown context at $ptr)` artifact as a
/// nested `private` type (#1229; empirically verified via `swiftc` — the
/// descriptor fix is type-shape-agnostic).
private enum FileScopeFixtureError: Error {
  case boom
}

/// Wrapper exposing a `private`-nested fixture that reproduces
/// `RecoveryReplayError` / `RecoveryArmError`'s pre-#1525-PR-C shape and
/// `NilCollaboratorError`'s pre-#1525-PR-H shape — all three were `private`
/// nested inside their owning type; PR C and PR H later widened them to
/// `internal` so their pins can be tested directly
/// (`RecoverySentryIdentityTests.swift`, `PRHLeftoverErrorsSentryIdentityTests.swift`).
/// This fixture continues to cover the generic `(unknown context at $ptr)`
/// normalization branch (#1229).
private struct NestedFixtureWrapper {
  private enum NestedFixtureError: Error {
    case boom
  }
  static func makeError() -> Error { NestedFixtureError.boom }
}

@Suite("Sentry/PostHog redaction tripwire (#1095)")
struct SentryEventSanitizerTests {

  /// Unique phrase searched for across the final payload.
  private static let marker = "PURPLE ELEPHANT SEVENTEEN"
  /// A realistic dictation transcript (>100 chars, the denylist threshold)
  /// that embeds the marker — this is the shape of real leaked content.
  private static let transcript =
    "Reminder to self, please email the whole team about the schedule change "
    + "for next week and mention that the code phrase is \(marker) before the call."
  /// A path-segment marker (no spaces/slashes) for the username in crash paths.
  private static let userMarker = "PURPLE-ELEPHANT-USER"

  // MARK: - Layer A: structural message

  @Test("structured descriptor is domain#code, never the localizedDescription")
  func structuralMessageDropsLocalizedDescription() {
    let err = NSError(
      domain: "AVFoundationErrorDomain", code: -11800,
      userInfo: [NSLocalizedDescriptionKey: Self.marker])

    let descriptor = SentryBreadcrumb.structuredDescriptor(err)
    #expect(descriptor == "AVFoundationErrorDomain#-11800")
    #expect(descriptor.contains(Self.marker) == false)

    // The message `captureError` composes, run through the FINAL sanitizer.
    let event = Event(level: .error)
    event.message = SentryMessage(
      formatted:
        "\(SentryBreadcrumb.ErrorCategory.audioCaptureFailed.rawValue): \(descriptor)")
    let sanitized = ObservabilityBootstrap.sanitizeSentryEvent(event)

    #expect(sanitized.message?.formatted == "audio_capture_failed: AVFoundationErrorDomain#-11800")
    #expect(payloadContainsMarker(sanitized) == false)
  }

  @Test("structural message holds even for a SHORT dictated phrase")
  func structuralMessageDropsShortPhrase() {
    // The denylist would NOT catch this short phrase — Layer A's structural
    // rule is what guarantees it can't enter the message at all.
    let shortPhrase = "call mom tomorrow"
    let err = NSError(
      domain: "MyDomain", code: 7,
      userInfo: [NSLocalizedDescriptionKey: shortPhrase])
    let descriptor = SentryBreadcrumb.structuredDescriptor(err)
    #expect(descriptor == "MyDomain#7")
    #expect(descriptor.contains(shortPhrase) == false)
  }

  // MARK: - Layer A: (unknown context) normalization (#1229)

  /// A `private`/nested Swift error type's bridged `NSError.domain` demangles to
  /// `…(unknown context at $<ptr>).TypeName` — long enough (>100 chars) to trip
  /// the `>100`-char denylist rule below and wipe the whole message to
  /// `[REDACTED]`, with a per-launch pointer that also fragments grouping. The
  /// descriptor must normalize this to the plain simple type name instead.
  @Test("file-scope private error descriptor normalizes (unknown context) to the simple type name")
  func fileScopePrivateErrorDescriptorNormalizes() {
    let descriptor = SentryBreadcrumb.structuredDescriptor(FileScopeFixtureError.boom)
    #expect(descriptor == "FileScopeFixtureError#0")
    #expect(descriptor.contains("(unknown context") == false)
    #expect(descriptor.contains("$") == false)
    #expect(descriptor.count < 100)

    let event = Event(level: .error)
    event.message = SentryMessage(
      formatted:
        "\(SentryBreadcrumb.ErrorCategory.recoveryTranscribeFailed.rawValue): \(descriptor)"
    )
    let sanitized = ObservabilityBootstrap.sanitizeSentryEvent(event)
    #expect(sanitized.message?.formatted == "recovery_transcribe_failed: FileScopeFixtureError#0")
  }

  @Test("nested private error descriptor normalizes (unknown context) to the simple type name")
  func nestedPrivateErrorDescriptorNormalizes() {
    let descriptor = SentryBreadcrumb.structuredDescriptor(NestedFixtureWrapper.makeError())
    #expect(descriptor == "NestedFixtureError#0")
    #expect(descriptor.contains("(unknown context") == false)
    #expect(descriptor.contains("$") == false)
    #expect(descriptor.count < 100)

    let event = Event(level: .error)
    event.message = SentryMessage(
      formatted:
        "\(SentryBreadcrumb.ErrorCategory.recoveryTranscribeFailed.rawValue): \(descriptor)"
    )
    let sanitized = ObservabilityBootstrap.sanitizeSentryEvent(event)
    #expect(sanitized.message?.formatted == "recovery_transcribe_failed: NestedFixtureError#0")
  }

  // MARK: - Layer D: denylist scrubs transcript-length content from every surface

  @Test("transcript-length content is scrubbed from every Sentry surface")
  func denylistScrubsTranscriptFromEverySurface() {
    #expect(Self.transcript.count > 100)  // premise: it trips the >100 denylist rule

    let event = Event(level: .error)
    event.message = SentryMessage(formatted: Self.transcript)
    event.extra = ["note": Self.transcript, "nested": ["deep": Self.transcript]]
    event.tags = ["some_tag": Self.transcript]
    event.context = ["diag": ["field": Self.transcript]]

    let crumb = Breadcrumb(level: .info, category: "pipeline.test")
    crumb.message = Self.transcript
    crumb.data = ["crumb_note": Self.transcript]
    event.breadcrumbs = [crumb]

    let exc = Exception(value: Self.transcript, type: "TestError")
    let mech = Mechanism(type: "test")
    mech.data = ["mech_note": Self.transcript]
    exc.mechanism = mech
    event.exceptions = [exc]

    let sanitized = ObservabilityBootstrap.sanitizeSentryEvent(event)
    #expect(payloadContainsMarker(sanitized) == false)
  }

  // MARK: - Layer C: native-crash field coverage

  @Test("native-crash fixture: serverName nil + usernames scrubbed from paths")
  func nativeCrashPathsAndServerNameScrubbed() {
    // Native crash shape: no message; threads + debugMeta carrying real paths.
    let event = Event()
    event.serverName = "\(Self.userMarker)-MacBook-Pro.local"

    // Frames live in THREE serialized surfaces — cover them all.
    let threadFrame = Frame()
    threadFrame.package =
      "/Users/\(Self.userMarker)/Library/Developer/Xcode/DerivedData/EnviousWispr/Build/Products/Release/EnviousWispr.app/Contents/MacOS/EnviousWispr"
    threadFrame.fileName = "/Users/\(Self.userMarker)/dev/EnviousWispr/Sources/Foo.swift"
    let thread = SentryThread(threadId: NSNumber(value: 0))
    thread.stacktrace = SentryStacktrace(frames: [threadFrame], registers: [:])
    event.threads = [thread]

    // event.stacktrace (separate top-level stacktrace).
    let eventFrame = Frame()
    eventFrame.package = "/Users/\(Self.userMarker)/dev/EnviousWispr/event-frame"
    event.stacktrace = SentryStacktrace(frames: [eventFrame], registers: [:])

    // exception.stacktrace (native crashes set the crashed thread's stacktrace
    // directly on the exception — the surface Codex flagged as missed).
    let excFrame = Frame()
    excFrame.fileName = "/Users/\(Self.userMarker)/dev/EnviousWispr/exc-frame.swift"
    let exc = Exception(value: "EXC_BAD_ACCESS", type: "SIGSEGV")
    exc.stacktrace = SentryStacktrace(frames: [excFrame], registers: [:])
    event.exceptions = [exc]

    let meta = DebugMeta()
    meta.codeFile =
      "/Users/\(Self.userMarker)/Library/Developer/CoreSimulator/EnviousWispr.app/Contents/MacOS/EnviousWispr"
    event.debugMeta = [meta]

    let sanitized = ObservabilityBootstrap.sanitizeSentryEvent(event)

    #expect(sanitized.serverName == nil)
    // Username gone from every frame surface, but path STRUCTURE preserved.
    #expect(threadFrame.package?.contains(Self.userMarker) == false)
    #expect(threadFrame.package?.hasPrefix("/Users/[REDACTED]/Library/Developer/") == true)
    #expect(threadFrame.fileName == "/Users/[REDACTED]/dev/EnviousWispr/Sources/Foo.swift")
    #expect(eventFrame.package?.contains(Self.userMarker) == false)
    #expect(excFrame.fileName?.contains(Self.userMarker) == false)
    #expect(meta.codeFile?.contains(Self.userMarker) == false)
    #expect(payloadContainsUserMarker(sanitized) == false)
  }

  @Test("redactUserPath replaces only the username segment, is a no-op otherwise, idempotent")
  func redactUserPathContract() {
    #expect(
      ObservabilityBootstrap.redactUserPath("/Users/saurabh/dev/x.swift")
        == "/Users/[REDACTED]/dev/x.swift")
    // No /Users/<name> segment → unchanged.
    #expect(
      ObservabilityBootstrap.redactUserPath("/Library/Frameworks/Foo.framework")
        == "/Library/Frameworks/Foo.framework")
    // Idempotent.
    let once = ObservabilityBootstrap.redactUserPath("/Users/saurabh/x")
    #expect(ObservabilityBootstrap.redactUserPath(once) == once)
  }

  // MARK: - Layer D: PostHog shares the same redactor

  @Test("PostHog properties: transcript scrubbed recursively, safe values survive")
  func postHogPropertiesSanitized() {
    let props: [String: Any] = [
      "event_name": "dictation_completed",  // safe, low-cardinality → survives
      "leak": Self.transcript,
      "nested": ["deep": Self.transcript, "arr": ["ok", Self.transcript]],
    ]
    let sanitized = ObservabilityBootstrap.sanitizePostHogProperties(props)

    #expect(sanitized["event_name"] as? String == "dictation_completed")
    #expect(sanitized["leak"] as? String == "[REDACTED]")
    let nested = sanitized["nested"] as? [String: Any]
    #expect(nested?["deep"] as? String == "[REDACTED]")
    let arr = nested?["arr"] as? [Any]
    #expect(arr?[0] as? String == "ok")
    #expect(arr?[1] as? String == "[REDACTED]")
    #expect(payloadContainsMarker(sanitized) == false)
  }

  // MARK: - Producers emit counts, never text

  @Test("real recording-snapshot builder emits counts only, never the transcript")
  func realBuilderEmitsCountsNotText() {
    // Feed a transcript containing the marker through the only transcript-aware
    // builder. It takes COUNTS, never the text — so no value can carry it.
    let dictation = Self.transcript
    let charCount = dictation.count
    let wordCount = dictation.split(separator: " ").count

    let snapshot = SentryBreadcrumb.RecordingSnapshot(
      backend: "parakeet",
      audioRoute: "built_in_mic",
      wasStreaming: false,
      startTime: Date(timeIntervalSince1970: 0),
      durationMs: 1234,
      targetAppBundleID: "com.apple.Notes",
      transcriptCharCount: charCount,
      transcriptWordCount: wordCount
    )
    let ctx = snapshot.sentryContext

    #expect(ctx["transcript_char_count"] as? Int == charCount)
    #expect(ctx["transcript_word_count"] as? Int == wordCount)
    for (_, value) in ctx {
      if let s = value as? String { #expect(s.contains(Self.marker) == false) }
    }

    // And through the final sanitizer's context path.
    let event = Event(level: .error)
    event.context = ["recording_snapshot": ctx]
    let sanitized = ObservabilityBootstrap.sanitizeSentryEvent(event)
    #expect(payloadContainsMarker(sanitized) == false)
  }

  // MARK: - Idempotency + safe values + existing denylist patterns

  @Test("sanitizeSentryEvent is idempotent and preserves safe diagnostic values")
  func idempotentAndSafeValuesSurvive() {
    let event = Event(level: .error)
    event.message = SentryMessage(formatted: Self.transcript)
    event.extra = ["route": "built_in_mic", "leak": Self.transcript]

    let first = ObservabilityBootstrap.sanitizeSentryEvent(event)
    let firstMessage = first.message?.formatted
    let firstExtra = first.extra?["leak"] as? String

    // Second pass over the already-sanitized event must not change anything.
    let second = ObservabilityBootstrap.sanitizeSentryEvent(first)
    #expect(second.message?.formatted == firstMessage)
    #expect(second.extra?["leak"] as? String == firstExtra)
    #expect((second.extra?["route"] as? String) == "built_in_mic")
    #expect(payloadContainsMarker(second) == false)
  }

  @Test("existing denylist patterns (email, API key, long hex) still redacted")
  func existingDenylistPatternsStillRedacted() {
    let event = Event(level: .error)
    event.extra = [
      "email": "saurabh@example.com",
      "key": "sk-abcdefghijklmnopqrstuvwxyz123456",
      "hex": "deadbeefdeadbeefdeadbeefdeadbeef0123",
      "safe_short": "built_in_mic",
    ]
    let sanitized = ObservabilityBootstrap.sanitizeSentryEvent(event)
    #expect(sanitized.extra?["email"] as? String == "[REDACTED]")
    #expect(sanitized.extra?["key"] as? String == "[REDACTED]")
    #expect(sanitized.extra?["hex"] as? String == "[REDACTED]")
    #expect(sanitized.extra?["safe_short"] as? String == "built_in_mic")
  }

  // MARK: - #2965: the survive direction

  /// The SDK's own trace/os/app context values and the model manifest SHA are
  /// content-free by construction and were arriving `[REDACTED]` on every Sentry
  /// event and on ~5,000 PostHog rows a month. Two-way: the SAME values under a
  /// key that is NOT allow-listed are still redacted, so the exemption is the key,
  /// never the shape.
  @Test(
    "content-free keys survive in Sentry contexts and PostHog properties; the same value under another key does not"
  )
  func contentFreeKeysSurvive() {
    let traceID = "53cd34f8daca430491da41d26b0b5149"  // 32 hex, live shape
    let spanID = "ae7c429f94234b05"
    let deviceHash = "b7c9e1d3f5a7b9c1d3e5f7a9b1c3d5e7f9a1b3c5"  // 40 hex, live shape
    let revision = "aed02740059203c4a87495924f685de3722ae9ce"  // manifest SHA, live
    let kernel =
      "Darwin Kernel Version 25.0.0: Thu Aug 14 21:17:10 PDT 2026; "
      + "root:xnu-12377.1.9~3/RELEASE_ARM64_T6041 (this banner is over one hundred characters)"
    #expect(kernel.count > 100)  // premise: trips the >100 rule without the exemption

    let event = Event(level: .error)
    event.context = [
      "trace": ["trace_id": traceID, "span_id": spanID],
      "os": ["kernel_version": kernel],
      "app": ["device_app_hash": deviceHash],
      "control": ["free_text": kernel, "token": traceID],
    ]
    event.extra = ["revision": revision, "unlisted": revision]

    let sanitized = ObservabilityBootstrap.sanitizeSentryEvent(event)
    #expect(sanitized.context?["trace"]?["trace_id"] as? String == traceID)
    #expect(sanitized.context?["trace"]?["span_id"] as? String == spanID)
    #expect(sanitized.context?["os"]?["kernel_version"] as? String == kernel)
    #expect(sanitized.context?["app"]?["device_app_hash"] as? String == deviceHash)
    #expect(sanitized.extra?["revision"] as? String == revision)
    // Control: identical values under unlisted keys still trip the heuristics.
    #expect(sanitized.context?["control"]?["free_text"] as? String == "[REDACTED]")
    #expect(sanitized.context?["control"]?["token"] as? String == "[REDACTED]")
    #expect(sanitized.extra?["unlisted"] as? String == "[REDACTED]")

    // PostHog bag goes through the same key-aware walk.
    let props = ObservabilityBootstrap.sanitizePostHogProperties([
      "revision": revision, "unlisted": revision,
      "nested": ["revision": revision, "unlisted": revision],
    ])
    #expect(props["revision"] as? String == revision)
    #expect(props["unlisted"] as? String == "[REDACTED]")
    let nested = props["nested"] as? [String: Any]
    #expect(nested?["revision"] as? String == revision)
    #expect(nested?["unlisted"] as? String == "[REDACTED]")
  }

  /// A short free-text value that passes every denylist pattern still cannot
  /// carry a home-directory username to either vendor.
  @Test(
    "a home path inside a short pass-through string has its username scrubbed on both pipelines")
  func homePathScrubbedOnPassThrough() {
    let short = "open failed: /Users/\(Self.userMarker)/Library/Application Support/x.bin"
    #expect(short.count <= 100)  // premise: NOT caught by the length rule

    let event = Event(level: .error)
    event.extra = ["error": short]
    let crumb = Breadcrumb(level: .info, category: "pipeline.test")
    crumb.message = short
    event.breadcrumbs = [crumb]
    let sanitized = ObservabilityBootstrap.sanitizeSentryEvent(event)
    #expect(
      sanitized.extra?["error"] as? String
        == "open failed: /Users/[REDACTED]/Library/Application Support/x.bin")
    #expect(payloadContainsUserMarker(sanitized) == false)

    let props = ObservabilityBootstrap.sanitizePostHogProperties(["error": short])
    #expect(
      props["error"] as? String
        == "open failed: /Users/[REDACTED]/Library/Application Support/x.bin")
    // Idempotent: a second pass changes nothing.
    #expect(
      SentryEventSanitizer.redactString(props["error"] as? String ?? "") == props["error"]
        as? String)

    // Boundary (Codex r1): a 100-char path whose username is SHORTER than
    // `[REDACTED]` grows past 100 once scrubbed. The scrub runs before the length
    // rule, so the first pass and the second pass agree.
    let boundary = "/Users/a/" + String(repeating: "z", count: 91)
    #expect(boundary.count == 100)
    let once = SentryEventSanitizer.redactString(boundary)
    #expect(once == "[REDACTED]")
    #expect(SentryEventSanitizer.redactString(once) == once)

    // Codex r2: the scrub must never LIFT a redaction the raw string earned.
    // Growing: 32 hex + 8 others trips the hex rule raw; scrubbed it is 49 chars
    // and the "within 8 of the whole string" clause would stop matching.
    let hexThenPath = String(repeating: "a", count: 32) + "/Users/b"
    #expect(SentryEventSanitizer.redactString(hexThenPath) == "[REDACTED]")
    // Shrinking: 108 chars raw trips the length rule; scrubbed it is 98.
    let longUserThenText =
      "/Users/abcdefghijklmnopqrst/" + String(repeating: "private ", count: 10)
    #expect(longUserThenText.count > 100)
    #expect(SentryEventSanitizer.redactString(longUserThenText) == "[REDACTED]")
  }

  // MARK: - Helpers

  /// True if the marker appears anywhere in the event's serialized wire payload.
  private func payloadContainsMarker(_ event: Event) -> Bool {
    allStrings(in: event.serialize()).contains { $0.contains(Self.marker) }
  }

  private func payloadContainsUserMarker(_ event: Event) -> Bool {
    allStrings(in: event.serialize()).contains { $0.contains(Self.userMarker) }
  }

  /// True if the marker appears anywhere in a sanitized property bag.
  private func payloadContainsMarker(_ properties: [String: Any]) -> Bool {
    allStrings(in: properties).contains { $0.contains(Self.marker) }
  }

  /// Recursively collect every string (keys and values) from a serialized
  /// payload so the assertion covers the full nested structure, not just the
  /// fields the test happened to set.
  private func allStrings(in value: Any) -> [String] {
    switch value {
    case let s as String:
      return [s]
    case let dict as [AnyHashable: Any]:
      return dict.keys.compactMap { $0 as? String } + dict.values.flatMap { allStrings(in: $0) }
    case let arr as [Any]:
      return arr.flatMap { allStrings(in: $0) }
    default:
      return []
    }
  }
}
