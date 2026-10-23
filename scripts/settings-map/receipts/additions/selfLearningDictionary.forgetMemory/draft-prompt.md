You are writing the search vocabulary for one place in the Settings search box of EnviousWispr, a macOS dictation app (you press a key and speak, it types your words into any app; optional "AI Polish" cleans the text with an on-device or cloud model). The interface ships in English and German; people also type searches in 30 other languages.

Use ONLY this brief and the place description below. Do not open, search or read any file, folder, repository or website. Do not run commands.

For the place below, write a block for each of these languages:
ar, bg, cs, da, de, el, en, es, et, fi, fr, hi, hr, hu, it, ja, ko, lt, lv, mt, nl, pl, pt, ro, ru, sk, sl, sv, tr, uk, vi, zh.

- "title": for every language EXCEPT en and de, the place's title in natural wording for that language (how an app in that language would label it; keep product names such as EG-1, Ollama, Claude, Parakeet unchanged). en and de have NO title: the interface supplies theirs.
- "words": short words or terms people really type for this place that are not already in its title: everyday names, common synonyms, loanwords. 0 to 6. An empty list is fine when the title and phrases already carry the place.
- "phrases": 1 to 3 short everyday searches a native speaker would type, in their own words (German: everyday du form). At least one.

Rules:
- Describe only what the place really does, judging from its title, description, page, tab and section. Do not invent features.
- Do not use words that would fit a different place in the same section equally well.
- Actions (buttons) get fewer words and one phrase.
- Use lowercase except product names and nouns that a language capitalises.
- A title whose source is "dynamic" is named at runtime (for example a device or provider name); write words about the place's role, never an example name.

Output: one JSON object only, no commentary, no code fence, in exactly this shape:
{"id": "<the place id>", "blocks": [{"language": "ar", "title": "...", "words": [...], "phrases": [...]}, ..., {"language": "de", "words": [...], "phrases": [...]}, ...]}
One block per language, in the order listed above.

The place (exported from the app's Settings Map; "entries" holds the place, "ancestors" its page, tab and section, outermost first):
{
  "ancestors" : [
    {
      "context" : [
        "window.settings"
      ],
      "declaredIn" : "Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift",
      "description" : null,
      "destination" : {
        "page" : "dictionary"
      },
      "dictionaryTab" : null,
      "fallbacks" : [

      ],
      "id" : "page.dictionary",
      "kind" : null,
      "parent" : "window.settings",
      "searchable" : false,
      "structure" : "page",
      "target" : null,
      "title" : {
        "catalog" : "Sources/EnviousWispr/Resources/Localizable.xcstrings",
        "de" : "Wörterbuch",
        "en" : "Dictionary",
        "key" : "Dictionary",
        "source" : "resource",
        "table" : "Localizable"
      },
      "visibility" : "always"
    },
    {
      "context" : [
        "window.settings",
        "page.dictionary"
      ],
      "declaredIn" : "Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift",
      "description" : {
        "catalog" : "Sources/EnviousWispr/Resources/Localizable.xcstrings",
        "de" : "Nebenbei lernen",
        "en" : "Learn as you go",
        "key" : "Learn as you go",
        "source" : "resource",
        "table" : "Localizable"
      },
      "destination" : {
        "page" : "dictionary"
      },
      "dictionaryTab" : "learnFrom",
      "fallbacks" : [

      ],
      "id" : "dictionary.tab.learnFrom",
      "kind" : "feature",
      "parent" : "page.dictionary",
      "searchable" : true,
      "structure" : "tab",
      "target" : "dictionary.tab.learnFrom",
      "title" : {
        "catalog" : "Sources/EnviousWispr/Resources/Localizable.xcstrings",
        "de" : "Lernen aus...",
        "en" : "Learn from...",
        "key" : "Learn from...",
        "source" : "resource",
        "table" : "Localizable"
      },
      "visibility" : "always"
    },
    {
      "context" : [
        "window.settings",
        "page.dictionary",
        "dictionary.tab.learnFrom"
      ],
      "declaredIn" : "Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift",
      "description" : {
        "catalog" : "Sources/EnviousWispr/Resources/Localizable.xcstrings",
        "de" : "Erkennt automatisch, wenn du ein Diktat korrigierst, und fügt das korrigierte Wort deinem Wörterbuch hinzu. Du kannst das über die Mitteilung rückgängig machen oder das Wort später unter „Deine Wörter“ entfernen.",
        "en" : "Automatically detects when you correct a dictation and adds the corrected word to your dictionary. Undo it from the notification, or remove it later in Your Words.",
        "key" : "Automatically detects when you correct a dictation and adds the corrected word to your dictionary. Undo it from the notification, or remove it later in Your Words.",
        "source" : "resource",
        "table" : "Localizable"
      },
      "destination" : {
        "page" : "dictionary"
      },
      "dictionaryTab" : "learnFrom",
      "fallbacks" : [

      ],
      "id" : "selfLearningDictionary",
      "kind" : "setting",
      "parent" : "dictionary.tab.learnFrom",
      "searchable" : true,
      "structure" : "item",
      "target" : "selfLearningDictionary",
      "title" : {
        "catalog" : "Sources/EnviousWispr/Resources/Localizable.xcstrings",
        "de" : "Selbstlernendes Wörterbuch",
        "en" : "Self-Learning Dictionary",
        "key" : "Self-Learning Dictionary",
        "source" : "resource",
        "table" : "Localizable"
      },
      "visibility" : "always"
    }
  ],
  "entries" : [
    {
      "context" : [
        "window.settings",
        "page.dictionary",
        "dictionary.tab.learnFrom",
        "selfLearningDictionary"
      ],
      "declaredIn" : "Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift",
      "description" : null,
      "destination" : {
        "page" : "dictionary"
      },
      "dictionaryTab" : "learnFrom",
      "fallbacks" : [
        "selfLearningDictionary"
      ],
      "id" : "selfLearningDictionary.forgetMemory",
      "kind" : "action",
      "parent" : "selfLearningDictionary",
      "searchable" : true,
      "structure" : "item",
      "target" : "selfLearningDictionary.forgetMemory",
      "title" : {
        "catalog" : "Sources/EnviousWispr/Resources/Localizable.xcstrings",
        "de" : "Lerngedächtnis löschen",
        "en" : "Forget learning memory",
        "key" : "Forget learning memory",
        "source" : "resource",
        "table" : "Localizable"
      },
      "visibility" : "learnMemoryStored"
    }
  ],
  "schema" : "settings-map-export",
  "version" : 2
}
