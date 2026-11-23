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
        "page" : "aiPolish"
      },
      "dictionaryTab" : null,
      "fallbacks" : [

      ],
      "id" : "page.aiPolish",
      "kind" : null,
      "parent" : "window.settings",
      "searchable" : false,
      "structure" : "page",
      "target" : null,
      "title" : {
        "catalog" : "Sources/EnviousWispr/Resources/Localizable.xcstrings",
        "de" : "KI-Nachbearbeitung",
        "en" : "AI Polish",
        "es" : "Pulido con IA",
        "fr" : "Retouche IA",
        "key" : "AI Polish",
        "source" : "resource",
        "table" : "Localizable"
      },
      "visibility" : "always"
    },
    {
      "context" : [
        "window.settings",
        "page.aiPolish"
      ],
      "declaredIn" : "Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift",
      "description" : null,
      "destination" : {
        "page" : "aiPolish"
      },
      "dictionaryTab" : null,
      "fallbacks" : [

      ],
      "id" : "section.aiPolishModel",
      "kind" : null,
      "parent" : "page.aiPolish",
      "searchable" : false,
      "structure" : "section",
      "target" : null,
      "title" : {
        "catalog" : "Sources/EnviousWispr/Resources/Localizable.xcstrings",
        "de" : "Modell",
        "en" : "Model",
        "es" : "Modelo",
        "fr" : "Modèle",
        "key" : "Model",
        "source" : "resource",
        "table" : "Localizable"
      },
      "visibility" : "aiPolishEnabled"
    },
    {
      "context" : [
        "window.settings",
        "page.aiPolish",
        "section.aiPolishModel"
      ],
      "declaredIn" : "Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift",
      "description" : null,
      "destination" : {
        "page" : "aiPolish"
      },
      "dictionaryTab" : null,
      "fallbacks" : [
        "enableAIPolish"
      ],
      "id" : "aiPolishProvider",
      "kind" : "setting",
      "parent" : "section.aiPolishModel",
      "searchable" : true,
      "structure" : "item",
      "target" : "aiPolishProvider",
      "title" : {
        "owner" : "Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift",
        "resolvedBy" : "SettingsMap.title(of:)",
        "resolver" : "providerName",
        "runtime" : true,
        "source" : "dynamic"
      },
      "visibility" : "aiPolishEnabled"
    },
    {
      "context" : [
        "window.settings",
        "page.aiPolish",
        "section.aiPolishModel",
        "aiPolishProvider"
      ],
      "declaredIn" : "Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift",
      "description" : null,
      "destination" : {
        "page" : "aiPolish"
      },
      "dictionaryTab" : null,
      "fallbacks" : [
        "aiPolishProvider",
        "enableAIPolish"
      ],
      "id" : "aiPolish.providerSection",
      "kind" : "feature",
      "parent" : "aiPolishProvider",
      "searchable" : true,
      "structure" : "item",
      "target" : "aiPolish.providerSection",
      "title" : {
        "owner" : "Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift",
        "resolvedBy" : "SettingsMap.title(of:)",
        "resolver" : "providerSection",
        "runtime" : true,
        "source" : "dynamic"
      },
      "visibility" : "providerSelected"
    }
  ],
  "entries" : [
    {
      "context" : [
        "window.settings",
        "page.aiPolish",
        "section.aiPolishModel",
        "aiPolishProvider",
        "aiPolish.providerSection"
      ],
      "declaredIn" : "Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift",
      "description" : {
        "catalog" : "Sources/EnviousWispr/Resources/Localizable.xcstrings",
        "de" : "Gibt den Speicher des Polish-Modells frei, wenn du nicht diktierst.",
        "en" : "Frees the polish model's memory when you are not dictating.",
        "es" : "Libera la memoria del modelo de Pulido cuando no estás dictando.",
        "fr" : "Libère la mémoire du modèle de retouche quand vous ne dictez pas.",
        "key" : "Frees the polish model's memory when you are not dictating.",
        "source" : "resource",
        "table" : "Localizable"
      },
      "destination" : {
        "page" : "aiPolish"
      },
      "dictionaryTab" : null,
      "fallbacks" : [
        "aiPolishProvider",
        "enableAIPolish"
      ],
      "id" : "unloadPolishModel",
      "kind" : "setting",
      "parent" : "aiPolish.providerSection",
      "searchable" : true,
      "structure" : "item",
      "target" : "unloadPolishModel",
      "title" : {
        "catalog" : "Sources/EnviousWispr/Resources/Localizable.xcstrings",
        "de" : "Polish-Modell entladen nach",
        "en" : "Unload polish model after",
        "es" : "Quitar modelo de Pulido de la RAM tras",
        "fr" : "Décharger le modèle de retouche après",
        "key" : "Unload polish model after",
        "source" : "resource",
        "table" : "Localizable"
      },
      "visibility" : "providerSelected"
    }
  ],
  "schema" : "settings-map-export",
  "version" : 2
}
