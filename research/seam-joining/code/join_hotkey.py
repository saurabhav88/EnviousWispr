"""Live seam-joining prototype. Real dictation, real fields, no app changes.

THE IDEA (founder, 2026-07-25). Instead of a classifier deciding whether two
recordings belong together, hand the polisher the last sentence already sitting
in the field plus the new recording, and let it produce clean joined text. Then
delete that last sentence and paste the result.

HOW TO USE IT
  1. start this, then click into a real text box: Notes, Slack, Mail, a browser
  2. dictate a half thought, pause, dictate the rest, exactly as you normally do
  3. hold LEFT control + LEFT option + LEFT command, then let go
  4. watch it replace the last two sentences with a joined version

Everything is real except the trigger. The automatic trigger is the expensive
part and is not worth building until the joining itself has earned its place.

TERMINALS ARE A FIRST-CLASS SURFACE (founder, 2026-07-25): a large share of
users dictate into one. The earlier failure was not the terminal, it was reading
AXValue, which in a terminal returns the ENTIRE scrollback — so the script fed
the polisher its own printed output. Reading a bounded window behind the cursor
fixes it and matches what the shipped app does. Still run it from a DIFFERENT
window than the one you type into.

Terminal needs Accessibility permission. Ctrl-C to stop.
"""

import json
import os
import re
import sys
import threading
import time

import regex

import Quartz
from AppKit import (NSPasteboard, NSPasteboardItem,
                    NSPasteboardTypeString, NSWorkspace)
from ApplicationServices import (AXUIElementCopyAttributeValue,
                                 AXUIElementCopyParameterizedAttributeValue,
                                 AXUIElementCreateApplication,
                                 AXUIElementSetAttributeValue, AXValueCreate,
                                 AXValueGetValue, kAXValueCFRangeType)

# Device-dependent modifier bits. The ordinary flags say "control is down" but
# not WHICH control, so a left-hand-only chord needs these.
LEFT_CONTROL, LEFT_COMMAND, LEFT_OPTION = 0x01, 0x08, 0x20
CHORD = LEFT_CONTROL | LEFT_COMMAND | LEFT_OPTION
DELETE_KEY, V_KEY = 51, 9

TERMINALS = {"ghostty", "terminal", "iterm2", "iterm", "warp", "alacritty",
             "kitty", "wezterm", "hyper", "tabby"}
TEXT_ROLES = {"AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"}

# The closing sentence is not padding. Without it the polisher rewrote the
# founder's live dictation "It now passes ten. Dictated chunks in a row,
# cleanly." into "It is now past ten." — it read "passes ten" as a time of day
# and threw away two thirds of what he said. Adding the no-invention clause
# fixed that case and scored 9/9 against 7/9 for the version without it,
# including an over-merge the looser wording also produced
# (`code/compare_join_notes.py`, 2026-07-25). Destroying a sentence is a worse
# failure than merging two that should have stayed apart.
JOIN_NOTE = (
    "\n\nThe transcript below is a PREVIOUS sentence followed by a NEW recording "
    "the speaker dictated moments later, after a pause. They may be one thought "
    "split by that pause, or two separate thoughts. If they are one thought, join "
    "them into a single natural sentence. If they are two, leave them as two "
    "sentences. Return only the cleaned text, never a question or a comment."
    " Never drop a word, never replace a word with a different word, and never "
    "reinterpret what was said. Every word of the transcript must appear in your "
    "answer unless joining the two halves makes a connecting word redundant."
)


# ── reading the field ────────────────────────────────────────────────────────

def attr(element, name):
    err, value = AXUIElementCopyAttributeValue(element, name, None)
    return value if err == 0 else None


def focused():
    """The frontmost app's focused element, or a reason it cannot be used."""
    NSWorkspace.sharedWorkspace().runningApplications()
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    if not app:
        return None, None, "no frontmost app"
    name = app.localizedName() or "?"
    element = attr(AXUIElementCreateApplication(app.processIdentifier()),
                   "AXFocusedUIElement")
    if element is None:
        return None, name, f"{name} has no focused element"
    role = attr(element, "AXRole")
    if role not in TEXT_ROLES:
        return None, name, f"{name}: focused thing is a {role}, not a text box"
    return element, name, None


def caret_position(element):
    raw = attr(element, "AXSelectedTextRange")
    if raw is None:
        return None
    ok, value = AXValueGetValue(raw, kAXValueCFRangeType, None)
    return int(value[0]) if ok else None


def text_before_caret(element, position, window=400):
    """Read a BOUNDED window behind the cursor, never the whole document.

    Terminals report their entire scrollback as AXValue, so reading that hands
    the polisher a whole session's history instead of the line being typed. A
    bounded backward read is also what the shipped app does: AXStringForRange
    costs the same 0.03-0.10 ms whether you ask for 2 characters or 1,556
    (accessibility-macos.md FACT: reading-caret-context-from-another-app).
    """
    start = max(0, position - window)
    length = position - start
    if length <= 0:
        return ""
    value = AXValueCreate(kAXValueCFRangeType, (start, length))
    if value is None:
        return ""
    err, result = AXUIElementCopyParameterizedAttributeValue(
        element, "AXStringForRange", value, None)
    return result if err == 0 and isinstance(result, str) else ""


# A terminal hands over the whole screen, so a TUI's status bar and separators
# arrive as if they were the user's prose. Claude Code contributed "git:main⚠",
# "Opus 5 (1M context)" and a rule of box-drawing characters, which inflated the
# input to 24 words against 6 real ones and tripped the lost-words guard on a
# join that was actually correct. Prototype-only: the shipped app reads a real
# focused text field and never sees chrome.
CHROME = re.compile(
    r"^\s*(?:[─━═|│┃┆┇┊┋]{4,}"                    # separator rules
    r"|[⏵▶▸►]+\s"                                  # mode indicators
    r"|.*\b(?:git:|⎇|shift\+tab|auto mode|context\))"  # status bars
    r"|[█░▓▒]{3,})")                                # progress meters


# In a terminal the screen buffer is NOT the editable region. Everything before
# the last shell prompt is already committed output: banners, paths, previous
# commands. Deleting into it is meaningless at best and destructive at worst —
# the first successful run here read 144 characters including "Claude Max" and
# the working directory, then backspaced over all of them. Anchor on the prompt
# so only the current input line is ever a candidate.
# Matched as a regex, not literals with a hard-coded trailing space. The chrome
# stripper rstrips each line, so a bare prompt ends "…Pro ~ %" with nothing
# after it — a literal "% " never matched, and a fresh window read back as
# "Last login: …" instead of empty.
PROMPT_RE = re.compile(r"(?:❯|➜|\|>|[$%#])\s*")

# Split by confidence. A "$" or a "%" is a shell prompt on a bare prompt line and
# is ALSO a dollar amount and a percentage — Claude Code's own status bar reads
# "81% | $107.40", so the weak markers matched a line BELOW the input box and the
# reader anchored on the status bar. Strong markers are unambiguous; the weak set
# is consulted only when no strong one is on screen.
STRONG_PROMPT_RE = re.compile(r"(?:❯|➜|\|>)\s*")


# A full-screen terminal UI draws its input box between two horizontal rules and
# prints hints UNDER it. Anchoring on the prompt marker alone therefore swept up
# everything below the box: with the box completely EMPTY, reading it back
# returned "/rc ⧉ seam-join-explainer". A reader that cannot tell empty from
# full is worse than no reader — it invites deleting text nobody typed.
RULE_LINE = re.compile(r"^\s*[─━═-]{4,}\s*$")


# How much of the screen to read back. 400 characters covered a single-line
# input box and nothing more: as soon as a dictation wrapped onto a second and
# third line, the prompt marker fell outside the window, no anchor was found,
# and the reader handed back the raw screen INCLUDING the footer hints — which
# is how "/rc ⧉ seam-join-explainer" ended up inside a sentence being polished.
TERMINAL_WINDOW = 2000


def input_box_body(lines):
    """The text inside a full-screen UI's input box, or None if there is no box.

    Anchoring on the prompt marker alone is fragile: it has to be on screen, it
    has to be found, and everything after it is assumed to be the user's. The
    box itself is a stronger landmark — it is drawn between two horizontal
    rules, and its contents are exactly the editable region. The prompt marker
    then only has to CONFIRM that the pair of rules found really is the input
    box rather than any other rule the program happened to print.
    """
    rules = [index for index, line in enumerate(lines) if RULE_LINE.match(line)]
    if len(rules) < 2:
        return None
    body = lines[rules[-2] + 1:rules[-1]]
    if not body or not STRONG_PROMPT_RE.search(body[0]):
        return None
    return body


def terminal_text(value):
    """The input line EXACTLY as the buffer holds it, trailing space and all.

    Trailing whitespace is load-bearing and was being thrown away. The app ends
    each dictation with a space so the next one does not run into it, so the
    buffer is one character longer than the visible sentence — and deleting the
    visible length from the end therefore stops one character short and leaves
    the FIRST letter of the old sentence welded to the new one. That is the
    "It" in "…again.It looks like", and it happened on every single terminal
    run: wanted '', last saw 'O'; wanted '', last saw 'T'.

    Safe to preserve because this terminal does not pad lines out to the window
    width — an empty box reads back as "❯\\xa0" with nothing after it, and a
    126-character sentence reads back as exactly 126 characters.
    """
    window = value[-TERMINAL_WINDOW:]
    body = input_box_body(window.splitlines())
    if body is None:
        return strip_chrome(after_shell_prompt(window))

    marker = list(STRONG_PROMPT_RE.finditer(body[0]))[-1]
    parts = [body[0][marker.end():]] + list(body[1:])
    # Every line but the last gets its wrap padding trimmed; the last keeps its
    # tail, because that tail is real text the buffer contains.
    head = [part.strip() for part in parts[:-1]]
    head = [part for part in head if part]
    last = parts[-1].lstrip()
    joined = " ".join(head + [last]) if last else " ".join(head)
    return joined.replace("\xa0", " ")


def terminal_wraps(value):
    """How many times the input box wrapped the line onto a new row.

    Any wrap at all means the screen cannot be read back faithfully, so this is
    now a REFUSAL signal rather than a number to compensate for. See the caller
    for the three ambiguities a wrap introduces and why only refusing closes
    them all.
    """
    body = input_box_body(value[-TERMINAL_WINDOW:].splitlines())
    return max(0, len(body) - 1) if body else 0


def after_shell_prompt(text):
    """The current input line: after the last prompt, before the box closes."""
    lines = text.splitlines()

    start, pattern = None, STRONG_PROMPT_RE
    for index, line in enumerate(lines):
        if STRONG_PROMPT_RE.search(line):
            start = index
    if start is None:
        pattern = PROMPT_RE
        for index, line in enumerate(lines):
            if PROMPT_RE.search(line) and not CHROME.match(line):
                start = index
    if start is None:
        return text

    collected = []
    for line in lines[start:]:
        if RULE_LINE.match(line):
            break  # the bottom of the input box; nothing below it is ours
        collected.append(line)

    marker = list(pattern.finditer(collected[0]))[-1]
    collected[0] = collected[0][marker.end():]
    # The box pads with a non-breaking space, which is whitespace to a human and
    # a distinct character to everything else.
    joined = " ".join(part.strip() for part in collected if part.strip())
    return joined.replace("\xa0", " ").strip()


def strip_chrome(text):
    kept = [ln for ln in text.splitlines() if ln.strip() and not CHROME.match(ln)]
    # A rule can also trail a real line: "…design. ────────────".
    kept = [re.sub(r"\s*[─━═]{4,}.*$", "", ln).rstrip() for ln in kept]
    return " ".join(ln for ln in kept if ln.strip())


def loose_pattern(text):
    """Find these words again however the gaps between them are punctuated.

    The sentence being looked for is REBUILT with single spaces, while the field
    holds whatever is really there. Requiring at least one space between every
    pair of words therefore fails on the commonest case of all: a dictation
    pasted straight onto the end of the previous one with no space at all, as in
    "…joining system.It looks like…". That failure is silent — it reports that
    it cannot find the text and does nothing, which is what happened twice in a
    row on 2026-07-25. Allowing ZERO whitespace matches what is actually there.
    """
    return r"\s*".join(re.escape(word) for word in text.split())


def sentences_in(text):
    return [s for s in re.split(r"(?<=[.!?])\s+", text.strip()) if s]


TRANSCRIPTS = os.path.expanduser("~/Library/Application Support/EnviousWispr/transcripts")


def latest_recording():
    """What the app most recently pasted, straight from its own transcript store.

    Without this the prototype guesses the seam by splitting on punctuation and
    taking the last two sentences. That is wrong twice over: when a recording
    contains two sentences it looks at the wrong seam entirely, and when a
    recording ends with NO full stop — the strongest possible signal that it is
    unfinished — it sees one blob, decides there is nothing to join, and skips.

    The shipped app never has to guess: it knows what it just pasted. Reading
    the store gives the prototype the same knowledge and makes it faithful.
    """
    try:
        files = [os.path.join(TRANSCRIPTS, f) for f in os.listdir(TRANSCRIPTS)
                 if f.endswith(".json")]
    except OSError:
        return None
    if not files:
        return None
    newest = max(files, key=os.path.getmtime)
    if time.time() - os.path.getmtime(newest) > 600:
        return None  # stale: nothing dictated recently
    try:
        data = json.load(open(newest, encoding="utf-8"))
    except Exception:
        return None
    text = (data.get("polishedText") or data.get("text") or "").strip()
    return text or None


# ── writing to the field ─────────────────────────────────────────────────────

def post_key(keycode, flags=0):
    source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    for pressed in (True, False):
        event = Quartz.CGEventCreateKeyboardEvent(source, keycode, pressed)
        if flags:
            Quartz.CGEventSetFlags(event, flags)
        Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, event)
        time.sleep(0.004)


def utf16_length(text):
    """Length in UTF-16 units, which is what accessibility ranges count.

    Python counts code points; macOS counts UTF-16 units. They agree until the
    text contains anything outside the basic plane — an emoji, which dictation
    produces routinely (`EmojiRestorer` exists for exactly that reason). "I said
    👍 to that" is 16 code points and 17 UTF-16 units, so a selection computed
    the Python way starts one unit late and the replacement eats a character it
    should have kept. Found by cloud review on PR #1793.
    """
    return len(text.encode("utf-16-le")) // 2


def keypress_length(text):
    """How many backspaces this text costs: one per user-visible character.

    A third counting system, agreeing with neither of the others. A backspace
    removes one grapheme cluster, so a flag or a family emoji is one keypress
    but several code points and several UTF-16 units.

    NOT verified against a real field — no emoji case has been run through the
    backspace path. The shipped implementation is Swift, where `String` already
    iterates graphemes and `String.utf16.count` gives the other number, so
    neither approximation survives into the product.
    """
    return len(regex.findall(r"\X", text))


def selected_range(element):
    raw = attr(element, "AXSelectedTextRange")
    if raw is None:
        return None
    ok, value = AXValueGetValue(raw, kAXValueCFRangeType, None)
    return (int(value[0]), int(value[1])) if ok else None


def select_range(element, location, length):
    """Ask the app to select exactly these characters, and CHECK that it did.

    An accessibility call that returns success and changes nothing is the
    failure mode this whole prototype keeps hitting, and here it would be
    destructive rather than merely useless: an ignored selection means the paste
    lands next to the old text instead of on top of it, doubling the sentence.
    So the range is read back before anything is written.
    """
    value = AXValueCreate(kAXValueCFRangeType, (location, length))
    if value is None:
        return False
    if AXUIElementSetAttributeValue(element, "AXSelectedTextRange", value) != 0:
        return False
    time.sleep(0.05)
    return selected_range(element) == (location, length)


def terminal_line(element):
    value = attr(element, "AXValue")
    if not isinstance(value, str):
        return None
    return terminal_text(value).strip()


def wait_for_change(element, previous, timeout=1.5):
    """Read back only once the screen has actually moved.

    A fixed sleep after posting keys reads a screen that has not repainted yet.
    That is how the check reported "wanted '', last saw 'I'" on runs whose text
    ended up perfectly correct: it was looking at a stale frame. Harmless when
    nothing remains to delete, and NOT harmless otherwise — it would have fired
    corrective backspaces into text the user was keeping.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        current = terminal_line(element)
        if current is not None and current != previous:
            return current
        time.sleep(0.05)
    return terminal_line(element)


def settle_deletion(element, expected, before, budget=8):
    """Confirm the deletion actually landed, and finish it if it did not.

    The founder has seen the replacement stop one character short twice. A
    twenty-run stress test in the very same text box deleted all 46 characters
    all 20 times, so a dropped keystroke is NOT the cause and guessing again
    would be the third guess. Instead: read the line back, correct the
    difference, and report what was actually seen so the next occurrence
    identifies itself rather than needing another screenshot.

    Bounded on purpose. Correcting one stray character is repair; hammering
    backspace until some expectation is met is how a bug becomes data loss.
    """
    expected = expected.strip()
    current = wait_for_change(element, before)
    for _ in range(3):
        if current is None or current.strip() == expected:
            return None
        current = current.strip()
        if current.startswith(expected):
            extra = len(current) - len(expected)
            if extra > budget:
                return f"{extra} characters too many left, refusing to keep deleting"
            for _ in range(extra):
                post_key(DELETE_KEY)
            current = wait_for_change(element, current)
            continue
        if expected.startswith(current):
            # Deleted too far. Put back what was taken; never leave it short.
            type_text(expected[len(current):])
            current = wait_for_change(element, current)
            continue
        return f"expected {expected!r}, found {current!r}"
    # Say WHAT it saw. "did not settle" on its own sent the last round back to
    # guesswork and a screenshot; the two strings identify the cause on sight.
    return f"did not settle — wanted {expected!r}, last saw {current!r}"


def replace_span(element, caret, span_text, replacement, expected_after=None):
    """Swap `span_text`, which ends at the caret, for `replacement`.

    Two mechanisms, measured across TextEdit, Chrome (both a plain textarea and
    a contenteditable), Slack, Excel and Ghostty on 2026-07-25:

      selection + paste   one call to select, one Cmd+V. Flat 0.37 s whatever
                          the length. Correct everywhere it is available, and
                          the app's own editor model follows it.
      backspace + paste   what this used to do always. 1.37 s for a real
                          two-sentence seam and rising with every character,
                          and in a browser contenteditable it silently turns
                          the space at the seam into a non-breaking space.

    So selection is the default and backspace is the fallback, chosen by whether
    the app reports a caret at all rather than by an app name. Terminals do not,
    which is also the only surface where backspace is the one thing that works:
    shift+arrow selection arrives there as literal escape sequences.

    Rejected outright: writing the whole value through accessibility was the
    fastest of all at 0.15 s and looked correct, but in Slack and in a
    contenteditable the editor never saw it — the next character typed landed at
    the very start of the field. Reading the text back cannot detect that.
    """
    # Three counting systems, one per consumer, and they disagree the moment an
    # emoji appears. Measure `span_text` itself rather than passing one number
    # around: accessibility ranges want UTF-16 units, backspaces want keypresses.
    units = utf16_length(span_text)
    if caret is not None and caret >= units:
        if select_range(element, caret - units, units):
            paste(replacement)
            return "selection"
    before = terminal_line(element) if expected_after is not None else None
    for _ in range(keypress_length(span_text)):
        post_key(DELETE_KEY)
    if expected_after is not None:
        problem = settle_deletion(element, expected_after, before)
        if problem:
            # ABORT, do not paste. settle_deletion refuses precisely when the
            # remaining text cannot be reconciled — too much left, or a prefix
            # that is not what we expected — which means we no longer know what
            # is in the field. Pasting on top of that writes the joined sentence
            # into unknown text and makes a recoverable mess unrecoverable.
            # It was previously logged and then pasted anyway. Found by cloud
            # review on PR #1793.
            return f"ABORTED before pasting, {problem}"
    paste(replacement)
    return "backspace"


def type_text(text):
    """Type characters as key events. Used only to put back an over-deletion."""
    source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    for character in text:
        for pressed in (True, False):
            event = Quartz.CGEventCreateKeyboardEvent(source, 0, pressed)
            Quartz.CGEventKeyboardSetUnicodeString(event, len(character), character)
            Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, event)
        time.sleep(0.01)


def paste(text):
    """Paste `text`, and put the clipboard back the way it was found.

    Saving only the plain-string representation destroyed everything else on the
    clipboard: a copied image, a file, or rich text with no string form left
    `saved` as None and the restore silently dropped it. Even a text item lost
    its styled and HTML flavours. The user never asked us to touch their
    clipboard at all, so losing what was on it is our bug, not a side effect.
    Found by cloud review on PR #1793.

    Every item and every type is snapshotted and written back.
    """
    board = NSPasteboard.generalPasteboard()
    saved = []
    for item in (board.pasteboardItems() or []):
        flavours = {}
        for kind in (item.types() or []):
            data = item.dataForType_(kind)
            if data is not None:
                flavours[kind] = data
        if flavours:
            saved.append(flavours)

    board.clearContents()
    board.setString_forType_(text, NSPasteboardTypeString)
    time.sleep(0.06)
    post_key(V_KEY, Quartz.kCGEventFlagMaskCommand)
    time.sleep(0.3)

    board.clearContents()
    restored = []
    for flavours in saved:
        item = NSPasteboardItem.alloc().init()
        for kind, data in flavours.items():
            item.setData_forType_(data, kind)
        restored.append(item)
    if restored:
        board.writeObjects_(restored)


# ── the join ─────────────────────────────────────────────────────────────────

def looks_unsafe(before, after):
    """Reasons to abandon rather than write. Each one was seen for real today."""
    if after.strip() == before.strip():
        return "nothing changed"
    if len(after.split()) < 0.6 * len(before.split()):
        return f"lost too many words ({len(before.split())} -> {len(after.split())})"
    if len(after.split()) > 1.6 * len(before.split()):
        return f"invented too many words ({len(before.split())} -> {len(after.split())})"
    # COUNTS are not enough. A same-length substitution passes every check
    # above: "It now passes ten" -> "It is now past ten" swaps a word for one
    # that was never spoken while keeping the length plausible, and the field
    # gets overwritten with words the user did not say. The real failure was
    # caught only because the count also collapsed; a tidier rewrite would have
    # sailed through. Found by cloud review on PR #1793.
    #
    # So check identity, not size: every word written must have been spoken.
    #
    # The first attempt at that check leaked three ways, all found by review on
    # PR #1819 and all REPRODUCED before being fixed. They are listed because
    # each is the kind of hole that reads as safe:
    #
    #   1. ASCII-only tokenizing. `[A-Za-z']+` finds NO words in Cyrillic,
    #      Greek or CJK, so the guard saw an empty list, concluded nothing was
    #      invented, and waved every substitution through. Silent, and worst in
    #      exactly the languages nobody spot-checks.
    #      "Это правильный ответ" -> "Это выдуманный ответ" passed.
    #   2. A bare prefix test. Meant to allow "pass"/"passes", it actually
    #      accepted any word starting with ANY spoken token — and almost every
    #      English sentence contains "I" or "a", which admit "invented" and
    #      "absurd". It is gone rather than tightened: joining stitches two
    #      transcripts, it does not re-inflect them, so nothing needs it.
    #   3. Exempting connectives exempted INSERTING them. Dropping one never
    #      needed an exemption, because this only inspects words in `after`.
    #      The old set also smuggled in "it" and "is" — content words, present
    #      only to paper over contractions — so "Ship Monday. Release Tuesday"
    #      -> "Ship Monday so release Tuesday" passed.
    #
    # When this is unsure it REFUSES. Abandoning a join costs a keystroke;
    # overwriting the field with words the user did not say costs their text.

    # Any script, not just Latin-1. `regex` is already imported for exactly
    # this reason; \p{L} is the platform's own letter property, so there is no
    # hand-maintained alphabet here to fall behind Unicode.
    # Coarse for scripts that do not space their words: Japanese or Chinese
    # yields one token per run of letters, so the comparison becomes
    # all-or-nothing rather than word-by-word. That is blunt, but it fails
    # CLOSED (any edit trips it) where the old ASCII regex failed OPEN (no
    # tokens at all, so everything passed). Real segmentation is the fix if
    # this prototype ever targets those languages.
    def tokens(text):
        return [w.lower() for w in regex.findall(r"[\p{L}\p{M}']+", text)]

    # English contractions are a genuinely CLOSED set, unlike an open-ended
    # word list — so enumerating them is honest. Expanded on both sides, which
    # covers the polisher contracting "it is" -> "it's" and the reverse.
    CONTRACTIONS = {
        "it's": "it is", "that's": "that is", "there's": "there is",
        "he's": "he is", "she's": "she is", "what's": "what is",
        "who's": "who is", "let's": "let us", "i'm": "i am",
        "you're": "you are", "we're": "we are", "they're": "they are",
        "i've": "i have", "you've": "you have", "we've": "we have",
        "they've": "they have", "i'll": "i will", "you'll": "you will",
        "we'll": "we will", "they'll": "they will", "i'd": "i would",
        "you'd": "you would", "we'd": "we would", "they'd": "they would",
        "don't": "do not", "doesn't": "does not", "didn't": "did not",
        "isn't": "is not", "aren't": "are not", "wasn't": "was not",
        "weren't": "were not", "can't": "can not", "couldn't": "could not",
        "won't": "will not", "wouldn't": "would not", "shouldn't": "should not",
        "haven't": "have not", "hasn't": "has not", "hadn't": "had not",
    }

    def expand(text):
        out = []
        for w in tokens(text):
            out.extend(tokens(CONTRACTIONS[w]) if w in CONTRACTIONS else [w])
        return out

    # A join may legitimately add ONE connective to stitch two fragments. More
    # than one is a rewrite, not a join. Content words are deliberately absent.
    #
    # KNOWN AND ACCEPTED LIMIT: this cannot tell "Ship Monday, and release
    # Tuesday" from "Ship Monday so release Tuesday". Both add exactly one
    # connective and invent no content word, so they are the same SHAPE; only
    # meaning separates them, and "so" quietly asserts a causation the speaker
    # did not. Refusing it would refuse every legitimate join, so the guard
    # accepts it. Narrowing this needs semantics, not a bigger word list.
    CONNECTIVES = {"and", "but", "so", "then", "or", "yet", "because",
                   "which", "while", "although", "though"}
    MAX_ADDED_CONNECTIVES = 1

    spoken = set(expand(before))
    unspoken = [w for w in expand(after) if w not in spoken]
    added_connectives = [w for w in unspoken if w in CONNECTIVES]
    invented = [w for w in unspoken if w not in CONNECTIVES]
    if invented:
        return f"used words that were never said: {sorted(set(invented))}"
    if len(added_connectives) > MAX_ADDED_CONNECTIVES:
        return f"stitched with too many added words: {sorted(added_connectives)}"

    lowered = after.lower()
    for tell in ("could you", "please share", "i need the", "the transcript you",
                 "appears to be", "i don't see"):
        if tell in lowered:
            return "model replied to us instead of cleaning the text"
    return None


def do_join(client, model, system):
    element, app, problem = focused()
    if problem:
        print(f"  SKIPPED  {problem}\n")
        return

    position = caret_position(element)
    value = attr(element, "AXValue")

    # Ghostty (and terminals generally) always report the caret at 0, so
    # "text before the cursor" is empty by definition and the bounded read
    # returns nothing. When the caret is unusable, the most recent content is
    # the TAIL of the value instead — in a terminal that is what was just typed.
    if position and position > 0:
        before_caret = text_before_caret(element, position)
        if not before_caret.strip() and isinstance(value, str):
            before_caret = value[:position]
        source = "before the cursor"
        raw_tail = before_caret
        before_caret = strip_chrome(after_shell_prompt(before_caret))
    elif isinstance(value, str) and value.strip():
        # THE WHOLE CLASS, closed at its source rather than patched again.
        #
        # A terminal shows a grid of cells, not the text buffer behind it, and
        # reconstructing one from the other is ambiguous in at least three ways
        # that each cost a review round:
        #   1. trailing whitespace is indistinguishable from cell padding
        #   2. a soft wrap may have replaced a space, or may not have
        #   3. a soft wrap may fall MID-WORD, so joining rows with a space
        #      invents text: "recognizing" reconstructs as "recog nizing"
        # The third is unrecoverable. The invented text does not match the real
        # recording, the code falls back to splitting on punctuation, and it
        # then rewrites the user's sentence around a word that was never there.
        #
        # Every one of these exists only because the box wrapped. So refuse a
        # wrapped box. A single-row box has no wrap, no phantom space and no
        # invented word, and the earlier compensation arithmetic disappears with
        # the ambiguity it was compensating for.
        #
        # Prototype-only. The shipped feature reads a real focused text field
        # and never reconstructs anything from a screen.
        if terminal_wraps(value):
            print(f"  SKIPPED  {app}: the input box has wrapped onto more than "
                  f"one line, and a wrapped terminal cannot be read back "
                  f"faithfully\n")
            return
        raw_tail = value[-TERMINAL_WINDOW:]
        before_caret = terminal_text(value)
        source = "end of the field (this app does not report a cursor position)"
    else:
        raw_tail = before_caret = ""
        source = ""

    if not before_caret.strip():
        print(f"  SKIPPED  {app}: nothing readable in the field\n")
        return

    # Prefer the REAL recording boundary over guessing it from punctuation.
    recording = latest_recording()
    target = None
    if recording:
        flexible = loose_pattern(recording)
        hit = list(re.finditer(flexible, before_caret))
        if hit:
            context = before_caret[:hit[-1].start()].rstrip()
            if context:
                previous = sentences_in(context)
                if previous:
                    target = f"{previous[-1]} {before_caret[hit[-1].start():].strip()}"
                    print(f"  seam     using the real recording boundary")

    if target is None:
        found = sentences_in(before_caret)
        if len(found) < 2:
            print(f"  SKIPPED  {app}: only one sentence before the cursor, "
                  f"nothing to join with\n")
            return
        target = f"{found[-2]} {found[-1]}"
    print(f"  app      {app}  ({source})")
    print(f"  reading  {target}")

    try:
        response = client.messages.create(
            model=model, max_tokens=800, temperature=0, system=system,
            messages=[{"role": "user", "content": f"Transcript to clean:\n\n{target}"}])
        result = response.content[0].text.strip()
    except Exception as exc:
        print(f"  FAILED   polish call: {type(exc).__name__}\n")
        return

    print(f"  polished {result}")

    # Deciding NOT to join is the system working, not the system failing. Both
    # used to print as "SKIPPED nothing changed", so a correct refusal was
    # indistinguishable from a fault and read to the founder as "not firing".
    if result.strip() == target.strip():
        print("  DECIDED  two separate thoughts, correctly left alone\n")
        return

    reason = looks_unsafe(target, result)
    if reason:
        print(f"  SKIPPED  {reason}, field untouched\n")
        return

    # Delete the REAL span, not the length of the rebuilt string. `target` joins
    # the two halves with exactly one space; the field may hold two spaces or a
    # newline, so counting the reconstruction leaves a stray character behind.
    # Anchor on where the earlier sentence actually starts in the raw text.
    # Locate the span with WHITESPACE-TOLERANT matching. `found[-2]` comes from
    # cleaned text: chrome stripped, line breaks collapsed to spaces. A literal
    # search for it in the raw screen text fails whenever the field held a
    # newline or a double space, which is most of the time — every "cannot
    # locate the text to replace" skip was this, on joins that were correct.
    # Match the WHOLE target and delete exactly what it spans. Deleting from the
    # anchor to the end of the buffer assumed the edited text is the last thing
    # on screen; in a TUI it is not. Claude Code renders its input box in the
    # MIDDLE, with a status bar below, so "to the end" meant 214 characters for
    # 51 of prose and would have eaten UI that is not editable.
    flexible = loose_pattern(target)
    expected_after = None

    if position and position > 0:
        # A real text field: the window ends AT the caret, so the span runs from
        # where the match starts to the caret — not the width of the match
        # itself. Those differ whenever whitespace sits after the sentence, and
        # counting the match instead shifted the deletion one character left.
        matches = list(re.finditer(flexible, raw_tail))
        if not matches:
            print("  SKIPPED  cannot locate the text to replace in the field\n")
            return
        span_text = raw_tail[matches[-1].start():]
    else:
        # A terminal, counted from the PARSED line rather than the raw screen.
        # The raw screen contains the line wraps and the box's own padding, so
        # its character count is not the buffer's: one run counted 126 against a
        # buffer of 149 and left 23 characters of the old sentence behind. The
        # parsed line is exact — typing 126 characters into the real box and
        # reading it back returns 126 — so it is the only honest ruler here.
        matches = list(re.finditer(flexible, before_caret))
        if not matches:
            print("  SKIPPED  cannot locate the text to replace in the field\n")
            return
        span_text = before_caret[matches[-1].start():]
        expected_after = before_caret[:matches[-1].start()].strip()

    # Screen content AFTER the match is not a problem: in a TUI the input box
    # sits mid-screen with a status bar below, but the caret is inside the box,
    # so backspaces only consume the box's own text. What matters is that the
    # caret sits at the end of what we matched, which it does straight after
    # dictating. Sanity-check the count instead.
    if len(span_text) > len(target) + 40:
        print(f"  SKIPPED  span looks wrong ({len(span_text)} chars for "
              f"{len(target)} of text), field untouched\n")
        return

    # Supply BOTH separators rather than trying to preserve them. The check
    # above converges on the text with whitespace stripped, so whatever spaces
    # sat either side of the replaced sentence are gone by design; writing them
    # back is deterministic, where reading them was not. The trailing one also
    # matches the app's own paste, so the next dictation does not land flush.
    if expected_after is None:
        to_paste = result
    else:
        to_paste = (" " if expected_after else "") + result + " "

    how = replace_span(element, position, span_text, to_paste, expected_after)
    print(f"  DONE     replaced {len(span_text)} characters by {how}\n")


# ── hotkey plumbing ──────────────────────────────────────────────────────────

def main():
    from anthropic import AnthropicBedrock

    client = AnthropicBedrock(
        aws_access_key=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        aws_region="us-east-1")
    model = os.environ.get("SEAM_MODEL", "us.anthropic.claude-haiku-4-5-20251001-v1:0")

    repo = os.path.expanduser("~/Developer/EnviousLabs/EnviousWispr")
    swift = os.path.join(repo, "Sources/EnviousWisprLLM/Prompting/CloudFixedPromptBuilder.swift")
    match = re.search(r'cloudFixedSystemPrompt = """\n(.*?)\n\s*"""',
                      open(swift, encoding="utf-8").read(), re.DOTALL)
    if not match:
        print("could not read the shipped polish prompt", file=sys.stderr)
        return 1
    system = match.group(1) + JOIN_NOTE

    print("\n  Seam-join prototype — running\n")
    print("  1. click into a REAL text box (Notes, Slack, Mail, a browser)")
    print("     it will refuse to touch a terminal, including this one")
    print("  2. dictate a half thought, pause, dictate the rest")
    print("  3. hold LEFT control + option + command, then let go")
    print("\n  Ctrl-C to stop.\n")

    busy = {"now": False}

    def on_event(proxy, event_type, event, refcon):
        held = (Quartz.CGEventGetFlags(event) & CHORD) == CHORD
        if held and not busy["now"]:
            busy["now"] = True

            def run():
                # Wait for release: backspaces posted while command is held
                # become command-delete and wipe the whole line.
                while (Quartz.CGEventSourceFlagsState(
                        Quartz.kCGEventSourceStateHIDSystemState) & CHORD):
                    time.sleep(0.03)
                time.sleep(0.15)
                print("  ── triggered")
                try:
                    do_join(client, model, system)
                except Exception as exc:
                    print(f"  FAILED   {type(exc).__name__}: {exc}\n")
                busy["now"] = False

            threading.Thread(target=run, daemon=True).start()
        return event

    tap = Quartz.CGEventTapCreate(
        Quartz.kCGSessionEventTap, Quartz.kCGHeadInsertEventTap,
        Quartz.kCGEventTapOptionListenOnly,
        Quartz.CGEventMaskBit(Quartz.kCGEventFlagsChanged), on_event, None)
    if not tap:
        print("Could not listen for the hotkey. Give Terminal Accessibility "
              "permission in System Settings > Privacy & Security.", file=sys.stderr)
        return 1
    Quartz.CFRunLoopAddSource(
        Quartz.CFRunLoopGetCurrent(),
        Quartz.CFMachPortCreateRunLoopSource(None, tap, 0),
        Quartz.kCFRunLoopCommonModes)
    Quartz.CGEventTapEnable(tap, True)
    Quartz.CFRunLoopRun()
    return 0


if __name__ == "__main__":
    sys.exit(main())
