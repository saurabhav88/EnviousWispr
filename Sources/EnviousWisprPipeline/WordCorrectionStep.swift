import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation

/// Applies custom word corrections to ASR output.
///
/// Phase 0 (#640) — receives the corrector lane (built-in + user + pack
/// terms). Adopts `CorrectorVocabularyConsumer` instead of the prior
/// `CustomWordsConsumer`. Bible §2.2.
///
/// Phase 3a (#631) — calls `customWordsManager.recordReplacements(_:)` after
/// each correction to attribute replacements to source `CustomWord.id`s.
/// Phase 3b implements the debounced writer; this call is exercised but
/// inert until then.
///
/// Phase 2b (#638) — generation-keyed cache of the lookup maps so they are
/// rebuilt only when the vocabulary generation changes (bible §17 R19).
///
/// #657 (2026-05-05) — heart-path inner 10ms cap removed: it was firing during
/// cold-cache lookup-map builds and on long-input scoring, causing silent
/// discard of the corrector result via the runner's outer timeout. The single
/// remaining bound is the runner-level `maxDuration` cap below (3 seconds).
/// Cap-trip telemetry now lives in `TextProcessingRunner` where the actual
/// discard happens.
@MainActor
public final class WordCorrectionStep: TextProcessingStep, CorrectorVocabularyConsumer {
  public let name = "Word Correction"

  public var wordCorrectionEnabled: Bool = false
  public var correctorVocabulary: CorrectorVocabulary = .empty {
    didSet {
      // Phase 2b (#638): invalidate the lookup-map cache when the vocabulary
      // generation changes. Same generation → reuse cached lookups.
      if oldValue.generation != correctorVocabulary.generation {
        cachedLookups = nil
      }
    }
  }

  public var isEnabled: Bool {
    wordCorrectionEnabled && !correctorVocabulary.terms.isEmpty
  }

  /// Runner-level safety net. #657 (2026-05-05) raised this from 100ms to 3
  /// seconds after empirical evidence showed the previous cap silently
  /// discarded corrector output on paragraph-length input. The cap is now a
  /// true runaway-protection ceiling, not a steady-state budget. When it
  /// fires, `TextProcessingRunner` emits `custom_words.timeout_fired` with
  /// vocabSize / elapsedMs / inputChars so we have feedback signal in
  /// production.
  public var maxDuration: Duration { .seconds(3) }

  /// Phase 3a (#631): manager handle for replacement attribution. Optional
  /// because pre-Phase-3a callers (and tests) construct the step with no
  /// manager; production wiring (AppState) supplies one.
  private let customWordsManager: CustomWordsManager?

  /// Phase 2b (#638): cached lookup maps keyed by `CorrectorVocabulary.generation`.
  /// `WordCorrector.buildLookups(...)` is the only producer; `correct(_:using:)`
  /// is the only consumer. Cache invalidates in the `correctorVocabulary`
  /// setter when generation changes.
  private struct CachedLookups {
    let generation: UInt64
    let lookups: WordCorrector.Lookups
  }
  private var cachedLookups: CachedLookups?

  public init(customWordsManager: CustomWordsManager? = nil) {
    self.customWordsManager = customWordsManager
  }

  public func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    let snapshot = correctorVocabulary
    let lookups = ensureLookups(for: snapshot)

    let inputText = context.text
    let vocabCount = snapshot.terms.count
    let generation = snapshot.generation
    let inputChars = inputText.count
    Task {
      await AppLogger.shared.log(
        "WordCorrection enter: vocab_count=\(vocabCount) generation=\(generation) input_chars=\(inputChars)",
        level: .info, category: "Pipeline"
      )
    }
    let startTime = CFAbsoluteTimeGetCurrent()
    // #657: corrector runs OFF MainActor (the WordCorrector matcher is pure
    // CPU; running it inline on @MainActor would stall the UI on long input).
    // The only meaningful cap is the runner's outer 3s `maxDuration`; this
    // 5-second inner wrapper exists solely to preserve the Phase 2b
    // off-actor execution pattern. When the runner trips its 3s cap, child
    // task cancellation propagates here too. Cap-trip telemetry now lives in
    // `TextProcessingRunner` where the actual discard happens.
    let result = try await withThrowingTimeout(seconds: 5.0) {
      WordCorrector().correct(inputText, using: lookups)
    }
    let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

    let (fixed, replacements) = result
    if !replacements.isEmpty {
      customWordsManager?.recordReplacements(replacements.map(\.sourceID))
      let count = replacements.count
      // Phase 8a (#620): emit one summary event per process() call. Bible §14.1.
      // Privacy-safe: counts + booleans + latency bucket. No term strings.
      let sourceIDs = Set(replacements.map(\.sourceID))
      var hadPack = false
      var hadUser = false
      var hadBuiltin = false
      for term in snapshot.terms where sourceIDs.contains(term.id) {
        switch term.source {
        case .pack: hadPack = true
        case .user: hadUser = true
        case .builtin: hadBuiltin = true
        case .observedAX: hadUser = true  // observedAX -> persists as user
        }
      }
      TelemetryService.shared.customWordsReplacementBatch(
        replacementCount: count,
        vocabSize: snapshot.terms.count,
        hadPackTerm: hadPack,
        hadUserTerm: hadUser,
        hadBuiltinTerm: hadBuiltin,
        latencyBucket: LatencyBucket.of(milliseconds: elapsedMs)
      )
      Task {
        await AppLogger.shared.log(
          "WordCorrector applied \(count) correction(s)",
          level: .verbose, category: "Pipeline"
        )
      }
    }
    var ctx = context
    ctx.text = fixed
    return ctx
  }

  /// Returns the cached lookups for `vocab` if the cache is fresh, otherwise
  /// rebuilds and stores them. Test seam: `lookupCacheHits` /
  /// `lookupCacheBuilds` expose effectiveness for the cache test.
  private func ensureLookups(for vocab: CorrectorVocabulary) -> WordCorrector.Lookups {
    if let cache = cachedLookups, cache.generation == vocab.generation {
      lookupCacheHits += 1
      return cache.lookups
    }
    let lookups = WordCorrector.buildLookups(words: vocab.terms)
    cachedLookups = CachedLookups(generation: vocab.generation, lookups: lookups)
    lookupCacheBuilds += 1
    return lookups
  }

  /// Phase 2b (#638) test-only: counts cache hits across `process(...)` calls.
  package internal(set) var lookupCacheHits: Int = 0
  /// Phase 2b (#638) test-only: counts cache builds across `process(...)` calls.
  package internal(set) var lookupCacheBuilds: Int = 0
}
