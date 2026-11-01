# German council digest: meetingFollowsCallMute (#4248)

Raw answers stay in the council's encrypted history (`~/.local/share/council/history.db`), looked up by run id.

## Round 1 (2026-11-01, run-1793524080-8e3d68a1, prompt `council-de-prompt.txt`)
GPT only (gpt-6-sol on Azure, $0.0044). Gemini was not run: no spend approval yet.
- Title: OK.
- Short line: reworded to "Wenn Zoom, Teams oder Google Meet dich als stummgeschaltet anzeigt, wird deine Stimme in der Meetingaufnahme weggelassen." Adopted, later replaced in round 2 when the English changed.
- Help text: reworded; adopted as the shipped German.
- Search block: shorter words; merged with the per-language Codex review into the round 2 input block.

## Round 2 (2026-11-01, run-1793538525-cd287be7, prompt `council-de-prompt-2.txt`)
GPT (gpt-6-sol on Azure, $0.0057) and Gemini (gemini-3.8-flash, $0.0141; founder approved the Gemini spend in chat 2026-11-01).
The English short line changed to "Follows the mute button in supported Zoom, Teams and Google Meet calls." (chunk 6 review: the old line promised omission without the limits).

| Item | GPT | Gemini | Adopted |
|------|-----|--------|---------|
| Title | OK | OK | unchanged |
| Short line "Richtet sich nach deiner Stummschaltung in unterstützten Anrufen mit Zoom, Teams und Google Meet." | OK | OK | as reviewed |
| Help text | reword: says "deine Stimme ... für einige Sekunden" | OK | unchanged: Gemini OK, and it keeps the English "brief audio" instead of adding "some seconds" |
| Search block | shorter phrases; drop the long Google Meet phrase as misleading | shorter phrases; long sentences are not typed into search | GPT's block: words Stummschaltung, stummgeschaltet, Mikrofon, Stimme; phrases "meine Stimme nicht aufnehmen, wenn ich stumm bin", "Stimme bei Stummschaltung weglassen", "Stummschaltung in Google Meet". Gemini's "Stummschaltung synchronisieren" not adopted: the switch syncs nothing |
