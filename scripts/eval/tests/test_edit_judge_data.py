"""Harness-contract tests for scripts/eval/edit_judge_data.py (#996 Chunk 2a).

When these fail the DATA CONTRACT is wrong (hash identity, family split,
leakage refusal, candidate builders); they say nothing about any judge.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts/eval"))

import edit_judge_data as data  # noqa: E402
import edit_judge_gate as gate  # noqa: E402

# A reviewed smoke fixture with every one of the three classes and several
# alias families, so a family split of it has something in every partition.
# Every family is DISJOINT from the frozen report set (asserted below): a dev
# file that overlaps the frozen rows is refused by the gate.
SMOKE = [
    # correctionAndSafe (family tailscale, three sentences)
    {"id": "S1", "stratum": "domain", "language": "en", "pasted": "deploy it to tail scale tonight", "edited": "deploy it to Tailscale tonight", "original": "tail scale", "replacement": "Tailscale", "correction": True, "safe_alias": True, "label_source": "smoke"},
    {"id": "S2", "stratum": "domain", "language": "en", "pasted": "the tail scale mesh is up", "edited": "the Tailscale mesh is up", "original": "tail scale", "replacement": "Tailscale", "correction": True, "safe_alias": True, "label_source": "smoke"},
    {"id": "S3", "stratum": "domain", "language": "en", "pasted": "ask about tail scale costs", "edited": "ask about Tailscale costs", "original": "tail scale", "replacement": "Tailscale", "correction": True, "safe_alias": True, "label_source": "smoke"},
    # correctionButUnsafe (family marisol; Marisa is a real name someone else could mean)
    {"id": "S4", "stratum": "ambiguous_name", "language": "en", "pasted": "send it to Marisa today", "edited": "send it to Marisol today", "original": "Marisa", "replacement": "Marisol", "correction": True, "safe_alias": False, "label_source": "smoke"},
    {"id": "S5", "stratum": "ambiguous_name", "language": "en", "pasted": "Marisa owns the roadmap", "edited": "Marisol owns the roadmap", "original": "Marisa", "replacement": "Marisol", "correction": True, "safe_alias": False, "label_source": "smoke"},
    # notCorrection (families ours, quickly, montag)
    {"id": "S6", "stratum": "rewording", "language": "en", "pasted": "the plan is theirs by Friday", "edited": "the plan is ours by Friday", "original": "theirs", "replacement": "ours", "correction": False, "safe_alias": False, "label_source": "smoke"},
    {"id": "S7", "stratum": "rewording", "language": "en", "pasted": "please reply fast", "edited": "please reply quickly", "original": "fast", "replacement": "quickly", "correction": False, "safe_alias": False, "label_source": "smoke"},
    {"id": "S8", "stratum": "non_english", "language": "de", "pasted": "wir treffen uns am Dienstag", "edited": "wir treffen uns am Montag", "original": "Dienstag", "replacement": "Montag", "correction": False, "safe_alias": False, "label_source": "smoke"},
    # a second safe family so calibration is not starved
    {"id": "S9", "stratum": "brand", "language": "en", "pasted": "open the you mommy dashboard", "edited": "open the Umami dashboard", "original": "you mommy", "replacement": "Umami", "correction": True, "safe_alias": True, "label_source": "smoke"},
    {"id": "S10", "stratum": "brand", "language": "en", "pasted": "you mommy is down again", "edited": "Umami is down again", "original": "you mommy", "replacement": "Umami", "correction": True, "safe_alias": True, "label_source": "smoke"},
    {"id": "S11", "stratum": "person", "language": "es", "pasted": "llama a Jorje mañana", "edited": "llama a Jorge mañana", "original": "Jorje", "replacement": "Jorge", "correction": True, "safe_alias": True, "label_source": "smoke"},
    {"id": "S12", "stratum": "grammar_punctuation", "language": "en", "pasted": "we was late", "edited": "we were late", "original": "was", "replacement": "were", "correction": False, "safe_alias": False, "label_source": "smoke"},
]


def test_smoke_fixture_is_a_valid_corpus_with_all_three_classes():
    assert gate.validate_rows(SMOKE, "smoke") == []
    classes = {data.three_class(r["correction"], r["safe_alias"]) for r in SMOKE}
    assert classes == set(data.THREE_CLASSES)


def test_smoke_fixture_is_disjoint_from_the_shipped_frozen_set():
    manifest, _, problems = gate.load_frozen()
    assert problems == []
    assert {data.family_key(r) for r in SMOKE} & data.frozen_families(manifest) == set()
    assert {data.content_hash(r) for r in SMOKE} & data.frozen_hashes(manifest) == set()
    gate.require_clean_dev(SMOKE, manifest)  # must not exit


def test_dev_input_overlapping_the_frozen_set_is_refused(capsys):
    manifest, loaded, _ = gate.load_frozen()
    frozen_row = loaded["working"][0]
    renamed = dict(frozen_row, id="RENAMED", correction=not frozen_row["correction"] and False, safe_alias=False)
    with pytest.raises(SystemExit) as exc:
        gate.require_clean_dev([renamed], manifest)
    assert exc.value.code == 2
    assert "content hash" in capsys.readouterr().err
    same_family = dict(SMOKE[0], id="SF", pasted="brand new context " + frozen_row["original"], edited="brand new context " + frozen_row["replacement"], original=frozen_row["original"], replacement=frozen_row["replacement"])
    with pytest.raises(SystemExit):
        gate.require_clean_dev([same_family], manifest)
    assert "alias famil" in capsys.readouterr().err


def test_content_hash_is_by_content_not_by_id_or_label():
    row = SMOKE[0]
    renamed = dict(row, id="OTHER", stratum="brand", label_source="someone else", probe=True)
    relabelled = dict(row, correction=False, safe_alias=False)
    assert data.content_hash(renamed) == data.content_hash(row)
    assert data.content_hash(relabelled) == data.content_hash(row)
    assert data.content_hash(dict(row, pasted=row["pasted"] + " ")) != data.content_hash(row)
    assert data.content_hash(dict(row, language="EN ")) == data.content_hash(row)
    # Casing is content: it can be the whole edit.
    assert data.content_hash(dict(row, replacement="tailscale")) != data.content_hash(row)


def test_content_hash_is_pinned_to_a_literal():
    # Independent oracle: sha256 over the JSON list
    # ["edit-judge-content-hash-v1","en","tail scale","Tailscale","deploy it to tail scale tonight"]
    # computed once with `shasum -a 256` and pinned. A change to the canonical
    # form or to HASH_VERSION must break this on purpose.
    assert data.content_hash(SMOKE[0]) == "c9734d466f539f11387aa99f8a17874f18036e8ee7f30b1d205889005407a206"


def test_content_hash_refuses_a_row_without_the_fields():
    with pytest.raises(ValueError):
        data.content_hash({"language": "en", "original": "a", "replacement": "b"})


def test_family_key_folds_case_and_whitespace_only():
    assert data.family_key({"replacement": "  Tailscale "}) == "tailscale"
    assert data.family_key({"replacement": "Post  Hog"}) == "post hog"
    assert data.family_key({"replacement": "Jorge"}) != data.family_key({"replacement": "Jorje"})


def test_three_class_mapping_is_total_and_refuses_the_impossible_pair():
    for c, s in ((False, False), (True, False), (True, True)):
        assert data.labels_from_class(data.three_class(c, s)) == (c, s)
    with pytest.raises(ValueError):
        data.three_class(False, True)
    with pytest.raises(ValueError):
        data.three_class(1, 0)  # type: ignore[arg-type]


def test_family_split_keeps_families_whole_and_is_deterministic():
    a = data.split_by_family(SMOKE, "chunk-2a")
    b = data.split_by_family(list(reversed(SMOKE)), "chunk-2a")
    ids = lambda parts: {k: sorted(r["id"] for r in v) for k, v in parts.items()}  # noqa: E731
    assert ids(a) == ids(b), "input order must not change the split"
    assert sum(len(v) for v in a.values()) == len(SMOKE)
    assert data.cross_partition_families(a) == []
    assert all(len(v) > 0 for v in a.values()), ids(a)
    assert ids(a) != ids(data.split_by_family(SMOKE, "another-seed")) or len({data.family_key(r) for r in SMOKE}) < 4


def test_family_split_refuses_bad_fractions():
    with pytest.raises(ValueError):
        data.split_by_family(SMOKE, "s", (0.5, 0.5, 0.5))


def test_frozen_manifest_round_trip_and_tamper_detection(tmp_path):
    w, h = SMOKE[:8], SMOKE[8:]
    wp, hp = tmp_path / "w.jsonl", tmp_path / "h.jsonl"
    data.write_jsonl(wp, w)
    data.write_jsonl(hp, h)
    manifest = data.build_frozen_manifest([("working", wp, w), ("holdout", hp, h)], "now", "test")
    parts = {"working": wp, "holdout": hp}
    assert data.check_frozen(manifest, parts, {"working": w, "holdout": h}) == []
    # Renamed ids: digest changes, hash set does not.
    data.write_jsonl(wp, [dict(r, id="X" + r["id"]) for r in w])
    probs = data.check_frozen(manifest, parts, {"working": [dict(r, id="X" + r["id"]) for r in w], "holdout": h})
    assert any("file sha256" in p for p in probs) and not any("content-hash set" in p for p in probs)
    # Changed content: both.
    changed = [dict(w[0], pasted=w[0]["pasted"] + "!", edited=w[0]["edited"] + "!")] + w[1:]
    data.write_jsonl(wp, changed)
    probs = data.check_frozen(manifest, parts, {"working": changed, "holdout": h})
    assert any("content-hash set" in p for p in probs)
    # Wrong version is refused before anything else.
    assert any("hash_version" in p for p in data.check_frozen(dict(manifest, hash_version="v0"), parts, {"working": w, "holdout": h}))
    # Erased families are caught even when every hash matches.
    data.write_jsonl(wp, w)
    erased = json.loads(json.dumps(manifest))
    for part in erased["partitions"]:
        part["families"] = []
    assert any("families differ" in p for p in data.check_frozen(erased, parts, {"working": w, "holdout": h}))


def test_frozen_manifest_refuses_shared_hashes():
    with pytest.raises(ValueError):
        data.build_frozen_manifest([("a", Path("/dev/null"), SMOKE[:1]), ("b", Path("/dev/null"), SMOKE[:1])], "now", "t")


def test_leakage_by_hash_and_by_family_and_clean(tmp_path):
    data.write_jsonl(tmp_path / "w.jsonl", SMOKE)
    manifest = data.build_frozen_manifest([("working", tmp_path / "w.jsonl", SMOKE)], "now", "t")
    clean = data.TrainingManifest("j", "trained", "c", "t", {}, {"train": {"hashes": ["0" * 64], "families": ["zeta"]}}, "p", data.HASH_VERSION, {"k": "v"})
    assert data.leakage_problems(clean, manifest) == []
    by_hash = data.TrainingManifest("j", "trained", "c", "t", {}, {"dev": {"hashes": [data.content_hash(dict(SMOKE[3], id="renamed"))], "families": []}}, "p", data.HASH_VERSION, {"k": "v"})
    assert any("content hash" in p for p in data.leakage_problems(by_hash, manifest))
    by_family = data.TrainingManifest("j", "trained", "c", "t", {}, {"calibration": {"hashes": [], "families": ["TAILSCALE".casefold()]}}, "p", data.HASH_VERSION, {"k": "v"})
    assert any("alias famil" in p for p in data.leakage_problems(by_family, manifest))


def test_training_manifest_fails_closed(tmp_path):
    path = tmp_path / "tm.json"
    good = {
        "judge": "xenc-xlmr-base", "kind": "trained", "checkpoint": "ckpt", "tokenizer": "tok",
        "thresholds": {"correctionAndSafe": 0.9}, "provenance": "test", "hash_version": data.HASH_VERSION,
        "execution_identity": {"checkpoint_sha256": "1" * 64, "tokenizer_sha256": "2" * 64, "config_sha256": "3" * 64},
        "partitions": {n: {"hashes": [c * 64], "families": [f"family-{c}"]} for n, c in zip(data.TRAINING_PARTITIONS, "abc")},
    }
    path.write_text(json.dumps(good))
    loaded = data.load_training_manifest(path)
    assert loaded.problems == []
    assert loaded.summary()["execution_identity"] == good["execution_identity"]
    # The old fixture shape, one partition repeated three times, is refused now.
    path.write_text(json.dumps(dict(good, partitions={n: {"hashes": ["a" * 64], "families": ["x"]} for n in data.TRAINING_PARTITIONS})))
    assert any("shares content with another training partition" in p for p in data.load_training_manifest(path).problems)
    for bad_part, needle in (
        ({"hashes": ["not-a-hash"], "families": ["f"]}, "invalid content hash"),
        ({"hashes": ["d" * 64], "families": ["Not Canonical"]}, "non-canonical family"),
        ({"hashes": ["d" * 64, "d" * 64], "families": ["f"]}, "duplicate content hashes"),
        ({"hashes": ["d" * 64], "families": ["f", "f"]}, "duplicate families"),
        ({"hashes": ["d" * 64], "families": []}, "needs both hashes and families"),
    ):
        doc = json.loads(json.dumps(good))
        doc["partitions"]["dev"] = bad_part
        path.write_text(json.dumps(doc))
        assert any(needle in p for p in data.load_training_manifest(path).problems), needle
    path.write_text(json.dumps(dict(good, kind="untrained-arm", partitions={})))
    assert any("needs a trained manifest" in p for p in data.load_training_manifest(path).problems)
    path.write_text(json.dumps(dict(good, execution_identity={})))
    assert any("execution_identity" in p for p in data.load_training_manifest(path).problems)
    path.write_text(json.dumps(dict(good, execution_identity={"x": "y"})))
    probs = data.load_training_manifest(path).problems
    assert sum("must be a SHA-256 digest" in p for p in probs) == 3
    for missing in ("checkpoint_sha256", "tokenizer_sha256", "config_sha256"):
        ident = {k: v for k, v in good["execution_identity"].items() if k != missing}
        path.write_text(json.dumps(dict(good, execution_identity=ident)))
        assert any(missing in p for p in data.load_training_manifest(path).problems), missing
    for key in good:
        doc = dict(good)
        del doc[key]
        path.write_text(json.dumps(doc))
        assert data.load_training_manifest(path).problems, f"missing {key} must be a problem"
    path.write_text(json.dumps(dict(good, judge="rules", kind="untrained-arm")))
    assert any("untrained arm declares data" in p for p in data.load_training_manifest(path).problems)
    untrained_identity = {"config_sha256": "9" * 64, "environment": "macOS 27 test"}
    path.write_text(json.dumps(dict(good, judge="rules", kind="untrained-arm", partitions={}, execution_identity=untrained_identity)))
    assert data.load_training_manifest(path).problems == []
    path.write_text(json.dumps(dict(good, judge="rules", kind="untrained-arm", partitions={})))
    assert any("environment is required" in p for p in data.load_training_manifest(path).problems)
    assert data.execution_identity_problems({"config_sha256": "short", "environment": "m"}, "untrained-arm") == ["execution_identity.config_sha256 must be a SHA-256 digest"]
    assert data.execution_identity_problems(untrained_identity, "bogus-kind") == ["execution_identity requires a recognised training kind"]
    path.write_text(json.dumps(dict(good, partitions={"train": {"hashes": [], "families": []}})))
    assert data.load_training_manifest(path).problems
    path.write_text(json.dumps(dict(good, partitions=dict(good["partitions"], extra={"hashes": [], "families": []}))))
    assert any("unknown partition" in p for p in data.load_training_manifest(path).problems)
    path.write_text("not json")
    assert data.load_training_manifest(path).problems
    assert data.load_training_manifest(tmp_path / "missing.json").problems


def test_pack_candidates_are_unlabelled_and_sentence_less(tmp_path):
    packs = tmp_path / "packs"
    packs.mkdir()
    (packs / "tech.json").write_text(json.dumps({"AngularJS": ["angularge", "inkyolarge"], "Tailscale": ["tail scale"]}))
    cands = data.pack_candidates(packs)
    assert len(cands) == 3
    assert all(c["label"] is None and c["review_status"] == "unreviewed" and c["pasted"] is None for c in cands)
    assert {c["replacement"] for c in cands} == {"AngularJS", "Tailscale"}
    assert len({c["id"] for c in cands}) == 3
    (packs / "bad.json").write_text(json.dumps(["not", "an", "object"]))
    with pytest.raises(ValueError):
        data.pack_candidates(packs)


def test_polish_spans_are_mined_with_bounds_and_skips():
    rows = [
        {"id": "A", "asr_input": "we ship on july eleventh and rest", "expected_output": "we ship on July 11th and rest"},
        {"id": "B", "asr_input": "same same", "expected_output": "same same"},
        {"id": "C", "asr_input": "one two three four five six", "expected_output": "uno dos tres cuatro cinco seis"},
        {"id": "D", "asr_input": "the cat the cat sat", "expected_output": "the dog the cat sat"},
        {"id": "E", "asr_input": 5, "expected_output": "x"},
    ]
    cands, skipped = data.mine_polish_spans(rows)
    assert [c["source_id"] for c in cands] == ["A"]
    assert cands[0]["original"] == "july eleventh" and cands[0]["replacement"] == "July 11th"
    assert cands[0]["edited"] == "we ship on July 11th and rest"
    assert cands[0]["label"] is None and cands[0]["review_status"] == "unreviewed"
    assert skipped["no_change"] == 1 and skipped["run_too_long"] == 1 and skipped["missing_fields"] == 1
    assert skipped["original_ambiguous"] == 1


def test_real_packs_and_frozen_manifest_produce_candidates_that_avoid_frozen_families():
    packs = ROOT / "Sources/EnviousWisprPostProcessing/Resources/Packs"
    manifest = json.loads((ROOT / "scripts/eval/corpus/edit-judge-frozen-manifest.json").read_text())
    cands = data.pack_candidates(packs)
    assert len(cands) > 1000
    ff = data.frozen_families(manifest)
    survivors = [c for c in cands if data.family_key(c) not in ff]
    assert 0 < len(survivors) < len(cands), "some pack families are frozen and must be dropped"


def test_shipped_frozen_manifest_matches_the_shipped_files():
    manifest, loaded, problems = gate.load_frozen()
    assert problems == []
    assert manifest["hash_version"] == data.HASH_VERSION
    sizes = {p["name"]: p["rows"] for p in manifest["partitions"]}
    assert sizes == {"working": len(loaded["working"]), "holdout": len(loaded["holdout"])}
    assert sizes["working"] + sizes["holdout"] == 209
    assert len(data.frozen_hashes(manifest)) == 209


def test_stage_one_shape_drop_matches_the_swift_fixtures():
    # The same pairs `EditRunShapeTests` pins on the Swift side.
    dropped = [("monday", "Monday"), ("figma", "Figma"), ("json", "JSON"), ("Github", "GitHub"), ("its", "it's"), ("hello", "hello!"),
               ("however", "however,"), ("the ceo", "the CEO"), ("Hello", "hello"), ("amanhã", "Amanhã"), ("sign up", "Sign Up"), ("e-mail", "E-Mail")]
    kept = [("post hog", "PostHog"), ("e mail", "e-mail"), ("well-known", "well known"), ("git lab", "GitLab"), ("bird", "birds"),
            ("Sarah", "Saira"), ("Mueller", "Müller"), ("pree yanka", "Priyanka"), ("tu", "tú"), ("same", "same"), ("", "x"), ("a b", "a b c")]
    # Combining marks (Devanagari matras) are letters to Swift's Character
    # and must stay in the comparison here too: an added matra is a real edit.
    kept += [("अमित", "अमिता"), ("प्रियांका", "प्रियंका")]
    for o, r in dropped:
        assert data.stage_one_shape_drop(o, r), (o, r)
    for o, r in kept:
        assert not data.stage_one_shape_drop(o, r), (o, r)


def test_training_manifest_accepts_the_optional_cross_dev_partition_and_nothing_else_unknown(tmp_path):
    import json as _json
    base = {"judge": "x", "kind": "trained", "checkpoint": "c", "tokenizer": "t", "thresholds": {}, "provenance": "p", "hash_version": data.HASH_VERSION,
            "execution_identity": {"checkpoint_sha256": "0" * 64, "tokenizer_sha256": "0" * 64, "config_sha256": "0" * 64},
            "partitions": {n: {"hashes": [c * 64], "families": [c]} for n, c in (("train", "a"), ("dev", "d"), ("calibration", "e"))}}
    with_cross = dict(base, partitions={**base["partitions"], "cross_dev": {"hashes": ["b" * 64], "families": ["g"]}})
    path = tmp_path / "m.json"
    path.write_text(_json.dumps(with_cross))
    assert data.load_training_manifest(path).problems == []
    unknown = dict(base, partitions={**base["partitions"], "holdout": {"hashes": [], "families": []}})
    path.write_text(_json.dumps(unknown))
    assert any("unknown partition 'holdout'" in p for p in data.load_training_manifest(path).problems)
