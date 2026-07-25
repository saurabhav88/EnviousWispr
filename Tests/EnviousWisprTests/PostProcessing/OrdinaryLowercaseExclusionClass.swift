// Words that must NEVER appear in
// `Sources/EnviousWisprPostProcessing/Resources/ordinary-lowercase-words.txt`.
//
// Each is an ordinary English word that is ALSO a name, brand, product,
// programming language, nationality, place, weekday, month, or the first-person
// pronoun. Lowercasing a capitalised occurrence of one of these mid-sentence
// produces exactly the visible failure this feature exists to avoid: someone's
// name, or a product, rendered in lowercase.
//
// Enumerated by axis rather than discovered one bug at a time. Adding a word
// here is always safe. Removing one requires justifying why the homograph
// cannot occur in ordinary dictation.
//
// Issue: #1785.

/// The exclusion class for the ordinary-lowercase lexicon, grouped by the axis
/// that makes each word unsafe to lowercase.
enum OrdinaryLowercaseExclusionClass {
  static let words: Set<String> = [
    // given names and surnames
    "amber", "april", "archer", "art", "august", "autumn", "baker", "barry", "bernard",
    "bill", "bishop", "bob", "buck", "bud", "carol", "carter", "chance", "chase",
    "christian", "cliff", "cook", "curt", "daisy", "dale", "dawn", "dean", "dick", "don",
    "drew", "earl", "ernest", "faith", "felix", "fisher", "forest", "frank", "gene",
    "glen", "grace", "grant", "guy", "hank", "harry", "hazel", "heather", "herb", "holly",
    "hope", "hunter", "ivy", "jack", "jade", "jasmine", "jasper", "jay", "jean", "jim",
    "joe", "john", "jordan", "joy", "justice", "king", "lance", "lane", "lily", "major",
    "mark", "marshall", "mason", "max", "mercy", "mike", "miles", "miller", "minor",
    "nick", "noble", "olive", "page", "parker", "pat", "patience", "pearl", "pete", "phil",
    "piper", "porter", "prudence", "rain", "ranger", "ray", "reed", "reid", "rich", "rob",
    "robin", "rock", "ron", "rose", "roy", "ruby", "russ", "sage", "sal", "sam", "sandy",
    "scout", "shane", "sky", "smith", "sonny", "stan", "star", "sterling", "stone",
    "storm", "sue", "summer", "taylor", "ted", "tim", "tom", "trinity", "turner", "van",
    "violet", "wade", "walker", "wally", "ward", "will", "wren",

    // ordinary-word surnames, second sweep
    "bailey", "banks", "bell", "best", "bird", "brooks", "brown", "bush", "church",
    "cooper", "crane", "drake", "east", "fields", "finch", "flowers", "ford", "foster",
    "fox", "frost", "gates", "gray", "green", "hall", "hawk", "heath", "hood", "hunt",
    "lamb", "lock", "long", "love", "marsh", "mills", "morgan", "moss", "myers", "north",
    "pope", "price", "rivers", "rush", "sanders", "sharp", "short", "small", "snow",
    "south", "strong", "swan", "thin", "waters", "west", "white", "wild", "winter", "wise",
    "wolf", "wood", "young",

    // languages and nationalities
    "african", "american", "arabic", "asian", "australian", "basque", "brazilian",
    "british", "bulgarian", "canadian", "catalan", "chinese", "croatian", "czech",
    "danish", "dutch", "english", "estonian", "european", "finnish", "french", "german",
    "greek", "hebrew", "hindi", "hungarian", "icelandic", "indian", "indonesian", "irish",
    "italian", "japanese", "korean", "latin", "latvian", "lithuanian", "malay", "mexican",
    "norwegian", "persian", "polish", "portuguese", "romanian", "russian", "scottish",
    "serbian", "slovak", "slovenian", "spanish", "swedish", "swiss", "thai", "turkish",
    "ukrainian", "vietnamese", "welsh",

    // brands, products and programming languages
    "alexa", "amazon", "angular", "apple", "arc", "astro", "automator", "axios", "babel",
    "backbone", "blender", "blizzard", "books", "box", "brave", "bun", "bungie",
    "calendar", "canva", "chai", "chrome", "claude", "clock", "codex", "contacts",
    "cortana", "cypress", "dart", "delta", "deno", "discord", "django", "docs", "drive",
    "dropbox", "duo", "echo", "edge", "elm", "ember", "epic", "excel", "express", "figma",
    "finder", "flask", "flow", "framer", "gemini", "go", "health", "home", "jasmine",
    "java", "jest", "jquery", "julia", "karma", "keep", "keynote", "kotlin", "lens",
    "lodash", "lyft", "mail", "maps", "meta", "mint", "mocha", "music", "nest", "news",
    "next", "nim", "notes", "notion", "numbers", "nuxt", "opera", "oracle", "origin",
    "pages", "parakeet", "parcel", "perl", "photos", "podcasts", "polish", "preview",
    "prime", "processing", "python", "rails", "react", "reminders", "remix", "riot",
    "rollup", "ruby", "rust", "safari", "scala", "sheets", "shell", "signal", "siri",
    "sketch", "slack", "sol", "spark", "spring", "square", "steam", "stocks", "stripe",
    "struts", "sun", "svelte", "swift", "target", "teams", "telegram", "terminal", "tor",
    "uber", "unity", "unreal", "valve", "visa", "vite", "vivaldi", "vue", "wallet",
    "weather", "webpack", "whisper", "windows", "word", "xcode", "zig", "zoom",

    // places
    "alexandria", "athens", "bath", "berlin", "boring", "brazil", "cairo", "chad", "chile",
    "china", "cuba", "dublin", "eureka", "florence", "georgia", "haiti", "hampshire",
    "hollywood", "india", "iran", "iraq", "japan", "jersey", "jordan", "kenya", "korea",
    "laos", "mali", "malta", "memphis", "mexico", "mobile", "naples", "nepal", "nice",
    "niger", "normal", "oman", "orange", "paradise", "peru", "phoenix", "qatar", "reading",
    "rome", "sandwich", "turkey", "york",

    // months and weekdays
    "april", "august", "december", "february", "friday", "january", "july", "june",
    "march", "may", "monday", "november", "october", "saturday", "september", "sunday",
    "thursday", "tuesday", "wednesday",

    // the first-person pronoun and its contractions
    "i", "i'd", "i'll", "i'm", "i've",

  ]
}
