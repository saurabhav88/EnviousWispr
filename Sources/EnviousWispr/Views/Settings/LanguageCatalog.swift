import Foundation

/// Display metadata for the 99 Whisper-supported languages.
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
        let code: String
        let nativeName: String
        let englishName: String
    }

    /// Lookup a display entry by ISO code. Returns a safe fallback entry using
    /// the code itself if the code is not in the catalog (defensive, should
    /// never happen for Whisper-supported codes).
    static func entry(for code: String) -> Entry {
        if let found = all.first(where: { $0.code == code.lowercased() }) {
            return found
        }
        return Entry(code: code, nativeName: code.uppercased(), englishName: code.uppercased())
    }

    /// All 99 languages, sorted alphabetically by English name for catalog display.
    static let sortedByEnglishName: [Entry] = all.sorted { lhs, rhs in
        lhs.englishName.localizedCaseInsensitiveCompare(rhs.englishName) == .orderedAscending
    }

    /// All 99 Whisper-supported languages. Order here is not significant; the
    /// UI sorts via `sortedByEnglishName`.
    static let all: [Entry] = [
        Entry(code: "af",  nativeName: "Afrikaans",        englishName: "Afrikaans"),
        Entry(code: "am",  nativeName: "አማርኛ",              englishName: "Amharic"),
        Entry(code: "ar",  nativeName: "العربية",           englishName: "Arabic"),
        Entry(code: "as",  nativeName: "অসমীয়া",            englishName: "Assamese"),
        Entry(code: "az",  nativeName: "Azərbaycanca",     englishName: "Azerbaijani"),
        Entry(code: "ba",  nativeName: "Башҡортса",        englishName: "Bashkir"),
        Entry(code: "be",  nativeName: "Беларуская",       englishName: "Belarusian"),
        Entry(code: "bg",  nativeName: "Български",        englishName: "Bulgarian"),
        Entry(code: "bn",  nativeName: "বাংলা",              englishName: "Bengali"),
        Entry(code: "bo",  nativeName: "བོད་སྐད་",            englishName: "Tibetan"),
        Entry(code: "br",  nativeName: "Brezhoneg",        englishName: "Breton"),
        Entry(code: "bs",  nativeName: "Bosanski",         englishName: "Bosnian"),
        Entry(code: "ca",  nativeName: "Català",           englishName: "Catalan"),
        Entry(code: "cs",  nativeName: "Čeština",          englishName: "Czech"),
        Entry(code: "cy",  nativeName: "Cymraeg",          englishName: "Welsh"),
        Entry(code: "da",  nativeName: "Dansk",            englishName: "Danish"),
        Entry(code: "de",  nativeName: "Deutsch",          englishName: "German"),
        Entry(code: "el",  nativeName: "Ελληνικά",         englishName: "Greek"),
        Entry(code: "en",  nativeName: "English",          englishName: "English"),
        Entry(code: "es",  nativeName: "Español",          englishName: "Spanish"),
        Entry(code: "et",  nativeName: "Eesti",            englishName: "Estonian"),
        Entry(code: "eu",  nativeName: "Euskara",          englishName: "Basque"),
        Entry(code: "fa",  nativeName: "فارسی",             englishName: "Persian"),
        Entry(code: "fi",  nativeName: "Suomi",            englishName: "Finnish"),
        Entry(code: "fo",  nativeName: "Føroyskt",         englishName: "Faroese"),
        Entry(code: "fr",  nativeName: "Français",         englishName: "French"),
        Entry(code: "gl",  nativeName: "Galego",           englishName: "Galician"),
        Entry(code: "gu",  nativeName: "ગુજરાતી",            englishName: "Gujarati"),
        Entry(code: "ha",  nativeName: "Hausa",            englishName: "Hausa"),
        Entry(code: "haw", nativeName: "ʻŌlelo Hawaiʻi",   englishName: "Hawaiian"),
        Entry(code: "he",  nativeName: "עברית",             englishName: "Hebrew"),
        Entry(code: "hi",  nativeName: "हिन्दी",              englishName: "Hindi"),
        Entry(code: "hr",  nativeName: "Hrvatski",         englishName: "Croatian"),
        Entry(code: "ht",  nativeName: "Kreyòl Ayisyen",   englishName: "Haitian Creole"),
        Entry(code: "hu",  nativeName: "Magyar",           englishName: "Hungarian"),
        Entry(code: "hy",  nativeName: "Հայերեն",          englishName: "Armenian"),
        Entry(code: "id",  nativeName: "Bahasa Indonesia", englishName: "Indonesian"),
        Entry(code: "is",  nativeName: "Íslenska",         englishName: "Icelandic"),
        Entry(code: "it",  nativeName: "Italiano",         englishName: "Italian"),
        Entry(code: "ja",  nativeName: "日本語",              englishName: "Japanese"),
        Entry(code: "jw",  nativeName: "Basa Jawa",        englishName: "Javanese"),
        Entry(code: "ka",  nativeName: "ქართული",          englishName: "Georgian"),
        Entry(code: "kk",  nativeName: "Қазақша",          englishName: "Kazakh"),
        Entry(code: "km",  nativeName: "ខ្មែរ",                englishName: "Khmer"),
        Entry(code: "kn",  nativeName: "ಕನ್ನಡ",              englishName: "Kannada"),
        Entry(code: "ko",  nativeName: "한국어",              englishName: "Korean"),
        Entry(code: "la",  nativeName: "Latina",           englishName: "Latin"),
        Entry(code: "lb",  nativeName: "Lëtzebuergesch",   englishName: "Luxembourgish"),
        Entry(code: "ln",  nativeName: "Lingála",          englishName: "Lingala"),
        Entry(code: "lo",  nativeName: "ລາວ",                englishName: "Lao"),
        Entry(code: "lt",  nativeName: "Lietuvių",         englishName: "Lithuanian"),
        Entry(code: "lv",  nativeName: "Latviešu",         englishName: "Latvian"),
        Entry(code: "mg",  nativeName: "Malagasy",         englishName: "Malagasy"),
        Entry(code: "mi",  nativeName: "Māori",            englishName: "Maori"),
        Entry(code: "mk",  nativeName: "Македонски",       englishName: "Macedonian"),
        Entry(code: "ml",  nativeName: "മലയാളം",            englishName: "Malayalam"),
        Entry(code: "mn",  nativeName: "Монгол",           englishName: "Mongolian"),
        Entry(code: "mr",  nativeName: "मराठी",              englishName: "Marathi"),
        Entry(code: "ms",  nativeName: "Bahasa Melayu",    englishName: "Malay"),
        Entry(code: "mt",  nativeName: "Malti",            englishName: "Maltese"),
        Entry(code: "my",  nativeName: "မြန်မာ",             englishName: "Burmese"),
        Entry(code: "ne",  nativeName: "नेपाली",             englishName: "Nepali"),
        Entry(code: "nl",  nativeName: "Nederlands",       englishName: "Dutch"),
        Entry(code: "nn",  nativeName: "Nynorsk",          englishName: "Norwegian Nynorsk"),
        Entry(code: "no",  nativeName: "Norsk",            englishName: "Norwegian"),
        Entry(code: "oc",  nativeName: "Occitan",          englishName: "Occitan"),
        Entry(code: "pa",  nativeName: "ਪੰਜਾਬੀ",             englishName: "Punjabi"),
        Entry(code: "pl",  nativeName: "Polski",           englishName: "Polish"),
        Entry(code: "ps",  nativeName: "پښتو",              englishName: "Pashto"),
        Entry(code: "pt",  nativeName: "Português",        englishName: "Portuguese"),
        Entry(code: "ro",  nativeName: "Română",           englishName: "Romanian"),
        Entry(code: "ru",  nativeName: "Русский",          englishName: "Russian"),
        Entry(code: "sa",  nativeName: "संस्कृतम्",            englishName: "Sanskrit"),
        Entry(code: "sd",  nativeName: "سنڌي",              englishName: "Sindhi"),
        Entry(code: "si",  nativeName: "සිංහල",             englishName: "Sinhala"),
        Entry(code: "sk",  nativeName: "Slovenčina",       englishName: "Slovak"),
        Entry(code: "sl",  nativeName: "Slovenščina",      englishName: "Slovenian"),
        Entry(code: "sn",  nativeName: "ChiShona",         englishName: "Shona"),
        Entry(code: "so",  nativeName: "Soomaali",         englishName: "Somali"),
        Entry(code: "sq",  nativeName: "Shqip",            englishName: "Albanian"),
        Entry(code: "sr",  nativeName: "Српски",           englishName: "Serbian"),
        Entry(code: "su",  nativeName: "Basa Sunda",       englishName: "Sundanese"),
        Entry(code: "sv",  nativeName: "Svenska",          englishName: "Swedish"),
        Entry(code: "sw",  nativeName: "Kiswahili",        englishName: "Swahili"),
        Entry(code: "ta",  nativeName: "தமிழ்",              englishName: "Tamil"),
        Entry(code: "te",  nativeName: "తెలుగు",              englishName: "Telugu"),
        Entry(code: "tg",  nativeName: "Тоҷикӣ",           englishName: "Tajik"),
        Entry(code: "th",  nativeName: "ไทย",               englishName: "Thai"),
        Entry(code: "tk",  nativeName: "Türkmençe",        englishName: "Turkmen"),
        Entry(code: "tl",  nativeName: "Tagalog",          englishName: "Tagalog"),
        Entry(code: "tr",  nativeName: "Türkçe",           englishName: "Turkish"),
        Entry(code: "tt",  nativeName: "Татарча",          englishName: "Tatar"),
        Entry(code: "uk",  nativeName: "Українська",       englishName: "Ukrainian"),
        Entry(code: "ur",  nativeName: "اردو",              englishName: "Urdu"),
        Entry(code: "uz",  nativeName: "Oʻzbekcha",        englishName: "Uzbek"),
        Entry(code: "vi",  nativeName: "Tiếng Việt",       englishName: "Vietnamese"),
        Entry(code: "yi",  nativeName: "ייִדיש",             englishName: "Yiddish"),
        Entry(code: "yo",  nativeName: "Yorùbá",           englishName: "Yoruba"),
        Entry(code: "yue", nativeName: "粵語",              englishName: "Cantonese"),
        Entry(code: "zh",  nativeName: "中文",              englishName: "Chinese"),
    ]
}
