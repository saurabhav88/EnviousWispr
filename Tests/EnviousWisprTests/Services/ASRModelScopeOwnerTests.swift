import EnviousWisprCore
import EnviousWisprObservabilityCore
import Foundation
import Sentry
import Testing

@testable import EnviousWisprServices

/// #3546 §3.7 T3: the crash-report model tags. When this fails, a crash report names a
/// model from a superseded load or from the engine not in use, or keeps a tag after the
/// model it named went away.
@MainActor
@Suite("ASR model scope tags (#3546)", .tags(.observabilityContract))
struct ASRModelScopeOwnerTests {
  static let ultra = ASRModelIdentity(
    name: "parakeet-ultra-coreml", revision: "95eaa59a39d4", variant: "int8")
  static let whisper = ASRModelIdentity(
    name: "whisperkit-coreml", revision: "01234567",
    variant: "openai_whisper-large-v3-v20240930_turbo")

  @MainActor final class Recorder {
    var snapshots: [ASRModelScopeOwner.Snapshot] = []
  }

  static func tags(_ scope: Scope) -> [String: String] {
    scope.serialize()["tags"] as? [String: String] ?? [:]
  }

  @Test("the writer sets all seven tags, and an absent value removes its tag")
  func writerSetsAndRemoves() {
    let scope = Scope()
    SentryBreadcrumb.writeASRModelScope(
      .init(requested: Self.ultra, phase: .loading, serving: Self.whisper), to: scope)
    #expect(
      Self.tags(scope) == [
        "asr.model_requested": "parakeet-ultra-coreml", "asr.model_requested_revision": "95eaa59a",
        "asr.model_requested_variant": "int8", "asr.load_phase": "loading",
        "asr.model": "whisperkit-coreml", "asr.model_revision": "01234567",
        "asr.model_variant": "openai_whisper-large-v3-v20240930_turbo",
      ])
    // The send-time pass leaves the real names, revisions and variants intact too.
    let written = Self.tags(scope)
    let event = Event(level: .error)
    event.tags = written
    #expect(SentryEventSanitizer.sanitize(event).tags == written)
    SentryBreadcrumb.writeASRModelScope(.init(requested: nil, phase: nil, serving: nil), to: scope)
    #expect(Self.tags(scope).isEmpty, "removed, never a sentinel")
  }

  @Test("a stale snapshot is dropped, and only the active engine reaches the scope")
  func staleAndInactiveSnapshotsAreHeldBack() {
    let recorder = Recorder()
    let owner = ASRModelScopeOwner(sink: { recorder.snapshots.append($0) })
    let loading = ASRModelScopeOwner.Snapshot(requested: Self.ultra, phase: .loading, serving: nil)
    let loaded = ASRModelScopeOwner.Snapshot(
      requested: Self.ultra, phase: .loaded, serving: Self.ultra)
    owner.observe(.parakeet, sequence: 2, snapshot: loaded)
    owner.observe(.parakeet, sequence: 1, snapshot: loading)
    #expect(recorder.snapshots == [loaded], "a late report from an older load is dropped")
    let whisperLoaded = ASRModelScopeOwner.Snapshot(
      requested: Self.whisper, phase: .loaded, serving: Self.whisper)
    owner.observe(.whisper, sequence: 1, snapshot: whisperLoaded)
    #expect(recorder.snapshots == [loaded], "the engine not in use never writes the scope")
    owner.activate(.whisper)
    #expect(recorder.snapshots.last == whisperLoaded, "switching shows that engine's own latest")
    owner.activate(.parakeet)
    #expect(recorder.snapshots.last == loaded)
  }

  @Test("an engine that never reported clears every tag when it becomes active")
  func unreportedEngineClearsTags() {
    let recorder = Recorder()
    let owner = ASRModelScopeOwner(sink: { recorder.snapshots.append($0) })
    owner.observe(
      .parakeet, sequence: 1,
      snapshot: .init(requested: Self.ultra, phase: .loaded, serving: Self.ultra))
    owner.activate(.whisper)
    #expect(recorder.snapshots.last == .init(requested: nil, phase: nil, serving: nil))
  }
}
