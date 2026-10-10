#!/usr/bin/env python3
"""Writes the Hugging Face reference ids that `SettingsSearchUnigramTokenizerTests` compares the
Swift tokenizer against (#3482 PR B chunk 3).

  meaning-tokenizer-fixture.py --tokenizer <hf-tokenizer/tokenizer.json> --texts <place-texts.json> \\
      --practice <queries/practice-all.jsonl> [--out Tests/Fixtures/settings-search/meaning-tokenizer-parity.json]

  <place-texts.json> is what the Swift text recipe writes (see meaning-assets.py's header).

The fixture holds explicit ids for the practice searches, the special cases and a seeded fuzz set,
and one short hash of the ids for every place text (the texts themselves are rebuilt by the test
from the committed export, and the fixture records their hash). Every input is encoded as
"query: " + text, the way the encoder is called. Needs transformers (the bench's .venv).

The fuzz set draws only code points that Unicode 15.1 assigns: grapheme-cluster rules for newly
assigned characters differ between the Rust tokenizer, Swift and Python, and a user cannot be
expected to type a character no keyboard has. Seeded, so the file is reproducible.
"""
import argparse
import hashlib
import json
import pathlib
import random
import sys
import unicodedata

PREFIX = "query: "

RANGES = [
    (0x20, 0x7E), (0xA0, 0x24F), (0x300, 0x36F), (0x370, 0x3FF), (0x400, 0x4FF), (0x590, 0x5FF),
    (0x600, 0x6FF), (0x900, 0x97F), (0xE00, 0xE7F), (0x1100, 0x11FF), (0x2000, 0x206F),
    (0x2100, 0x214F), (0x2460, 0x24FF), (0x3040, 0x30FF), (0x3400, 0x4DBF), (0x4E00, 0x9FFF),
    (0xAC00, 0xD7AF), (0xFB00, 0xFB4F), (0xFF00, 0xFFEF), (0x1F300, 0x1F5FF), (0x1F600, 0x1F64F),
    (0x0, 0x1F), (0x7F, 0x9F), (0xE000, 0xE0FF),
]

SPECIALS = [
    "", " ", "   ", "\t", "a\tb\nc", "  leading and   multiple   spaces  ", "<s>", "</s>", "<pad>",
    "<unk>", "<mask>", "a<mask>b", "x<s>y</s>z", "<s", "s>", "<S>", "<mask><mask>",
    "ﬁnance ﬂow", "Ａｂｃ１２３", "ｶﾀｶﾅ", "é café", "한국어 입력", "日本語のテキスト",
    "ไทยภาษา", "हिन्दी में", "العربية", "​‍zero width", "a b", "a　b", "ǅ", "ß",
    "İstanbul", "👨‍👩‍👧‍👦 family", "🇩🇪 flag", "😀🎙️", "x" * 200, "é" * 50, "ab " * 80,
    "\u0000", "\ufeffbom", "\u00ad", "a\u0085b", "\u2026", "\u2014", "\u201cquoted\u201d", "½ ² ™ ℃ ㎏",
    "Mikrofon 麦克风 ميكروفون", "stop recording when I pause",
]


def ids_hash(ids):
    return hashlib.sha256(",".join(map(str, ids)).encode()).hexdigest()[:16]


def fuzz_strings(count, seed):
    rng = random.Random(seed)
    out = []
    while len(out) < count:
        chars = []
        for _ in range(rng.randint(1, 40)):
            low, high = rng.choice(RANGES)
            cp = rng.randint(low, high)
            if 0xD800 <= cp <= 0xDFFF or unicodedata.category(chr(cp)) == "Cn":
                continue
            chars.append(chr(cp))
            if rng.random() < 0.12:
                chars.append(" ")
        if chars:
            out.append("".join(chars))
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tokenizer", required=True)
    parser.add_argument("--texts", required=True)
    parser.add_argument("--practice", required=True)
    parser.add_argument("--fuzz", type=int, default=1500)
    parser.add_argument("--seed", type=int, default=20261007)
    parser.add_argument(
        "--out", default=str(pathlib.Path(__file__).resolve().parents[2]
                             / "Tests/Fixtures/settings-search/meaning-tokenizer-parity.json"))
    args = parser.parse_args()

    import tokenizers
    import transformers
    from transformers import PreTrainedTokenizerFast

    tokenizer = PreTrainedTokenizerFast(tokenizer_file=args.tokenizer)

    def encode(text):
        return tokenizer(PREFIX + text)["input_ids"]

    texts = json.loads(pathlib.Path(args.texts).read_text())
    practice = [json.loads(line)["q"] for line in pathlib.Path(args.practice).read_text().splitlines()]
    explicit = []
    for group, items in (
        ("practice", practice), ("special", SPECIALS), ("fuzz", fuzz_strings(args.fuzz, args.seed))
    ):
        for text in items:
            explicit.append({"group": group, "text": text, "ids": encode(text)})
    fixture = {
        "schema": "settings-search-meaning-tokenizer-parity", "version": 1,
        "source": {
            "tokenizer": "bench models/coreml/e5small-v2-pal6/hf-tokenizer/tokenizer.json",
            "tokenizerSHA256": hashlib.sha256(pathlib.Path(args.tokenizer).read_bytes()).hexdigest(),
            "transformers": transformers.__version__, "tokenizers": tokenizers.__version__,
            "unicodeData": unicodedata.unidata_version, "prefix": PREFIX, "seed": args.seed,
        },
        "placeTexts": {
            "textsSHA256": texts["textsSHA256"], "rows": len(texts["rows"]),
            "idsHash": [ids_hash(encode(row)) for row in texts["rows"]],
        },
        "cases": explicit,
    }
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(fixture, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"{len(explicit)} explicit cases, {len(texts['rows'])} place texts hashed -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
