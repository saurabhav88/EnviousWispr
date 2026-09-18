#!/usr/bin/env python3
"""Build the alias-veto resource for the edit judge (#996 chunk 3, veto portion).

The veto answers ONE question for a candidate alias: is the run the
recogniser wrote (the ORIGINAL) an ordinary word someone could mean
literally? If so, learning it as an alias would silently rewrite future
dictations, so the alias is refused whatever the classifier says. Absence
from the resource is never proof of safety; it only means the veto has
nothing to say and the classifier decides.

Sources, both versioned and digested into `manifest.json`:
  * wordfreq 3.1.1 (Apache-2.0 code, CC-BY-SA-4.0 data): for every language
    wordfreq covers, every word whose Zipf frequency is >= `--zipf-list`
    with its Zipf value (`word<TAB>zipf`), lowercase NFC, so the policy's
    two floors (single token, joined multi-token) read one file per language.
  * the macOS `/usr/share/dict/words` (Webster's Second, public domain) as an
    English DICTIONARY list, because rare real words (`mastodont`) fall below
    any frequency floor yet are words a person might dictate.

Output: `<out>/<version>/{<lang>.tsv, en-dictionary.txt, manifest.json}`.
Languages outside the resource are UNCOVERED: the veto abstains there and
the judge grants no alias (plan §3.1 step 7). Since v4 (v5 corrects the evidence wording) an alias is granted
ONLY in `--alias-languages`: the languages whose lists were measured to
carry that language's common given names (wordfreq lists words, not names;
the Korean and Chinese lists missed half the unsafe-name rows on the
2026-09-18 calibration sets). Every other language, listed or not, abstains
on the alias and the corrected spelling is still learned (founder decision
2026-09-18: no automatic alias where name coverage is unproven).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

RESOURCE_VERSION = "edit-judge-veto-v5"
# Lists carry every word at or above `--zipf-list` with its Zipf value, so
# the two policy floors below can both be answered from one file per language:
#   single-token originals are vetoed at >= `--zipf-single` (about one per
#   million words), joined multi-token forms (`pine cone` -> `pinecone`) at
#   >= `--zipf-joined` (rarer lexicalised compounds still count as words).
DEFAULT_ZIPF_LIST = 2.0
DEFAULT_ZIPF_SINGLE = 3.0
DEFAULT_ZIPF_JOINED = 2.0
DICTIONARY_PATH = Path("/usr/share/dict/words")
DICTIONARY_MIN_LETTERS = 3


sys.path.insert(0, str(Path(__file__).parent))
from edit_judge_veto import normalise_token as normalise  # noqa: E402  (one normalisation authority)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", type=Path, required=True, help="resource root; a <version> directory is created under it")
    p.add_argument("--zipf-list", type=float, default=DEFAULT_ZIPF_LIST)
    p.add_argument("--zipf-single", type=float, default=DEFAULT_ZIPF_SINGLE)
    p.add_argument("--zipf-joined", type=float, default=DEFAULT_ZIPF_JOINED)
    p.add_argument("--top-n", type=int, default=300_000, help="wordfreq candidates per language before the Zipf filter")
    p.add_argument("--alias-languages", required=True, help="comma-separated languages whose name coverage was measured; only these may grant an alias")
    p.add_argument("--alias-languages-evidence", required=True, help="where the name-coverage measurement lives (calibration ids or a file)")
    args = p.parse_args()
    alias_languages = sorted({x.strip().casefold() for x in args.alias_languages.split(",") if x.strip()})
    if not alias_languages or not args.alias_languages_evidence.strip():
        print("INFRA-ERROR: --alias-languages and --alias-languages-evidence must both be non-empty", file=sys.stderr)
        return 2
    import wordfreq
    from importlib.metadata import version as pkg_version

    wf_version = pkg_version("wordfreq")
    if wf_version != "3.1.1":
        print(f"INFRA-ERROR: wordfreq {wf_version} is not the pinned 3.1.1", file=sys.stderr)
        return 2
    out = args.out / RESOURCE_VERSION
    out.mkdir(parents=True, exist_ok=False)
    files: dict[str, dict] = {}
    languages = sorted(wordfreq.available_languages("best"))
    unknown = sorted(set(alias_languages) - set(languages))
    if unknown:
        print(f"INFRA-ERROR: alias languages without a wordfreq list: {unknown}", file=sys.stderr)
        return 2
    for lang in languages:
        seen: dict[str, float] = {}
        for w in wordfreq.top_n_list(lang, args.top_n):
            z = wordfreq.zipf_frequency(w, lang)
            n = normalise(w)
            if z >= args.zipf_list and n:
                seen[n] = max(seen.get(n, 0.0), z)
        path = out / f"{lang}.tsv"
        path.write_text("".join(f"{w}\t{seen[w]:.2f}\n" for w in sorted(seen)), encoding="utf-8")
        files[lang] = {"path": path.name, "words": len(seen), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    if not DICTIONARY_PATH.exists():
        print(f"INFRA-ERROR: dictionary missing at {DICTIONARY_PATH}", file=sys.stderr)
        return 2
    dictionary = sorted({normalise(w) for w in DICTIONARY_PATH.read_text(encoding="utf-8", errors="ignore").splitlines() if len(w.strip()) >= DICTIONARY_MIN_LETTERS and w.strip().isalpha()})
    dpath = out / "en-dictionary.txt"
    dpath.write_text("\n".join(dictionary) + "\n", encoding="utf-8")
    files["en-dictionary"] = {"path": dpath.name, "words": len(dictionary), "sha256": hashlib.sha256(dpath.read_bytes()).hexdigest(), "source": str(DICTIONARY_PATH), "source_sha256": hashlib.sha256(DICTIONARY_PATH.read_bytes()).hexdigest()}
    manifest = {
        "version": RESOURCE_VERSION,
        "built_at": datetime.now(timezone.utc).isoformat(),
        "policy": {
            "zipf_list_min": args.zipf_list,
            "zipf_single_min": args.zipf_single,
            "zipf_joined_min": args.zipf_joined,
            "top_n": args.top_n,
            "normalisation": "edit_judge_veto.normalise_token: NFC, casefold, punctuation stripped from the edges only (combining marks kept)",
            "multi_token": "vetoed when the tokens joined without spaces are a listed word at zipf_joined_min or a dictionary word; otherwise not vetoed",
            "languages_checked": "row language plus en (tech vocabulary crosses languages)",
            "uncovered_language": "abstain: the judge grants no alias",
            "alias_languages": alias_languages,
            "alias_languages_evidence": args.alias_languages_evidence.strip(),
            "unproven_name_coverage": "a listed language outside alias_languages abstains on the alias; the corrected spelling is still learned",
            "dictionary_min_letters": DICTIONARY_MIN_LETTERS,
        },
        "sources": {
            "wordfreq": {"version": wf_version, "licence": "Apache-2.0 code, CC-BY-SA-4.0 data (attribution required; derived lists share alike)"},
            "dictionary": {"path": str(DICTIONARY_PATH), "licence": "Webster's Second International (1934), public domain in the US"},
        },
        "languages": languages,
        "files": files,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    total = sum(f.stat().st_size for f in out.iterdir())
    print(json.dumps({"resource": str(out), "languages": len(languages), "words": sum(v["words"] for k, v in files.items() if k != "en-dictionary"), "dictionary_words": files["en-dictionary"]["words"], "size_mb": round(total / 1e6, 1)}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
