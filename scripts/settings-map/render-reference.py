#!/usr/bin/env python3
"""Renders reference/settings-map.md from the Settings Map export (#3482).

  render-reference.py <export.json> <out.md>
  render-reference.py --self-test

The export (reference/settings-map.json, written by SettingsMapExportTests) is the only input
and the only metadata authority; this script decides layout and escaping, nothing else. The
same export always renders the same bytes: no timestamp, no path outside the repository.
"""

import json
import re
import sys

LINK_ROOT = "../"  # the reference lives in reference/; sources are repo-relative


def fail(message):
    print(f"render-reference: {message}", file=sys.stderr)
    sys.exit(1)


def escape(text):
    """Markdown- and HTML-safe inline text, safe inside a table cell."""
    text = str(text)
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    text = text.replace("\\", "\\\\")
    for char in "`*_[]|#":
        text = text.replace(char, "\\" + char)
    return text.replace("\r\n", "<br>").replace("\n", "<br>").replace("\r", "<br>")


def anchor(node_id):
    return "node-" + re.sub(r"[^A-Za-z0-9-]", "-", node_id)


def code(text):
    """An id or key as inline code; ids never hold backticks, but refuse one rather than break."""
    if "`" in text or "\n" in text:
        fail(f"cannot render {text!r} as code")
    return f"`{text}`"


def title_text(title):
    source = title["source"]
    if source == "resource":
        return f"{escape(title['en'])} / {escape(title['de'])}"
    if source == "verbatim":
        return escape(title["text"])
    if source == "dynamic":
        return f"(named at runtime by {code(title['resolver'])})"
    fail(f"unknown title source {source!r}")


def description_text(description):
    if description is None:
        return "none"
    if description["source"] == "resource":
        return f"{escape(description['en'])} / {escape(description['de'])}"
    if description["source"] == "runtime":
        return "composed at display time from live state (not exported)"
    fail(f"unknown description source {description['source']!r}")


def source_cell(title):
    source = title["source"]
    if source == "resource":
        table = "" if title["table"] == "Localizable" else f" (table {code(title['table'])})"
        return f"catalog key {code(title['key'])}{table}"
    if source == "verbatim":
        return "product name"
    return f"resolver {code(title['resolver'])} in [{title['resolvedBy']}]({LINK_ROOT}{title['owner']})"


def destination_text(destination):
    if destination is None:
        return "none"
    tab = f" › {code(destination['tab'])}" if "tab" in destination else ""
    return f"{code(destination['page'])}{tab}"


def node_link(node_id, ids):
    if node_id not in ids:
        fail(f"link to unknown node {node_id}")
    return f"[{code(node_id)}](#{anchor(node_id)})"


def words(block):
    parts = []
    if block.get("words"):
        parts.append("words: " + ", ".join(escape(w) for w in block["words"]))
    if block.get("phrases"):
        parts.append("phrases: " + "; ".join(escape(p) for p in block["phrases"]))
    if block.get("phraseExemption"):
        parts.append("phrase exemption: " + escape(block["phraseExemption"]))
    return "<br>".join(parts) if parts else "none"


def render(document):
    if document.get("schema") != "settings-map-export" or document.get("version") != 2:
        fail("not a version 2 settings-map-export document")
    nodes = document["nodes"]
    ids = [n["id"] for n in nodes]
    if len(set(ids)) != len(ids):
        fail("an id appears twice")
    anchors = [anchor(i) for i in ids]
    if len(set(anchors)) != len(anchors):
        fail("two ids share an anchor")
    by_id = {n["id"]: n for n in nodes}
    children = {}
    for n in nodes:
        children.setdefault(n["parent"], []).append(n["id"])
    sources, fingerprints, counts = document["sources"], document["fingerprints"], document["counts"]
    other = [c for c in document["languages"] if c not in document["interfaceLanguages"]]

    out = [
        "# Settings Map",
        "",
        "Generated from the compiled Settings Map and the validated search vocabulary. Do not edit by hand.",
        "",
        "- Regenerate: `scripts/settings-map/export.sh`",
        "- Check: `scripts/settings-map/export.sh --check` (CI runs the same comparison)",
        f"- Map: [{sources['map']}]({LINK_ROOT}{sources['map']}); runtime titles: [{sources['titleResolver']}]({LINK_ROOT}{sources['titleResolver']})",
        f"- Interface text: [{sources['uiCatalog']}]({LINK_ROOT}{sources['uiCatalog']}) (English and German)",
        f"- Search vocabulary: [{sources['vocabulary']}]({LINK_ROOT}{sources['vocabulary']})",
        "- Machine-readable export with every field and all vocabulary: [settings-map.json](settings-map.json)",
        "- Authoring and review: [scripts/settings-map/README.md](../scripts/settings-map/README.md)",
        "",
        f"The interface ships in English and German. The other {len(other)} languages ({', '.join(other)}) are search metadata only: words and titles people may type, matched against the same places. Titles below read English / German.",
        "",
        f"{counts['nodes']} nodes, {counts['searchable']} searchable, {counts['vocabularyBlocks']} vocabulary blocks.",
        "",
        "Fingerprints: " + ", ".join(f"{k} {code(str(v))}" for k, v in sorted(fingerprints.items())),
        "",
        "## Structure",
        "",
    ]

    def tree(parent, depth):
        for child in children.get(parent, []):
            n = by_id[child]
            kind = n["kind"] or n["structure"]
            out.append(f"{'  ' * depth}- [{title_text(n['title'])}](#{anchor(child)}) {code(child)} ({escape(kind)})")
            tree(child, depth + 1)

    tree(None, 0)

    out += ["", "## Places", ""]
    for n in nodes:
        out.append(f'<a id="{anchor(n["id"])}"></a>')
        out.append("")
        out.append(f"### {title_text(n['title'])} ({code(n['id'])})")
        out.append("")
        out.append("| Field | Value |")
        out.append("|---|---|")
        rows = [
            ("Structure", escape(n["structure"])),
            ("Kind", escape(n["kind"]) if n["kind"] else "structure only, not searchable"),
            ("Parent", node_link(n["parent"], by_id) if n["parent"] else "none"),
            ("Title source", source_cell(n["title"])),
            ("Description", description_text(n["description"])),
            ("Destination", destination_text(n["destination"])),
            ("Dictionary tab", code(n["dictionaryTab"]) if n["dictionaryTab"] else "none"),
            ("Shown when", code(n["visibility"])),
            ("Arrival target", node_link(n["target"], by_id) if n["target"] else "none"),
            ("Fallbacks, in order", ", ".join(node_link(f, by_id) for f in n["fallbacks"]) or "none"),
            ("Declared in", f"[{n['declaredIn']}]({LINK_ROOT}{n['declaredIn']})"),
        ]
        if n["description"] and n["description"]["source"] == "resource":
            rows.insert(5, ("Description source", source_cell(n["description"])))
        for field, value in rows:
            out.append(f"| {field} | {value} |")
        vocabulary = n.get("vocabulary")
        if n["searchable"]:
            if not vocabulary or set(vocabulary) != set(document["languages"]):
                fail(f"{n['id']}: vocabulary is not complete")
            for code_ in document["interfaceLanguages"]:
                out.append(f"| Search ({code_}) | {words(vocabulary[code_])} |")
            out.append(
                f"| Search (other {len(other)} languages) | titles, words and phrases in "
                f"[settings-map.json](settings-map.json) under this id |")
        out.append("")

    out += ["## Language lists", "",
            "Stop words may be ignored by search; markers never are. Per declared language:", ""]
    for data in document["languageData"]:
        out.append(f"- {code(data['language'])} stop ({len(data['stop'])}): "
                   + ", ".join(escape(w) for w in data["stop"]))
        out.append(f"  markers ({len(data['markers'])}): "
                   + ", ".join(escape(w) for w in data["markers"]))
    out.append("")
    return "\n".join(out)


def self_test():
    cases = 0
    failures = 0

    def check(name, got, want):
        nonlocal cases, failures
        cases += 1
        if got != want:
            failures += 1
            print(f"FAIL {name}: {got!r} != {want!r}")

    check("escape pipe and backtick", escape("a|b`c"), "a\\|b\\`c")
    check("escape html", escape("<b>&"), "&lt;b&gt;&amp;")
    check("escape newline", escape("a\nb"), "a<br>b")
    check("escape link brackets", escape("[x](y)"), "\\[x\\](y)")
    check("escape backslash first", escape("\\|"), "\\\\\\|")
    check("anchor", anchor("dictation.tab.engine"), "node-dictation-tab-engine")

    def doc(ids):
        nodes = []
        for i, node_id in enumerate(ids):
            nodes.append({
                "id": node_id, "structure": "item", "kind": "setting", "searchable": True,
                "parent": None, "context": [], "declaredIn": "S.swift", "visibility": "always",
                "title": {"source": "resource", "key": "k|", "table": "Localizable",
                          "catalog": "C", "en": f"T{i} <x>", "de": "D|"},
                "description": None, "destination": {"page": "dictation", "tab": "engine"},
                "dictionaryTab": None, "target": node_id, "fallbacks": [],
                "vocabulary": {"en": {"words": ["a|b"], "phrases": ["p\nq"]},
                               "de": {"words": [], "phrases": ["x"]}},
            })
        return {"schema": "settings-map-export", "version": 2, "interfaceLanguages": ["en", "de"],
                "languages": ["en", "de"], "sources": {"map": "M", "titleResolver": "R",
                "uiCatalog": "C", "vocabulary": "V"}, "fingerprints": {"x": "1"},
                "counts": {"nodes": len(ids), "searchable": len(ids), "vocabularyBlocks": 2 * len(ids)},
                "languageData": [{"language": "en", "stop": ["the"], "markers": ["not"]}],
                "nodes": nodes}

    first = render(doc(["a.b"]))
    check("deterministic", render(doc(["a.b"])), first)
    check("cell escaping applied", "a\\|b" in first and "p<br>q" in first and "T0 &lt;x&gt;" in first, True)
    check("no raw pipe inside a cell", "| words: a|b" in first, False)
    for name, ids in (("duplicate id", ["a.b", "a.b"]), ("anchor collision", ["a.b", "a-b"])):
        cases += 1
        try:
            render(doc(ids))
            failures += 1
            print(f"FAIL {name}: rendered")
        except SystemExit:
            pass
    incomplete = doc(["a.b"])
    incomplete["nodes"][0]["vocabulary"].pop("de")
    cases += 1
    try:
        render(incomplete)
        failures += 1
        print("FAIL incomplete vocabulary: rendered")
    except SystemExit:
        pass
    print(f"self-test: {cases - failures} passed, {failures} failed")
    sys.exit(1 if failures or not cases else 0)


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    if len(sys.argv) != 3:
        fail("usage: render-reference.py <export.json> <out.md>")
    with open(sys.argv[1], encoding="utf-8") as handle:
        document = json.load(handle)
    text = render(document)
    with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


if __name__ == "__main__":
    main()
