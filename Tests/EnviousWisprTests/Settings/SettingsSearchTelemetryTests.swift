import EnviousWisprServices
import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit

/// The failed-search signal (#3482 plan §8.1). When this fails, Envious Labs either learns
/// nothing about what people cannot find in Settings, or receives text it must never receive: an
/// email, a web address, a number, a key, or any query from someone who switched usage metrics off.
@MainActor
@Suite("Settings search telemetry (#3482)", .tags(.productOutcome, .localParallel))
struct SettingsSearchTelemetryTests {
  // MARK: - The privacy filter

  /// The filter as the app calls it: the word count comes from the real Settings search word
  /// splitter, never a test copy (#4843).
  static func sent(_ text: String) -> String? {
    SettingsSearchQueryFilter.reportable(text, wordCount: SearchText.words(text).count)
  }

  @Test("ordinary failed searches are kept, trimmed and lowercased")
  func keepsOrdinaryQueries() {
    #expect(Self.sent("  Dark Mode ") == "dark mode")
    #expect(Self.sent("API key") == "api key")
    #expect(Self.sent("Tastenkürzel ändern") == "tastenkürzel ändern")
    #expect(Self.sent("windows 11") == "windows 11")
    // Near misses for the credential check: real words, a long German compound, a key's name.
    #expect(Self.sent("skip silence") == "skip silence")
    #expect(Self.sent("hfp headset") == "hfp headset")
    #expect(Self.sent("asian languages") == "asian languages")
    #expect(
      Self.sent("Spracherkennungseinstellungen")
        == "spracherkennungseinstellungen")
    #expect(Self.sent("openai key: where?") == "openai key: where?")
    #expect(Self.sent("pause after 10:30") == "pause after 10:30")
    #expect(Self.sent("talk at home") == "talk at home")
    #expect(Self.sent("password manager") == "password manager")
    #expect(Self.sent("users folder") == "users folder")
    #expect(Self.sent("desk-top mic") == "desk-top mic")
    #expect(Self.sent("what is that") == "what is that")
    for text in ["formatting dotted lists", "formatting dot points", "dictation dot commands"] {
      #expect(Self.sent(text) == text, "dropped \(text)")
    }
    // The sent text keeps what was typed; only the checks read the normalized copy.
    #expect(Self.sent("dark\u{00A0}mode") == "dark\u{00A0}mode")
    // A Japanese vocabulary phrase longer than 32 characters, written without spaces, is not
    // taken for a key. The word rule is held aside here (its 18 words drop it, #4843).
    let japanese = "文章整形に使うClaudeモデルの選び方や表示されない理由を知りたい"
    #expect(SettingsSearchQueryFilter.reportable(japanese, wordCount: 1) == japanese.lowercased())
    #expect(Self.sent(japanese) == nil)
  }

  @Test("a failed search of more than 6 words never leaves the Mac, in any script (#4843)")
  func sentencesAreDropped() {
    #expect(SettingsSearchQueryFilter.maxWords == 6)
    #expect(Self.sent("turn off the sound when recording starts") == nil)  // 7 words
    #expect(Self.sent("turn off sound when recording starts") == "turn off sound when recording starts")
    #expect(Self.sent("wie kann ich die Tastenkürzel für Diktat ändern") == nil)
    #expect(Self.sent("Tastenkürzel für Diktat ändern") == "tastenkürzel für diktat ändern")
    // Hyphens split words the way search splits them: 7 words.
    #expect(Self.sent("self-learning off for e-mail and chat") == nil)
    // Scripts written without spaces: the system word splitter counts every word, so a sentence
    // is never one word.
    let sentences = [
      "我想知道为什么我说话的时候这个应用程序没有把文字粘贴到我正在使用的窗口里面",
      "ฉันอยากรู้ว่าทำไมแอปนี้ไม่วางข้อความลงในหน้าต่างที่ฉันกำลังใช้อยู่ตอนนี้",
      "話している時にこのアプリが文字を今使っているウィンドウに貼り付けないのはなぜですか",
      "제가 말할 때 이 앱이 왜 지금 쓰고 있는 창에 글자를 붙여 넣지 않는지 알고 싶어요",
      "मैं जानना चाहता हूं कि यह ऐप काम क्यों नहीं करता",
    ]
    for text in sentences {
      #expect(SearchText.words(text).count > SettingsSearchQueryFilter.maxWords, "\(text)")
      #expect(Self.sent(text) == nil, "kept \(text)")
    }
    for text in ["深色模式", "快捷键设置", "ショートカット", "โหมดมืด", "단축키 설정"] {
      #expect(Self.sent(text) == text, "dropped \(text)")
    }
    // The row applies the same rule.
    let long = "please tell me why my words never paste anywhere"
    let row = SettingsSearchFinished(
      outcome: .zeroResults, endedBy: .escape, resultCount: 0, appLanguage: "en",
      typedQuery: long, typedQueryWordCount: SearchText.words(long).count)
    #expect(row.query == nil, "a sentence reached the row")
    #expect(row.outcome == .zeroResults)
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
      #expect(Self.sent(text) == nil, "kept \(text)")
    }
  }

  @Test("naturally labelled passwords never enter failed-search reports (#3526)")
  func labelledPasswordRegression() {
    #expect(Self.sent("password is hunter2") == nil)
    #expect(Self.sent("Passwort ist geheim") == nil)
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
        #expect(Self.sent(text) == nil, "kept \(text)")
      }
      #expect(Self.sent("\(label) manager") == "\(label) manager")
    }
    let separators = [
      "is", "was", "are", "ist", "war", "lautet", "est", "c'est", "c’est", "es", "era", "é", "jest",
    ]
    for separator in separators {
      let sensitive = "password \(separator) !value"
      let ordinary = "bypass \(separator) !value"
      #expect(Self.sent(sensitive) == nil, "kept \(sensitive)")
      #expect(Self.sent(ordinary) == ordinary, "dropped \(ordinary)")
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
        #expect(Self.sent(sensitive) == nil, "kept \(sensitive)")
        #expect(Self.sent(ordinary) == ordinary, "dropped \(ordinary)")
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
      #expect(Self.sent(text) == nil, "kept \(text)")
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
      #expect(Self.sent(text) == text, "dropped \(text)")
    }
    #expect(Self.sent("password is ") == "password is")
  }

  @Test("documented labelled-password over-drops are intentional (#3526)")
  func labelledPasswordOverDrops() {
    for text in [
      "password is wrong", "password is the", "reset password is broken", "pin 2 settings",
      "password 2024", "pin: 2 cups", "password is !!!",
    ] {
      #expect(Self.sent(text) == nil, "kept \(text)")
    }
  }

  @Test("filtered passwords are omitted from every finished-search outcome (#3526)")
  func labelledPasswordOutcomeRows() {
    for outcome in [SettingsSearchFinished.Outcome.zeroResults, .sidebarBypass, .resultChosen, .abandoned] {
      for sensitive in ["password is hunter2", "Passwort ist geheim", "pin 1234"] {
        let row = SettingsSearchFinished(
          outcome: outcome, endedBy: .escape, resultCount: 0, appLanguage: "en", typedQuery: sensitive,
          typedQueryWordCount: SearchText.words(sensitive).count)
        #expect(row.query == nil, "password reached \(outcome.rawValue)")
      }
      let control = SettingsSearchFinished(
        outcome: outcome, endedBy: .escape, resultCount: 0, appLanguage: "en", typedQuery: "dark mode",
          typedQueryWordCount: SearchText.words("dark mode").count)
      let expected = outcome == .zeroResults || outcome == .sidebarBypass ? "dark mode" : nil
      #expect(control.query == expected)
    }
  }

  @Test("copied invisible password gaps never enter reports (#3526)")
  func passwordFormatRegression() {
    #expect(Self.sent("password\u{200B}is\u{200B}hunter2") == nil)
    #expect(Self.sent("Passwort\u{200B}ist\u{200B}geheim") == nil)
    // Marks that render as nothing (variation selector, combining grapheme joiner) too.
    #expect(Self.sent("password\u{FE0F}is\u{FE0F}hunter2") == nil)
    #expect(Self.sent("password\u{034F}is\u{034F}hunter2") == nil)
    #expect(Self.sent("dark\u{FE0F}mode") == "dark\u{FE0F}mode")
  }

  @Test("every Unicode format or default-ignorable member can separate a labelled password (#3526)")
  func passwordFormatClass() {
    let formats = (0...0x10FFFF).compactMap { Unicode.Scalar($0) }
      .filter {
        $0.properties.generalCategory == .format || $0.properties.isDefaultIgnorableCodePoint
      }
    // Variation selector and combining grapheme joiner are marks, not format characters.
    #expect(formats.contains("\u{FE0F}") && formats.contains("\u{034F}"))
    #expect(formats.isEmpty == false)
    print("Settings search password format members: \(formats.count)")
    for scalar in formats {
      let f = String(scalar)
      #expect(Self.sent("password\(f)is\(f)hunter2") == nil)
      let ordinary = "password\(f)manager"
      #expect(Self.sent(ordinary) == ordinary)
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
      #expect(Self.sent(text) == nil, "kept \(text)")
    }
    for text in [
      "by\u{200B}pass is enabled", "pass\u{200B}port is expired",
      "password\u{200B}hunter", "password hint hunter2", "hasło\u{200B}to x", "dark\u{200B}mode",
    ] {
      #expect(Self.sent(text) == text, "dropped \(text)")
    }
    // Foundation's existing whitespace trim removes a trailing U+200B before detection.
    #expect(Self.sent("password is\u{200B}") == "password is")
  }

  @Test("the query rides only on zero_results and sidebar_bypass")
  func queryOnlyOnGaps() {
    func query(_ outcome: SettingsSearchFinished.Outcome) -> String? {
      SettingsSearchFinished(
        outcome: outcome, endedBy: .escape, resultCount: 0, appLanguage: "en",
        typedQuery: "dark mode", typedQueryWordCount: 2
      ).query
    }
    #expect(query(.zeroResults) == "dark mode")
    #expect(query(.sidebarBypass) == "dark mode")
    #expect(query(.resultChosen) == nil)
    #expect(query(.abandoned) == nil)
    let leak = SettingsSearchFinished(
      outcome: .zeroResults, endedBy: .clear, resultCount: 0, appLanguage: "en",
      typedQuery: "me@example.com",
          typedQueryWordCount: SearchText.words("me@example.com").count)
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

  /// #4843: text EnviousWispr dictated into its own Settings search is dictated content, so the
  /// row carries counts only, whichever lands first: the delivery notice or the field's text.
  static func delivered(_ text: String, to bundleID: String?) -> PasteCompletionEvent {
    PasteCompletionEvent(pastedText: text, destinationBundleID: bundleID)
  }

  @Test("a search holding text dictated into our own app never sends its words (#4843)")
  func dictatedSearchSendsCountsOnly() async throws {
    // The field's text changes first (a direct write), then the delivery notice arrives.
    let sent = Sent()
    let textFirst = try Self.model(sent: sent)
    textFirst.setQuery("zzqx blorp")
    #expect(await SettingsSearchModelTests.ready(textFirst))
    textFirst.pasteCompleted(Self.delivered("Zzqx blorp ", to: AppBundleIdentity.production))
    textFirst.reset(endedBy: .escape)
    var row = try #require(sent.rows.last)
    #expect(row.outcome == .zeroResults)
    #expect(row.query == nil, "dictated words reached the row")

    // The delivery notice arrives first, then the pasted text lands in the empty field (a key
    // paste into our own window is handled after the notice); later typed edits keep the mark.
    let noticeFirst = try Self.model(sent: sent)
    noticeFirst.pasteCompleted(Self.delivered(" Zzqx\nblorp", to: AppBundleIdentity.development))
    noticeFirst.setQuery("Zzqx blorp")
    #expect(await SettingsSearchModelTests.ready(noticeFirst))
    noticeFirst.setQuery("zzqx blo")
    noticeFirst.setQuery("zzqx blorq")
    noticeFirst.reset(endedBy: .escape)
    row = try #require(sent.rows.last)
    #expect(row.outcome == .zeroResults)
    #expect(row.query == nil, "dictated words reached the row after edits")

    // The text lands while the take is still delivering and the search ends before any notice
    // (or the route sends none): a field change during an active dictation marks the search.
    let inFlight = try Self.model(sent: sent)
    var active = true
    inFlight.dictationInFlight = { active }
    inFlight.setQuery("zzqx blorp")
    active = false
    #expect(await SettingsSearchModelTests.ready(inFlight))
    inFlight.reset(endedBy: .escape)
    row = try #require(sent.rows.last)
    #expect(row.outcome == .zeroResults)
    #expect(row.query == nil, "text typed during a dictation reached the row")
    #expect(sent.rows.count == 3)
  }

  @Test("a typed failed search of more than 6 words is sent without its words, counts kept (#4843)")
  func longTypedSearchSendsCountsOnly() async throws {
    let sent = Sent()
    let model = try Self.model(sent: sent)
    model.setQuery("zzqx blorp zzqx blorp zzqx blorp zzqx")
    #expect(await SettingsSearchModelTests.ready(model))
    model.reset(endedBy: .escape)
    let row = try #require(sent.rows.last)
    #expect(row.outcome == .zeroResults)
    #expect(row.query == nil, "a 7-word typed search reached the row")
    model.setQuery("zzqx blorp zzqx blorp zzqx blorp")
    #expect(await SettingsSearchModelTests.ready(model))
    model.reset(endedBy: .escape)
    #expect(sent.rows.last?.query == "zzqx blorp zzqx blorp zzqx blorp", "6 words are sent")
  }

  @Test("a dictation into another app, or a blank one, leaves a typed search alone (#4843)")
  func otherAppDictationKeepsTypedQuery() async throws {
    let sent = Sent()
    let model = try Self.model(sent: sent)
    model.pasteCompleted(Self.delivered("zzqx blorp", to: "com.apple.TextEdit"))
    model.pasteCompleted(Self.delivered("zzqx blorp", to: nil))
    model.pasteCompleted(Self.delivered("   ", to: AppBundleIdentity.production))
    model.setQuery("zzqx blorp")
    #expect(await SettingsSearchModelTests.ready(model))
    model.reset(endedBy: .escape)
    let row = try #require(sent.rows.last)
    #expect(row.query == "zzqx blorp")
    #expect(model.recentDictations.isEmpty)
    // The mark belongs to one search: a dictation that marked an open search does not mark the
    // next search, whose text is unrelated.
    model.setQuery("zzqw")
    #expect(await SettingsSearchModelTests.ready(model))
    model.pasteCompleted(Self.delivered("zzqx other", to: AppBundleIdentity.production))
    model.reset(endedBy: .escape)
    #expect(sent.rows.last?.query == nil, "an open search was not marked")
    model.setQuery("zzqy")
    #expect(await SettingsSearchModelTests.ready(model))
    model.reset(endedBy: .escape)
    #expect(sent.rows.last?.query == "zzqy", "the mark carried over to the next search")
  }

  @Test("remembered dictation text is cleared on window close and is never in the event (#4843)")
  func rememberedDictationsStayInMemory() async throws {
    let sent = Sent()
    let model = try Self.model(sent: sent)
    let secret = "zzqx secretphrase blorp"
    model.pasteCompleted(Self.delivered(secret, to: AppBundleIdentity.production))
    #expect(model.recentDictations == [secret])
    // A search that ends as a gap with the dictation in memory: counts only, and no part of the
    // remembered text appears anywhere in the row.
    model.setQuery(secret)
    #expect(await SettingsSearchModelTests.ready(model))
    model.reset(endedBy: .escape)
    let row = try #require(sent.rows.last)
    #expect(row.query == nil)
    #expect(!String(describing: row).contains("secretphrase"), "dictated text reached the row")
    // Closing the window forgets the memory.
    model.reset(endedBy: .windowClose)
    #expect(model.recentDictations.isEmpty)
    model.setQuery(secret)
    #expect(await SettingsSearchModelTests.ready(model))
    model.reset(endedBy: .escape)
    #expect(sent.rows.last?.query == secret, "a closed window still remembered")
  }

  @Test("only the last few own dictations are remembered (#4843)")
  func recentDictationsAreBounded() throws {
    let model = try Self.model(sent: Sent())
    for n in 0..<(SettingsSearchModel.recentDictationsKept + 3) {
      model.pasteCompleted(Self.delivered("take \(n)", to: AppBundleIdentity.production))
    }
    #expect(SettingsSearchModel.recentDictationsKept == 8)
    #expect(model.recentDictations == (3..<11).map { "take \($0)" }, "oldest three not evicted in order")
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

  /// #3142 French slice: the row reports each shipped interface language as itself and anything
  /// else as English, so French searches are measured apart from English ones.
  @Test("the row keeps a shipped interface language and reports any other as en")
  func appLanguageAllowList() {
    func row(_ language: String) -> String {
      SettingsSearchFinished(
        outcome: .zeroResults, endedBy: .escape, resultCount: 0, appLanguage: language,
        typedQuery: nil, typedQueryWordCount: 0
      ).appLanguage
    }
    #expect(row("fr") == "fr")
    #expect(row("de") == "de")
    #expect(row("es") == "es")
    #expect(row("en") == "en")
    #expect(row("it") == "en")
    #expect(row("") == "en")
  }
}
