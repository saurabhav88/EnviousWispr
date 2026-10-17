"""Shared helpers for the Ollama library feed tools (#2778).

Used by `scan.py` (finds candidate models for the weekly routine) and
`validate-feed.py` (checks the committed feed). Standard library only.

Authority split, stated once:
- The Swift parser `OllamaLibraryFeedClient.parseFeed` owns RUNTIME eligibility
  (canonical identity, shipped and verdict exclusions). The functions here are
  preliminary shape checks that mirror it so a bad file is caught before merge;
  the required Swift test `OllamaLibraryFeedTests` rejects any committed row the
  Swift parser would drop, so a disagreement between the two fails CI there.
- This module owns the things Swift cannot check offline: the append-only
  comparison against the PR base and the registry's view of a model.

Where the shipped, private and measured model names come from: they are read out
of `OllamaSetupService.swift` (`modelCatalog`, `curatedPrivateCatalog`) and
`OllamaModelVerdicts.swift` (`measured`) with the regexes below, and the readers
fail closed (raise) when the file layout stops matching.
"""

import html
import json
import re
import sys
import unicodedata
import urllib.error
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FEED_PATH = "website/public/ollama-library.json"

SCHEMA = 1
MIN_SIZE_BYTES = 50_000_000
MAX_SIZE_BYTES = 200_000_000_000
# The routine never proposes anything larger than this (a Mac with 8 GB cannot run it).
ROUTINE_MAX_SIZE_BYTES = 16_000_000_000
MAX_ADDITIONS_PER_RUN = 3
MAX_ROWS = 40
RUNTIME_MAX_ROWS = 200

# Whole-string match; mirrors OllamaLibraryFeedClient.namePattern.
NAME_RE = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}(:[A-Za-z0-9._-]{1,64})?")
ROW_KEYS = {"name", "displayName", "parameterCount", "sizeBytes", "reason"}
REQUIRED_ROW_KEYS = {"name", "displayName", "parameterCount", "sizeBytes"}

REGISTRY = "https://registry.ollama.ai/v2/library"
LIBRARY_URL = "https://ollama.com/library"
USER_AGENT = "EnviousWispr-ollama-library-tool (+https://enviouswispr.com)"
MANIFEST_ACCEPT = "application/vnd.docker.distribution.manifest.v2+json"


# --- identity -----------------------------------------------------------------


def canonical(name: str) -> str:
    """`canonicalModelName`: strips exactly one trailing ':latest'."""
    return name[: -len(":latest")] if name.endswith(":latest") else name


def is_first_party(name: str) -> bool:
    lower = name.lower()
    return canonical(lower) == "eg-1" or lower.startswith("eg-1:")


# --- row shape (mirror of the Swift parser) -----------------------------------


def _displayable(text, max_length: int) -> bool:
    if not isinstance(text, str) or not text.strip() or len(text) > max_length:
        return False
    for ch in text:
        if unicodedata.category(ch) in {"Cc", "Cf", "Zl", "Zp", "Cs", "Co", "Cn"}:
            return False
    return True


def row_shape_errors(row) -> list:
    """Shape problems of one feed row, as human strings. Empty means well formed."""
    if not isinstance(row, dict):
        return ["row is not an object"]
    errors = []
    unknown = set(row) - ROW_KEYS
    if unknown:
        errors.append(f"unknown keys {sorted(unknown)} (a row cannot carry a verdict or a URL)")
    missing = REQUIRED_ROW_KEYS - set(row)
    if missing:
        errors.append(f"missing keys {sorted(missing)}")
        return errors
    name = row["name"]
    if not isinstance(name, str) or NAME_RE.fullmatch(name) is None:
        errors.append(f"bad name {name!r}")
    else:
        tag = name.split(":", 1)[1] if ":" in name else None
        if tag is not None and tag.lower() == "latest" and tag != "latest":
            errors.append(f"case variant of the latest alias in {name!r}")
        lowered = name.lower()
        if lowered.startswith("hf.co/") or "cloud" in lowered:
            errors.append(f"reserved name {name!r}")
    if not _displayable(row["displayName"], 60):
        errors.append(f"bad displayName {row['displayName']!r}")
    if not _displayable(row["parameterCount"], 12):
        errors.append(f"bad parameterCount {row['parameterCount']!r}")
    size = row["sizeBytes"]
    if (
        isinstance(size, bool)
        or not isinstance(size, int)
        or not (MIN_SIZE_BYTES <= size <= MAX_SIZE_BYTES)
    ):
        errors.append(f"bad sizeBytes {size!r}")
    reason = row.get("reason")
    if reason is not None and not (isinstance(reason, str) and len(reason) <= 240):
        errors.append("bad reason")
    return errors


# --- known models, read from the Swift sources --------------------------------


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _block(text: str, start_marker: str, end_marker: str) -> str:
    start = text.find(start_marker)
    if start < 0:
        raise RuntimeError(f"layout changed: {start_marker!r} not found")
    end = text.find(end_marker, start)
    if end < 0:
        raise RuntimeError(f"layout changed: {end_marker!r} not found after {start_marker!r}")
    return text[start:end]


def shipped_names(root: Path = REPO_ROOT) -> set:
    """Canonical names of `modelCatalog` and `curatedPrivateCatalog`."""
    text = _read(root / "Sources/EnviousWisprLLM/OllamaSetupService.swift")
    public = _block(
        text,
        "public nonisolated static let modelCatalog: [OllamaModelCatalogEntry] = [",
        "\n  ]\n",
    )
    private = _block(
        text,
        "public nonisolated static let curatedPrivateCatalog: [OllamaModelCatalogEntry] = [",
        "\n  ]\n",
    )
    names = {canonical(n) for n in re.findall(r'name:\s*"([^"]+)"', public)}
    if len(names) < 10:
        raise RuntimeError(f"layout changed: found only {len(names)} shipped catalog names")
    names |= {canonical(n) for n in re.findall(r'name:\s*"([^"]+)"', private)}
    return names


def measured_names(root: Path = REPO_ROOT) -> set:
    """Keys of `OllamaModelVerdicts.measured`."""
    text = _read(root / "Sources/EnviousWisprLLM/OllamaModelVerdicts.swift")
    block = _block(text, "private static let measured: [String: Entry] = [", "\n  ]\n")
    names = set(re.findall(r'^\s*"([^"]+)":\s*Entry\(', block, flags=re.MULTILINE))
    if len(names) < 10:
        raise RuntimeError(f"layout changed: found only {len(names)} measured names")
    return names


def known_names(root: Path = REPO_ROOT) -> set:
    return shipped_names(root) | measured_names(root)


def known_errors(row: dict, known: set) -> list:
    """Reasons a well-shaped row collides with a model we already have a position on."""
    name = row["name"]
    errors = []
    lowered = canonical(name.lower())
    if canonical(name) in known or lowered in known:
        errors.append(f"{name!r} is a shipped or already-measured model")
    if is_first_party(name):
        errors.append(f"{name!r} is a first-party model")
    return errors


# --- network ------------------------------------------------------------------


def fetch(url: str, accept: str = None, timeout: int = 30):
    """GET, returning (status, body bytes). Raises on transport failure (never swallowed)."""
    headers = {"User-Agent": USER_AGENT}
    if accept:
        headers["Accept"] = accept
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def manifest_layer_bytes(name: str):
    """Sum of the registry manifest's layer sizes for `name`, or raise."""
    repo, _, tag = name.partition(":")
    tag = tag or "latest"
    status, body = fetch(f"{REGISTRY}/{repo}/manifests/{tag}", accept=MANIFEST_ACCEPT)
    if status != 200:
        raise RuntimeError(f"registry returned {status} for {name}")
    layers = json.loads(body).get("layers")
    if not isinstance(layers, list) or not layers:
        raise RuntimeError(f"registry manifest for {name} has no layers")
    sizes = [layer.get("size") for layer in layers]
    if any(isinstance(s, bool) or not isinstance(s, int) or s < 0 for s in sizes):
        raise RuntimeError(f"registry manifest for {name} has a malformed layer size")
    return sum(sizes)


# --- the library page ---------------------------------------------------------


class _CardParser(HTMLParser):
    """Collects one dict per `<li>` card on https://ollama.com/library."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.cards = []
        self._card = None
        self._in_description = False
        self._span_kind = None
        self._buffer = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        classes = attrs.get("class", "") or ""
        if tag == "li" and "border-b" in classes:
            self._card = {
                "name": None,
                "description": "",
                "capabilities": [],
                "sizes": [],
                "cloud": False,
            }
        elif self._card is None:
            return
        elif tag == "a" and self._card["name"] is None:
            href = attrs.get("href", "") or ""
            if href.startswith("/library/"):
                self._card["name"] = href[len("/library/") :]
        elif tag == "p" and "max-w-lg" in classes:
            self._in_description = True
            self._buffer = []
        elif tag == "span":
            if "text-indigo-600" in classes:
                self._span_kind = "capability"
            elif "text-cyan-500" in classes:
                self._span_kind = "cloud"
            elif "text-blue-600" in classes:
                self._span_kind = "size"
            else:
                self._span_kind = None
            self._buffer = []

    def handle_data(self, data):
        if self._card is not None and (self._in_description or self._span_kind):
            self._buffer.append(data)

    def handle_endtag(self, tag):
        if self._card is None:
            return
        if tag == "p" and self._in_description:
            self._card["description"] = " ".join("".join(self._buffer).split())
            self._in_description = False
        elif tag == "span" and self._span_kind:
            text = "".join(self._buffer).strip()
            if text:
                if self._span_kind == "capability":
                    self._card["capabilities"].append(text)
                elif self._span_kind == "size":
                    self._card["sizes"].append(text)
                else:
                    self._card["cloud"] = True
            self._span_kind = None
        elif tag == "li":
            if self._card["name"]:
                self.cards.append(self._card)
            self._card = None


def parse_library_html(page: str) -> list:
    parser = _CardParser()
    parser.feed(page)
    parser.close()
    return parser.cards


def fetch_library_cards(minimum_cards: int = 100) -> list:
    """Fetch and parse the library; raises when the layout looks changed."""
    status, body = fetch(LIBRARY_URL)
    if status != 200:
        raise RuntimeError(f"ollama.com/library returned {status}")
    cards = parse_library_html(body.decode("utf-8", errors="replace"))
    if len(cards) < minimum_cards:
        raise RuntimeError(
            f"layout changed: parsed {len(cards)} cards from the library page (expected at least "
            f"{minimum_cards})"
        )
    return cards


def die(message: str, code: int = 1):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(code)
