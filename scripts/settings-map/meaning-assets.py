#!/usr/bin/env python3
"""Build and check the Settings search meaning assets (#3482 PR B chunk 3).

The assets live in `Sources/EnviousWispr/Resources/SettingsSearchMeaning/` and ride the app target:

  SettingsSearchEncoder.mlmodelc/   precompiled Core ML query encoder (6-bit palettized, CPU only)
  tokenizer.unigram                                                the model's tokenizer, compact
  place-vectors.bin / place-vectors.json                            one vector per place text
  manifest.json                                                    pinned hashes and provenance

Subcommands (each rewrites only its own manifest sections):

  place-vectors --texts <texts.json> --model <fine-tuned model dir> [--out-dir <dir>]
      Embeds the place texts with the FULL-quality fine-tuned model (prefix "passage: ",
      normalized) and stores float16. <texts.json> comes from the Swift text recipe:
        TEST_RUNNER_EW_SETTINGS_PLACE_TEXTS=/tmp/texts.json scripts/xcode-test.sh \\
            --filter EnviousWisprTests/SettingsSearchPlaceTextsExportTests
      Needs sentence-transformers (the Phase 0 bench used 6.1.0 with torch 2.14.1, numpy 2.5.3).

  encoder --package <Encoder.mlpackage> --tokenizer-dir <hf-tokenizer dir> [--out-dir <dir>]
      Compiles the package with `xcrun coremlcompiler` (macOS 14 target), builds `tokenizer.unigram`
      from the model's tokenizer.json (the vocabulary, the precompiled normalizer table and the
      pipeline facts the Swift tokenizer implements; any other pipeline is refused), and records
      reference vectors for a few searches, computed by Python Core ML with the Hugging Face
      tokenizer on the SOURCE package (an instrument independent of the Swift tokenizer and the
      compiled model).
      Needs coremltools and transformers (the bench's .venv-coreml: coremltools 9.0, torch 2.7.0).

  check [--out-dir <dir>] [--export <reference/settings-map.json>]
      Recomputes every hash and size from the files on disk and compares them with manifest.json,
      and the recorded map and vocabulary fingerprints with the committed export.

  --self-test
      Offline checks of the hashing, float16 packing and manifest merging.

How a new setting gets its vector: add the map node and its reviewed vocabulary, run
scripts/settings-map/export.sh, then run `place-vectors` (the texts of every place are rebuilt, so
the whole file is regenerated: a few minutes on CPU). `SettingsSearchPlaceVectorsTests` fails until
the committed vectors match the texts of the current export.

The conversion of the fine-tuned model to Core ML (6-bit palettization, sequence length 32) is the
Phase 0 bench's `convert_coreml.py` (branch feat/3482-settings-search-bench); its provenance is
recorded in manifest.json. Nothing here calls a paid service.
"""
import argparse
import hashlib
import json
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[2]
ASSET_DIR = REPO / "Sources/EnviousWispr/Resources/SettingsSearchMeaning"
ENCODER_DIR = "SettingsSearchEncoder.mlmodelc"
TOKENIZER_SOURCE_FILES = ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"]
TOKENIZER_BINARY = "tokenizer.unigram"
UNIGRAM_MAGIC = b"EWUNIG01"
PLACE_BIN = "place-vectors.bin"
PLACE_INDEX = "place-vectors.json"
MANIFEST = "manifest.json"
SCHEMA = "settings-search-meaning-assets"
VERSION = 1
DOC_PREFIX = "passage: "
QUERY_PREFIX = "query: "
SEQUENCE_LENGTH = 32
PAD_ID = 1
DIMENSION = 384
SELF_TEST_QUERIES = ["stop recording on silence", "dunkler Modus", "parakeet"]


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_sha256(root: pathlib.Path) -> str:
    """sha256 over sorted '<relative path> <file sha256>' lines (the classifier's convention)."""
    lines = []
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        lines.append(f"{path.relative_to(root).as_posix()} {sha256_file(path)}\n")
    return hashlib.sha256("".join(lines).encode()).hexdigest()


def tree_bytes(root: pathlib.Path) -> int:
    return sum(p.stat().st_size for p in root.rglob("*") if p.is_file())


def file_entry(path: pathlib.Path) -> dict:
    return {"sha256": sha256_file(path), "bytes": path.stat().st_size}


def pack_float16(rows) -> bytes:
    """Little-endian IEEE half precision, row-major (numpy-free path for the self-test)."""
    out = bytearray()
    for row in rows:
        out += struct.pack(f"<{len(row)}e", *row)
    return bytes(out)


def read_manifest(out_dir: pathlib.Path) -> dict:
    path = out_dir / MANIFEST
    if path.exists():
        return json.loads(path.read_text())
    return {"schema": SCHEMA, "version": VERSION}


def update_manifest(out_dir: pathlib.Path, sections: dict) -> None:
    manifest = read_manifest(out_dir)
    manifest["schema"], manifest["version"] = SCHEMA, VERSION
    manifest.update(sections)
    (out_dir / MANIFEST).write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")


def export_fingerprints(export_path: pathlib.Path) -> dict:
    fingerprints = json.loads(export_path.read_text())["fingerprints"]
    return {key: fingerprints[key] for key in ("mapSHA256", "vocabularySHA256", "uiCatalogSHA256")}


# ------------------------------------------------------------------------------ tokenizer


def build_unigram(tokenizer: dict) -> bytes:
    """The compact tokenizer file the Swift tokenizer reads (SettingsSearchUnigramTokenizer).

    Layout, little endian: magic "EWUNIG01"; ten u32 (vocabulary count, unknown id, longest piece in
    scalars, begin id, end id, flags [bit 0: scores are float32], added-token count, normalizer trie
    bytes, normalizer pool bytes, piece blob bytes); the added tokens (u32 id, u32 byte length,
    UTF-8); the trie; the pool; u32 start[count + 1] and u32 id[count] over the pieces sorted by
    their UTF-8 bytes; the scores by id (float32 when every score is exactly one); the blob.

    Refuses any tokenizer whose pipeline is not the one implemented: the Swift code carries no
    switch for other normalizers, pre-tokenizers or post-processors.
    """
    import base64

    model = tokenizer["model"]
    if model.get("type") != "Unigram" or model.get("byte_fallback"):
        sys.exit("tokenizer model is not a Unigram model without byte fallback")
    if (tokenizer.get("normalizer") or {}).get("type") != "Precompiled":
        sys.exit("tokenizer normalizer is not Precompiled")
    expected_pre = [
        {"type": "WhitespaceSplit"},
        {"type": "Metaspace", "replacement": "\u2581", "prepend_scheme": "always", "split": True},
    ]
    pre = tokenizer.get("pre_tokenizer") or {}
    if pre.get("type") != "Sequence" or pre.get("pretokenizers") != expected_pre:
        sys.exit("tokenizer pre-tokenizer is not WhitespaceSplit then Metaspace(always, split)")
    expected_single = [
        {"SpecialToken": {"id": "<s>", "type_id": 0}},
        {"Sequence": {"id": "A", "type_id": 0}},
        {"SpecialToken": {"id": "</s>", "type_id": 0}},
    ]
    if (tokenizer.get("post_processor") or {}).get("single") != expected_single:
        sys.exit("tokenizer post-processor is not <s> A </s>")
    added = tokenizer["added_tokens"]
    for token in added:
        flags = [token.get(k) for k in ("lstrip", "rstrip", "normalized", "single_word")]
        if any(flags) or not token.get("special"):
            sys.exit(f"added token {token['content']!r} is not a plain special token")
    by_content = {token["content"]: token["id"] for token in added}
    vocab = model["vocab"]
    order = sorted(range(len(vocab)), key=lambda i: vocab[i][0].encode("utf-8"))
    pieces = [vocab[i][0].encode("utf-8") for i in order]
    if len(set(pieces)) != len(pieces):
        sys.exit("tokenizer vocabulary has duplicate pieces")
    scores = [score for _, score in vocab]
    float32 = all(struct.unpack("<f", struct.pack("<f", s))[0] == s for s in scores)
    charsmap = base64.b64decode(tokenizer["normalizer"]["precompiled_charsmap"])
    trie_bytes = struct.unpack("<I", charsmap[:4])[0]
    if trie_bytes % 4 or 4 + trie_bytes > len(charsmap):
        sys.exit("normalizer table is malformed")
    trie, pool = charsmap[4 : 4 + trie_bytes], charsmap[4 + trie_bytes :]
    blob = b"".join(pieces)
    starts = [0]
    for piece in pieces:
        starts.append(starts[-1] + len(piece))
    out = bytearray(UNIGRAM_MAGIC)
    out += struct.pack(
        "<10I", len(vocab), model["unk_id"], max(len(piece) for piece, _ in vocab),
        by_content["<s>"], by_content["</s>"], 1 if float32 else 0, len(added), len(trie),
        len(pool), len(blob))
    for token in added:
        encoded = token["content"].encode("utf-8")
        out += struct.pack("<II", token["id"], len(encoded)) + encoded
    out += trie + pool
    out += struct.pack(f"<{len(starts)}I", *starts)
    out += struct.pack(f"<{len(order)}I", *order)
    out += struct.pack(f"<{len(scores)}{'f' if float32 else 'd'}", *scores)
    out += blob
    return bytes(out)


# --------------------------------------------------------------------------- place-vectors


def cmd_place_vectors(args) -> int:
    import numpy as np
    import sentence_transformers
    import torch
    from sentence_transformers import SentenceTransformer

    out_dir = pathlib.Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    texts = json.loads(pathlib.Path(args.texts).read_text())
    if texts.get("schema") != "settings-search-place-texts":
        sys.exit("--texts is not a settings-search-place-texts file")
    rows = texts["rows"]
    model_dir = pathlib.Path(args.model)
    model = SentenceTransformer(str(model_dir), device=args.device)
    vectors = model.encode(
        [DOC_PREFIX + text for text in rows], normalize_embeddings=True, batch_size=64,
        convert_to_numpy=True)
    if vectors.shape != (len(rows), DIMENSION) or not np.isfinite(vectors).all():
        sys.exit(f"bad vectors: shape {vectors.shape}, finite {bool(np.isfinite(vectors).all())}")
    (out_dir / PLACE_BIN).write_bytes(vectors.astype("<f2").tobytes())
    index = {
        "schema": "settings-search-place-vectors", "version": VERSION, "dimension": DIMENSION,
        "dtype": "float16", "normalized": True, "docPrefix": DOC_PREFIX,
        "recipeVersion": texts["recipeVersion"], "textsSHA256": texts["textsSHA256"],
        "rows": len(rows), "entryOrder": texts["entryOrder"], "entries": texts["entries"],
    }
    (out_dir / PLACE_INDEX).write_text(json.dumps(index, sort_keys=True, separators=(",", ":")) + "\n")
    weights = model_dir / "model.safetensors"
    sections = {
        "placeVectors": {
            "bin": file_entry(out_dir / PLACE_BIN), "index": file_entry(out_dir / PLACE_INDEX),
            "textsSHA256": texts["textsSHA256"], "rows": len(rows), "dimension": DIMENSION,
            "dtype": "float16",
            "model": {
                "base": args.base, "fineTunedWeightsSHA256": sha256_file(weights),
                "sentenceTransformers": sentence_transformers.__version__,
                "torch": torch.__version__, "numpy": np.__version__, "device": args.device,
                "docPrefix": DOC_PREFIX,
            },
        },
    }
    export = pathlib.Path(args.export)
    if export.exists():
        sections["sources"] = export_fingerprints(export)
    update_manifest(out_dir, sections)
    print(f"{len(rows)} rows, {(out_dir / PLACE_BIN).stat().st_size} bytes of vectors")
    return 0


# ------------------------------------------------------------------------------- encoder


def reference_vector(model, tokenizer, query: str):
    import numpy as np

    ids = tokenizer(QUERY_PREFIX + query)["input_ids"]
    if len(ids) > SEQUENCE_LENGTH:
        ids = ids[: SEQUENCE_LENGTH - 1] + [ids[-1]]
    input_ids = np.full((1, SEQUENCE_LENGTH), PAD_ID, dtype=np.int32)
    mask = np.zeros((1, SEQUENCE_LENGTH), dtype=np.int32)
    input_ids[0, : len(ids)] = ids
    mask[0, : len(ids)] = 1
    vector = model.predict({"input_ids": input_ids, "attention_mask": mask})["embedding"][0]
    if not np.isfinite(vector).all():
        sys.exit(f"non-finite reference vector for {query!r}")
    return [round(float(x), 8) for x in vector]


def cmd_encoder(args) -> int:
    import coremltools as ct
    from transformers import PreTrainedTokenizerFast

    out_dir = pathlib.Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    package = pathlib.Path(args.package)
    tokenizer_dir = pathlib.Path(args.tokenizer_dir)
    with tempfile.TemporaryDirectory() as staging:
        subprocess.run(
            ["xcrun", "coremlcompiler", "compile", str(package), staging,
             "--deployment-target", "14.0", "--platform", "macos"], check=True)
        compiled = pathlib.Path(staging) / (package.stem + ".mlmodelc")
        shutil.rmtree(out_dir / ENCODER_DIR, ignore_errors=True)
        shutil.copytree(compiled, out_dir / ENCODER_DIR)
    tokenizer_data = json.loads((tokenizer_dir / "tokenizer.json").read_text())
    (out_dir / TOKENIZER_BINARY).write_bytes(build_unigram(tokenizer_data))
    for stale in TOKENIZER_SOURCE_FILES:  # the full files are no longer shipped
        (out_dir / stale).unlink(missing_ok=True)
    model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_ONLY)
    tokenizer = PreTrainedTokenizerFast(tokenizer_file=str(tokenizer_dir / "tokenizer.json"))
    compiler = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout
    update_manifest(out_dir, {
        "encoder": {
            "directory": ENCODER_DIR, "treeSHA256": tree_sha256(out_dir / ENCODER_DIR),
            "bytes": tree_bytes(out_dir / ENCODER_DIR), "sequenceLength": SEQUENCE_LENGTH,
            "queryPrefix": QUERY_PREFIX, "padTokenID": PAD_ID, "dimension": DIMENSION,
            "inputs": ["input_ids", "attention_mask"], "output": "embedding",
            "computeUnits": "cpuOnly", "deploymentTarget": "macOS 14",
            "compiler": " ".join(compiler.split()),
            "sourcePackageSHA256": tree_sha256(package), "sourcePackageBytes": tree_bytes(package),
            "coremltools": ct.__version__,
        },
        "tokenizer": {
            "file": TOKENIZER_BINARY, **file_entry(out_dir / TOKENIZER_BINARY),
            "source": {name: file_entry(tokenizer_dir / name) for name in TOKENIZER_SOURCE_FILES},
        },
        "selfTest": [
            {"query": query, "vector": reference_vector(model, tokenizer, query)}
            for query in SELF_TEST_QUERIES
        ],
    })
    print(f"encoder {tree_bytes(out_dir / ENCODER_DIR)} bytes, tokenizer {(out_dir / TOKENIZER_BINARY).stat().st_size} bytes")
    return 0


# --------------------------------------------------------------------------------- check


def check_problems(out_dir: pathlib.Path, export: pathlib.Path | None) -> list[str]:
    problems: list[str] = []
    path = out_dir / MANIFEST
    if not path.exists():
        return [f"{path} is missing"]
    manifest = json.loads(path.read_text())

    def expect(label: str, actual, recorded) -> None:
        if actual != recorded:
            problems.append(f"{label}: on disk {actual}, manifest {recorded}")

    if manifest.get("schema") != SCHEMA or manifest.get("version") != VERSION:
        problems.append("manifest schema or version is not the one this tool writes")
    encoder = manifest.get("encoder", {})
    if (out_dir / ENCODER_DIR).is_dir():
        expect("encoder treeSHA256", tree_sha256(out_dir / ENCODER_DIR), encoder.get("treeSHA256"))
        expect("encoder bytes", tree_bytes(out_dir / ENCODER_DIR), encoder.get("bytes"))
    else:
        problems.append(f"{ENCODER_DIR} is missing")
    tokenizer = manifest.get("tokenizer", {})
    name = tokenizer.get("file", TOKENIZER_BINARY)
    if (out_dir / name).exists():
        expect(name, file_entry(out_dir / name), {k: tokenizer.get(k) for k in ("sha256", "bytes")})
    else:
        problems.append(f"{name} is missing")
    vectors = manifest.get("placeVectors", {})
    for key, name in (("bin", PLACE_BIN), ("index", PLACE_INDEX)):
        if (out_dir / name).exists():
            expect(name, file_entry(out_dir / name), vectors.get(key))
        else:
            problems.append(f"{name} is missing")
    if export is not None and export.exists():
        expect("map/vocabulary fingerprints", export_fingerprints(export), manifest.get("sources"))
    return problems


def cmd_check(args) -> int:
    problems = check_problems(pathlib.Path(args.out_dir), pathlib.Path(args.export))
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    print("meaning assets match manifest.json" if not problems else f"{len(problems)} problem(s)")
    return 1 if problems else 0


# ---------------------------------------------------------------------------- self-test


def cmd_self_test(_args) -> int:
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        (root / "a").mkdir()
        (root / "a/x.bin").write_bytes(b"abc")
        (root / "b.txt").write_bytes(b"de")
        expected = hashlib.sha256(
            f"a/x.bin {hashlib.sha256(b'abc').hexdigest()}\nb.txt {hashlib.sha256(b'de').hexdigest()}\n"
            .encode()).hexdigest()
        if tree_sha256(root) != expected:
            failures.append("tree_sha256 does not follow the sorted '<path> <sha>' convention")
        if tree_bytes(root) != 5:
            failures.append("tree_bytes")
        # half precision: 1.0 is 0x3C00, -2.0 is 0xC000, little endian
        if pack_float16([[1.0, -2.0]]) != bytes([0x00, 0x3C, 0x00, 0xC0]):
            failures.append("pack_float16 is not little-endian half precision")
        update_manifest(root, {"encoder": {"bytes": 1}})
        update_manifest(root, {"placeVectors": {"rows": 2}})
        merged = read_manifest(root)
        if merged.get("encoder") != {"bytes": 1} or merged.get("placeVectors") != {"rows": 2}:
            failures.append("update_manifest lost a section written by another subcommand")
        import base64
        special = {"lstrip": False, "rstrip": False, "normalized": False, "single_word": False, "special": True}
        tiny = {
            "model": {"type": "Unigram", "unk_id": 0, "byte_fallback": False,
                      "vocab": [["<unk>", 0.0], ["\u2581a", -1.5], ["b", -2.0]]},
            "normalizer": {"type": "Precompiled", "precompiled_charsmap":
                           base64.b64encode(struct.pack("<I", 4) + bytes(4) + b"\0").decode()},
            "pre_tokenizer": {"type": "Sequence", "pretokenizers": [
                {"type": "WhitespaceSplit"},
                {"type": "Metaspace", "replacement": "\u2581", "prepend_scheme": "always", "split": True}]},
            "post_processor": {"single": [{"SpecialToken": {"id": "<s>", "type_id": 0}},
                                          {"Sequence": {"id": "A", "type_id": 0}},
                                          {"SpecialToken": {"id": "</s>", "type_id": 0}}]},
            "added_tokens": [{"id": 0, "content": "<s>", **special}, {"id": 1, "content": "</s>", **special}],
        }
        blob = build_unigram(tiny)
        header = struct.unpack("<10I", blob[8:48])
        # count, unk, longest piece, begin, end, flags, added, trie, pool, blob bytes
        if blob[:8] != UNIGRAM_MAGIC or header != (3, 0, 5, 0, 1, 1, 2, 4, 1, 10):
            failures.append(f"build_unigram header is {header}")
        if not blob.endswith(b"<unk>b" + "\u2581a".encode()):
            failures.append("build_unigram did not sort the pieces by their UTF-8 bytes")
        broken = dict(tiny, pre_tokenizer={"type": "Whitespace"})
        try:
            build_unigram(broken)
            failures.append("build_unigram accepted another pre-tokenizer")
        except SystemExit:
            pass
        problems = check_problems(root, None)
        if not any("is missing" in p or "treeSHA256" in p for p in problems):
            failures.append("check_problems did not notice the missing assets")
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    print("self-test " + ("FAILED" if failures else "passed"))
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--self-test", action="store_true")
    sub = parser.add_subparsers(dest="command")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--out-dir", default=str(ASSET_DIR))
    common.add_argument("--export", default=str(REPO / "reference/settings-map.json"))
    place = sub.add_parser("place-vectors", parents=[common])
    place.add_argument("--texts", required=True)
    place.add_argument("--model", required=True)
    place.add_argument("--base", default="intfloat/multilingual-e5-small")
    place.add_argument("--device", default="cpu")
    encoder = sub.add_parser("encoder", parents=[common])
    encoder.add_argument("--package", required=True)
    encoder.add_argument("--tokenizer-dir", required=True)
    sub.add_parser("check", parents=[common])
    args = parser.parse_args()
    if args.self_test:
        return cmd_self_test(args)
    handlers = {"place-vectors": cmd_place_vectors, "encoder": cmd_encoder, "check": cmd_check}
    if args.command not in handlers:
        parser.print_help()
        return 2
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
