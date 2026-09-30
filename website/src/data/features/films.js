// Feature film scenes (#2816), copied from the approved mock's films.py. Only
// the kinds a page renders are kept: dictionary, snippets, quickadd,
// correction, selflearn, formatting, languages, preview. The same data renders the finished frame at build time
// (FeatureFilm.astro) and drives the animation (scripts/features/film-director.js).
export const SCENES = {
  dictionary: [
    { label: 'People', title: 'Names you know.', where: 'On your Mac', raw: 'send the notes to a mirror', out: 'Send the notes to Amira.', raw_marks: ['a mirror'], out_marks: ['Amira'], saved: 'Amira', explain: 'Your spelling, ready to use.' },
    { label: 'Tools', title: 'Tools you use.', where: 'On your Mac', raw: 'open the post gres sequel dashboard', out: 'Open the PostgreSQL dashboard.', raw_marks: ['post gres sequel'], out_marks: ['PostgreSQL'], saved: 'PostgreSQL', explain: 'Your vocabulary, in place.' },
    { label: 'Business', title: 'Your product name.', where: 'On your Mac', raw: 'envious whisper keeps up with my ideas', out: 'EnviousWispr keeps up with my ideas.', raw_marks: ['envious whisper'], out_marks: ['EnviousWispr'], saved: 'EnviousWispr', explain: 'Your product, spelled your way.' },
  ],
  snippets: [
    { label: 'Email', title: 'Your email address.', where: 'Saved text', raw: 'backslash my email', out: 'john.doe@example.com', raw_marks: ['my email'], out_marks: [], saved: 'my email', explain: 'Your email address, ready to use.' },
    { label: 'Address', title: 'Your mailing address.', where: 'Saved text', raw: 'backslash my address', out: '1600 Example Way, Suite 200, Springfield, IL 62704', raw_marks: ['my address'], out_marks: [], saved: 'my address', explain: 'Your full address, ready to use.' },
    { label: 'Calendar', title: 'Your calendar link.', where: 'Saved text', raw: 'backslash my calendar', out: 'https://cal.example.com/john-doe', raw_marks: ['my calendar'], out_marks: [], saved: 'my calendar', explain: 'Your calendar link, ready to share.' },
  ],
  quickadd: [
    { label: 'Quick Add', title: 'Find the word you meant.', where: 'Quick Add', raw: 'Let’s use NVS Vispr.', out: '"NVS Vispr" added to EnviousWispr', raw_marks: ['NVS Vispr'], saved: 'EnviousWispr', explain: 'Added as a spelling in your dictionary.' },
  ],
  correction: [
    { label: 'Self-correction', title: 'The thought you meant.', where: 'With AI polish', raw: 'Let’s meet Thursday, actually Friday.', out: 'Let’s meet Friday.', raw_marks: ['Thursday, actually '], out_marks: ['Friday'], saved: 'Keep the corrected detail', explain: 'Keep what you meant.' },
  ],
  // Self-Learning Dictionary (#996): the pasted text, the user's own fix, the
  // pill, then the next dictation. Pill wording is the app's own
  // (help/self-learning-dictionary.md, "Read the pill").
  selflearn: [
    { label: 'Names', title: 'Correcting a name', where: 'On your Mac', pasted: 'Send the draft to ', wrong: 'Sasha', fixed: 'Saoirse', tail: ' tonight.', pill: 'Added “Saoirse” to Dictionary', out: 'Saoirse signed off on the draft.', out_marks: ['Saoirse'], explain: 'Checked locally each time before changing your text.' },
    { label: 'Tools', title: 'Working in your daily apps', where: 'On your Mac', pasted: 'The build runs on ', wrong: 'Twist', fixed: 'Tuist', tail: ' now.', pill: 'Added “Tuist” to Dictionary', out: 'Run Tuist before you open the project.', out_marks: ['Tuist'], explain: 'Checked locally against context before it is applied.' },
    { label: 'Updates', title: 'Updating an existing word', where: 'On your Mac', pasted: 'Put the notes in ', wrong: 'Motion', fixed: 'Notion', tail: ' for now.', pill: '“Notion” updated', out: 'The roadmap lives in Notion.', out_marks: ['Notion'], explain: 'The new mishearing is attached to your existing word.' },
  ],
  // Smart Formatting (2.5.0/2.5.1 What's New): spoken technical text written the
  // way you would type it. Every example is a row in help/numbers-dates-and-times.md
  // or help/spoken-punctuation-and-emoji.md, which own the behavior.
  formatting: [
    { label: 'Versions', title: 'Version numbers, whole.', where: 'On your Mac', raw: 'ship version two point five point zero tonight', out: 'Ship version 2.5.0 tonight.', raw_marks: ['version two point five point zero'], out_marks: ['version 2.5.0'], saved: 'Version number', explain: 'Formatted on your Mac, before any AI polish.' },
    { label: 'Hosts', title: 'Hosts and ports.', where: 'On your Mac', raw: 'the app runs on localhost colon three thousand', out: 'The app runs on localhost:3000.', raw_marks: ['localhost colon three thousand'], out_marks: ['localhost:3000'], saved: 'Host and port', explain: 'Formatted on your Mac, before any AI polish.' },
    { label: 'Commands', title: 'Slash commands.', where: 'On your Mac', raw: 'type slash clear and start again', out: 'Type /clear and start again.', raw_marks: ['slash clear'], out_marks: ['/clear'], saved: 'Slash command', explain: 'Works with Convert spoken punctuation on or off.' },
    { label: 'Dates', title: 'Dates in the format you asked for.', where: 'On your Mac', raw: 'the release is twenty twenty six dash nine dash twenty six', out: 'The release is 2026-09-26.', raw_marks: ['twenty twenty six dash nine dash twenty six'], out_marks: ['2026-09-26'], saved: 'Dashed date', explain: 'Formatted on your Mac, before any AI polish.' },
  ],
  // Languages (2.5.1 What's New): British spelling and addresses said with each
  // language's own words. Examples from help/multi-language-dictation.md and
  // help/numbers-dates-and-times.md.
  languages: [
    { label: 'English (UK)', title: 'British spelling.', where: 'English (UK)', raw: 'we changed the color of the logo at the center', out: 'We changed the colour of the logo at the centre.', raw_marks: ['color', 'center'], out_marks: ['colour', 'centre'], saved: 'British spelling', lang: 'en-GB', explain: 'Choose English (UK) and the spelling follows.' },
    { label: 'Español', title: 'Email addresses in Spanish.', where: 'Español', raw: 'maría punto lópez arroba gmail punto com', out: 'maría.lópez@gmail.com', raw_marks: ['punto', 'arroba'], out_marks: ['maría.lópez@gmail.com'], saved: 'Email address', lang: 'es', explain: 'The local words for at and dot, understood.' },
    { label: 'Deutsch', title: 'Web addresses in German.', where: 'Deutsch', raw: 'beispiel Punkt de Schrägstrich hilfe', out: 'beispiel.de/hilfe', raw_marks: ['Punkt', 'Schrägstrich'], out_marks: ['beispiel.de/hilfe'], saved: 'Web address', lang: 'de', explain: 'The local words for dot and slash, understood.' },
    { label: 'Italiano', title: 'Links in Italian.', where: 'Italiano', raw: 'https due punti barra barra esempio punto it', out: 'https://esempio.it', raw_marks: ['due punti', 'barra barra', 'punto'], out_marks: ['https://esempio.it'], saved: 'Web address', lang: 'it', explain: 'Set your dictation language so the app knows it.' },
  ],
  preview: [
    { label: 'English', title: 'Your words, as you speak.', where: 'Live draft', raw: 'Hi Maya um for Friday please bring the design notes the launch checklist and the revised budget of six thousand two hundred thirty nine dollars thanks Amira', lang: 'en', explain: 'Your thought, in view.' },
    { label: 'Deutsch', title: 'Ein Gedanke nimmt Form an.', where: 'Live draft', raw: 'Ein bisschen Raum für den Gedanken, den du gerade hast.', lang: 'de', explain: 'A draft in your language.' },
    { label: '日本語', title: '考えを言葉に。', where: 'Live draft', raw: '今考えていることを、少しずつ言葉にしていく。', lang: 'ja', explain: 'A draft in your language.' },
  ],
};

// Phase durations in ms: listening, working, writing, result.
export const DURATIONS = {
  dictionary: [1700, 700, 650, 3000],
  snippets: [1100, 500, 1350, 3200],
  quickadd: [1300, 3200, 700, 2600],
  correction: [1800, 850, 650, 3200],
  formatting: [1800, 850, 700, 3200],
  languages: [1900, 850, 700, 3200],
  selflearn: [1500, 2800, 4000, 3200],
  preview: [4800, 450, 450, 3000],
};

export const STATUS_WORDS = {
  quickadd: ['Select the misheard words.', 'Pick the word you meant.', 'Press Return to add the spelling.', ''],
  selflearn: ['Pasting the dictation', 'Editing the misheard word', 'Saved to dictionary, with four seconds to undo', ''],
  snippets: ['A short spoken phrase…', 'Finding your saved text…', 'Your words, ready to use…', ''],
  formatting: ['Listening to the example…', 'Formatting on your Mac…', 'Written the way you would type it…', ''],
  languages: ['Listening to the example…', 'Reading it in your language…', 'Written the way you would type it…', ''],
  preview: ['A thought takes shape…', 'The draft updates…', 'Keep it in view…', ''],
  default: ['Listening to the example…', 'Matching your words…', 'Your finished text…', ''],
};

// Static snapshot of the homepage's live-preview well, the frame the
// live-preview page shows before native-preview.js replaces it.
export const NATIVE_PREVIEW_SNAPSHOT_BARS = [
  ['rgb(255,42,64)', 8.35], ['rgb(255,76,42)', 10.46], ['rgb(255,110,19)', 11.47], ['rgb(255,143,0)', 11.36], ['rgb(255,169,0)', 10.33], ['rgb(255,195,0)', 8.73],
  ['rgb(248,218,4)', 6.97], ['rgb(219,232,20)', 5.48], ['rgb(191,246,37)', 4.85], ['rgb(150,254,61)', 5.01], ['rgb(90,253,98)', 4.96], ['rgb(30,251,135)', 6.0],
  ['rgb(0,251,172)', 7.18], ['rgb(0,253,207)', 8.11], ['rgb(0,254,242)', 8.43], ['rgb(7,231,255)', 7.88], ['rgb(17,192,255)', 6.39], ['rgb(27,154,255)', 5.32],
  ['rgb(39,134,247)', 8.09], ['rgb(51,120,237)', 10.89], ['rgb(63,107,226)', 13.21], ['rgb(87,86,225)', 14.61], ['rgb(113,65,226)', 14.75], ['rgb(138,43,226)', 13.52],
];
