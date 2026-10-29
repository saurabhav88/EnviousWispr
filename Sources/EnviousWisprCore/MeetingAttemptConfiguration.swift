import Foundation

/// What one transcription attempt of a meeting was asked to do (#3973 C2), frozen when it is
/// asked for: at Start (before any wait) and at Transcribe again (the meeting language chosen
/// then, against the chosen engine). The queue and launch recovery continue an unfinished
/// (queued or processing) attempt and never read Settings again; Transcribe again after a
/// failure asks anew.
public struct MeetingAttemptConfiguration: Sendable, Equatable, Codable {
  /// New for every Start and every Transcribe again; kept by a continued attempt. Keys the
  /// checkpoint and, once committed, pairs the History row with its meeting facts.
  public let attemptID: UUID
  public let requestedEngine: MeetingEngineChoice
  /// The language choice the attempt was asked with: a language code, nil for Auto.
  public let languageIntent: String?
  /// The language the requested engine decodes with for that choice: a code, nil for Auto.
  public let requestedEffectiveLanguage: String?

  public init(
    attemptID: UUID = UUID(), requestedEngine: MeetingEngineChoice, languageIntent: String?,
    requestedEffectiveLanguage: String?
  ) {
    self.attemptID = attemptID
    self.requestedEngine = requestedEngine
    self.languageIntent = Self.normalized(languageIntent)
    self.requestedEffectiveLanguage = Self.normalized(requestedEffectiveLanguage)
  }

  /// A new attempt for `language` on `engine`. #3973 C3: a language `engine` cannot decode
  /// (`supports` says no) is asked as Auto, the intent kept, so a fallback to another engine can
  /// decide again from the user's choice.
  public init(
    requestedEngine: MeetingEngineChoice, language: LanguageMode,
    supports: (MeetingEngineChoice, String) -> Bool = { _, _ in true }
  ) {
    let code: String?
    if case .locked(let locked) = language { code = locked } else { code = nil }
    self.init(
      requestedEngine: requestedEngine, languageIntent: code,
      requestedEffectiveLanguage: code.flatMap { supports(requestedEngine, $0) ? $0 : nil })
  }

  /// #3973 C3: the language `engine` decodes this attempt with: the intent when `engine` can
  /// decode it, else Auto.
  public func effectiveLanguage(
    on engine: MeetingEngineChoice, supports: (MeetingEngineChoice, String) -> Bool
  ) -> String? {
    languageIntent.flatMap { supports(engine, $0) ? $0 : nil }
  }

  /// One spelling of Auto, so two Auto attempts compare equal.
  public static func normalized(_ code: String?) -> String? {
    code?.isEmpty == false ? code : nil
  }
}

/// The engine one pass of an attempt runs on, decided before the pass is built (#3973 C3):
/// the requested engine, or Parakeet with the reason when Whisper was asked for and is
/// positively unavailable. The whole pass runs on it; engines are never mixed.
public struct MeetingEngineResolution: Sendable, Equatable {
  public let engine: MeetingEngineChoice
  public let fallbackReason: MeetingTranscriptFallbackReason?
  /// The language the pass decodes with on `engine` (a code; nil is Auto): the attempt's own
  /// when it runs on the engine it asked for, else decided again from its intent.
  public let effectiveLanguage: String?

  public init(
    engine: MeetingEngineChoice, fallbackReason: MeetingTranscriptFallbackReason? = nil,
    effectiveLanguage: String? = nil
  ) {
    self.engine = engine
    self.fallbackReason = fallbackReason
    self.effectiveLanguage = MeetingAttemptConfiguration.normalized(effectiveLanguage)
  }
}

/// Why an attempt ran on another engine than it asked for (#3973 C3 uses it; closed set).
public enum MeetingTranscriptFallbackReason: String, Sendable, Equatable, Codable {
  case notDownloaded
  case deliveryDisabled
  case modelUnavailable
}

/// What an attempt was resolved to before its first decode: the engine and model it really
/// uses (#3973 C2). Nil `modelIdentity` means the engine reported none.
public struct MeetingResolvedAttempt: Sendable, Equatable, Codable {
  public let attemptID: UUID
  public let requestedEngine: MeetingEngineChoice
  public let resolvedEngine: MeetingEngineChoice
  public let effectiveLanguage: String?
  public let modelIdentity: String?
  public let fallbackReason: MeetingTranscriptFallbackReason?

  public init(
    attemptID: UUID, requestedEngine: MeetingEngineChoice, resolvedEngine: MeetingEngineChoice,
    effectiveLanguage: String?, modelIdentity: String?,
    fallbackReason: MeetingTranscriptFallbackReason?
  ) {
    self.attemptID = attemptID
    self.requestedEngine = requestedEngine
    self.resolvedEngine = resolvedEngine
    self.effectiveLanguage = MeetingAttemptConfiguration.normalized(effectiveLanguage)
    self.modelIdentity = modelIdentity
    self.fallbackReason = fallbackReason
  }
}

extension MeetingEngineChoice {
  /// The History row's engine for a transcript this engine wrote.
  public var backendType: ASRBackendType {
    switch self {
    case .parakeet: .parakeet
    case .whisper: .whisper
    }
  }
}
