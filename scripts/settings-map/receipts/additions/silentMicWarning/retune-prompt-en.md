You review Settings search vocabulary for one setting of a macOS dictation app, in English only.

The setting: a switch titled "Warn when the microphone is silent" on the Microphone tab of Dictation Settings. When on (default), the recording pill shows a notice after about 5 seconds of digital silence from the microphone and a stronger one after 15 seconds. Recording continues either way. It does not stop recordings; a separate switch ("Stop recording on silence" / "Aufnahme bei Stille stoppen") does that.

Search words are short terms a user types; phrases are natural sentences a user might type. The title already matches words like "microphone"/"Mikrofon" and "silent"/"Stille". These blocks must NOT use the bare tokens "mic", "micro", "Mikro" or "sound"/"Ton alone as a standalone search word" in ways that pull generic queries ("mic", "Micro", "turn off the sound", "Ton aus") onto this switch, and must not collide with: Microphone readiness, Input device, Stop recording on silence, Media during dictation (mute/pause music), Recording chimes, the Bluetooth guide.

Proposed English block:
words: ["silence warning", "silent input alert"]
phrases: ["warn me if nothing comes through while I dictate", "stop the silence warning on the recording pill"]

Judge accuracy, naturalness for a English speaker, and collisions. Reply with a FINAL LIST in exactly this JSON shape and nothing after it: {"words": [...], "phrases": [...]}. Keep items that are fine; change only what needs changing, with one line of reason per change above the JSON.