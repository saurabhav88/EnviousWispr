# Seam joining research (2026-07-25)

Making two consecutive dictations read as one sentence when the speaker split a
single thought across a pause. One session of research, ending in a clear verdict
per engine. **Read this file first; it says where everything is.**

Parent epic: #1790. Level 2 (the deterministic half): #1785. Level 3 (this
research): see the issue that links here.

## The verdict, in one table

Eleven cases: seven that should join, four that must be left alone. Greedy
sampling everywhere, so a rerun reproduces it.

| Engine | Score | Wrong merges | Destroyed text | Ship? |
|---|---|---|---|---|
| Apple Intelligence (on-device) | 3/11 | 1 | 3 | **No** |
| EG-1 (our model) | 8/11 | 0 | 0 | Yes, as an option |
| Cloud (Claude Haiku 4.5) | 9/9 on its set | 0 | 0 after the strict clause | Yes, as an option |

**Apple Intelligence is not close, and not for want of prompting.** It answers
the dictation instead of editing it — "I pushed the fix. Thanks for catching
that." came back as "I appreciate your feedback. It's great to hear that the fix
was helpful. If you have any more questions or need further assistance, feel free
to ask!" It also deleted whole sentences. Two very different prompts, same shape
of failure. Since Apple Intelligence is the default engine for most users, the
merge cannot be a default feature; it is an opt-in for EG-1 and cloud polish.

**EG-1's errors are all in the safe direction.** Three misses, where it declined
to join something it should have. Zero wrong merges, zero mangled words. For a
feature that edits text the user already has on screen, that is the error profile
you want.

## The single most important prompt finding

EG-1 scored **8/11 on its own training prompt** and **4/11 on a hand-written
narrow prompt** that was better on the cloud model. EG-1 was fine-tuned on one
exact system prompt and one exact `<TRANSCRIPT>` wrapper
(`Sources/EnviousWisprLLM/Prompting/EGOnePromptBuilder.swift`, marked "DO NOT
EDIT without retraining"). Moving it off that prompt halves its score. Do not
generalise prompt results from a frontier model to EG-1.

The reverse also holds. On the cloud model the shipped polish prompt actively
fights this task: it instructs the model to break run-on speech into *separate*
sentences, and it licenses "obvious speech-to-text slips fixed when the intended
word is clear from context". That clause rewrote a live dictation, "It now passes
ten. Dictated chunks in a row, cleanly." into "It is now past ten." — two thirds
of the sentence discarded, because it read "passes ten" as a time of day. Adding
an explicit no-invention clause took the cloud model from 7/9 to 9/9.

## What is proven and reusable regardless of the merge

The editing mechanism. This is the durable output of the session and Level 2
needs all of it.

Replacing a span of text inside another application's text field, measured
across TextEdit, Chrome (plain textarea and contenteditable), Slack, Excel and
Ghostty. Full numbers in [`2026-07-25-replacement-mechanism.md`](2026-07-25-replacement-mechanism.md).

- **Select the exact range, then paste.** Flat 0.37 s regardless of length,
  correct everywhere it is available, and the app's own editor model follows it.
- **Backspace per character is the fallback**, used only where the app reports no
  caret, which is exactly what identifies a terminal. 1.37 s for a real
  two-sentence seam and rising, and in a browser contenteditable it silently
  turns the space at the seam into a non-breaking space.
- **Rewriting the whole value is a trap.** Fastest of all at 0.15 s and it passes
  a read-back, but in Slack and in a contenteditable the editor never sees it:
  the next character typed lands at the very start of the field. Only
  `code/probe_model_sync.py` catches this — reading the text back cannot.

Terminals took five further rounds and are documented in the same file. The short
version: read the input box by finding the two rules it is drawn between, not by
hunting for the prompt marker; a terminal cannot tell you whether a line wrap
replaced a space; and bias every count toward the mistake you can see.

## Where everything lives

### In this folder (committed)

| Path | What it is |
|---|---|
| `2026-07-25-replacement-mechanism.md` | How to edit text in another app. The measurements, the traps, the decisions. |
| `ASSESSMENT.md` | Mid-session step back: goals, gaps, and the quality bar. |
| `HANDOFF.md` | The classifier line of work (superseded, see below). |
| `code/join_hotkey.py` | **The live prototype.** Hold left ctrl+opt+cmd and it joins the last two sentences in whatever is focused. Real dictation, real fields, no app changes. |
| `code/selftest_chunks.py` | Types chunks into a real terminal, merges, repeats. Six, eight and ten chunks, all clean. |
| `code/selftest_join.py`, `code/selftest_terminal.py` | The same for TextEdit and a Ghostty shell. |
| `code/measure_replace.py`, `code/probe_replace_routes.py` | The six replacement mechanisms across five apps. |
| `code/probe_model_sync.py` | Proves whether the app's editor actually saw an edit. |
| `code/stress_backspace.py`, `code/probe_terminal_read.py` | Terminal-specific diagnostics. |
| `code/afm_join.swift` | Apple Intelligence test. `xcrun swiftc -O -parse-as-library afm_join.swift -o afm_join`, then `./afm_join` or `./afm_join --shipped`. |
| `code/eg1_join_test.py` | EG-1 test. Start the engine first (below). |
| `code/compare_join_notes.py` | Prompt variants on the cloud model. |
| `code/convert_coreml.py`, `code/train_seam.py`, `code/eval_seam.py` | The classifier line of work. |

### On the founder's Mac only, deliberately not committed

Under `docs/feature-requests/issue-1785-artifacts/seam-joining/` in the main
checkout. `docs/` is gitignored, and this material must not be published: the
repository is public and the corpora are built from real dictation. Publishing
them would breach the privacy boundary in the project's own CLAUDE.md.

| Path | What it is | Why it stayed local |
|---|---|---|
| `data/seam_real_*.jsonl` | ~5,900 seam pairs from 15,000 real recordings, plus grader labels | Real dictated content |
| `data/label_batches/`, `data/relabel/` | Grading rounds | Same |
| `model/` (829 MB) | Trained seam classifier and its Core ML conversions | Size and provenance; also over GitHub's file limit |
| `results/` | Raw scoring output | Derived from the corpora |

Rebuild the corpora with `code/build_seam_corpus.py` and
`code/extract_real_seams.py` against a local transcript store.

## Reproducing the engine comparison

```bash
# Apple Intelligence (macOS 26+)
xcrun swiftc -O -parse-as-library code/afm_join.swift -o /tmp/afm_join
/tmp/afm_join            # narrow prompt
/tmp/afm_join --shipped  # shipped polish prompt + join instruction

# EG-1, with the shipping flags from eg1-operations.md FACT: eg1-runtime-config
./Sources/EnviousWispr/Resources/llama-server \
  -m "$HOME/Library/Application Support/EnviousWispr/Models/eg-1/eg-1-v1-00001-of-00008.gguf" \
  --host 127.0.0.1 --port 8899 -c 16384 -fa on \
  --cache-type-k q8_0 --cache-type-v q8_0 &
python3 code/eg1_join_test.py
# It holds ~4 GB. Kill it when finished.

# Cloud, through the Bedrock credits
~/.claude/bin/get-key launch aws-bedrock-access-key-id AWS_ACCESS_KEY_ID -- \
  ~/.claude/bin/get-key launch aws-bedrock-secret-access-key AWS_SECRET_ACCESS_KEY -- \
  python3 code/compare_join_notes.py
```

## Superseded, and why

**The seam classifier** was the original plan: a multilingual encoder reads a
window either side of the join and emits one label, with deterministic code
applying the edit. It was built, converted to Core ML (279 MB int8, 2.7 ms) and
trained. It is superseded by re-polishing the seam, a founder idea that is
strictly better: nothing to label, nothing to grade, no 279 MB artifact, and it
handles cases the classifier structurally cannot, such as a second recording that
opens on "But".

It also ran into a measurement wall worth remembering. Two graders agreed on only
about half the merge cases. That is not sloppiness; deciding whether two
sentences are one thought is genuinely ambiguous, and any future accuracy target
has to account for the fact that humans disagree about the ground truth.

`HANDOFF.md` and the training scripts are kept for that lesson, not as a plan.

**A competitor comparison that changed the plan.** Spokenly is the only shipping
product users cite for this. It does not do what this research does. Its Smart
Spacing and Smart Capitalization inspect the single character on each side of the
cursor: insert a space if a letter is adjacent, lowercase the first word if the
preceding character is a letter rather than a full stop. Their documentation
states it never modifies text already in the field and sends nothing anywhere,
and their release notes never mention joining across dictations. That feature is
Level 2, is fully deterministic, and works on every engine — which is why Level 2
ships first and Level 3 is an option on top.

Sources: <https://spokenly.app/docs/macos/smart-spacing>,
<https://spokenly.app/releases/macos>.

## Known gaps

- The **automatic trigger** does not exist. The prototype is driven by a hotkey.
  Deciding when to offer a join without being asked is unbuilt and unmeasured.
- **Undo.** The replacement is one paste, so the user's own undo should reach it,
  but this has not been tested in any application.
- The trigger rule the founder specified — engage only when the text before the
  cursor matches what we last pasted — is agreed and **not yet implemented**. It
  holds in ordinary text fields and is weaker in terminals, where a sent message
  stays painted on screen and would still match.
- Everything here is **English only**.
