# German council review, 2026-10-06 (#3482)

Council session `settings-search-german-2026-10-06`: GPT `gpt-6-sol` (Azure) and Gemini `gemini-3.8-flash`, no web tools. Founder approved the spend on 2026-10-06; it cost about $0.24 over three rounds. Raw answers stay in the council's encrypted history; this file is the digest.

Input (round 1): every German block of the 246 searchable ids (words and phrases, with each place's page, section, English and German title and description), the reviewed German stop list and the protected markers. Prompts: `round1-prompt-head.md` plus `round1-prompt-body.txt`.

## Round 1 findings and dispositions

| Place or list | Finding | Raised by | Disposition |
|---|---|---|---|
| autoDetectLanguage words | "Spracherkennungautomatik" is an unnatural compound (missing linking s) | GPT, Gemini | Adopted: replaced by "automatische Spracherkennung" |
| recordingChime.dustMote words | "tonlos" reads as silent | GPT | Adopted: removed |
| recordingChime.dustMote phrases | "ohne hörbaren Ton" contradicts an audible sound | GPT | Adopted: "ohne erkennbare Tonhöhe" |
| yourWords.category.general | "Alltagswörter", "Alltag" claim more than the General category | GPT | Adopted: both words removed; phrase now names the category |
| aiPolish.providerSection phrases | "Diktatanbieter" means a speech provider, not an AI Polish provider | GPT | Adopted: "Anbieter zur KI-Nachbearbeitung" (the app's German name for AI Polish) |
| Stop list | Common fillers missing | GPT | Adopted: einen, einem, einer, eines, des, dass, mal, doch, auch, habe, haben, könnte, würde. Also removed "fur", an accent-stripped copy of "für" |
| Markers | Switching and direction words missing | GPT | Adopted 7 within the 40 cap: anmachen, ausmachen, anschalten, abschalten, einblenden, höher, niedriger; removed keinem, keiner, keines, niemals, verbergen, zeigen, nein (none is in the stop list) |
| Markers | nur, alle, oben, unten, links, rechts | GPT | Rejected: not in the stop list, so never dropped (the 40-word cap was withdrawn in round 3) |
| Markers | Remove "wieder" | Gemini | Rejected: "again" is an intended marker kind |
| dictionary.tab.vocabularyPacks phrases | Medical and brand-name packs not established | GPT | Rejected: `Sources/EnviousWispr/Resources/Packs/` ships brands, legal, medical, names and tech |
| Interface titles "Eingang 1, Input 2", "Download herunterladen" | Mixed or doubled German | GPT | Rejected: shorthand in the prompt's place list; the String Catalog has "Eingang %lld" and "Laden" |

## Round 2

Prompt: `round2-prompt.md` (the adopted and rejected list, and the final stop list and markers). Both GPT and Gemini returned no changes.

## Round 3 (markers, after the chunk 4 review)

Prompt: `round3-prompt.md`. The markers had to include every required intent and negation form, with no length limit; a focused isolated Codex review produced 129 German markers (`../lists/markers-r3-0.txt`). Cost about $0.08.

| Finding | Raised by | Disposition |
|---|---|---|
| "entstummen", "entstumme", "entstumm" are not real German words | GPT, Gemini | Adopted: removed |
| "ein" is a switching word ("ein oder aus") | GPT | Adopted: added (it is not in the stop list) |
| "entmuten", "entmute" are the common words for unmute; "wechsel" is a common imperative | Gemini | Adopted: added |

Neither provider found a required form missing. Final German markers: 130.
