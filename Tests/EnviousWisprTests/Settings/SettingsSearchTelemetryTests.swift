import EnviousWisprServices
import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit

/// The failed-search signal (#3482 plan §8.1). When this fails, Envious Labs either learns
/// nothing about what people cannot find in Settings, or receives text it must never receive: an
/// email, a web address, a number, a key, or any query from someone who switched usage metrics off.
@MainActor
@Suite("Settings search telemetry (#3482)", .tags(.productOutcome))
struct SettingsSearchTelemetryTests {
  // MARK: - The privacy filter

  @Test("ordinary failed searches are kept, trimmed and lowercased")
  func keepsOrdinaryQueries() {
    #expect(SettingsSearchQueryFilter.reportable("  Dark Mode ") == "dark mode")
    #expect(SettingsSearchQueryFilter.reportable("API key") == "api key")
    #expect(SettingsSearchQueryFilter.reportable("Tastenkürzel ändern") == "tastenkürzel ändern")
    #expect(SettingsSearchQueryFilter.reportable("windows 11") == "windows 11")
    // Near misses for the credential check: real words, a long German compound, a key's name.
    #expect(SettingsSearchQueryFilter.reportable("skip silence") == "skip silence")
    #expect(SettingsSearchQueryFilter.reportable("hfp headset") == "hfp headset")
    #expect(SettingsSearchQueryFilter.reportable("asian languages") == "asian languages")
    #expect(
      SettingsSearchQueryFilter.reportable("Spracherkennungseinstellungen")
        == "spracherkennungseinstellungen")
    #expect(SettingsSearchQueryFilter.reportable("openai key: where?") == "openai key: where?")
    #expect(SettingsSearchQueryFilter.reportable("pause after 10:30") == "pause after 10:30")
    #expect(SettingsSearchQueryFilter.reportable("talk at home") == "talk at home")
    #expect(SettingsSearchQueryFilter.reportable("password manager") == "password manager")
    #expect(SettingsSearchQueryFilter.reportable("users folder") == "users folder")
    #expect(SettingsSearchQueryFilter.reportable("desk-top mic") == "desk-top mic")
    #expect(SettingsSearchQueryFilter.reportable("what is that") == "what is that")
    for text in ["formatting dotted lists", "formatting dot points", "dictation dot commands"] {
      #expect(SettingsSearchQueryFilter.reportable(text) == text, "dropped \(text)")
    }
    // The sent text keeps what was typed; only the checks read the normalized copy.
    #expect(SettingsSearchQueryFilter.reportable("dark\u{00A0}mode") == "dark\u{00A0}mode")
    // A Japanese vocabulary phrase longer than 32 characters, written without spaces.
    let japanese = "文章整形に使うClaudeモデルの選び方や表示されない理由を知りたい"
    #expect(SettingsSearchQueryFilter.reportable(japanese) == japanese.lowercased())
  }

  @Test("the whole query is dropped when it could identify someone or hold a secret")
  func dropsSensitiveQueries() {
    for text in [
      "me@example.com", "jane@work", "https://example.com/x", "www.example.com", "visit example.com",
      "example.cloud", "my.site.xyz",
      "call 555 123 4567", "1234567", "sk-proj-abc123", "AIzaSyD-whatever",
      "ghp_0123456789abcdef", "a8F3k2L9q0Z7x1C4v6B5n", "ab", String(repeating: "x", count: 81),
      // A key glued to a label or wrapped in punctuation (cloud review, PR #3513); built from
      // parts so no secret-shaped literal sits in the source.
      "token:ghp_" + String(repeating: "a", count: 36), "key=sk-ant-api03-abc", "(AIzaSyabc)",
      "\"xoxb-abc-def\"", "github_pat_abcdefghij", "AKIA" + String(repeating: "B", count: 16),
      "hf_abcdefgh", "glpat-abcdefghij", "my key is " + String(repeating: "q", count: 32),
      // Found by a local enumeration of the class (PR #3513): an invisible character inside a
      // key, a base64 key, an email spelled out, network and hardware addresses, a home-folder
      // path, an IBAN with letters in its account part.
      "g\u{200B}hp_" + String(repeating: "a", count: 18) + "\u{200B}" + String(repeating: "b", count: 18),
      "sA9vwtMpIDApkvvl82t+Rpf/OtIxebKjstdK=", "jane at example dot com", "10.0.0.1",
      "fe80::abcd", "aa:bb:cc:dd:ee:ff", "/Users/Jane/Documents", "LU46 001A BCDE FGHI JKLM",
      // Second enumeration round: labels joined by "=", a non-ASCII label, a labelled password,
      // labelled and Windows paths, and any whitespace between the parts of an address.
      "key=glpat-abcdefghijklmnopqrst", "key=AKIA" + String(repeating: "B", count: 16),
      "clé=" + String(repeating: "a", count: 32), "password:Tr0ub4dor!", "Passwort = geheim",
      "path:/Users/Jane", "path=/Users/Jane", "C:/Users/Jane", "jane  at  example  dot  com",
      "jane\u{00A0}at\u{00A0}example\u{00A0}dot\u{00A0}com",
      "LU46\u{00A0}001A\u{00A0}BCDE\u{00A0}FGHI\u{00A0}JKLM", "token/ghp_abc", "notes.sk-abc",
      // Third round: prefixes after "_" or "-", a full-width colon, nested home paths, bracketed
      // at and dot, spaced dots in an IPv4 address.
      "key_glpat-abcdefghijklmnopqrst", "key-AKIA" + String(repeating: "B", count: 16),
      "password\u{FF1A}Tr0ub4dor!", "/System/Volumes/Data/Users/Jane", "/Volumes/Mac/Users/Jane",
      "jane(at)example(dot)com", "jane [at] example [dot] com", "10 . 0 . 0 . 1",
    ] {
      #expect(SettingsSearchQueryFilter.reportable(text) == nil, "kept \(text)")
    }
  }

  @Test("naturally labelled passwords never enter failed-search reports (#3526)")
  func labelledPasswordRegression() {
    #expect(SettingsSearchQueryFilter.reportable("password is hunter2") == nil)
    #expect(SettingsSearchQueryFilter.reportable("Passwort ist geheim") == nil)
  }

  @Test("approved labelled-password forms are dropped (#3526)")
  func labelledPasswordForms() {
    // Independent literals: do not read the production matcher lists for expectations.
    let labels = [
      "password", "passwd", "pwd", "passwort", "kennwort", "mot de passe", "contraseña", "senha",
      "wachtwoord", "hasło", "pass", "passcode", "passphrase", "pw", "pin", "secret",
    ]
    for label in labels {
      for text in ["\(label) is !value", "\(label):!value", "\(label)=!value", "\(label) value2"] {
        #expect(SettingsSearchQueryFilter.reportable(text) == nil, "kept \(text)")
      }
      #expect(SettingsSearchQueryFilter.reportable("\(label) manager") == "\(label) manager")
    }
    let separators = [
      "is", "was", "are", "ist", "war", "lautet", "est", "c'est", "c’est", "es", "era", "é", "jest",
    ]
    for separator in separators {
      let sensitive = "password \(separator) !value"
      let ordinary = "bypass \(separator) !value"
      #expect(SettingsSearchQueryFilter.reportable(sensitive) == nil, "kept \(sensitive)")
      #expect(SettingsSearchQueryFilter.reportable(ordinary) == ordinary, "dropped \(ordinary)")
    }
    let gaps = [" ", ",", ";", ":", "=", ".", "-", "\"", "'", "“", "”", "‘", "’", "(", ")", "[", "]"]
    for gap in gaps {
      // c'est leaves only a one-letter domain part before the apostrophe, so the dot-gap
      // example is not swallowed by the earlier domain filter. Pre-separator colon/equal
      // cases also match Form 1; their post-separator twins independently reach Form 2.
      for (sensitive, ordinary) in [
        ("password\(gap)c'est !value", "bypass\(gap)c'est !value"),
        ("password c'est\(gap)!value", "bypass c'est\(gap)!value"),
      ] {
        #expect(SettingsSearchQueryFilter.reportable(sensitive) == nil, "kept \(sensitive)")
        #expect(SettingsSearchQueryFilter.reportable(ordinary) == ordinary, "dropped \(ordinary)")
      }
    }
    for text in [
      "my password is hunter2", "password  is   hunter2", "password\u{00A0}is\u{00A0}hunter2",
      "password, is hunter2", "password is: hunter2", "password is=hunter2", "password is !secret",
      "password is \"hunter2\"", "PASSWORD IS HUNTER2", "mot de passe est secret",
      "mot de passe c'est secret", "mot de passe c’est secret", "contraseña es secreta",
      "senha é secreta", "wachtwoord is geheim", "hasło jest tajne", "pw is x9k2m",
      "passcode is 1234", "secret is abc123", "password hunter2", "password \"hunter2\"",
      "password 2024 reset", "pin 1234", "pin 1234 is it", "password hunter٢",
    ] {
      #expect(SettingsSearchQueryFilter.reportable(text) == nil, "kept \(text)")
    }
  }

  @Test("ordinary near-misses and documented residuals are kept (#3526)")
  func labelledPasswordControls() {
    for text in [
      "password manager", "reset password", "what is the password", "password reset is broken",
      "password is", "forgot password is", "password island", "pin isolation", "pass the butter",
      "passport is expired", "bypass is on", "spin is enabled", "pin code settings", "pin to taskbar",
      "secret sauce", "login is broken", "password to reset", "password hunter",
      "my password hint hunter2", "hasło to x", "pass the hunter", "password !!!",
    ] {
      #expect(SettingsSearchQueryFilter.reportable(text) == text, "dropped \(text)")
    }
    #expect(SettingsSearchQueryFilter.reportable("password is ") == "password is")
  }

  @Test("documented labelled-password over-drops are intentional (#3526)")
  func labelledPasswordOverDrops() {
    for text in [
      "password is wrong", "password is the", "reset password is broken", "pin 2 settings",
      "password 2024", "pin: 2 cups", "password is !!!",
    ] {
      #expect(SettingsSearchQueryFilter.reportable(text) == nil, "kept \(text)")
    }
  }

  @Test("filtered passwords are omitted from every finished-search outcome (#3526)")
  func labelledPasswordOutcomeRows() {
    for outcome in [SettingsSearchFinished.Outcome.zeroResults, .sidebarBypass, .resultChosen, .abandoned] {
      for sensitive in ["password is hunter2", "Passwort ist geheim", "pin 1234"] {
        let row = SettingsSearchFinished(
          outcome: outcome, endedBy: .escape, resultCount: 0, appLanguage: "en", typedQuery: sensitive)
        #expect(row.query == nil, "password reached \(outcome.rawValue)")
      }
      let control = SettingsSearchFinished(
        outcome: outcome, endedBy: .escape, resultCount: 0, appLanguage: "en", typedQuery: "dark mode")
      let expected = outcome == .zeroResults || outcome == .sidebarBypass ? "dark mode" : nil
      #expect(control.query == expected)
    }
  }

  @Test("copied invisible password gaps never enter reports (#3526)")
  func passwordFormatRegression() {
    #expect(SettingsSearchQueryFilter.reportable("password\u{200B}is\u{200B}hunter2") == nil)
    #expect(SettingsSearchQueryFilter.reportable("Passwort\u{200B}ist\u{200B}geheim") == nil)
  }

  @Test("every Unicode format member can separate a labelled password (#3526)")
  func passwordFormatClass() {
    let formats = (0...0x10FFFF).compactMap { Unicode.Scalar($0) }
      .filter { $0.properties.generalCategory == .format }
    #expect(formats.isEmpty == false)
    print("Settings search password format members: \(formats.count)")
    for scalar in formats {
      let f = String(scalar)
      #expect(SettingsSearchQueryFilter.reportable("password\(f)is\(f)hunter2") == nil)
      let ordinary = "password\(f)manager"
      #expect(SettingsSearchQueryFilter.reportable(ordinary) == ordinary)
    }
  }

  @Test("format locations preserve password detection and ordinary controls (#3526)")
  func passwordFormatLocations() {
    for text in [
      "pas\u{200B}sword is hunter2", "password i\u{200B}s hunter2",
      "password\u{200B}is hunter2", "password is\u{200B}hunter2", "password\u{200B}hunter2",
      "password is hun\u{200B}ter2", "pas\u{200B}sword\u{2060}i\u{200D}s\u{FEFF}hunter2",
      "Pass\u{200C}wort\u{2060}i\u{200D}st\u{FEFF}geheim",
      "pass\u{200B}word\u{2060}:hunter2", "pass\u{200B}word\u{2060}=hunter2",
      "mot\u{200B}de\u{200B}passe est secret",
    ] {
      #expect(SettingsSearchQueryFilter.reportable(text) == nil, "kept \(text)")
    }
    for text in [
      "by\u{200B}pass is enabled", "pass\u{200B}port is expired",
      "password\u{200B}hunter", "password hint hunter2", "hasło\u{200B}to x", "dark\u{200B}mode",
    ] {
      #expect(SettingsSearchQueryFilter.reportable(text) == text, "dropped \(text)")
    }
    // Foundation's existing whitespace trim removes a trailing U+200B before detection.
    #expect(SettingsSearchQueryFilter.reportable("password is\u{200B}") == "password is")
  }

  @Test("the query rides only on zero_results and sidebar_bypass")
  func queryOnlyOnGaps() {
    func query(_ outcome: SettingsSearchFinished.Outcome) -> String? {
      SettingsSearchFinished(
        outcome: outcome, endedBy: .escape, resultCount: 0, appLanguage: "en",
        typedQuery: "dark mode"
      ).query
    }
    #expect(query(.zeroResults) == "dark mode")
    #expect(query(.sidebarBypass) == "dark mode")
    #expect(query(.resultChosen) == nil)
    #expect(query(.abandoned) == nil)
    let leak = SettingsSearchFinished(
      outcome: .zeroResults, endedBy: .clear, resultCount: 0, appLanguage: "en",
      typedQuery: "me@example.com")
    #expect(leak.query == nil, "an email reached the row")
  }

  // MARK: - Outcomes

  typealias Attempt = SettingsSearchModel.Attempt

  static func snapshot(results: Int, pending: Bool = false) -> Attempt {
    var attempt = Attempt(eligible: true)
    attempt.query = "x"
    attempt.resultCount = results
    attempt.meaningPending = pending
    return attempt
  }

  @Test("each way a search ends maps to the plan's outcome")
  func outcomes() {
    let outcome = SettingsSearchModel.outcome
    #expect(outcome(.searchResult, Self.snapshot(results: 3)) == .resultChosen)
    #expect(outcome(.sidebar, Self.snapshot(results: 3)) == .sidebarBypass)
    #expect(outcome(.sidebar, Self.snapshot(results: 0)) == .zeroResults)
    #expect(outcome(.sidebar, Self.snapshot(results: 0, pending: true)) == .abandoned)
    for ended: SettingsSearchFinished.EndedBy in [
      .externalDestination, .escape, .clear, .queryEmpty, .windowClose,
    ] {
      #expect(outcome(ended, Self.snapshot(results: 0)) == .zeroResults, "\(ended)")
      #expect(outcome(ended, Self.snapshot(results: 2)) == .abandoned, "\(ended)")
      #expect(outcome(ended, Self.snapshot(results: 0, pending: true)) == .abandoned, "\(ended)")
    }
  }

  // MARK: - Attempts through the model

  @MainActor @Observable final class Sent { var rows: [SettingsSearchFinished] = [] }

  static func model(usageOn: Bool = true, sent: Sent) throws -> SettingsSearchModel {
    let index = try SettingsSearchModelTests.index.get()
    let model = SettingsSearchModel(
      loadIndex: { index }, usageMetricsOn: { usageOn }, emitFinished: { sent.rows.append($0) },
      announce: { _ in }, announcementDelay: .seconds(60))
    return model
  }

  @Test("one row per attempt: typing and editing do not send; Escape finishes it once")
  func oneRowPerAttempt() async throws {
    let sent = Sent()
    let model = try Self.model(sent: sent)
    model.setQuery("zz")
    #expect(await SettingsSearchModelTests.ready(model))
    model.setQuery("zzq")
    model.setQuery("zzqx")
    #expect(sent.rows.isEmpty, "an edit sent a row")
    model.reset(endedBy: .escape)
    model.reset(endedBy: .escape)
    #expect(sent.rows.count == 1, "\(sent.rows)")
    let row = try #require(sent.rows.first)
    #expect(row.outcome == .zeroResults)
    #expect(row.endedBy == .escape)
    #expect(row.query == "zzqx", "the last presented query, not a prefix")
    #expect(row.appLanguage == "en")
  }

  @Test("deleting to empty finishes with the last non-empty search")
  func deletionToEmpty() async throws {
    let sent = Sent()
    let model = try Self.model(sent: sent)
    model.setQuery("dock")
    #expect(await SettingsSearchModelTests.ready(model))
    model.setQuery("")
    let row = try #require(sent.rows.first)
    #expect(row.endedBy == .queryEmpty)
    #expect(row.outcome == .abandoned, "it had results")
    #expect(row.query == nil)
    #expect(row.resultCount > 0)
  }

  @Test("with usage metrics off nothing is sent; switching off mid-search cancels that attempt")
  func usageSwitch() async throws {
    let sent = Sent()
    let off = try Self.model(usageOn: false, sent: sent)
    off.setQuery("zzqx")
    #expect(await SettingsSearchModelTests.ready(off))
    off.reset(endedBy: .escape)
    #expect(sent.rows.isEmpty)
    let on = try Self.model(sent: sent)
    on.setQuery("zzqx")
    #expect(await SettingsSearchModelTests.ready(on))
    on.usageMetricsChanged(isOn: false)
    on.usageMetricsChanged(isOn: true)
    on.reset(endedBy: .escape)
    #expect(sent.rows.isEmpty, "an attempt switched off midway was reported")
  }

  @Test("a closed panel keeps the snapshot it last showed")
  func frozenSnapshot() async throws {
    let sent = Sent()
    let model = try Self.model(sent: sent)
    model.setQuery("zzqx")
    #expect(await SettingsSearchModelTests.ready(model))
    model.dismissPanel()
    model.finish(endedBy: .sidebar, sidebarPage: "keybinds", sidebarTab: nil)
    let row = try #require(sent.rows.first)
    #expect(row.outcome == .zeroResults)
    #expect(row.query == "zzqx")
    #expect(row.sidebarPage == "keybinds")
  }

  @Test("a chosen result is result_chosen with no query")
  func resultChosen() async throws {
    let sent = Sent()
    let model = try Self.model(sent: sent)
    model.setQuery("dock")
    #expect(await SettingsSearchModelTests.ready(model))
    model.finish(endedBy: .searchResult)
    model.reset()
    #expect(sent.rows.map(\.outcome) == [.resultChosen])
    #expect(sent.rows.first?.query == nil)
  }
}
