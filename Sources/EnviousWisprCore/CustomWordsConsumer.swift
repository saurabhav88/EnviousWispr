import Foundation

/// Phase 0 (#640) split: two narrow consumer protocols replace the prior
/// single `CustomWordsConsumer`. Each consumer subscribes to ONE lane, never
/// both. Pack-to-prompt leaks become a compile error.
///
/// `CustomWordsPropagator` (in the App target) writes new vocabularies to all
/// registered consumers via these properties. Consumers MUST NOT call
/// `propagator.update(corrector:polish:)` synchronously from inside these
/// setters; doing so triggers a DEBUG `precondition`.

/// Consumes the corrector lane (built-in + user + pack terms). `WordCorrectionStep`
/// adopts this protocol.
@MainActor
package protocol CorrectorVocabularyConsumer: AnyObject {
  var correctorVocabulary: CorrectorVocabulary { get set }
}

/// Consumes the polish lane (built-in + user terms only — never pack).
/// `LLMPolishStep` adopts this protocol.
@MainActor
package protocol PolishVocabularyConsumer: AnyObject {
  var polishVocabulary: PolishVocabulary { get set }
}
