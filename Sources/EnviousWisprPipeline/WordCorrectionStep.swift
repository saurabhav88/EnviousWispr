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
/// Phase 2b (#638) — heart-path 10ms hard cap on `WordCorrector.correct(...)`
/// invocation (bible §2.2.1) + generation-keyed cache of the lookup maps so
/// they are rebuilt only when the vocabulary generation changes (bible §17
/// R19). The correction runs OFF MainActor inside the timeout closure so
/// the timer task can preempt; on timeout we return the raw text and emit a
/// Sentry breadcrumb (no escalation).
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

  /// Outer runner cap (unchanged). Phase 2b adds a tighter inner 10ms cap
  /// that fires before this would, protecting the heart path from runaway
  /// matcher cost on pathological vocab + transcript combinations.
  public var maxDuration: Duration { .milliseconds(100) }

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
    let result: (corrected: String, replacements: [WordCorrector.Replacement])
    let startTime = CFAbsoluteTimeGetCurrent()
    do {
      // Phase 2b (#638) bible §2.2.1: hard 10ms cap. WordCorrector.correct is
      // pure CPU work; we run it OFF MainActor inside the timeout closure so
      // the timer Task can preempt. On timeout, raw text passes through.
      result = try await withThrowingTimeout(seconds: 0.010) {
        let corrector = WordCorrector()
        return corrector.correct(inputText, using: lookups)
      }
    } catch is TimeoutError {
      SentryBreadcrumb.add(
        stage: "wordcorrector",
        message: "WordCorrector timeout (10ms cap exceeded)",
        data: ["vocab_size": String(snapshot.terms.count)]
      )
      // Phase 8a (#620): emit timeout event. Bible §14.1.
      TelemetryService.shared.customWordsTimeoutFired(vocabSize: snapshot.terms.count)
      return context  // raw text passes through; heart path unaffected
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
