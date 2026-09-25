import EnviousWisprCore
import Foundation

/// Display metadata for the languages accepted by the Whisper path.
///
/// Keyed by ISO 639-1 (and one ISO 639-3-style code, `haw`, plus `yue` for
/// Cantonese) matching `LanguageTypes.whisperSupportedLanguages`. Each entry
/// carries the endonym (native-script name) and an English exonym so the UI
/// can render both: "日本語 (Japanese)", "தமிழ் (Tamil)", etc.
///
/// Native names were researched per language. Keep them accurate. Users see
/// their own language spelled correctly, in their own script.
enum LanguageCatalog {
  struct Entry: Sendable, Equatable {
    /// The row's identity. For a language row, its ISO code; for a spelling variant row
    /// (`englishUK`), a code of its own that no engine ever receives.
    let code: String
    let nativeName: String
    /// The English name, verbatim: identity, English search and tests read this. The screen
    /// shows `displayName`.
    let englishName: String
    /// #3142: the language's name in the interface language (the English name when the app runs
    /// in English), from the catalog, where every `englishName` literal is extracted by type.
    let displayName: String
    /// #3124: the code the dictation engine is locked to when this row is chosen. Equal to `code`
    /// for every language row; "en" for English (UK), because the engines only speak "en".
    let lockCode: String
    /// #3124: the English spelling this row selects, or nil for a non-English row.
    let spelling: EnglishSpelling?

    /// A catalog row. `englishName` is a literal; its key is the English name.
    init(
      code: String, nativeName: String, englishName: LocalizedStringResource,
      lockCode: String? = nil, spelling: EnglishSpelling? = nil
    ) {
      self.init(
        code: code, nativeName: nativeName, verbatimEnglishName: englishName.key,
        displayName: String(localized: englishName), lockCode: lockCode, spelling: spelling)
    }

    /// A row built at run time (the unknown-code fallback), shown exactly as given.
    init(
      code: String, nativeName: String, verbatimEnglishName: String,
      displayName: String? = nil, lockCode: String? = nil, spelling: EnglishSpelling? = nil
    ) {
      self.code = code
      self.nativeName = nativeName
      self.englishName = verbatimEnglishName
      self.displayName = displayName ?? verbatimEnglishName
      self.lockCode = lockCode ?? code
      self.spelling = spelling
    }
  }

  /// #3124: the picker row for British spelling. NOT in `all`, which is the catalogue of languages
  /// the engines accept: this row selects a spelling of one of them.
  static let englishUK = Entry(
    code: "en-gb", nativeName: "English (UK)",
    englishName: LocalizedStringResource(
      "English (UK)", comment: "A language name (dictation language picker)."), lockCode: "en",
    spelling: .british)

  /// Every row the dictation-language picker can offer: the languages, with English (UK) directly
  /// after English so the two spellings sit together.
  static let pickerEntries: [Entry] = sortedForDisplay.flatMap { entry in
    entry.code == "en" ? [entry, englishUK] : [entry]
  }

  /// The picker's second line for a row. The two English rows say what they DO, since both lock
  /// the engine to "en"; every other row keeps its name and code.
  static func pickerSubtitle(for entry: Entry) -> String {
    switch entry.spelling {
    case .british:
      return String(
        localized: "British spelling: colour, organise, centre",
        comment:
          "Dictation language picker: under English (UK). Keep the three example words in British spelling; they show the result."
      )
    case .american:
      return String(
        localized: "American spelling: color, organize, center",
        comment:
          "Dictation language picker: under English. Keep the three example words in American spelling; they show the result."
      )
    case nil:
      return String(
        localized: "language.picker.subtitle",
        defaultValue: "\(entry.displayName) · \(entry.code)",
        comment:
          "Dictation language picker: second line of a language row. The first %@ is the language's name, the second its code, such as de."
      )
    }
  }

  /// How the Transcription page names the current lock: "Deutsch (German)", or the one name when
  /// both are the same ("English", "English (UK)"; "Deutsch" in a German interface), rather than
  /// repeating it in brackets.
  static func lockDisplayName(for entry: Entry) -> String {
    entry.nativeName == entry.displayName
      ? entry.displayName
      : String(
        localized: "\(entry.nativeName) (\(entry.displayName))",
        comment:
          "Speech engine settings: the locked language, as in \"Deutsch (German)\". The first %@ is its name in its own language, the second its name in the interface language."
      )
  }

  /// The row that names a lock: the English row matching the spelling for "en", the language row
  /// for any other code. Used wherever the app shows the current or a recent lock.
  static func entry(forLockedCode code: String, spelling: EnglishSpelling) -> Entry {
    let language = entry(for: code)
    guard language.spelling != nil else { return language }
    return spelling == .british ? englishUK : language
  }

  /// Lookup a display entry by ISO code. Returns a safe fallback entry using
  /// the code itself if the code is not in the catalog (defensive, should
  /// never happen for Whisper-supported codes).
  static func entry(for code: String) -> Entry {
    if let found = all.first(where: { $0.code == code.lowercased() }) {
      return found
    }
    return Entry(code: code, nativeName: code.uppercased(), verbatimEnglishName: code.uppercased())
  }

  /// Every accepted Whisper language, sorted alphabetically by English name.
  static let sortedByEnglishName: [Entry] = all.sorted { lhs, rhs in
    lhs.englishName.localizedCaseInsensitiveCompare(rhs.englishName) == .orderedAscending
  }

  /// Every accepted Whisper language in the order the picker shows it: by the name the screen
  /// shows, compared in the interface language, with the code breaking a tie. In English this is
  /// exactly `sortedByEnglishName` (#3142).
  static let sortedForDisplay: [Entry] = all.sorted { lhs, rhs in
    switch lhs.displayName.compare(
      rhs.displayName, options: [.caseInsensitive], range: nil, locale: displayLocale)
    {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame: return lhs.code < rhs.code
    }
  }

  /// The locale the interface is shown in: the bundle's chosen localization, not the Mac's
  /// region, so a German interface sorts German names by German rules.
  private static var displayLocale: Locale {
    Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
  }

  /// Every language accepted by the Whisper path. Order here is not
  /// significant; the UI sorts via `sortedByEnglishName`.
  static let all: [Entry] = [
    Entry(
      code: "af", nativeName: "Afrikaans",
      englishName: LocalizedStringResource(
        "Afrikaans", comment: "A language name (dictation language picker).")),
    Entry(
      code: "am", nativeName: "አማርኛ",
      englishName: LocalizedStringResource(
        "Amharic", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ar", nativeName: "العربية",
      englishName: LocalizedStringResource(
        "Arabic", comment: "A language name (dictation language picker).")),
    Entry(
      code: "as", nativeName: "অসমীয়া",
      englishName: LocalizedStringResource(
        "Assamese", comment: "A language name (dictation language picker).")),
    Entry(
      code: "az", nativeName: "Azərbaycanca",
      englishName: LocalizedStringResource(
        "Azerbaijani", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ba", nativeName: "Башҡортса",
      englishName: LocalizedStringResource(
        "Bashkir", comment: "A language name (dictation language picker).")),
    Entry(
      code: "be", nativeName: "Беларуская",
      englishName: LocalizedStringResource(
        "Belarusian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "bg", nativeName: "Български",
      englishName: LocalizedStringResource(
        "Bulgarian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "bn", nativeName: "বাংলা",
      englishName: LocalizedStringResource(
        "Bengali", comment: "A language name (dictation language picker).")),
    Entry(
      code: "bo", nativeName: "བོད་སྐད་",
      englishName: LocalizedStringResource(
        "Tibetan", comment: "A language name (dictation language picker).")),
    Entry(
      code: "br", nativeName: "Brezhoneg",
      englishName: LocalizedStringResource(
        "Breton", comment: "A language name (dictation language picker).")),
    Entry(
      code: "bs", nativeName: "Bosanski",
      englishName: LocalizedStringResource(
        "Bosnian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ca", nativeName: "Català",
      englishName: LocalizedStringResource(
        "Catalan", comment: "A language name (dictation language picker).")),
    Entry(
      code: "cs", nativeName: "Čeština",
      englishName: LocalizedStringResource(
        "Czech", comment: "A language name (dictation language picker).")),
    Entry(
      code: "cy", nativeName: "Cymraeg",
      englishName: LocalizedStringResource(
        "Welsh", comment: "A language name (dictation language picker).")),
    Entry(
      code: "da", nativeName: "Dansk",
      englishName: LocalizedStringResource(
        "Danish", comment: "A language name (dictation language picker).")),
    Entry(
      code: "de", nativeName: "Deutsch",
      englishName: LocalizedStringResource(
        "German", comment: "A language name (dictation language picker).")),
    Entry(
      code: "el", nativeName: "Ελληνικά",
      englishName: LocalizedStringResource(
        "Greek", comment: "A language name (dictation language picker).")),
    Entry(
      code: "en", nativeName: "English",
      englishName: LocalizedStringResource(
        "English", comment: "A language name (dictation language picker)."), spelling: .american),
    Entry(
      code: "es", nativeName: "Español",
      englishName: LocalizedStringResource(
        "Spanish", comment: "A language name (dictation language picker).")),
    Entry(
      code: "et", nativeName: "Eesti",
      englishName: LocalizedStringResource(
        "Estonian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "eu", nativeName: "Euskara",
      englishName: LocalizedStringResource(
        "Basque", comment: "A language name (dictation language picker).")),
    Entry(
      code: "fa", nativeName: "فارسی",
      englishName: LocalizedStringResource(
        "Persian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "fi", nativeName: "Suomi",
      englishName: LocalizedStringResource(
        "Finnish", comment: "A language name (dictation language picker).")),
    Entry(
      code: "fo", nativeName: "Føroyskt",
      englishName: LocalizedStringResource(
        "Faroese", comment: "A language name (dictation language picker).")),
    Entry(
      code: "fr", nativeName: "Français",
      englishName: LocalizedStringResource(
        "French", comment: "A language name (dictation language picker).")),
    Entry(
      code: "gl", nativeName: "Galego",
      englishName: LocalizedStringResource(
        "Galician", comment: "A language name (dictation language picker).")),
    Entry(
      code: "gu", nativeName: "ગુજરાતી",
      englishName: LocalizedStringResource(
        "Gujarati", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ha", nativeName: "Hausa",
      englishName: LocalizedStringResource(
        "Hausa", comment: "A language name (dictation language picker).")),
    Entry(
      code: "haw", nativeName: "ʻŌlelo Hawaiʻi",
      englishName: LocalizedStringResource(
        "Hawaiian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "he", nativeName: "עברית",
      englishName: LocalizedStringResource(
        "Hebrew", comment: "A language name (dictation language picker).")),
    Entry(
      code: "hi", nativeName: "हिन्दी",
      englishName: LocalizedStringResource(
        "Hindi", comment: "A language name (dictation language picker).")),
    Entry(
      code: "hr", nativeName: "Hrvatski",
      englishName: LocalizedStringResource(
        "Croatian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ht", nativeName: "Kreyòl Ayisyen",
      englishName: LocalizedStringResource(
        "Haitian Creole", comment: "A language name (dictation language picker).")),
    Entry(
      code: "hu", nativeName: "Magyar",
      englishName: LocalizedStringResource(
        "Hungarian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "hy", nativeName: "Հայերեն",
      englishName: LocalizedStringResource(
        "Armenian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "id", nativeName: "Bahasa Indonesia",
      englishName: LocalizedStringResource(
        "Indonesian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "is", nativeName: "Íslenska",
      englishName: LocalizedStringResource(
        "Icelandic", comment: "A language name (dictation language picker).")),
    Entry(
      code: "it", nativeName: "Italiano",
      englishName: LocalizedStringResource(
        "Italian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ja", nativeName: "日本語",
      englishName: LocalizedStringResource(
        "Japanese", comment: "A language name (dictation language picker).")),
    Entry(
      code: "jw", nativeName: "Basa Jawa",
      englishName: LocalizedStringResource(
        "Javanese", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ka", nativeName: "ქართული",
      englishName: LocalizedStringResource(
        "Georgian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "kk", nativeName: "Қазақша",
      englishName: LocalizedStringResource(
        "Kazakh", comment: "A language name (dictation language picker).")),
    Entry(
      code: "km", nativeName: "ខ្មែរ",
      englishName: LocalizedStringResource(
        "Khmer", comment: "A language name (dictation language picker).")),
    Entry(
      code: "kn", nativeName: "ಕನ್ನಡ",
      englishName: LocalizedStringResource(
        "Kannada", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ko", nativeName: "한국어",
      englishName: LocalizedStringResource(
        "Korean", comment: "A language name (dictation language picker).")),
    Entry(
      code: "la", nativeName: "Latina",
      englishName: LocalizedStringResource(
        "Latin", comment: "A language name (dictation language picker).")),
    Entry(
      code: "lb", nativeName: "Lëtzebuergesch",
      englishName: LocalizedStringResource(
        "Luxembourgish", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ln", nativeName: "Lingála",
      englishName: LocalizedStringResource(
        "Lingala", comment: "A language name (dictation language picker).")),
    Entry(
      code: "lo", nativeName: "ລາວ",
      englishName: LocalizedStringResource(
        "Lao", comment: "A language name (dictation language picker).")),
    Entry(
      code: "lt", nativeName: "Lietuvių",
      englishName: LocalizedStringResource(
        "Lithuanian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "lv", nativeName: "Latviešu",
      englishName: LocalizedStringResource(
        "Latvian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "mg", nativeName: "Malagasy",
      englishName: LocalizedStringResource(
        "Malagasy", comment: "A language name (dictation language picker).")),
    Entry(
      code: "mi", nativeName: "Māori",
      englishName: LocalizedStringResource(
        "Maori", comment: "A language name (dictation language picker).")),
    Entry(
      code: "mk", nativeName: "Македонски",
      englishName: LocalizedStringResource(
        "Macedonian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ml", nativeName: "മലയാളം",
      englishName: LocalizedStringResource(
        "Malayalam", comment: "A language name (dictation language picker).")),
    Entry(
      code: "mn", nativeName: "Монгол",
      englishName: LocalizedStringResource(
        "Mongolian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "mr", nativeName: "मराठी",
      englishName: LocalizedStringResource(
        "Marathi", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ms", nativeName: "Bahasa Melayu",
      englishName: LocalizedStringResource(
        "Malay", comment: "A language name (dictation language picker).")),
    Entry(
      code: "mt", nativeName: "Malti",
      englishName: LocalizedStringResource(
        "Maltese", comment: "A language name (dictation language picker).")),
    Entry(
      code: "my", nativeName: "မြန်မာ",
      englishName: LocalizedStringResource(
        "Burmese", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ne", nativeName: "नेपाली",
      englishName: LocalizedStringResource(
        "Nepali", comment: "A language name (dictation language picker).")),
    Entry(
      code: "nl", nativeName: "Nederlands",
      englishName: LocalizedStringResource(
        "Dutch", comment: "A language name (dictation language picker).")),
    Entry(
      code: "nn", nativeName: "Nynorsk",
      englishName: LocalizedStringResource(
        "Norwegian Nynorsk", comment: "A language name (dictation language picker).")),
    Entry(
      code: "no", nativeName: "Norsk",
      englishName: LocalizedStringResource(
        "Norwegian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "oc", nativeName: "Occitan",
      englishName: LocalizedStringResource(
        "Occitan", comment: "A language name (dictation language picker).")),
    Entry(
      code: "pa", nativeName: "ਪੰਜਾਬੀ",
      englishName: LocalizedStringResource(
        "Punjabi", comment: "A language name (dictation language picker).")),
    Entry(
      code: "pl", nativeName: "Polski",
      englishName: LocalizedStringResource(
        "Polish", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ps", nativeName: "پښتو",
      englishName: LocalizedStringResource(
        "Pashto", comment: "A language name (dictation language picker).")),
    Entry(
      code: "pt", nativeName: "Português",
      englishName: LocalizedStringResource(
        "Portuguese", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ro", nativeName: "Română",
      englishName: LocalizedStringResource(
        "Romanian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ru", nativeName: "Русский",
      englishName: LocalizedStringResource(
        "Russian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "sa", nativeName: "संस्कृतम्",
      englishName: LocalizedStringResource(
        "Sanskrit", comment: "A language name (dictation language picker).")),
    Entry(
      code: "sd", nativeName: "سنڌي",
      englishName: LocalizedStringResource(
        "Sindhi", comment: "A language name (dictation language picker).")),
    Entry(
      code: "si", nativeName: "සිංහල",
      englishName: LocalizedStringResource(
        "Sinhala", comment: "A language name (dictation language picker).")),
    Entry(
      code: "sk", nativeName: "Slovenčina",
      englishName: LocalizedStringResource(
        "Slovak", comment: "A language name (dictation language picker).")),
    Entry(
      code: "sl", nativeName: "Slovenščina",
      englishName: LocalizedStringResource(
        "Slovenian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "sn", nativeName: "ChiShona",
      englishName: LocalizedStringResource(
        "Shona", comment: "A language name (dictation language picker).")),
    Entry(
      code: "so", nativeName: "Soomaali",
      englishName: LocalizedStringResource(
        "Somali", comment: "A language name (dictation language picker).")),
    Entry(
      code: "sq", nativeName: "Shqip",
      englishName: LocalizedStringResource(
        "Albanian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "sr", nativeName: "Српски",
      englishName: LocalizedStringResource(
        "Serbian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "su", nativeName: "Basa Sunda",
      englishName: LocalizedStringResource(
        "Sundanese", comment: "A language name (dictation language picker).")),
    Entry(
      code: "sv", nativeName: "Svenska",
      englishName: LocalizedStringResource(
        "Swedish", comment: "A language name (dictation language picker).")),
    Entry(
      code: "sw", nativeName: "Kiswahili",
      englishName: LocalizedStringResource(
        "Swahili", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ta", nativeName: "தமிழ்",
      englishName: LocalizedStringResource(
        "Tamil", comment: "A language name (dictation language picker).")),
    Entry(
      code: "te", nativeName: "తెలుగు",
      englishName: LocalizedStringResource(
        "Telugu", comment: "A language name (dictation language picker).")),
    Entry(
      code: "tg", nativeName: "Тоҷикӣ",
      englishName: LocalizedStringResource(
        "Tajik", comment: "A language name (dictation language picker).")),
    Entry(
      code: "th", nativeName: "ไทย",
      englishName: LocalizedStringResource(
        "Thai", comment: "A language name (dictation language picker).")),
    Entry(
      code: "tk", nativeName: "Türkmençe",
      englishName: LocalizedStringResource(
        "Turkmen", comment: "A language name (dictation language picker).")),
    Entry(
      code: "tl", nativeName: "Tagalog",
      englishName: LocalizedStringResource(
        "Tagalog", comment: "A language name (dictation language picker).")),
    Entry(
      code: "tr", nativeName: "Türkçe",
      englishName: LocalizedStringResource(
        "Turkish", comment: "A language name (dictation language picker).")),
    Entry(
      code: "tt", nativeName: "Татарча",
      englishName: LocalizedStringResource(
        "Tatar", comment: "A language name (dictation language picker).")),
    Entry(
      code: "uk", nativeName: "Українська",
      englishName: LocalizedStringResource(
        "Ukrainian", comment: "A language name (dictation language picker).")),
    Entry(
      code: "ur", nativeName: "اردو",
      englishName: LocalizedStringResource(
        "Urdu", comment: "A language name (dictation language picker).")),
    Entry(
      code: "uz", nativeName: "Oʻzbekcha",
      englishName: LocalizedStringResource(
        "Uzbek", comment: "A language name (dictation language picker).")),
    Entry(
      code: "vi", nativeName: "Tiếng Việt",
      englishName: LocalizedStringResource(
        "Vietnamese", comment: "A language name (dictation language picker).")),
    Entry(
      code: "yi", nativeName: "ייִדיש",
      englishName: LocalizedStringResource(
        "Yiddish", comment: "A language name (dictation language picker).")),
    Entry(
      code: "yo", nativeName: "Yorùbá",
      englishName: LocalizedStringResource(
        "Yoruba", comment: "A language name (dictation language picker).")),
    Entry(
      code: "yue", nativeName: "粵語",
      englishName: LocalizedStringResource(
        "Cantonese", comment: "A language name (dictation language picker).")),
    Entry(
      code: "zh", nativeName: "中文",
      englishName: LocalizedStringResource(
        "Chinese", comment: "A language name (dictation language picker).")),
  ]
}
