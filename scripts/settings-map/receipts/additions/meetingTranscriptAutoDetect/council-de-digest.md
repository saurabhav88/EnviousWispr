# German council digest: #4320 (meetingLiveWordsLanguage, meetingTranscriptAutoDetect, new Models tab copy)

Raw answers stay in the council's encrypted history (`~/.local/share/council/history.db`), looked up by run id.

## Round 1 (2026-11-01, run-1793575577-c77124af, session `ew-4320-german-2026-11-01`, prompt `council-de-prompt.txt`)
GPT (gpt-6-sol on Azure, $0.0063) and Gemini (gemini-3.8-flash, $0.0128; founder approved the Gemini spend in chat 2026-11-01, issue #4320 comment 6565456792).

| Item | GPT | Gemini | Adopted |
|------|-----|--------|---------|
| 1 "Nicht eingerichtet" | OK | OK | unchanged |
| 2 "Sprachdownload von Apple" | "Download je Sprache von Apple" | OK | GPT's: says each language is its own download |
| 3 "%lld Sprachen" | OK | OK | unchanged |
| 4 "Sprache der Live-Vorschau" | OK | OK | unchanged |
| 5 "…auf die die Live-Vorschau … hört." | "…die die Live-Vorschau … mitschreibt." | "…die die Live-Vorschau … erkennt." | Gemini's: both flag "hören" as unnatural; "mitschreibt" suggests a transcript |
| 6 "VERFÜGBAR FÜR LIVE-VORSCHAU" | "VERFÜGBARE SPRACHEN FÜR DIE LIVE-VORSCHAU" | OK | unchanged: Gemini OK, shorter heading |
| 7 "Verfügbar für %@" | OK | OK | unchanged |
| 8 "Erkennt die Sprache aus dem Gesagten. %@." | OK | OK | unchanged |
| 9 Live Preview language block | shorter terms | keywords incl. "Untertitel" | merged: words Sprache, Live-Vorschau, Live-Text, Meeting; phrases "Sprache der Live-Vorschau ändern", "Sprache für Live-Text im Meeting". Not adopted: "gesprochene Sprache im Meeting einstellen" (fits Transcript language equally), "Untertitel" (the feature is not subtitles) |
| 10 Auto-detect block | shorter terms | keywords | merged: words Transkript, Spracherkennung, automatisch; phrases "Sprache des Transkripts automatisch erkennen", "automatische Spracherkennung im Meeting" |
