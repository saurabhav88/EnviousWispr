import Foundation

extension InverseTextNormalizer {

  /// The language route's text execution (#1677): what runs on a take whose language HAS a vetted
  /// rule set.
  ///
  /// The language-neutral subset runs first; then each of the language's passes (number style,
  /// phone, clock, hour-first clock) runs on a FRESH
  /// snapshot of the previous stage's output, and the shared editor applies its edits or refuses
  /// the whole set. A pass that is unavailable or whose edits the editor refuses leaves its input
  /// unchanged, so a failure never costs the neutral result or an earlier pass's edits.
  ///
  /// **Never calls the English `normalize`.** English number words collide with other languages
  /// (`ten` is a Polish demonstrative, German `am` is not the meridiem), so this entry must not
  /// reach the English lexicon.
  ///
  /// Takes the immutable rule-set SNAPSHOT, not a language code: nothing here rereads a registry.
  /// `homeRegion` is the Mac's region (ISO 3166), read by the caller; it decides how a domestic
  /// telephone number is grouped and nothing else.
  package func normalize(
    _ text: String, language ruleSet: LanguageRuleSet,
    homeRegion: String? = Locale.current.region?.identifier
  ) -> String {
    var output = normalizeLanguageNeutral(text)
    guard let passes = LanguagePassCatalog.passes(for: ruleSet.baseCode) else { return output }
    if let style = passes.numberStyle {
      let snapshot = LanguageTextSnapshot(output)
      if case .applied(let applied) = LanguageTextEditor.apply(style.propose(in: snapshot), to: snapshot) {
        output = applied
      }
    }
    if let phone = passes.phone {
      let snapshot = LanguageTextSnapshot(output)
      if case .ran(let run) = phone.propose(in: snapshot, homeRegion: homeRegion),
        case .applied(let applied) = LanguageTextEditor.apply(run.edits, to: snapshot)
      {
        output = applied
      }
    }
    if let clock = passes.clock {
      let snapshot = LanguageTextSnapshot(output)
      if case .ran(let run) = clock.propose(in: snapshot),
        case .applied(let applied) = LanguageTextEditor.apply(run.edits, to: snapshot)
      {
        output = applied
      }
    }
    if let hourFirstClock = passes.hourFirstClock {
      let snapshot = LanguageTextSnapshot(output)
      if case .ran(let edits) = hourFirstClock.propose(in: snapshot),
        case .applied(let applied) = LanguageTextEditor.apply(edits, to: snapshot)
      {
        output = applied
      }
    }
    return output
  }
}

/// The language passes each registered base code runs, built ONCE from the generated data. A
/// language whose data does not build has no passes (it runs the neutral subset only); nothing
/// throws at dictation time. German runs number style, phone and clock; French, Spanish, Italian
/// and Portuguese run the signed phone path and the hour-first clock pass; Dutch runs the signed
/// phone path and the minute-first clock pass with its own number grammar; Polish runs the signed
/// phone path. The ordinal pass is not listed: its month, fixed-phrase and name data are still
/// pending.
enum LanguagePassCatalog {

  struct Passes: Sendable {
    let numberStyle: LanguageNumberStylePass?
    let phone: LanguagePhonePrefixPass?
    let clock: LanguageClockIdiomPass?
    let hourFirstClock: LanguageHourFirstClockPass?
  }

  private static let german: Passes? = {
    guard let grammar = try? LanguageNumberGrammar.german() else { return nil }
    return Passes(
      numberStyle: (try? LanguageNumberStyleRules.german()).map { LanguageNumberStylePass(rules: $0) },
      phone: (try? LanguagePhonePrefixRules.german()).map {
        LanguagePhonePrefixPass(grammar: grammar, rules: $0)
      },
      clock: (try? LanguageClockIdiomRules.forLanguage("de")).flatMap { $0 }.map {
        LanguageClockIdiomPass(grammar: grammar, rules: $0)
      },
      hourFirstClock: nil)
  }()

  /// Languages whose phone pass runs the signed path only (spoken plus word, written sign), with
  /// an hour-first clock pass (French, Spanish, Italian, Portuguese) or a minute-first clock pass
  /// over the language's own number grammar (Dutch). Each pass is present when its own data
  /// builds.
  private static let signedPhoneOnly: [String: Passes] = {
    var table: [String: Passes] = [:]
    let codes = Set(PhoneTriggerData.triggerTokens.keys).union(HourFirstClockData.languages.keys)
      .union(LanguageClockIdiomRules.languages).subtracting(["de"])
    for code in codes {
      // The language's number grammar, when it has one (Dutch), also lets the phone pass refuse a
      // spoken operand before the plus word ("een plus 31 …" is a sum).
      let grammar = (try? LanguageNumberGrammar.forLanguage(code)).flatMap { $0 }
      let phone = (try? LanguagePhonePrefixRules.signedOnly(language: code)).map {
        LanguagePhonePrefixPass(grammar: grammar, rules: $0)
      }
      let hourFirstClock = LanguageHourFirstClockRules(language: code).map {
        LanguageHourFirstClockPass(rules: $0)
      }
      var clock: LanguageClockIdiomPass?
      if let rules = (try? LanguageClockIdiomRules.forLanguage(code)).flatMap({ $0 }), let grammar {
        clock = LanguageClockIdiomPass(grammar: grammar, rules: rules)
      }
      guard phone != nil || hourFirstClock != nil || clock != nil else { continue }
      table[code] = Passes(
        numberStyle: nil, phone: phone, clock: clock, hourFirstClock: hourFirstClock)
    }
    return table
  }()

  static func passes(for baseCode: String) -> Passes? {
    switch baseCode {
    case "de": return german
    default: return signedPhoneOnly[baseCode]
    }
  }
}
