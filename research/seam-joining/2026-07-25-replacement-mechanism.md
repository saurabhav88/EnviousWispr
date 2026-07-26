# How to replace a span of text in someone else's app

Measured 2026-07-25 with `code/measure_replace.py` and `code/probe_model_sync.py`.
Every number here comes from staging a real field in the real app, running the
mechanism, and reading the field back
(validation-discipline.md RULE: measure-with-the-real-tool-never-a-simulation).

## The question

Seam joining has to delete text a previous recording already committed and put
joined text in its place. The prototype did that by posting one backspace per
character. Founder objection: visibly slow, and a dropped keystroke inside a
burst of forty leaves a character behind.

## Result

Correctness on a real two-sentence seam, 89 characters replaced by 82, five runs
each. `-` means the mechanism could not be attempted at all.

| mechanism | TextEdit | Chrome textarea | Chrome contenteditable | Slack | Excel | Ghostty |
|---|---|---|---|---|---|---|
| backspace × N, then paste | 5/5 | 5/5 | **0/5** | 5/5 | 5/5 | 5/5 |
| select the range, then paste | 5/5 | 5/5 | 5/5 | 5/5 | 5/5 | **-** |
| select the range, then write through accessibility | 5/5 | 0/5 | 0/5 | 0/5 | 0/5 | - |
| shift+Left × N, then paste | 5/5 | 5/5 | 5/5 | 5/5 | **0/5** | **0/5** |
| rewrite the whole value | 5/5 | 5/5 | 5/5 | 5/5 | 0/5 | 0/5 |
| shift+Home, then paste | 0/5 | 0/5 | 0/5 | 0/5 | 0/5 | 0/5 |

Wall clock, same fixed settle time in every arm, so the differences are the
mechanisms and not the harness:

| span | backspace | select |
|---|---|---|
| 20 characters | 673 ms | 371 ms |
| 89 characters | 1369 ms | 370 ms |

Selection is flat. Backspace is linear and unbounded.

## What each failure actually was

- **Backspace in a browser contenteditable** turns the space at the seam into a
  non-breaking space. The text looks identical and is a different character.
  That matters beyond cosmetics: the trigger rule compares the last sentence in
  the field against what we last pasted, and an invisible character swap breaks
  that comparison.
- **shift+Left in a terminal** arrives as literal escape sequences: the field
  ends up holding `;2D;2D;2D…`. Terminals have no selection to extend.
- **shift+Left in Excel** extends the cell selection instead of the text
  selection and wipes the cell.
- **shift+Home** takes the whole line, so it destroys anything before the seam.
  Only correct when the span happens to be the entire line.
- **Writing through accessibility** is accepted and does nothing in every
  Chromium app.

## The one that had to be ruled out carefully

Rewriting the whole value was the fastest of all, 155 ms, and passed the
read-back everywhere except Excel and Ghostty. It is still wrong.

Reading the text back proves the text changed; it cannot prove the app's own
editor saw it. `probe_model_sync.py` types one more character afterwards and
checks where it lands. In Slack and in a contenteditable the next character
landed at the **start** of the field: the visible text was right, the editor's
own cursor and document were not. Selection-then-paste passed the same check
everywhere, because the text arrives through a genuine paste the editor
processes normally.

This is the failure shape that has burned this work repeatedly — an
accessibility call reporting success while nothing real happened — and it is
invisible to any check that only reads the value back.

## Decision, implemented in `code/join_hotkey.py`

Select the exact range and paste. Fall back to backspace when the app reports no
caret position, which is the same condition that identifies a terminal and the
one surface where backspace is the only thing that works. Chosen by the caret
signal, not by an app name, so an unknown app routes itself.

The selection is read back before anything is written. An ignored selection
would be worse than useless: the paste would land beside the old text instead of
on top of it and double the sentence.

Both self-tests pass with the change, and each picks its own mechanism without
being told: `selftest_join.py` reports `by selection`, `selftest_terminal.py`
reports `by backspace`.

## The terminal path, which took five more rounds

Every one of these was found by the founder dictating into his own Claude Code
input box and reporting what he saw. None reproduced in a fresh shell, because a
full-screen text UI and a bare prompt are not the same surface.

1. **Reading returned the footer.** With the box completely EMPTY it read back
   `/rc ⧉ seam-join-explainer`. Anchoring on the prompt marker swept up
   everything below the box. Fixed by finding the box itself, which is drawn
   between two horizontal rules.
2. **The status bar looked like a shell prompt.** `81% | $107.40` contains both
   `%` and `$`. Those markers are now weak and consulted only when no
   unambiguous one (`❯`, `➜`) is on screen.
3. **The read window was too small.** 400 characters covered a one-line box; a
   wrapped dictation pushed the prompt out of view, no anchor was found, and the
   whole screen came back. Now 2000.
4. **Counting from the screen instead of the text.** The screen holds the line
   wraps and the box's padding, so its length is not the buffer's. One run
   counted 126 against a buffer of 149 and left 23 characters behind.
5. **Trailing whitespace was discarded.** The app ends every dictation with a
   space, so the buffer is one character longer than the visible sentence, and
   deleting the visible length leaves the FIRST letter of the old sentence
   welded to the new one — the `It` in `…again.It looks like`.

### Two ambiguities that cannot be read away

A terminal cannot tell you whether a line break replaced a space or fell
mid-word, and it cannot reliably report trailing spaces. Both are unmeasurable,
so the design stops trying to measure them:

- **Bias toward the visible mistake.** The initial deletion is deliberately one
  character short per wrap. A character left behind can be seen and removed; a
  space eaten off the front is invisible to any comparison that strips
  whitespace, so it could never be detected. Under-delete, then converge.
- **Write the separators rather than preserve them.** Both the leading and the
  trailing space are supplied on paste. Deterministic, where reading was not.

### Verification

`code/selftest_chunks.py` runs the founder's own test without him: type a chunk,
merge, type the next chunk, merge, in his real terminal, reproducing what the
app does including the trailing space. Six chunks, then eight, then ten, all
clean — every merge correct, every genuinely-separate pair correctly left alone,
no lost words, no leftover characters, no missing spaces.

Two harness lessons worth keeping. A fixed sleep before reading the screen back
reads a stale frame, which reported failures on runs that were correct and would
have fired corrective backspaces into kept text; wait for the screen to change
instead. And a strict word check called the polisher's "It's" for "It is" both a
lost word and an invented one, so comparison ignores apostrophes and allows
prefixes.

## Also fixed while in here

The deletion length was computed from the width of the matched sentence rather
than from the match's start to the caret. Those differ whenever whitespace sits
between the sentence and the cursor, which shifted the whole replacement one
character left. Latent in every run so far.
