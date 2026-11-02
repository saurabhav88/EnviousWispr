# Per-language rename review (#4320 chunk 7 repair)

Why: the first rename pass (rereview.txt) was one combined multilingual Codex session. The
Settings-search README requires a fresh Codex session per language for naturalness review.

How: review-driver.py.txt started one fresh isolated Codex session per language (32 languages,
English included; 2026-11-01). Each session saw only its language's FINAL blocks for the ids
that changed since chunk 6 (commit 554f1470), plus the sibling blocks (dictation Live Preview
switch, tab and section; meeting live language; transcript language and engine). Prompts are
prompt-<lang>.txt; answers are review-<lang>.txt. All 32 exited 0 and returned valid JSON.

Result: 73 blocks reviewed; 68 changed, 5 unchanged. All 68 changes were adopted after a
mechanical check (shape, no title for en/de, 1 to 3 phrases, at most 6 words, no dashes, the old
German name only on the card). Ten sessions also returned sibling ids they were not asked to
change; those were ignored.

Main correction: the first pass named the meeting card after dictation's switch ("show words
while you speak"). Many reviewers now use the name the app gives the dictation Live Preview TAB in
that language (for example fr "aperçu en direct", ja "ライブプレビュー"), which matches the card's
English title "Live Preview". Every block keeps meeting or EnviousMeet context.

German: the council round 2 blocks (council-de-digest.md) stand except as changed here: the
German session added "im Meeting" to the .change and .keepCurrent phrases. The earlier narrowing
(old-name-on-card-only.md) is kept: "Live-Transkript" stays only on meetingLiveWords.
