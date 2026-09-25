#!/usr/bin/env python3
"""Render marketing-friendly GitHub release notes from the in-app What's New copy.

Single source of truth: Sources/EnviousWisprAppKit/Views/Settings/WhatsNewContent.swift
(the same copy users see in Settings > What's New). This script extracts the entries
for one version and emits a flat, plain-English markdown list for the GitHub release body.

Entries render in SOURCE ORDER: whatever order the author placed them in the Swift
`entries` array is the order the reader gets, here and in the app. There is no category
grouping (removed 2026-07-11 — the six generic headings repeated down every release and
carried no information). Source order IS the hierarchy, so a version must be authored
headline-feature-first.

Parse contract: `title`, `description`, and `version` must be direct, ordinary
double-quoted Swift literals. This script reads Swift source TEXT, it does not compile it.
A raw string or a named constant makes the entry fail to parse (--self-test catches that,
because it asserts the parsed count matches the number of `version:` fields). Concatenation
silently captures only the first segment, and interpolation emits unresolved Swift source:
NEITHER is caught by the count check, so both would ship wrong text. Validate by comparing
parsed values against expected strings, not by counting items alone.

The optional `bullets:` field (#2484) is a Swift array literal of the same direct
double-quoted literals, written between `description:` and `version:` (the order the
Swift initialiser fixes), on one line or one bullet per line:

    bullets: ["First point", "Second point"],

Absent means no list. Each bullet renders as an indented markdown sub-bullet under its
entry's line and is normalised exactly like `description` (a backslash line-continuation
or any run of whitespace becomes one space). The array is read STRICTLY: any token
between `[` and `]` that is not a string literal, a comma or whitespace (a named constant,
`+`, a raw string, a comment) makes the WHOLE array unreadable, which `empty_fields`
turns into a hard failure. A partial read would be the silent failure this file exists
to prevent: a list one item shorter than the one the app shows, with every count green.

The in-app screen is translated through the String Catalog (#3142). `--catalog-seed-json`
gives every entry field its catalog key and English value, in source order:
`whatsNew.<id>.title`, `whatsNew.<id>.description` and `whatsNew.<id>.bullet.<n>` (n counts
from 0). A bullet's key is its POSITION, not its text: editing a bullet keeps its key and
changes its English, which is what lets the catalog sync mark an existing translation for
review. The entry `id:` must be a direct literal of lowercase words joined by hyphens,
written before `title:`, and unique; the seed refuses any entry it cannot key, and any entry
`--self-test` would refuse. Entries are read only inside the `static let entries = [...]`
array, outside comments and ordinary string literals. Known limit: a Swift RAW string
(a `#` before the opening quote, single-line or multiline) anywhere in the file can confuse the literal scanner; the parse
contract already forbids raw strings in entries, and the failure is loud (a dropped-entry
or count refusal), never a silently shorter seed.

Used by .github/workflows/release.yml. Designed to fail SAFELY: if it cannot produce
notes for the requested version, it exits non-zero and the workflow falls back to
GitHub's auto-generated notes, so a release is never blocked or shipped blank.

Usage:
  render-release-notes.py --version 2.1.4 [--swift-file PATH] [--out FILE]
  render-release-notes.py --list
  render-release-notes.py --self-test   # parse + assert currentContentVersion renders
  render-release-notes.py --catalog-seed-json   # catalog key -> English, source order
"""
import argparse
import collections
import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_SWIFT = os.path.join(
    REPO_ROOT, "Sources/EnviousWisprAppKit/Views/Settings/WhatsNewContent.swift"
)
CONSTANTS_SWIFT = os.path.join(
    REPO_ROOT, "Sources/EnviousWisprCore/WhatsNewConstants.swift"
)

def parse_entries(swift_path):
    with open(swift_path, encoding="utf-8") as fh:
        text = fh.read()
    # Split on `Entry(` boundaries: each chunk after the first holds exactly one
    # entry's fields at its start. This is robust to the `// MARK:` comments
    # between version sections (a previous lookahead-based regex over-extended
    # across those comments and silently swallowed the first entry of each older
    # version section).
    #
    # Every boundary and label is found in the MASKED text (string literals and comments
    # blanked, positions kept), so an `Entry(`, `title:` or `version: "1.2.3"` inside a
    # comment or a string is never read as the entry's own; each value is then read from
    # the original text right after its label.
    masked_text = mask_literals_and_comments(text)
    first, last = entries_region(masked_text)
    calls = list(re.compile(r"Entry\(").finditer(masked_text, first, last))
    entries = []
    for n, call in enumerate(calls):
        end = calls[n + 1].start() if n + 1 < len(calls) else last
        chunk, masked = text[call.end():end], masked_text[call.end():end]
        t = labelled_literal(chunk, masked, "title", FIELD_LITERAL)
        d = labelled_literal(chunk, masked, "description", FIELD_LITERAL)
        v = labelled_literal(chunk, masked, "version", VERSION_LITERAL)
        if not (t and d and v):
            continue
        # `bullets:` is looked for only BEFORE `version:`. That is where the Swift
        # initialiser puts it, and bounding the search there keeps the parser inside
        # the entry's own argument list: the chunk runs on to the next `Entry(`, so
        # it also holds the comments above the NEXT entry, and a comment that merely
        # mentions `bullets: [...]` must not become a phantom list on this one.
        bullets = parse_bullets(chunk[: v[0]])
        # `id:` is looked for only BEFORE `title:`, where the initialiser puts it, for
        # the same reason: the chunk also holds the comments above the next entry.
        entry_id = parse_id(chunk[: t[0]])
        entries.append(
            {
                # Parser state for the catalog seed only; `public_values` leaves it out,
                # so `--dump-json` and the release notes are unchanged.
                "id": entry_id,
                "title": normalise_literal(t[1]),
                "desc": normalise_literal(d[1]),
                "version": v[1],
                # Absent in source is the same as `bullets: []`, so every entry
                # written before #2484 parses and renders exactly as it did.
                "bullets": bullets if bullets is not None else [],
                # Parser state, not content: the field is in the source but could
                # not be read (see `parse_bullets`). Consumed by `empty_fields` and
                # never dumped, since the app compiles no such value to compare.
                "bullets_unreadable": bullets is None,
            }
        )
    return entries


FIELD_LITERAL = re.compile(r'\s*"((?:[^"\\]|\\.)*)"', re.DOTALL)
VERSION_LITERAL = re.compile(r'\s*"([\d.]+)"')


ENTRIES_DECLARATION = re.compile(r"\bstatic\s+let\s+entries\b[^=\n]*=\s*\[")


def entries_region(masked):
    """(start, end) of the `static let entries = [ ... ]` array in the masked source, so an
    `Entry(` or `version:` elsewhere in the file (a helper, an example) is never read as a
    What's New entry. A source with no such declaration (the parser fixtures) is read whole."""
    declaration = ENTRIES_DECLARATION.search(masked)
    if not declaration:
        return 0, len(masked)
    depth = 1
    for i in range(declaration.end(), len(masked)):
        if masked[i] == "[":
            depth += 1
        elif masked[i] == "]":
            depth -= 1
            if depth == 0:
                return declaration.end(), i
    return declaration.end(), len(masked)


def labelled_literal(chunk, masked, name, literal):
    """The entry's own `name:` argument: its label found in `masked` (comments and strings
    blanked), its value the literal right after that label in `chunk`, as (label start,
    value). None when the label is missing or not followed by a readable literal. The label
    start bounds the id and bullets searches."""
    label = re.search(rf"\b{name}:", masked)
    if not label:
        return None
    value = literal.match(chunk, label.end())
    return (label.start(), value.group(1)) if value else None


def normalise_literal(raw):
    """One literal's captured text as the reader sees it: an escaped quote becomes a
    quote, a backslash line-continuation and any run of whitespace become one space,
    both ends are trimmed. The same rule for title, description and each bullet."""
    text = raw.replace('\\"', '"')
    text = re.sub(r"\s*\\\s*\n\s*", " ", text)
    return re.sub(r"\s+", " ", text).strip()


BULLETS_OPEN = re.compile(r"bullets:\s*\[")
STRING_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"', re.DOTALL)


def mask_literals_and_comments(fields):
    """`fields` with every string literal, `//` comment and `/* */` comment replaced by
    spaces (newlines kept, so positions and line anchors still index the original), so a
    search over it sees only the entry's own argument syntax. One left-to-right scan, so
    each form is read in its own context: a `//` or `/*` inside a string is prose, a quote
    inside a comment is not a string, and block comments nest as Swift nests them."""
    out = list(fields)
    i, n = 0, len(fields)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        if fields[i] == '"':
            j = i + 1
            while j < n and fields[j] != '"':
                j += 2 if fields[j] == "\\" else 1
            j = min(j + 1, n)
            blank(i, j)
            i = j
        elif fields.startswith("//", i):
            j = fields.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif fields.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if fields.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif fields.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        else:
            i += 1
    return "".join(out)


# No trailing `\s*` on the label: in the masked text the literal itself is spaces, and
# the literal is matched in the ORIGINAL text from the label's end.
ID_FIELD = re.compile(r"\bid:")
ID_LITERAL = re.compile(r'\s*"((?:[^"\\]|\\.)*)"\s*,')


def parse_id(fields):
    """The entry's `id:` when it is ONE direct literal ending its argument, else None.
    The label is found in the masked text, so an `id:` inside a comment or a string is
    never the entry's own; the literal must then be followed by the argument comma, so
    `"short" + "suffix"` or a named constant reads as no id rather than a wrong one."""
    label = ID_FIELD.search(mask_literals_and_comments(fields))
    if not label:
        return None
    literal = ID_LITERAL.match(fields, label.end())
    return literal.group(1) if literal else None


def parse_bullets(fields):
    """The entry's `bullets:` array: `[]` when the field is absent, the normalised
    bullets in source order when it reads cleanly, or `None` when the field is
    present but this parser cannot read it.

    Walks the array body token by token rather than regexing string literals out of
    it, because the failure to avoid is a PARTIAL read: `["a", b]` must not become
    `["a"]` with every assertion green. So anything between `[` and `]` that is not
    a string literal, a comma or whitespace makes the whole array unreadable, and so
    does a missing `]`. A `]` inside a bullet's text is fine: the literal is consumed
    before the closer is looked for.
    """
    # Found in the argument SYNTAX only. A description whose prose happens to contain
    # `bullets: [one, two]` is a string literal, and searching the raw text would read
    # the words inside it as a field that cannot be parsed, which `empty_fields` then
    # turns into a refusal of the whole release's notes. The mask keeps every offset,
    # so `m.end()` indexes the original text and the walk below reads the real array.
    m = BULLETS_OPEN.search(mask_literals_and_comments(fields))
    if not m:
        return []
    pos = m.end()
    bullets = []
    while pos < len(fields):
        ch = fields[pos]
        if ch.isspace() or ch == ",":
            pos += 1
            continue
        if ch == "]":
            # The closer must be the END of the argument: only whitespace, a comment and
            # the argument's own comma may follow it before `version:` (where `fields`
            # ends). `["First"] + ["Second"]` is a valid Swift expression, and returning
            # at the first `]` read it as one bullet and let the release path exit 0 with
            # half the list (Codex, #2680). Anything else there makes the array unreadable.
            trailing = mask_literals_and_comments(fields[pos + 1:]).strip()
            return bullets if trailing in ("", ",") else None
        if ch != '"':
            return None
        lit = STRING_LITERAL.match(fields, pos)
        if not lit:
            return None
        bullets.append(normalise_literal(lit.group(1)))
        pos = lit.end()
    return None


def version_key(v):
    return tuple(int(x) for x in v.split("."))


def render(entries, version):
    # Flat list in SOURCE ORDER — `parse_entries` walks the Swift file top-to-bottom,
    # and `filter` preserves that order, so the author's sequence is the reader's.
    # No sorting or grouping happens here by design.
    es = [e for e in entries if e["version"] == version]
    if not es:
        return None
    out = []
    for e in es:
        title = e["title"].rstrip()
        if title and title[-1] not in ".!?":
            title += "."
        out.append(f"- **{title}** {e['desc']}")
        # Two-space indent nests each one under the entry's bullet on GitHub.
        out.extend(f"  - {bullet}" for bullet in e["bullets"])
    rendered = "\n".join(out).strip()
    return rendered or None


def empty_fields(entries):
    """Entries whose title or description parsed EMPTY, as `version: title` strings.

    A field this parser cannot read still MATCHES its regex with a zero-length capture,
    so the entry parses, the count check is satisfied, and the text is gone. Measured on
    v2.4.5 (#2234), whose headline entry was a multiline literal and rendered as a bare
    title while both existing assertions passed.

    An OUTCOME check rather than a syntax allow-list: the protocol's list of prohibited
    forms has been wrong twice about which forms exist, and "no entry renders empty"
    holds whatever syntax the next author reaches for.

    Bullets (#2484) get the same outcome check for the same reason: a `bullets:` array
    this parser cannot read would otherwise parse as NO bullets, the entry still parses,
    the count check still passes, and the list the app shows is simply missing from the
    release page. So an unreadable array, or any bullet that parsed blank, fails here.
    """
    return [
        f"{e['version']}: {e['title'][:60] or '(no title)'}"
        for e in entries
        if not e["desc"].strip()
        or not e["title"].strip()
        or e["bullets_unreadable"]
        or any(not b.strip() for b in e["bullets"])
    ]


def empty_fields_message(empty):
    return (
        "error: %d entr%s parsed with an empty title, description or bullet, or a "
        "bullets array this parser could not read — the field is present in the "
        "source but its text is not (a multiline, concatenated, interpolated or raw "
        "literal, or something other than a string literal inside `bullets: [...]`). "
        "Rewrite it as direct double-quoted literals:\n  %s"
        % (len(empty), "y" if len(empty) == 1 else "ies", "\n  ".join(empty))
    )


def public_values(entries):
    """The parsed values the app also compiles, in source order: what `--dump-json`
    emits and what `WhatsNewContentTests` compares against `WhatsNewContent.entries`
    field by field. Parser state such as `bullets_unreadable` stays out."""
    return [{k: e[k] for k in ("title", "desc", "version", "bullets")} for e in entries]


ENTRY_ID = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\Z")


def dropped_entries(entries, swift_path):
    """An error message when the parse dropped entries, else None. The parsed count must
    equal BOTH the literal `version:` fields and the `Entry(` calls: an entry whose version
    is not a literal drops out of the parse AND the version count together, so only the
    call count still sees it."""
    with open(swift_path, encoding="utf-8") as fh:
        source = fh.read()
    # Both counted in the masked source: a `version: "1.2.3"` or `Entry(` inside a comment
    # or a string is not an entry's. A version label counts when a literal follows it.
    # Both read only inside the entries array, where `parse_entries` reads.
    masked = mask_literals_and_comments(source)
    first, last = entries_region(masked)
    field_count = sum(
        1 for label in re.compile(r"\bversion:").finditer(masked, first, last)
        if VERSION_LITERAL.match(source, label.end())
    )
    call_count = len(re.compile(r"(?m)^[ \t]*Entry\(").findall(masked, first, last))
    if len(entries) != field_count or len(entries) != call_count:
        return (
            f"error: parsed {len(entries)} entries but the source has {field_count} "
            f"version fields and {call_count} Entry( calls; the parser dropped entries (drift)"
        )
    return None


def seed_for_catalog(swift_path):
    """(seed, error): the complete catalog seed for a source file, or the refusal message.
    What `--catalog-seed-json` runs, so its fixtures exercise the real refusal path."""
    entries = parse_entries(swift_path)
    if not entries:
        return None, "error: parsed 0 entries from What's New source"
    dropped = dropped_entries(entries, swift_path)
    if dropped:
        return None, dropped
    seed, problems = catalog_seed(entries)
    if problems:
        return None, seed_problems_message(problems)
    return seed, None


def catalog_seed(entries):
    """(seed, problems): each field's catalog key and English value in source order, and
    one line per entry that cannot be keyed. A seed is usable only when problems is empty;
    a partial seed would drop fields from the catalog with every check green."""
    seed = {}
    problems = []
    seen = set()
    for e in entries:
        label = f"{e['version']}: {e['title'][:60] or '(no title)'}"
        entry_id = e["id"]
        if entry_id is None:
            problems.append(f"{label}: no readable `id:` literal before `title:`")
            continue
        if not ENTRY_ID.match(entry_id):
            problems.append(f"{label}: id {entry_id!r} is not lowercase words joined by hyphens")
            continue
        if entry_id in seen:
            problems.append(f"{label}: id {entry_id!r} is used by an earlier entry")
            continue
        seen.add(entry_id)
        seed[f"whatsNew.{entry_id}.title"] = e["title"]
        seed[f"whatsNew.{entry_id}.description"] = e["desc"]
        for n, bullet in enumerate(e["bullets"]):
            seed[f"whatsNew.{entry_id}.bullet.{n}"] = bullet
    problems.extend(f"{line}: empty or unreadable field" for line in empty_fields(entries))
    return seed, problems


# Two-way controls for the parser, run by `--self-test` before the real content.
# Each case is (label, Swift source text, expected parse, expected render of 9.9.9,
# expected `empty_fields` outcome). The expected parse pins VALUES rather than counts,
# because a count is exactly what a zero-length capture satisfies. Each fixture is
# written the way an author writes an entry, indentation included, and exercises one
# spelling the parse contract allows or one it must refuse.
FIXTURE_CASES = [
    (
        "no bullets field parses as an empty list and renders as before",
        '''
    Entry(
      id: "plain",
      icon: "sparkles",
      title: "A plain entry",
      description:
        "One paragraph, no list.",
      version: "9.9.9"
    ),
''',
        [{"title": "A plain entry", "desc": "One paragraph, no list.",
          "version": "9.9.9", "bullets": []}],
        "- **A plain entry.** One paragraph, no list.",
        [],
    ),
    (
        "two bullets render as two indented sub-bullets",
        '''
    Entry(
      id: "listed",
      icon: "list.bullet",
      title: "An entry with a list",
      description: "The paragraph above the list.",
      bullets: [
        "First point",
        "Second point",
      ],
      version: "9.9.9"
    ),
''',
        [{"title": "An entry with a list", "desc": "The paragraph above the list.",
          "version": "9.9.9", "bullets": ["First point", "Second point"]}],
        "- **An entry with a list.** The paragraph above the list.\n"
        "  - First point\n"
        "  - Second point",
        [],
    ),
    (
        "a one-line array, with an escaped quote and brackets inside a bullet",
        r'''
    Entry(
      id: "inline",
      icon: "sparkles",
      title: "Inline",
      description: "Desc.",
      bullets: ["Say \"hi\"", "Keys [Option] and ]"],
      version: "9.9.9"
    ),
''',
        [{"title": "Inline", "desc": "Desc.", "version": "9.9.9",
          "bullets": ['Say "hi"', "Keys [Option] and ]"]}],
        '- **Inline.** Desc.\n  - Say "hi"\n  - Keys [Option] and ]',
        [],
    ),
    (
        "a bullet literal spanning lines is normalised like a description",
        r'''
    Entry(
      id: "wrapped",
      icon: "sparkles",
      title: "Wrapped",
      description: "Desc.",
      bullets: [
        "A bullet   whose text \
         continues on the next line",
      ],
      version: "9.9.9"
    ),
''',
        [{"title": "Wrapped", "desc": "Desc.", "version": "9.9.9",
          "bullets": ["A bullet whose text continues on the next line"]}],
        "- **Wrapped.** Desc.\n  - A bullet whose text continues on the next line",
        [],
    ),
    (
        "a named constant inside the array is refused, not partially read",
        '''
    Entry(
      id: "constant",
      icon: "sparkles",
      title: "Constant",
      description: "Desc.",
      bullets: ["Readable", Copy.secondBullet],
      version: "9.9.9"
    ),
''',
        [{"title": "Constant", "desc": "Desc.", "version": "9.9.9", "bullets": []}],
        "- **Constant.** Desc.",
        ["9.9.9: Constant"],
    ),
    (
        "a concatenated bullet is refused",
        '''
    Entry(
      id: "concat",
      icon: "sparkles",
      title: "Concat",
      description: "Desc.",
      bullets: ["First " + "second"],
      version: "9.9.9"
    ),
''',
        [{"title": "Concat", "desc": "Desc.", "version": "9.9.9", "bullets": []}],
        "- **Concat.** Desc.",
        ["9.9.9: Concat"],
    ),
    (
        "a raw-string bullet is refused",
        '''
    Entry(
      id: "raw",
      icon: "sparkles",
      title: "Raw",
      description: "Desc.",
      bullets: [#"Raw text"#],
      version: "9.9.9"
    ),
''',
        [{"title": "Raw", "desc": "Desc.", "version": "9.9.9", "bullets": []}],
        "- **Raw.** Desc.",
        ["9.9.9: Raw"],
    ),
    (
        "an array extended by another expression after its closer is refused, not truncated",
        '''
    Entry(
      id: "extended",
      icon: "sparkles",
      title: "Extended",
      description: "Desc.",
      bullets: ["First"] + ["Second"],
      version: "9.9.9"
    ),
''',
        [{"title": "Extended", "desc": "Desc.", "version": "9.9.9", "bullets": []}],
        "- **Extended.** Desc.",
        ["9.9.9: Extended"],
    ),
    (
        "a comment after the closer is not an extension of the array",
        '''
    Entry(
      id: "commented",
      icon: "sparkles",
      title: "Commented",
      description: "Desc.",
      bullets: ["Only"], // + ["never"]
      version: "9.9.9"
    ),
''',
        [{"title": "Commented", "desc": "Desc.", "version": "9.9.9", "bullets": ["Only"]}],
        "- **Commented.** Desc.\n  - Only",
        [],
    ),
    (
        "an array with no closing bracket before version is refused",
        '''
    Entry(
      id: "open",
      icon: "sparkles",
      title: "Open",
      description: "Desc.",
      bullets: ["Never closed",
      version: "9.9.9"
    ),
''',
        [{"title": "Open", "desc": "Desc.", "version": "9.9.9", "bullets": []}],
        "- **Open.** Desc.",
        ["9.9.9: Open"],
    ),
    (
        "a blank bullet is refused",
        '''
    Entry(
      id: "blank",
      icon: "sparkles",
      title: "Blank",
      description: "Desc.",
      bullets: ["Present", "   "],
      version: "9.9.9"
    ),
''',
        [{"title": "Blank", "desc": "Desc.", "version": "9.9.9",
          "bullets": ["Present", ""]}],
        # `render` strips the whole body, so the blank last line loses its space.
        "- **Blank.** Desc.\n  - Present\n  -",
        ["9.9.9: Blank"],
    ),
    (
        "a description that mentions bullets: [...] in prose is not a bullets field",
        '''
    Entry(
      id: "prose",
      icon: "sparkles",
      title: "Prose",
      description: "Format bullets: [one, two] the way you like.",
      version: "9.9.9"
    ),
''',
        [{"title": "Prose", "desc": "Format bullets: [one, two] the way you like.",
          "version": "9.9.9", "bullets": []}],
        "- **Prose.** Format bullets: [one, two] the way you like.",
        [],
    ),
    (
        "a real bullets field after a description that mentions one is still read",
        '''
    Entry(
      id: "both",
      icon: "sparkles",
      title: "Both",
      description: "Mentions bullets: [not these].",
      // bullets: ["not this either"]
      bullets: ["The real one"],
      version: "9.9.9"
    ),
''',
        [{"title": "Both", "desc": "Mentions bullets: [not these].",
          "version": "9.9.9", "bullets": ["The real one"]}],
        "- **Both.** Mentions bullets: [not these].\n  - The real one",
        [],
    ),
    (
        "bullets on one entry do not leak into the next, nor out of a comment",
        '''
    Entry(
      id: "with",
      icon: "sparkles",
      title: "With",
      description: "Desc.",
      bullets: ["Only mine"],
      version: "9.9.9"
    ),

    // MARK: - v9.9.8

    // Written without bullets: ["Not a bullet"] on purpose.
    Entry(
      id: "without",
      icon: "sparkles",
      title: "Without",
      description: "Desc.",
      version: "9.9.8"
    ),
''',
        [{"title": "With", "desc": "Desc.", "version": "9.9.9", "bullets": ["Only mine"]},
         {"title": "Without", "desc": "Desc.", "version": "9.9.8", "bullets": []}],
        "- **With.** Desc.\n  - Only mine",
        [],
    ),
]


# Whole-file outcomes through `seed_for_catalog`, the path `--catalog-seed-json` runs:
# (label, Swift source text, expected start of the refusal message, or None for a seed).
SEED_REFUSALS = [
    (
        "an Entry( outside the entries array is not a What's New entry",
        '''
enum WhatsNewContent {
  static let entries: [Entry] = [
    Entry(
      id: "real",
      icon: "sparkles",
      title: "Real title",
      description: "Real paragraph.",
      bullets: ["Point [one]"],
      version: "9.9.9"
    ),
  ]

  static let demo = Entry(
    id: "demo", icon: "sparkles", title: "Demo", description: "Not shipped.",
    version: "1.0.0")
}
''',
        None,
    ),
    (
        "a version or title example inside comments is not an entry's field",
        '''
    // An entry reads like this: version: "1.2.3", title: "Example"
    /* Another example: version: "4.5.6" */
    Entry(
      id: "real",
      icon: "sparkles",
      // title: "Commented title",
      title: "Real title",
      description: "Real paragraph.",
      version: "9.9.9"
    ),
''',
        None,
    ),
    (
        "an Entry( inside a block comment is not counted as an entry",
        '''
    Entry(
      id: "only",
      icon: "sparkles",
      title: "Only",
      description: "The one real entry.",
      version: "9.9.9"
    ),
    /*
    Entry(
    */
''',
        None,
    ),
    (
        "an entry whose version is not a literal drops out, and the seed refuses the file",
        '''
    Entry(
      id: "kept",
      icon: "sparkles",
      title: "Kept",
      description: "Literal version.",
      version: "9.9.9"
    ),
    Entry(
      id: "computed",
      icon: "sparkles",
      title: "Computed",
      description: "Named-constant version.",
      version: Copy.version
    ),
''',
        "error: parsed 1 entries but the source has 1 version fields and 2 Entry( calls",
    ),
]


def seed_problems_message(problems):
    return "error: %d What's New entr%s cannot be given catalog keys:\n  %s" % (
        len(problems),
        "y" if len(problems) == 1 else "ies",
        "\n  ".join(problems),
    )


# Two-way controls for `catalog_seed`. Each case is (label, Swift source text, expected
# seed, expected problems). The expected seed pins every key AND value, in order.
SEED_CASES = [
    (
        "an entry with two bullets keys its title, description and each bullet by position",
        '''
    Entry(
      id: "two-points",
      icon: "sparkles",
      title: "Two points",
      description: "Has a list.",
      bullets: ["First point", "Second point"],
      version: "9.9.9"
    ),
''',
        {
            "whatsNew.two-points.title": "Two points",
            "whatsNew.two-points.description": "Has a list.",
            "whatsNew.two-points.bullet.0": "First point",
            "whatsNew.two-points.bullet.1": "Second point",
        },
        [],
    ),
    (
        "an edited second bullet keeps its key and carries the new English",
        '''
    Entry(
      id: "two-points",
      icon: "sparkles",
      title: "Two points",
      description: "Has a list.",
      bullets: ["First point", "Second point, reworded"],
      version: "9.9.9"
    ),
''',
        {
            "whatsNew.two-points.title": "Two points",
            "whatsNew.two-points.description": "Has a list.",
            "whatsNew.two-points.bullet.0": "First point",
            "whatsNew.two-points.bullet.1": "Second point, reworded",
        },
        [],
    ),
    (
        "a second entry reusing an id is refused, the first is still keyed",
        '''
    Entry(
      id: "same",
      icon: "sparkles",
      title: "First",
      description: "One.",
      version: "9.9.9"
    ),
    Entry(
      id: "same",
      icon: "sparkles",
      title: "Second",
      description: "Two.",
      version: "9.9.9"
    ),
''',
        {"whatsNew.same.title": "First", "whatsNew.same.description": "One."},
        ["9.9.9: Second: id 'same' is used by an earlier entry"],
    ),
    (
        "an entry with no id is refused, and a later entry's comment cannot lend it one",
        '''
    Entry(
      icon: "sparkles",
      title: "Nameless",
      description: "No id.",
      version: "9.9.9"
    ),

    // The next entry, id: "borrowed", is documented here.
    Entry(
      id: "next",
      icon: "sparkles",
      title: "Next",
      description: "Keyed.",
      version: "9.9.9"
    ),
''',
        {"whatsNew.next.title": "Next", "whatsNew.next.description": "Keyed."},
        ["9.9.9: Nameless: no readable `id:` literal before `title:`"],
    ),
    (
        "an id that is not lowercase words joined by hyphens is refused",
        '''
    Entry(
      id: "Bad.ID",
      icon: "sparkles",
      title: "Odd id",
      description: "Refused.",
      version: "9.9.9"
    ),
''',
        {},
        ["9.9.9: Odd id: id 'Bad.ID' is not lowercase words joined by hyphens"],
    ),
    (
        "an id in a comment is not the entry's id, and a named constant is no id",
        '''
    Entry(
      // was id: "borrowed", before the rename
      id: Copy.entryID,
      icon: "sparkles",
      title: "Constant id",
      description: "Refused.",
      version: "9.9.9"
    ),
''',
        {},
        ["9.9.9: Constant id: no readable `id:` literal before `title:`"],
    ),
    (
        "an id inside a block comment is not the entry's id",
        '''
    Entry(
      /* id: "old", */
      id: "actual",
      icon: "sparkles",
      title: "Block comment",
      description: "Keyed by its real id.",
      version: "9.9.9"
    ),
''',
        {
            "whatsNew.actual.title": "Block comment",
            "whatsNew.actual.description": "Keyed by its real id.",
        },
        [],
    ),
    (
        "an id inside a nested block comment is not the entry's id",
        '''
    Entry(
      /* outer /* inner */ id: "old", */
      id: "actual",
      icon: "sparkles",
      title: "Nested comment",
      description: "Keyed by its real id.",
      version: "9.9.9"
    ),
''',
        {
            "whatsNew.actual.title": "Nested comment",
            "whatsNew.actual.description": "Keyed by its real id.",
        },
        [],
    ),
    (
        "a concatenated id is refused rather than read as its first piece",
        '''
    Entry(
      id: "short" + "suffix",
      icon: "sparkles",
      title: "Joined id",
      description: "Refused.",
      version: "9.9.9"
    ),
''',
        {},
        ["9.9.9: Joined id: no readable `id:` literal before `title:`"],
    ),
    (
        "an entry the release notes would refuse is refused by the seed too",
        '''
    Entry(
      id: "unreadable",
      icon: "sparkles",
      title: "Unreadable list",
      description: "Has a constant.",
      bullets: ["Readable", Copy.second],
      version: "9.9.9"
    ),
''',
        {
            "whatsNew.unreadable.title": "Unreadable list",
            "whatsNew.unreadable.description": "Has a constant.",
        },
        ["9.9.9: Unreadable list: empty or unreadable field"],
    ),
]


def self_test_fixtures():
    """Run FIXTURE_CASES and SEED_CASES; one line per failed assertion, empty when all pass."""
    import tempfile

    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "fixture.swift")
        for label, source, want_entries, want_body, want_empty in FIXTURE_CASES:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(source)
            entries = parse_entries(path)
            got = public_values(entries)
            if got != want_entries:
                failures.append(f"[{label}] parsed {got!r}, wanted {want_entries!r}")
            body = render(entries, "9.9.9")
            if body != want_body:
                failures.append(f"[{label}] rendered {body!r}, wanted {want_body!r}")
            empty = empty_fields(entries)
            if empty != want_empty:
                failures.append(f"[{label}] empty_fields {empty!r}, wanted {want_empty!r}")
        for label, source, want_seed, want_problems in SEED_CASES:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(source)
            seed, problems = catalog_seed(parse_entries(path))
            if list(seed.items()) != list(want_seed.items()):
                failures.append(f"[{label}] seed {seed!r}, wanted {want_seed!r}")
            if problems != want_problems:
                failures.append(f"[{label}] problems {problems!r}, wanted {want_problems!r}")
        for label, source, want_error in SEED_REFUSALS:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(source)
            seed, error = seed_for_catalog(path)
            if want_error is None:
                if error is not None or not seed:
                    failures.append(f"[{label}] seed {seed!r} error {error!r}, wanted a seed")
                elif seed.get("whatsNew.real.title", "Real title") != "Real title":
                    failures.append(f"[{label}] title {seed['whatsNew.real.title']!r}, wanted 'Real title'")
                elif any(".demo." in k for k in seed):
                    failures.append(f"[{label}] seeded an entry outside the array: {sorted(seed)!r}")
            elif seed is not None or not (error or "").startswith(want_error):
                failures.append(f"[{label}] seed {seed!r} error {error!r}, wanted {want_error!r}")
    return failures


def current_content_version():
    try:
        with open(CONSTANTS_SWIFT, encoding="utf-8") as fh:
            source = fh.read()
        # The declaration is found outside comments and strings, its literal read after it.
        label = re.search(r"\bcurrentContentVersion\s*=", mask_literals_and_comments(source))
        value = VERSION_LITERAL.match(source, label.end()) if label else None
        return value.group(1) if value else None
    except OSError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version")
    ap.add_argument("--swift-file", default=DEFAULT_SWIFT)
    ap.add_argument("--out")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument(
        "--dump-json",
        action="store_true",
        help="emit parsed entry values for the compiled-value Swift test",
    )
    ap.add_argument(
        "--catalog-seed-json",
        action="store_true",
        help="emit each field's String Catalog key and English value, in source order",
    )
    args = ap.parse_args()

    entries = parse_entries(args.swift_file)
    if not entries:
        print("error: parsed 0 entries from What's New source", file=sys.stderr)
        return 2

    if args.dump_json:
        # Only the values the app compiles. An unreadable bullets array dumps as
        # `[]`, which the compiled-value comparison in WhatsNewContentTests then
        # rejects against the entry's real bullets, the same way a multiline
        # description dumps as "" and is rejected against the real text.
        json.dump(
            public_values(entries), sys.stdout, ensure_ascii=False, separators=(",", ":")
        )
        sys.stdout.write("\n")
        return 0

    if args.catalog_seed_json:
        # Refuses rather than emitting a partial seed: the catalog sync treats this
        # output as the complete set of What's New keys.
        seed, error = seed_for_catalog(args.swift_file)
        if error:
            print(error, file=sys.stderr)
            return 2
        json.dump(seed, sys.stdout, ensure_ascii=False, indent=1)
        sys.stdout.write("\n")
        return 0

    if args.list:
        versions = sorted({e["version"] for e in entries}, key=version_key, reverse=True)
        print("\n".join(versions))
        return 0

    if args.self_test:
        # Two-way controls on fixtures first: a parser only ever run on correct
        # input has never been seen to refuse anything.
        fixture_failures = self_test_fixtures()
        if fixture_failures:
            print(
                "error: %d fixture case%s failed:\n  %s"
                % (
                    len(fixture_failures),
                    "" if len(fixture_failures) == 1 else "s",
                    "\n  ".join(fixture_failures),
                ),
                file=sys.stderr,
            )
            return 2
        # Integrity check: every entry has exactly one `version:` field, so the
        # number of parsed entries must equal the number of version fields in the
        # source. A mismatch means the parser dropped entries (e.g. the MARK-comment
        # swallowing bug), even if individual versions still render.
        dropped = dropped_entries(entries, args.swift_file)
        if dropped:
            print(dropped, file=sys.stderr)
            return 2
        # PER-ENTRY completeness, not just per-VERSION presence (#2234).
        # Shared with the RENDER path below — cloud review r1 P2: this check only
        # protected `--self-test`, which runs weekly, while the release workflow
        # invokes `--version`, which would still have emitted a bare-title bullet.
        empty = empty_fields(entries)
        if empty:
            print(empty_fields_message(empty), file=sys.stderr)
            return 2
        # Every real entry must also be keyable for the catalog (#3142), so a bad or
        # repeated id fails here as well as in the catalog sync.
        _, problems = catalog_seed(entries)
        if problems:
            print(seed_problems_message(problems), file=sys.stderr)
            return 2

        cv = current_content_version()
        if not cv:
            print("error: could not read currentContentVersion", file=sys.stderr)
            return 2
        body = render(entries, cv)
        if not body:
            print(
                f"error: no What's New entries render for currentContentVersion {cv}; "
                "the parser or the content may have drifted",
                file=sys.stderr,
            )
            return 2
        print(
            f"self-test OK: {len(entries)} entries parsed (matches source); "
            f"{cv} renders {sum(e['version'] == cv for e in entries)} item(s); "
            f"{len(FIXTURE_CASES)} fixture cases, {len(SEED_CASES)} seed cases and "
            f"{len(SEED_REFUSALS)} whole-file seed cases pass"
        )
        return 0

    if not args.version:
        print("error: --version is required", file=sys.stderr)
        return 2

    # The SAME completeness check on the PUBLISH path, not only in `--self-test`
    # (cloud review r1 P2 on PR #2235). `--self-test` runs weekly via
    # `ci-drift-check`; `.github/workflows/release.yml` renders with `--version`,
    # so a guard living only in the self-test would let a bare-title bullet ship
    # for up to a week — which is exactly how #2234 reached a release branch.
    #
    # FAILING HERE IS THE SAFE DIRECTION, and the workflow is already built for
    # it: that step is `continue-on-error: true` and its own comment says the
    # publish job "falls back to GitHub's auto-generated notes, so this step can
    # never block a release or ship it with a blank body". So a refusal costs an
    # auto-generated note plus a `::warning::`, where the alternative is
    # publishing a headline with no text under it.
    #
    # Scoped to the entries being RENDERED: an unrelated older entry that has
    # rotted must not block today's release.
    for_version = [e for e in entries if e["version"] == args.version]
    empty = empty_fields(for_version)
    if empty:
        print(empty_fields_message(empty), file=sys.stderr)
        return 2

    body = render(entries, args.version)
    if not body:
        print(
            f"error: no What's New entries for version {args.version}", file=sys.stderr
        )
        return 2

    text = f"## What's new in v{args.version}\n\n{body}\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(
            f"wrote {args.out} ({sum(e['version'] == args.version for e in entries)} item(s))",
            file=sys.stderr,
        )
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
