Wording review (one language only), EnviousWispr Settings search vocabulary. Repo (read-only): /Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-4501-search-eg1.
The change adds search terms for ONE settings place, `aiPolishProvider.egOne` (the EG-1 choice in AI Polish, which has three size cards: EG-1 (Full, "Best quality"), EG-1 Mini ("Fast all-rounder"), EG-1 Micro ("Smallest and fastest")), so people searching for the model size find it. Language under review: English (en).
Terms added (the existing words and phrases of this block stay as they are):
- words: ["model size", "EG-1 size"]
- phrases: ["EG-1 Micro, smallest and fastest", "EG-1 Mini, fast all-rounder"]
Card taglines in English (from the app's own reviewed catalog, Sources/EnviousWispr/Resources/Localizable.xcstrings, keys "Smallest and fastest", "Fast all-rounder", "Best quality"): Smallest and fastest / Fast all-rounder / Best quality
Review, answering ONLY for English:
1. ACCURACY against the real control: read Sources/EnviousWisprAppKit/Views/Settings/EGOneSizeCards.swift (titles, taglines, summaries) and the en translations in the xcstrings for those keys. Is every added term true of the size cards?
2. NATURALNESS: would a native English speaker type or say each term when looking for the model size? Mark each term KEEP / CHANGE (give the replacement) / DROP.
3. COLLISIONS: false friends or words that mean something else in English (for example "micro" meaning microphone) that make a term misleading.
Output max 220 words: a table term | verdict | reason, then "FINAL LIST" (the exact words and phrases to ship, if different), then "VERDICT: APPROVE or REVISE". Write NOT VERIFIED where you cannot check. Stop after VERDICT.
