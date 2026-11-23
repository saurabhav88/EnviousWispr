You are writing the search vocabulary for one place in the Settings search box of EnviousWispr, a macOS dictation app (you press a key and speak, it types your words into any app; optional "AI Polish" cleans the text with an on-device or cloud model). The interface ships in English, German, French and Spanish; people also type searches in 28 other languages.

Use ONLY this brief and the place description below. Do not open, search or read any file, folder, repository or website. Do not run commands.

For the place below, write a block for each of these languages:
ar, bg, cs, da, de, el, en, es, et, fi, fr, hi, hr, hu, it, ja, ko, lt, lv, mt, nl, pl, pt, ro, ru, sk, sl, sv, tr, uk, vi, zh.

- "title": for every language EXCEPT en, de, es and fr, the place's title in natural wording for that language (how an app in that language would label it; keep product names such as EG-1, Ollama, Claude, Parakeet unchanged). en, de, es and fr have NO title: the interface supplies theirs.
- "words": short words or terms people really type for this place that are not already in its title: everyday names, common synonyms, loanwords. 0 to 6. An empty list is fine when the title and phrases already carry the place.
- "phrases": 1 to 3 short everyday searches a native speaker would type, in their own words (German: everyday du form; French: vous form; Spanish: tú form, neutral for Spain and Latin America). At least one.

Rules:
- Describe only what the place really does, judging from its title, description, page, tab and section. Do not invent features.
- Do not use words that would fit a different place in the same section equally well.
- Actions (buttons) get fewer words and one phrase.
- Use lowercase except product names and nouns that a language capitalises.
- A title whose source is "dynamic" is named at runtime (for example a device or provider name); write words about the place's role, never an example name.

Output: one JSON object only, no commentary, no code fence, in exactly this shape:
{"id": "<the place id>", "blocks": [{"language": "ar", "title": "...", "words": [...], "phrases": [...]}, ..., {"language": "de", "words": [...], "phrases": [...]}, ..., {"language": "es", "words": [...], "phrases": [...]}, ..., {"language": "fr", "words": [...], "phrases": [...]}, ...]}
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
        "page" : "dictation",
        "tab" : "engine"
      },
      "dictionaryTab" : null,
      "fallbacks" : [

      ],
      "id" : "page.dictation",
      "kind" : null,
      "parent" : "window.settings",
      "searchable" : false,
      "structure" : "page",
      "target" : null,
      "title" : {
        "catalog" : "Sources/EnviousWispr/Resources/Localizable.xcstrings",
        "de" : "Diktateinstellungen",
        "en" : "Dictation Settings",
        "es" : "Ajustes del dictado",
        "fr" : "Réglages de dictée",
        "key" : "Dictation Settings",
        "source" : "resource",
        "table" : "Localizable"
      },
      "visibility" : "always"
    },
    {
      "context" : [
        "window.settings",
        "page.dictation"
      ],
      "declaredIn" : "Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift",
      "description" : null,
      "destination" : {
        "page" : "dictation",
        "tab" : "microphone"
      },
      "dictionaryTab" : null,
      "fallbacks" : [

      ],
      "id" : "dictation.tab.microphone",
      "kind" : "feature",
      "parent" : "page.dictation",
      "searchable" : true,
      "structure" : "tab",
      "target" : "dictation.tab.microphone",
      "title" : {
        "catalog" : "Sources/EnviousWispr/Resources/Localizable.xcstrings",
        "de" : "Mikrofon",
        "en" : "Microphone",
        "es" : "Micrófono",
        "fr" : "Micro",
        "key" : "Microphone",
        "source" : "resource",
        "table" : "Localizable"
      },
      "visibility" : "always"
    },
    {
      "context" : [
        "window.settings",
        "page.dictation",
        "dictation.tab.microphone"
      ],
      "declaredIn" : "Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift",
      "description" : null,
      "destination" : {
        "page" : "dictation",
        "tab" : "microphone"
      },
      "dictionaryTab" : null,
      "fallbacks" : [

      ],
      "id" : "section.microphone",
      "kind" : null,
      "parent" : "dictation.tab.microphone",
      "searchable" : false,
      "structure" : "section",
      "target" : null,
      "title" : {
        "catalog" : "Sources/EnviousWispr/Resources/Localizable.xcstrings",
        "de" : "EINGABE & VERHALTEN",
        "en" : "INPUT & BEHAVIOR",
        "es" : "ENTRADA Y COMPORTAMIENTO",
        "fr" : "ENTRÉE ET COMPORTEMENT",
        "key" : "INPUT & BEHAVIOR",
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
        "page.dictation",
        "dictation.tab.microphone",
        "section.microphone"
      ],
      "declaredIn" : "Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift",
      "description" : {
        "catalog" : "Sources/EnviousWispr/Resources/Localizable.xcstrings",
        "de" : "Zeigt einen Hinweis an der Aufnahmeanzeige, wenn kein Ton ankommt.",
        "en" : "Shows a notice on the pill when no sound arrives.",
        "es" : "Muestra un aviso en la píldora de grabación cuando no llega sonido.",
        "fr" : "Affiche un avis sur la pastille d’enregistrement quand aucun son n’arrive.",
        "key" : "Shows a notice on the pill when no sound arrives.",
        "source" : "resource",
        "table" : "Localizable"
      },
      "destination" : {
        "page" : "dictation",
        "tab" : "microphone"
      },
      "dictionaryTab" : null,
      "fallbacks" : [

      ],
      "id" : "silentMicWarning",
      "kind" : "setting",
      "parent" : "section.microphone",
      "searchable" : true,
      "structure" : "item",
      "target" : "silentMicWarning",
      "title" : {
        "catalog" : "Sources/EnviousWispr/Resources/Localizable.xcstrings",
        "de" : "Bei Mikrofonstille warnen",
        "en" : "Warn when the microphone is silent",
        "es" : "Avisar si el micrófono está en silencio",
        "fr" : "Avertir en cas de silence du micro",
        "key" : "Warn when the microphone is silent",
        "source" : "resource",
        "table" : "Localizable"
      },
      "visibility" : "always"
    }
  ],
  "schema" : "settings-map-export",
  "version" : 2
}
