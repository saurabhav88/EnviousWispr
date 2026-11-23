Wording review (one language only), EnviousWispr Settings search vocabulary. Repo (read-only): /Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-4501-search-eg1.
The change adds search terms for ONE settings place, `aiPolishProvider.egOne` (the EG-1 choice in AI Polish, which has three size cards: EG-1 (Full, "Best quality"), EG-1 Mini ("Fast all-rounder"), EG-1 Micro ("Smallest and fastest")), so people searching for the model size find it. Language under review: German (de).
Terms added (the existing words and phrases of this block stay as they are):
- words: ["Modellgröße", "EG-1 Größe"]
- phrases: ["EG-1 Micro, am kleinsten und schnellsten", "EG-1 Mini, schneller Allrounder"]
Card taglines in German (from the app's own reviewed catalog, Sources/EnviousWispr/Resources/Localizable.xcstrings, keys "Smallest and fastest", "Fast all-rounder", "Best quality"): Am kleinsten und schnellsten / Schneller Allrounder / Beste Qualität
Review, answering ONLY for German:
1. ACCURACY against the real control: read Sources/EnviousWisprAppKit/Views/Settings/EGOneSizeCards.swift (titles, taglines, summaries) and the de translations in the xcstrings for those keys. Is every added term true of the size cards?
2. NATURALNESS: would a native German speaker type or say each term when looking for the model size? Mark each term KEEP / CHANGE (give the replacement) / DROP.
3. COLLISIONS: false friends or words that mean something else in German (for example "micro" meaning microphone) that make a term misleading.
Output max 220 words: a table term | verdict | reason, then "FINAL LIST" (the exact words and phrases to ship, if different), then "VERDICT: APPROVE or REVISE". Write NOT VERIFIED where you cannot check. Stop after VERDICT.
