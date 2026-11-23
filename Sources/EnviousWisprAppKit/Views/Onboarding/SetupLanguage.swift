import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// The Language screen's matching and greeting data (#4528 D1, plan M75). Language names and
/// support come from `LanguageCatalog.all` only (no second inventory); folding and typo distance
/// from `SearchText`.
enum SetupLanguage {
  /// What a typed text resolves to.
  enum Match: Equatable {
    case language(LanguageCatalog.Entry)
    /// An existing Auto choice, restored or re-typed ("Detect automatically" or "auto").
    case automatic

    var mode: LanguageMode {
      switch self {
      case .language(let entry): .locked(entry.lockCode)
      case .automatic: .auto
      }
    }

    /// The chip's text: "Deutsch · German", or the one name when both are the same.
    var label: String {
      switch self {
      case .automatic: String(localized: automaticLabel)
      case .language(let entry):
        entry.nativeName == entry.displayName
          ? entry.displayName
          : String(
            localized: "\(entry.nativeName) · \(entry.displayName)",
            comment:
              "Setup language match: the language's own name, then its name in the interface language, as in Deutsch · German."
          )
      }
    }

    /// The code whose greeting plays, if any.
    var greetingCode: String? {
      if case .language(let entry) = self { return entry.code }
      return nil
    }
  }

  static let automaticLabel = LocalizedStringResource(
    "Detect automatically",
    comment:
      "Setup language field: shown for a person who already chose automatic language detection.")

  /// Resolves typed text (mockup `matchLanguage`): an exact name or a code (2+ letters) first,
  /// then a prefix (2+ letters, shorter names first), then a typo (distance 1 from 4 letters, 2
  /// from 7). nil when nothing matches.
  static func match(_ input: String) -> Match? {
    let query = fold(input)
    guard !query.isEmpty else { return nil }
    if query == "auto" || query == fold(String(localized: automaticLabel)) { return .automatic }
    var best: (score: Double, entry: LanguageCatalog.Entry)?
    for entry in LanguageCatalog.all {
      for name in names(of: entry) {
        guard let score = score(query: query, name: name, code: entry.code) else { continue }
        if let current = best, score >= current.score { continue }
        best = (score, entry)
      }
    }
    return best.map { .language($0.entry) }
  }

  /// The field's starting text: the committed language when there is one (Auto included), else
  /// the Mac's language when the catalog has it, else blank (founder D8: never a default).
  static func initialText(committed: LanguageMode?, macCode: String?) -> (
    text: String, guessed: Bool
  ) {
    switch committed {
    case .locked(let code)?:
      return (LanguageCatalog.entry(for: code).nativeName, false)
    case .auto?:
      return (String(localized: automaticLabel), false)
    case nil:
      guard let macCode, let entry = LanguageCatalog.all.first(where: { $0.code == macCode })
      else { return ("", false) }
      return (entry.nativeName, true)
    }
  }

  /// The hint shows once at least three folded letters match nothing (mockup `noMatch`).
  static func showsNoMatch(_ input: String) -> Bool {
    fold(input).count >= 3 && match(input) == nil
  }

  // MARK: Greetings (mockup `GREET`: "Hello" and its spoken beats)

  struct Greeting: Equatable {
    let text: String
    let beats: Int
    /// How long the bubble stays: the beats, then a short hold (mockup greetFor).
    var seconds: Double { Double(beats) * 0.3 + 1.6 }
  }

  /// The pause before a new greeting appears (mockup greetFor `wait`).
  static let greetingDelay: Double = 0.15

  static func greeting(for code: String) -> Greeting? {
    greetings[code].map { Greeting(text: $0.0, beats: $0.1) }
  }

  /// Each language's own word for hello; never translated (it IS the language). DRAFT values from
  /// the mockup; G's native-speaker review checks them.
  private static let greetings: [String: (String, Int)] = [
    "en": ("Hello!", 2), "es": ("¡Hola!", 2), "fr": ("Bonjour !", 2), "de": ("Hallo!", 2),
    "it": ("Ciao!", 1), "pt": ("Olá!", 2), "nl": ("Hallo!", 2), "pl": ("Cześć!", 1),
    "ru": ("Привет!", 2), "uk": ("Привіт!", 2), "cs": ("Ahoj!", 2), "sk": ("Ahoj!", 2),
    "sl": ("Živjo!", 2), "hr": ("Bok!", 1), "bg": ("Здравей!", 2), "ro": ("Salut!", 2),
    "hu": ("Szia!", 2), "el": ("Γεια σου!", 3), "sv": ("Hej!", 1), "da": ("Hej!", 1),
    "fi": ("Hei!", 1), "et": ("Tere!", 2), "lv": ("Sveiki!", 2), "lt": ("Labas!", 2),
    "mt": ("Bonġu!", 2), "ja": ("こんにちは！", 5), "zh": ("你好！", 2), "yue": ("你好！", 2),
    "ko": ("안녕하세요!", 5), "hi": ("नमस्ते!", 3), "ar": ("مرحبا!", 3), "he": ("שלום!", 2),
    "tr": ("Merhaba!", 3), "fa": ("سلام!", 2), "ur": ("سلام!", 2), "bn": ("নমস্কার!", 3),
    "ta": ("வணக்கம்!", 3), "te": ("నమస్కారం!", 4), "mr": ("नमस्कार!", 3), "gu": ("નમસ્તે!", 3),
    "kn": ("ನಮಸ್ಕಾರ!", 4), "ml": ("നമസ്കാരം!", 4), "pa": ("ਸਤ ਸ੍ਰੀ ਅਕਾਲ!", 5), "th": ("สวัสดี!", 3),
    "vi": ("Xin chào!", 2), "id": ("Halo!", 2), "ms": ("Helo!", 2), "tl": ("Kumusta!", 3),
    "sw": ("Jambo!", 2), "no": ("Hei!", 1), "is": ("Halló!", 2), "ca": ("Hola!", 2),
    "gl": ("Ola!", 2), "eu": ("Kaixo!", 2), "cy": ("Helo!", 2), "sr": ("Здраво!", 2),
    "bs": ("Zdravo!", 2), "be": ("Прывітанне!", 4), "kk": ("Сәлем!", 2), "az": ("Salam!", 2),
    "hy": ("Բարև!", 2), "ka": ("გამარჯობა!", 4), "ne": ("नमस्ते!", 3), "si": ("ආයුබෝවන්!", 4),
    "km": ("សួស្តី!", 2), "my": ("မင်္ဂလာပါ!", 4), "am": ("ሰላም!", 2), "af": ("Hallo!", 2),
    "yo": ("Báwo!", 2), "haw": ("Aloha!", 3), "la": ("Salve!", 2), "mi": ("Kia ora!", 3),
  ]

  // MARK: Matching internals

  private static func fold(_ text: String) -> String {
    SearchText.normalize(text).split(separator: " ").joined(separator: " ")
  }

  private static func names(of entry: LanguageCatalog.Entry) -> [String] {
    var seen = Set<String>()
    let spellings = [entry.englishName, entry.displayName, entry.nativeName]
      + (aliases[entry.code] ?? [])
    return spellings.map(fold).filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  /// Other names people type for a catalog language (the approved mockup's extra spellings),
  /// keyed by `LanguageCatalog` code: metadata on the catalog's own entries, never a language
  /// the catalog lacks.
  static let aliases: [String: [String]] = [
    "ar": ["arabi"],
    "az": ["azeri"],
    "bn": ["bangla"],
    "cs": ["cesky", "tschechisch"],
    "de": ["aleman", "alemán", "allemand", "tedesco"],
    "el": ["ellinika"],
    "en": ["eng", "inglés", "ingles", "anglais", "englisch", "american", "british"],
    "es": ["castellano", "espanol", "espagnol", "spanisch"],
    "fa": ["farsi", "dari"],
    "fr": ["francais", "francés", "frances", "französisch"],
    "haw": ["olelo"],
    "he": ["ivrit"],
    "hi": ["hindustani"],
    "id": ["bahasa"],
    "it": ["italien", "italienisch"],
    "ja": ["nihongo"],
    "km": ["cambodian"],
    "ko": ["hangul"],
    "mi": ["te", "reo"],
    "ms": ["melayu"],
    "my": ["myanmar"],
    "nl": ["flemish", "vlaams", "hollands"],
    "no": ["bokmal", "nynorsk"],
    "pa": ["panjabi"],
    "pl": ["polnisch"],
    "pt": ["portugues", "brazilian", "brasileiro", "portugais"],
    "ro": ["romana", "moldovan"],
    "ru": ["russkiy", "russisch"],
    "si": ["sinhalese"],
    "sk": ["slovencina"],
    "sl": ["slovene"],
    "sr": ["srpski"],
    "tl": ["filipino", "pilipino"],
    "tr": ["turkce"],
    "uk": ["ukrainska"],
    "vi": ["tieng", "viet"],
    "yue": ["guangdonghua", "广东话"],
    "zh": ["mandarin", "putonghua", "zhongwen", "普通话"],
  ]

  private static func score(query: String, name: String, code: String) -> Double? {
    if name == query || (query.count >= 2 && query == code) { return 0 }
    if query.count >= 2, name.hasPrefix(query) {
      return 1 + Double(name.count - query.count) / 100
    }
    guard query.count >= 4 else { return nil }
    let limit = query.count >= 7 ? 2 : 1
    let prefixLength = max(query.count, min(name.count, query.count + 1))
    let distance = min(
      SearchText.editDistance(query, String(name.prefix(prefixLength)), limit: limit),
      SearchText.editDistance(query, name, limit: limit))
    return distance <= limit ? 2 + Double(distance) : nil
  }
}
