You are drafting search phrases for the Settings search box of EnviousWispr, a macOS dictation app (press a key and speak, it types your words into any app). People type everyday searches in English or German to find a place in Settings.

Use ONLY this brief. Do not open, search or read any file, folder, repository or website. Do not run commands.

Two places, both tabs on the Dictionary page (Dictionary: words the app should recognise and spell correctly):

1. id "dictionary.tab.vocabularyPacks"
   English title: "Vocabulary Packs"; line under it: "Ready-made lists".
   German title: "Wortschatzpakete"; line under it: "Fertige Listen".
   What it is: ready-made word lists the user can switch on (for example tech, medical, legal, brand and people's names), so dictation recognises specialist words without adding them one by one.

2. id "dictionary.tab.learnFrom"
   English title: "Learn from..."; line under it: "Learn as you go".
   German title: "Lernen aus..."; line under it: "Nebenbei lernen".
   What it is: lets the app pick up new words on its own: from the corrections you make after dictating (a self-learning dictionary) and from importing the names in your Contacts.

For each place write 2 or 3 phrases in English and 2 or 3 in German: what a person types when looking for this place, in their own words, without the title words where possible. Natural everyday German (du form), not a translation of the English. Do not promise anything the description does not say.

Output: one JSON object and nothing else:
{"dictionary.tab.vocabularyPacks": {"en": [...], "de": [...]}, "dictionary.tab.learnFrom": {"en": [...], "de": [...]}}
Stop after the JSON. Do not summarise.
