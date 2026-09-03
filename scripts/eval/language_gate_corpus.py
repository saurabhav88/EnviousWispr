#!/usr/bin/env python3
"""Language-gate benchmark corpus (#2614): real engine output for sentences whose
words COLLIDE with the English cleanup rules.

The cleanup chain (filler removal, inverse text normalization) runs English rules
on every dictation whose language it does not know, which on the default engine
under Automatic is every dictation (#2614). This corpus proves the damage on REAL
engine output rather than on hand-typed text: each sentence is spoken by an Azure
neural voice in its own language, transcribed by BOTH shipped engines (Parakeet
v3 via `parakeet_runner`, WhisperKit large-v3-turbo via
`scripts/multilingual-eval/runner`), and the transcripts are what the benchmark
test feeds to the app's own chain.

Every case carries its oracle, written BEFORE any run and independent of the
chain: `must_keep` names the words that are lexical in the sentence's language
and must survive cleanup verbatim; `must_convert` names the written form an
English control must reach; `must_drop` names the English fillers a control must
lose. A case is STAGED only when the engine actually emitted the oracle word, so
a misrecognition is reported as unreachable rather than as a pass or a fail.

Authoring note, honest limit: sentences are LLM-authored and not native-reviewed.
They exist to put a specific colliding word in front of a real recogniser; they
are not a native-idiom corpus (same limit as `stress_lang_packs.py`).

Reuse, stated: every stage reuses what is already in the run directory (a WAV
over 1,000 bytes, an engine output file that exists). Change a sentence, a voice,
or an engine and you must delete the affected outputs yourself; the fixture
stage refuses to write when either engine lacks a row for any case, so a
killed or partial engine run cannot become a fixture, but a STALE complete run
can. The `_meta` header records the repo revision and the run name.

Usage (three stages, each resumable):
  ~/.claude/bin/get-key launch azure-speech-key AZURE_SPEECH_KEY -- \\
  ~/.claude/bin/get-key launch azure-speech-region AZURE_SPEECH_REGION -- \\
    python3 scripts/eval/language_gate_corpus.py --run <run-dir> --synth
  python3 scripts/eval/language_gate_corpus.py --run <run-dir> --transcribe
  python3 scripts/eval/language_gate_corpus.py --run <run-dir> --fixture \\
    Tests/EnviousWisprTests/Resources/LanguageGate/transcripts.jsonl
"""

from __future__ import annotations

import argparse
import html
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PARAKEET_RUNNER = ROOT / "scripts/eval/parakeet_runner/.build/release/ParakeetRunner"
WHISPERKIT_RUNNER = ROOT / "scripts/multilingual-eval/runner/.build/release/MultilingualEvalRunner"
# Default WhisperKit model location on the dev machine; override with --whisperkit-model-folder.
WHISPERKIT_MODEL_FOLDER = (
    Path.home()
    / "Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo_632MB"
)

# Two voices per locale so no bucket is one voice's articulation.
VOICES = {
    "nl-NL": ["nl-NL-FennaNeural", "nl-NL-MaartenNeural"],
    "de-DE": ["de-DE-KatjaNeural", "de-DE-ConradNeural"],
    "da-DK": ["da-DK-ChristelNeural", "da-DK-JeppeNeural"],
    "nb-NO": ["nb-NO-PernilleNeural", "nb-NO-FinnNeural"],
    "sv-SE": ["sv-SE-SofieNeural", "sv-SE-MattiasNeural"],
    "pt-PT": ["pt-PT-RaquelNeural", "pt-PT-DuarteNeural"],
    "pt-BR": ["pt-BR-FranciscaNeural", "pt-BR-AntonioNeural"],
    "pl-PL": ["pl-PL-AgnieszkaNeural", "pl-PL-MarekNeural"],
    "cs-CZ": ["cs-CZ-VlastaNeural", "cs-CZ-AntoninNeural"],
    "sk-SK": ["sk-SK-ViktoriaNeural", "sk-SK-LukasNeural"],
    "lt-LT": ["lt-LT-OnaNeural", "lt-LT-LeonasNeural"],
    "lv-LV": ["lv-LV-EveritaNeural", "lv-LV-NilsNeural"],
    "hr-HR": ["hr-HR-GabrijelaNeural", "hr-HR-SreckoNeural"],
    "sl-SI": ["sl-SI-PetraNeural", "sl-SI-RokNeural"],
    "fr-FR": ["fr-FR-DeniseNeural", "fr-FR-HenriNeural"],
    "it-IT": ["it-IT-ElsaNeural", "it-IT-DiegoNeural"],
    "es-ES": ["es-ES-ElviraNeural", "es-ES-AlvaroNeural"],
    "hu-HU": ["hu-HU-NoemiNeural", "hu-HU-TamasNeural"],
    "fi-FI": ["fi-FI-SelmaNeural", "fi-FI-HarriNeural"],
    "ro-RO": ["ro-RO-AlinaNeural", "ro-RO-EmilNeural"],
    "et-EE": ["et-EE-AnuNeural", "et-EE-KertNeural"],
    "mt-MT": ["mt-MT-GraceNeural", "mt-MT-JosephNeural"],
    "el-GR": ["el-GR-AthinaNeural", "el-GR-NestorasNeural"],
    "bg-BG": ["bg-BG-KalinaNeural", "bg-BG-BorislavNeural"],
    "ru-RU": ["ru-RU-SvetlanaNeural", "ru-RU-DmitryNeural"],
    "uk-UA": ["uk-UA-PolinaNeural", "uk-UA-OstapNeural"],
    "en-US": ["en-US-AvaNeural", "en-US-AndrewNeural"],
}

# Buckets:
#   filler_collision  a word the filler regex strips (er, um, ah, mm, hmm, uh) that is
#                     lexical in this language
#   itn_collision     a word the English ITN rewrites (ten, am, at, dot, august, ...)
#                     that is lexical in this language
#   numbers_native    numbers, money, dates spoken in the language — observe only:
#                     records the engine's own rendering and any English-rule touch
#   foreign_clean     an ordinary sentence with no colliding word — must be unchanged
#   english_control   English with numbers/dates/fillers — must convert / must drop
#   english_short     short English where a detector may abstain — today's behaviour
#   mixed             two languages in one dictation
#
# Row shape: (id, locale, bucket, text, must_keep, must_convert, must_drop)
# must_keep / must_convert / must_drop are lists; empty means "no oracle" (observe).
C: list[tuple[str, str, str, str, list[str], list[str], list[str]]] = []


def add(locale: str, bucket: str, text: str, keep=(), convert=(), drop=()):
    slug = locale.lower().replace("-", "_")
    n = sum(1 for c in C if c[1] == locale) + 1
    C.append((f"{slug}_{bucket.split('_')[0]}_{n:02d}", locale, bucket, text,
              list(keep), list(convert), list(drop)))


# ---- Dutch: "ten" (at least / firstly), "er" (there) ------------------------------
add("nl-NL", "itn_collision", "Dit is ten minste duidelijk.", keep=["ten"])
add("nl-NL", "itn_collision", "We hebben ten minste drie opties besproken.", keep=["ten"])
add("nl-NL", "itn_collision", "Ten eerste moeten we de planning bekijken, ten tweede het budget.", keep=["Ten", "ten"])
add("nl-NL", "itn_collision", "Ten opzichte van vorig jaar is de omzet gestegen.", keep=["Ten"])
add("nl-NL", "filler_collision", "Er is nog koffie in de keuken als je wilt.", keep=["Er"])
add("nl-NL", "filler_collision", "Ik denk dat er morgen een vergadering is om tien uur.", keep=["er"])
add("nl-NL", "filler_collision", "Er zijn er nog twee over, dus we hebben er genoeg.", keep=["Er", "er"])
add("nl-NL", "filler_collision", "Kun je er even naar kijken en er later op terugkomen?", keep=["er"])
add("nl-NL", "numbers_native", "Het pakket kost drieëntwintig euro vijftig en komt op vijf maart aan.")
add("nl-NL", "foreign_clean", "Kun je me het verslag sturen voor het einde van de dag?")

# ---- German: "er" (he), "um" (at / around), "am" (on the), "August" ---------------
add("de-DE", "filler_collision", "Er kommt um drei Uhr nach Hause.", keep=["Er", "um"])
add("de-DE", "filler_collision", "Ich glaube, er hat um die zwanzig Bewerbungen geschickt.", keep=["er", "um"])
add("de-DE", "itn_collision", "Wir treffen uns um acht am Bahnhof.", keep=["um", "am"])
add("de-DE", "itn_collision", "Er war am Montag um neun im Büro.", keep=["Er", "am", "um"])
add("de-DE", "filler_collision", "Um ehrlich zu sein, er hat recht.", keep=["Um", "er"])
add("de-DE", "itn_collision", "Am fünften August fahren wir in den Urlaub.", keep=["Am", "August"])
add("de-DE", "filler_collision", "Kannst du ihn um eine Rückmeldung bitten? Er antwortet meistens schnell.", keep=["um", "Er"])
add("de-DE", "itn_collision", "Der Termin ist um halb zehn am Dienstag.", keep=["um", "am"])
add("de-DE", "numbers_native", "Die Rechnung beträgt zweihundertfünfzig Euro und ist am fünfzehnten fällig.")
add("de-DE", "foreign_clean", "Bitte schick mir die Unterlagen bis Ende der Woche.")

# ---- Danish: "er" (is), "at" (to / that) ------------------------------------------
add("da-DK", "filler_collision", "Det er godt at se dig igen.", keep=["er", "at"])
add("da-DK", "filler_collision", "Han er ikke hjemme, men hun er på kontoret.", keep=["er"])
add("da-DK", "filler_collision", "Vi skal huske at sende rapporten, den er vigtig.", keep=["at", "er"])
add("da-DK", "filler_collision", "Mødet er klokken ti, og det er i det store lokale.", keep=["er"])
add("da-DK", "filler_collision", "Er du klar til at tage af sted?", keep=["Er", "at"])
add("da-DK", "filler_collision", "Det er svært at sige, om det er en god idé.", keep=["er", "at"])
add("da-DK", "numbers_native", "Prisen er to hundrede og femogtyve kroner.")
add("da-DK", "foreign_clean", "Kan du sende mig referatet inden i morgen?")

# ---- Norwegian: "er" (is) ---------------------------------------------------------
add("nb-NO", "filler_collision", "Det er bra at du kom.", keep=["er"])
add("nb-NO", "filler_collision", "Han er på jobb, og hun er hjemme.", keep=["er"])
add("nb-NO", "filler_collision", "Møtet er klokken ti i morgen.", keep=["er"])
add("nb-NO", "filler_collision", "Er det noe jeg kan hjelpe med?", keep=["Er"])
add("nb-NO", "filler_collision", "Det er viktig at vi sender rapporten i dag.", keep=["er"])
add("nb-NO", "foreign_clean", "Kan du sende meg notatene fra møtet?")

# ---- Swedish: "er" (your, formal) -------------------------------------------------
add("sv-SE", "filler_collision", "Jag skickar rapporten till er imorgon.", keep=["er"])
add("sv-SE", "filler_collision", "Tack för att ni kom, det här är er kopia.", keep=["er"])
add("sv-SE", "numbers_native", "Mötet börjar klockan halv tio och kostar tvåhundra kronor.")
add("sv-SE", "foreign_clean", "Kan du skicka mig anteckningarna från mötet?")

# ---- Portuguese: "um" (a / one) — both European and Brazilian voices --------------
add("pt-PT", "filler_collision", "Quero um café e um pão, por favor.", keep=["um"])
add("pt-PT", "filler_collision", "Ele tem um irmão e uma irmã.", keep=["um"])
add("pt-PT", "filler_collision", "Foi um dia muito longo, mas um bom dia.", keep=["um"])
add("pt-PT", "numbers_native", "A reunião é às três e meia e custa vinte e cinco euros.")
add("pt-PT", "foreign_clean", "Podes enviar-me o documento até amanhã?")
add("pt-BR", "filler_collision", "Preciso de um minuto para pensar.", keep=["um"])
add("pt-BR", "filler_collision", "Tenho um amigo que mora em São Paulo.", keep=["um"])
add("pt-BR", "filler_collision", "Há um problema com o relatório de ontem.", keep=["um"])
add("pt-BR", "foreign_clean", "Você pode me mandar o documento até amanhã?")

# ---- Polish: "ten" (this) ---------------------------------------------------------
add("pl-PL", "itn_collision", "Ten dom jest bardzo stary.", keep=["Ten"])
add("pl-PL", "itn_collision", "Czy widziałeś ten film w zeszłym tygodniu?", keep=["ten"])
add("pl-PL", "itn_collision", "Ten projekt musimy skończyć do piątku.", keep=["Ten"])
add("pl-PL", "itn_collision", "Nie ten, tylko tamten stół.", keep=["ten"])
add("pl-PL", "itn_collision", "Ten człowiek pomógł mi wczoraj.", keep=["Ten"])
add("pl-PL", "itn_collision", "Podoba mi się ten pomysł, ale ten drugi też jest dobry.", keep=["ten"])
add("pl-PL", "numbers_native", "Spotkanie jest o dziesiątej trzydzieści, a bilet kosztuje sto pięćdziesiąt złotych.")
add("pl-PL", "foreign_clean", "Możesz mi wysłać notatki ze spotkania?")

# ---- Czech / Slovak: "ten" (that) -------------------------------------------------
add("cs-CZ", "itn_collision", "Ten muž stojí u dveří.", keep=["Ten"])
add("cs-CZ", "itn_collision", "Chci ten modrý svetr, ne ten červený.", keep=["ten"])
add("cs-CZ", "itn_collision", "Ten dokument musíme poslat dnes.", keep=["Ten"])
add("cs-CZ", "itn_collision", "Viděl jsi ten nový film?", keep=["ten"])
add("cs-CZ", "itn_collision", "Ten návrh se mi líbí.", keep=["Ten"])
add("cs-CZ", "numbers_native", "Schůzka je v deset třicet a stojí to dvě stě korun.")
add("cs-CZ", "foreign_clean", "Můžeš mi poslat poznámky ze schůzky?")
add("sk-SK", "itn_collision", "Ten muž stojí pri dverách.", keep=["Ten"])
add("sk-SK", "itn_collision", "Chcem ten modrý sveter.", keep=["ten"])
add("sk-SK", "itn_collision", "Ten dokument musíme poslať dnes.", keep=["Ten"])
add("sk-SK", "foreign_clean", "Môžeš mi poslať poznámky zo stretnutia?")

# ---- Lithuanian: "ten" (there); Latvian: "dot" (to give) --------------------------
add("lt-LT", "itn_collision", "Jis gyvena ten, prie upės.", keep=["ten"])
add("lt-LT", "itn_collision", "Ten yra daug žmonių šiandien.", keep=["Ten"])
add("lt-LT", "itn_collision", "Palik knygą ten, ant stalo.", keep=["ten"])
add("lt-LT", "foreign_clean", "Ar gali atsiųsti man susitikimo užrašus?")
add("lv-LV", "itn_collision", "Es gribu dot viņam šo grāmatu.", keep=["dot"])
add("lv-LV", "itn_collision", "Vai vari man dot padomu?", keep=["dot"])
add("lv-LV", "itn_collision", "Mums vajag dot atbildi līdz rītdienai.", keep=["dot"])
add("lv-LV", "foreign_clean", "Vai vari atsūtīt man sanāksmes piezīmes?")

# ---- Croatian / Slovenian: "um" (mind) --------------------------------------------
add("hr-HR", "filler_collision", "Njegov um je bistar i brz.", keep=["um"])
add("hr-HR", "filler_collision", "Zdrav um u zdravom tijelu.", keep=["um"])
add("hr-HR", "foreign_clean", "Možeš li mi poslati bilješke sa sastanka?")
add("sl-SI", "filler_collision", "Njegov um je zelo bister.", keep=["um"])
add("sl-SI", "filler_collision", "Zdrav um v zdravem telesu.", keep=["um"])
add("sl-SI", "foreign_clean", "Mi lahko pošlješ zapiske s sestanka?")

# ---- French / Italian / Spanish: no filler collision; numbers + clean --------------
add("fr-FR", "itn_collision", "Il a six ans et il habite à cent mètres d'ici.", keep=["six", "cent"])
add("fr-FR", "itn_collision", "C'est un point de vue intéressant, en second lieu.", keep=["point", "second"])
add("fr-FR", "numbers_native", "La réunion est à quatorze heures trente et le billet coûte vingt-cinq euros.")
add("fr-FR", "foreign_clean", "Peux-tu m'envoyer le compte rendu avant la fin de la journée ?")
add("it-IT", "numbers_native", "La riunione è alle dieci e mezza e costa venticinque euro.")
add("it-IT", "foreign_clean", "Puoi mandarmi gli appunti della riunione?")
add("it-IT", "foreign_clean", "Ci vediamo domani mattina in ufficio.")
add("es-ES", "numbers_native", "La reunión es a las diez y media y cuesta veinticinco euros.")
add("es-ES", "foreign_clean", "¿Puedes enviarme las notas de la reunión?")
add("es-ES", "foreign_clean", "Nos vemos mañana por la mañana en la oficina.")

# ---- Hungarian / Finnish / Romanian / Estonian / Maltese: controls ----------------
add("hu-HU", "numbers_native", "A találkozó fél tízkor kezdődik és kétezer forintba kerül.")
add("hu-HU", "foreign_clean", "El tudod küldeni a jegyzeteket a megbeszélésről?")
add("fi-FI", "numbers_native", "Kokous alkaa puoli kymmeneltä ja maksaa kaksikymmentäviisi euroa.")
add("fi-FI", "foreign_clean", "Voitko lähettää minulle kokouksen muistiinpanot?")
add("ro-RO", "numbers_native", "Ședința este la zece și jumătate și costă douăzeci și cinci de lei.")
add("ro-RO", "foreign_clean", "Poți să-mi trimiți notițele de la ședință?")
add("et-EE", "foreign_clean", "Kas saad mulle koosoleku märkmed saata?")
add("mt-MT", "foreign_clean", "Tista' tibgħatli n-noti tal-laqgħa?")

# ---- Non-Latin scripts: controls (English regexes cannot match Cyrillic/Greek) ----
add("el-GR", "foreign_clean", "Μπορείς να μου στείλεις τις σημειώσεις της συνάντησης;")
add("el-GR", "numbers_native", "Η συνάντηση είναι στις δέκα και μισή και κοστίζει είκοσι πέντε ευρώ.")
add("bg-BG", "foreign_clean", "Можеш ли да ми изпратиш бележките от срещата?")
add("ru-RU", "foreign_clean", "Можешь прислать мне заметки со встречи?")
add("ru-RU", "numbers_native", "Встреча в половине одиннадцатого, билет стоит двести рублей.")
add("uk-UA", "foreign_clean", "Можеш надіслати мені нотатки зі зустрічі?")

# ---- English controls: the rules MUST keep firing ---------------------------------
add("en-US", "english_control", "Call me at two zero three nine five four eight eight seven nine.", convert=["203-954-8879"])
add("en-US", "english_control", "It cost eighty million dollars last year.", convert=["$80 million"])
add("en-US", "english_control", "The meeting is on March twelfth two thousand seven at three thirty PM.", convert=["March 12, 2007"])
add("en-US", "english_control", "Send it to john dot smith at example dot com.")  # both engines already emit dots; observe
add("en-US", "english_control", "Twenty one percent of users upgraded.", convert=["21%"])
add("en-US", "english_control", "Um, I think we should, uh, wait until seventy eight thousand units ship.", convert=["78,000"], drop=["um", "uh"])
add("en-US", "english_control", "Er, let me check the calendar for the fourteenth.", convert=["14th"], drop=["er"])
add("en-US", "english_control", "Our revenue grew from two million to three point five million.", convert=["3.5 million"])
add("en-US", "english_control", "The invoice number is four seven one two.")  # a bare 4-digit read is not an ITN rule; observe
add("en-US", "english_control", "The gap is about five millimeters wide.")
add("en-US", "english_control", "We need forty two chairs and one hundred and twenty plates.", convert=["42", "120"])
add("en-US", "english_short", "Yes.")
add("en-US", "english_short", "On my way.")
add("en-US", "english_short", "Um, yeah, okay.", drop=["um"])
add("en-US", "english_short", "Twenty twenty six.", convert=["2026"])

# ---- Mixed-language dictations ----------------------------------------------------
add("en-US", "mixed", "I sent the Krankenversicherung form to the Finanzamt on the fifth of May.", convert=["May 5"])
add("de-DE", "mixed", "Wir müssen das Deployment um drei am Nachmittag mergen.", keep=["um", "am"])
add("nl-NL", "mixed", "Er is een bug in de login flow, ten minste in de staging build.", keep=["Er", "ten"])

# ---- Wave 2 (2026-09-03): more sentences for the collisions wave 1 proved on real engine output ----
add("de-DE", "itn_collision", "Wir sehen uns um neun am Eingang.", keep=["um", "am"])
add("de-DE", "filler_collision", "Er hat gesagt, dass er um zehn am Flughafen ist.", keep=["Er", "er", "um", "am"])
add("de-DE", "itn_collision", "Ruf mich bitte um sieben am Abend an.", keep=["um", "am"])
add("de-DE", "filler_collision", "Er fragt, ob er um Hilfe bitten darf.", keep=["Er", "er", "um"])
add("de-DE", "filler_collision", "Am Wochenende ist er um die zwanzig Kilometer gelaufen.", keep=["Am", "er", "um"])
add("de-DE", "itn_collision", "Wir treffen uns um vier am Marktplatz, er kommt später.", keep=["um", "am", "er"])
add("de-DE", "filler_collision", "Er arbeitet um diese Zeit meistens am Laptop.", keep=["Er", "um", "am"])
add("de-DE", "itn_collision", "Kannst du um sechs am Bahnhof sein? Er wartet dort.", keep=["um", "am", "Er"])
add("nl-NL", "itn_collision", "Ten slotte wil ik iedereen bedanken.", keep=["Ten"])
add("nl-NL", "filler_collision", "Er is ten minste één optie die werkt.", keep=["Er", "ten"])
add("nl-NL", "filler_collision", "Ik heb er ten minste drie gezien.", keep=["er", "ten"])
add("nl-NL", "filler_collision", "Er staat een pakket voor de deur.", keep=["Er"])
add("nl-NL", "filler_collision", "Hoe laat is er morgen een afspraak?", keep=["er"])
add("nl-NL", "filler_collision", "Er wordt gezegd dat er regen komt.", keep=["Er", "er"])
add("nl-NL", "itn_collision", "Ten eerste is het te duur, ten tweede is het te laat.", keep=["Ten", "ten"])
add("nl-NL", "filler_collision", "Wat is er aan de hand?", keep=["er"])
add("da-DK", "filler_collision", "Hvad er der sket?", keep=["er"])
add("da-DK", "filler_collision", "Det er en god dag at gå en tur.", keep=["er", "at"])
add("da-DK", "filler_collision", "Hun er læge, og han er lærer.", keep=["er"])
add("da-DK", "filler_collision", "Jeg tror, det er tid til at gå hjem.", keep=["er", "at"])
add("da-DK", "filler_collision", "Er der noget, jeg kan hjælpe med?", keep=["Er"])
add("da-DK", "filler_collision", "Det er ikke nemt at forklare.", keep=["er", "at"])
add("sv-SE", "filler_collision", "Vi hörde av er i går, tack för brevet.", keep=["er"])
add("sv-SE", "filler_collision", "Har ni glömt er kod igen?", keep=["er"])
add("sv-SE", "filler_collision", "Vi behöver er hjälp med projektet.", keep=["er"])
add("sv-SE", "filler_collision", "Det är er tur att välja.", keep=["er"])
add("pt-PT", "filler_collision", "Vou tomar um banho e depois um café.", keep=["um"])
add("pt-PT", "filler_collision", "Ele comprou um carro novo.", keep=["um"])
add("pt-PT", "filler_collision", "Há um erro no relatório.", keep=["um"])
add("pt-PT", "filler_collision", "Isso é um bom sinal.", keep=["um"])
add("pt-PT", "filler_collision", "Preciso de um médico.", keep=["um"])
add("pt-BR", "filler_collision", "Foi um prazer conhecer você.", keep=["um"])
add("pt-BR", "filler_collision", "Quero um copo de água.", keep=["um"])
add("pt-BR", "filler_collision", "Tem um cachorro no jardim.", keep=["um"])
add("pl-PL", "itn_collision", "Czy ten pociąg jedzie do Krakowa?", keep=["ten"])
add("pl-PL", "itn_collision", "Ten sklep jest zamknięty w niedzielę.", keep=["Ten"])
add("pl-PL", "itn_collision", "Lubię ten kolor.", keep=["ten"])
add("pl-PL", "itn_collision", "Ten raport trzeba wysłać dzisiaj.", keep=["Ten"])
add("pl-PL", "itn_collision", "Kto napisał ten list?", keep=["ten"])
add("cs-CZ", "itn_collision", "Ten vlak jede do Prahy.", keep=["Ten"])
add("cs-CZ", "itn_collision", "Znáš ten obchod na rohu?", keep=["ten"])
add("cs-CZ", "itn_collision", "Ten problém musíme vyřešit dnes.", keep=["Ten"])
add("cs-CZ", "itn_collision", "Kdo napsal ten dopis?", keep=["ten"])
add("sk-SK", "itn_collision", "Ten vlak ide do Bratislavy.", keep=["Ten"])
add("sk-SK", "itn_collision", "Poznáš ten obchod na rohu?", keep=["ten"])
add("sk-SK", "itn_collision", "Kto napísal ten list?", keep=["ten"])
add("lt-LT", "itn_collision", "Ar tu buvai ten vakar?", keep=["ten"])
add("lt-LT", "itn_collision", "Ten labai gražu vasarą.", keep=["Ten"])
add("lt-LT", "itn_collision", "Mes nuėjome ten pėsčiomis.", keep=["ten"])
add("nb-NO", "filler_collision", "Hva er det som skjer?", keep=["er"])
add("nb-NO", "filler_collision", "Det er ikke lett å forklare.", keep=["er"])
add("nb-NO", "filler_collision", "Hun er lege, og han er lærer.", keep=["er"])
add("sl-SI", "filler_collision", "Ima bister um.", keep=["um"])
add("sl-SI", "filler_collision", "Um in telo sta povezana.", keep=["Um"])
add("hr-HR", "filler_collision", "Ima bistar um.", keep=["um"])
add("hr-HR", "filler_collision", "Um i tijelo su povezani.", keep=["Um"])


def cases() -> list[dict]:
    rows = []
    for i, (cid, locale, bucket, text, keep, convert, drop) in enumerate(C):
        voices = VOICES[locale]
        rows.append({
            "id": cid, "locale": locale, "lang": locale.split("-")[0], "bucket": bucket,
            "text": text, "voice": voices[i % len(voices)],
            "must_keep": keep, "must_convert": convert, "must_drop": drop,
        })
    ids = [r["id"] for r in rows]
    assert len(ids) == len(set(ids)), "duplicate case ids"
    return rows


# ---- Stage 1: Azure TTS ------------------------------------------------------------

def ssml(text: str, voice: str, xml_lang: str) -> str:
    return (f'<speak version="1.0" xml:lang="{xml_lang}">'
            f'<voice name="{voice}">{html.escape(text)}</voice></speak>')


def synth(run: Path) -> None:
    key = os.environ.get("AZURE_SPEECH_KEY", "").strip()
    region = os.environ.get("AZURE_SPEECH_REGION", "eastus2").strip() or "eastus2"
    if not key:
        sys.exit("AZURE_SPEECH_KEY not set — run via `get-key launch`")
    wav_dir = run / "wav"
    wav_dir.mkdir(parents=True, exist_ok=True)
    url = f"https://{region}.tts.speech.microsoft.com/cognitiveservices/v1"
    rows = cases()
    chars = sum(len(r["text"]) for r in rows)
    print(f"{len(rows)} cases, {chars:,} chars (~${chars / 1e6 * 15:.2f} on Azure credits)", file=sys.stderr)
    done = skipped = 0
    for r in rows:
        out = wav_dir / f"{r['id']}.wav"
        if out.exists() and out.stat().st_size > 1000:
            skipped += 1
            continue
        body = ssml(r["text"], r["voice"], r["locale"]).encode("utf-8")
        req = urllib.request.Request(url, data=body, headers={
            "Ocp-Apim-Subscription-Key": key,
            "Content-Type": "application/ssml+xml",
            "X-Microsoft-OutputFormat": "riff-16khz-16bit-mono-pcm",
            "User-Agent": "EnviousWispr-language-gate-benchmark",
        })
        for attempt in range(5):
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    out.write_bytes(resp.read())
                break
            except urllib.error.HTTPError as e:
                if e.code in (429, 500, 502, 503, 504) and attempt < 4:
                    time.sleep(2 ** attempt)
                    continue
                sys.exit(f"TTS failed for {r['id']}: HTTP {e.code} {e.read()[:200]!r}")
        done += 1
        time.sleep(0.15)  # Azure asks for a gentle ramp rather than a spike
    print(f"synth: {done} new, {skipped} already present", file=sys.stderr)
    (run / "cases.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))


# ---- Stage 2: both engines ---------------------------------------------------------

def transcribe(run: Path, whisperkit_model_folder: Path = WHISPERKIT_MODEL_FOLDER) -> None:
    rows = cases()
    wav_dir = run / "wav"
    missing = [r["id"] for r in rows if not (wav_dir / f"{r['id']}.wav").exists()]
    if missing:
        sys.exit(f"{len(missing)} WAVs missing (run --synth first): {missing[:5]}")
    for tool in (PARAKEET_RUNNER, WHISPERKIT_RUNNER):
        if not tool.exists():
            sys.exit(f"missing runner binary: {tool}\nBuild it with `swift build -c release` in its package.")
    expected = {r["id"] for r in rows}

    def _complete(path: Path) -> bool:
        """An existing engine output is reused only when it is complete; a partial
        one (a killed runner) is an error here, not at the fixture stage."""
        if not path.exists():
            return False
        _jsonl(path, expected)  # raises with the delete-and-rerun message
        return True

    if not whisperkit_model_folder.exists():
        sys.exit(f"WhisperKit model folder missing: {whisperkit_model_folder}")

    pk_manifest = run / "parakeet-manifest.jsonl"
    pk_manifest.write_text("".join(
        json.dumps({"id": r["id"], "wav": str(wav_dir / f"{r['id']}.wav")}) + "\n" for r in rows))
    pk_out = run / "parakeet.jsonl"
    if not _complete(pk_out):
        print("Parakeet v3 …", file=sys.stderr)
        subprocess.run([str(PARAKEET_RUNNER), str(pk_manifest), str(pk_out)], check=True)

    wk_manifest = run / "whisperkit-manifest.jsonl"
    wk_manifest.write_text("".join(json.dumps({
        "id": r["id"], "lang": r["lang"], "text": r["text"],
        "audio_path": str(wav_dir / f"{r['id']}.wav"),
    }, ensure_ascii=False) + "\n" for r in rows))
    wk_out = run / "whisperkit.jsonl"
    if not _complete(wk_out):
        print("WhisperKit large-v3-turbo (autodetect) …", file=sys.stderr)
        subprocess.run([
            str(WHISPERKIT_RUNNER), "--manifest", str(wk_manifest), "--mode", "autodetect",
            "--output", str(wk_out), "--model-folder", str(whisperkit_model_folder),
        ], check=True)
    print("transcribe: done", file=sys.stderr)


# ---- Stage 3: the fixture the Swift benchmark reads --------------------------------

def _jsonl(path: Path, expected_ids: set[str]) -> dict[str, dict]:
    """Engine output keyed by case id. Fails closed: a duplicate, unknown, or
    missing id is an error, never a silent last-row-wins or a silent omission."""
    out = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        d = json.loads(line)
        cid = d.get("id")
        if cid not in expected_ids:
            raise ValueError(f"{path.name}: unexpected id {cid!r}")
        if cid in out:
            raise ValueError(f"{path.name}: duplicate id {cid!r}")
        out[cid] = d
    missing = sorted(expected_ids - out.keys())
    if missing:
        raise ValueError(f"{path.name}: {len(missing)} case(s) have no row, e.g. {missing[:5]}; "
                         "delete the file and rerun --transcribe")
    return out


def fixture(run: Path, dest: Path) -> None:
    rows = cases()
    expected = {r["id"] for r in rows}
    pk = _jsonl(run / "parakeet.jsonl", expected)
    wk = _jsonl(run / "whisperkit.jsonl", expected)
    rev = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"],
                         capture_output=True, text=True).stdout.strip()
    lines = []
    for r in rows:
        base = {k: r[k] for k in ("id", "locale", "lang", "bucket", "text", "voice",
                                  "must_keep", "must_convert", "must_drop")}
        p = pk[r["id"]]
        if "text" not in p:
            raise ValueError(f"parakeet.jsonl: {r['id']} has no 'text'")
        lines.append({**base, "engine": "parakeet", "raw": p["text"], "engine_language": None})
        w = wk[r["id"]]
        if "transcript" not in w:
            raise ValueError(f"whisperkit.jsonl: {r['id']} has no 'transcript'")
        lines.append({**base, "engine": "whisperkit", "raw": w["transcript"],
                      "engine_language": w.get("detected_lang"),
                      "engine_language_prob": w.get("detected_prob")})
    assert len(lines) == 2 * len(rows), (len(lines), len(rows))
    dest.parent.mkdir(parents=True, exist_ok=True)
    header = {"_meta": {"generated_at_repo_rev": rev, "run": run.name, "rows": len(lines),
                        "tts": "Azure Neural TTS, riff-16khz-16bit-mono-pcm",
                        "parakeet": "FluidAudio parakeet-tdt-0.6b-v3 via scripts/eval/parakeet_runner",
                        "whisperkit": "openai_whisper-large-v3-v20240930_turbo autodetect via scripts/multilingual-eval/runner"}}
    dest.write_text(json.dumps(header, ensure_ascii=False) + "\n"
                    + "".join(json.dumps(l, ensure_ascii=False) + "\n" for l in lines))
    print(f"fixture: {len(lines)} transcript rows -> {dest}", file=sys.stderr)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True, help="run directory, e.g. scripts/eval/runs/language-gate-2026-09-03")
    ap.add_argument("--synth", action="store_true")
    ap.add_argument("--transcribe", action="store_true")
    ap.add_argument("--fixture", metavar="DEST", help="write the Swift benchmark fixture here")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--whisperkit-model-folder", type=Path, default=WHISPERKIT_MODEL_FOLDER,
                    help=f"WhisperKit CoreML model folder (default: {WHISPERKIT_MODEL_FOLDER})")
    a = ap.parse_args()
    run = Path(a.run)
    if a.list:
        for r in cases():
            print(json.dumps(r, ensure_ascii=False))
        return
    if a.synth:
        synth(run)
    if a.transcribe:
        transcribe(run, a.whisperkit_model_folder)
    if a.fixture:
        fixture(run, Path(a.fixture))


if __name__ == "__main__":
    main()
