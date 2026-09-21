"""Harness-contract tests for scripts/eval/probe_edit_judge_compatibility.py (#996 chunk 2b).

The pure parts only: the pair-encoding mirror, the id comparison, the
placement verdict and the fixture hygiene (no frozen row, no frozen family).
No model, tokenizer download or Core ML call happens here.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts/eval"))

import edit_judge_data as data  # noqa: E402
import probe_edit_judge_compatibility as probe  # noqa: E402


def _fake_encode(text: str) -> list[int]:
    # One id per whitespace token, deterministic from the token's length, so a
    # prefix changes the id sequence and truncation is observable.
    return [1000 + len(tok) for tok in text.split()]


def _contract(template: str, token_types: str) -> dict:
    spec = {"family": "roberta_bpe", "template": template, "token_types": token_types}
    return probe.build_contract("t", spec, {"pad": 0, "cls": 101, "sep": 102, "bos": 5, "eos": 6})


def test_compare_ids_names_the_first_divergence_never_the_text():
    assert probe.compare_ids([1, 2, 3], [1, 2, 3]) is None
    assert probe.compare_ids([1, 2, 3], [1, 9, 3]) == "first divergence at index 1: expected 2, got 9 (lengths 3 vs 3)"
    assert probe.compare_ids([1, 2], [1, 2, 3]) == "length differs: expected 2, got 3"


def test_bert_pair_mirror_assembles_cls_sep_segments_and_pads():
    c = _contract("bert_pair", "bert_segments")
    enc = probe.mirror_pair_encoding(c, _fake_encode, "a bb", "ccc")
    in_ids = _fake_encode("Edit: a bb")
    out_ids = _fake_encode("Sentence: ccc")
    expect_ids = [101] + in_ids + [102] + out_ids + [102]
    assert enc["input_ids"][: len(expect_ids)] == expect_ids
    assert enc["input_ids"][len(expect_ids) :] == [0] * (128 - len(expect_ids))
    assert enc["attention_mask"] == [1] * len(expect_ids) + [0] * (128 - len(expect_ids))
    segs = [0] * (1 + len(in_ids) + 1) + [1] * (len(out_ids) + 1)
    assert enc["token_type_ids"][: len(segs)] == segs
    assert enc["token_type_ids"][len(segs) :] == [0] * (128 - len(segs))
    assert len(enc["input_ids"]) == len(enc["attention_mask"]) == len(enc["token_type_ids"]) == 128


def test_roberta_pair_mirror_uses_bos_double_eos_and_no_segments():
    c = _contract("roberta_pair", "none")
    enc = probe.mirror_pair_encoding(c, _fake_encode, "a", "b")
    in_ids = _fake_encode("Edit: a")
    out_ids = _fake_encode("Sentence: b")
    expect = [5] + in_ids + [6, 6] + out_ids + [6]
    assert enc["input_ids"][: len(expect)] == expect
    assert set(enc["token_type_ids"]) == {0}


def test_mirror_truncates_input_head_tail_and_output_head_tail():
    c = _contract("bert_pair", "bert_segments")
    long_input = " ".join(f"w{i}" for i in range(200))
    long_output = " ".join(f"v{i}" for i in range(200))
    enc = probe.mirror_pair_encoding(c, _fake_encode, long_input, long_output)
    assert len(enc["input_ids"]) == 128 and sum(enc["attention_mask"]) == 128
    # Input capped at maxLength - specials - minOutput = 128 - 3 - 32 = 93 (48 head + 45 tail),
    # output gets the remaining budget max(32, 128 - 93 - 3) = 32.
    in_ids = _fake_encode("Edit: " + long_input)
    head = min(48, 93 - 16)
    expect_in = in_ids[:head] + in_ids[-(93 - head) :]
    assert enc["input_ids"][1 : 1 + 93] == expect_in
    assert enc["input_ids"][1 + 93] == 102
    out_ids = _fake_encode("Sentence: " + long_output)
    ohead = min(40, 32 - 24)
    expect_out = out_ids[:ohead] + out_ids[-(32 - ohead) :]
    assert enc["input_ids"][1 + 93 + 1 : 1 + 93 + 1 + 32] == expect_out
    assert enc["input_ids"][-1] == 102


def test_placement_verdict_refuses_incomplete_batches_and_bad_references():
    ref = [[0.1, 0.5, 0.2], [0.9, 0.0, 0.1], [0.2, 0.2, 0.7]]
    assert probe.placement_verdict(ref, [])["ok"] is False
    assert probe.placement_verdict(ref, ref[:2])["ok"] is False
    assert probe.placement_verdict(ref, ref + [[0.0, 0.0, 1.0]])["ok"] is False
    assert probe.placement_verdict(ref, [r[:2] for r in ref])["ok"] is False
    assert probe.placement_verdict([[0.1, 0.5]] * 3, [[0.1, 0.5]] * 3)["ok"] is False
    assert probe.placement_verdict(ref[:1], ref[:1])["ok"] is False
    assert probe.placement_verdict([[float("inf"), 0.0, 0.0]] + ref[1:], [[1.0, 0.0, 0.0]] + ref[1:])["error"] == "reference logits are nonfinite"
    assert probe.placement_verdict([[0.1, 0.5, 0.2]] * 3, [[0.1, 0.5, 0.2]] * 3)["error"] == "reference fixtures are not discriminating"


def test_placement_verdict_flags_nonfinite_constant_flips_and_drift():
    ref = [[0.1, 0.5, 0.2], [0.9, 0.0, 0.1], [0.2, 0.2, 0.7]]
    assert probe.placement_verdict(ref, [list(r) for r in ref])["ok"] is True
    nan = probe.placement_verdict(ref, [[float("nan"), 0.5, 0.2]] + ref[1:])
    assert nan["ok"] is False and nan["nonfinite"] == 1
    const = probe.placement_verdict(ref, [[0.3, 0.3, 0.3]] * 3)
    assert const["ok"] is False and const["constant_output"] is True
    flip = probe.placement_verdict(ref, [[0.6, 0.5, 0.2]] + ref[1:])
    assert flip["ok"] is False and flip["argmax_flips"] == 1
    drift = probe.placement_verdict(ref, [[0.1, 0.5, 0.2 + 0.01]] + ref[1:])
    assert drift["ok"] is False and abs(drift["max_abs_drift"] - 0.01) < 1e-9
    assert probe.placement_verdict(ref, [[0.1, 0.5, 0.2 + 5e-4]] + ref[1:])["ok"] is True


def test_placement_verdict_without_a_tolerance_reports_drift_and_still_refuses_flips_nonfinite_and_constant():
    # The half-precision bar (#996, 2026-09-21): drift is reported, never
    # gated; every other refusal is unchanged. Same drifted output, two bars.
    ref = [[0.1, 0.5, 0.2], [0.9, 0.0, 0.1], [0.2, 0.2, 0.7]]
    drifted = [[0.1, 0.5, 0.2 + 0.24]] + ref[1:]
    assert probe.placement_verdict(ref, drifted, tolerance=1e-2)["ok"] is False
    reported = probe.placement_verdict(ref, drifted, tolerance=None)
    assert reported["ok"] is True and abs(reported["max_abs_drift"] - 0.24) < 1e-9 and reported["tolerance"] is None
    assert probe.placement_verdict(ref, [[0.6, 0.5, 0.2]] + ref[1:], tolerance=None)["ok"] is False
    assert probe.placement_verdict(ref, [[float("nan"), 0.5, 0.2]] + ref[1:], tolerance=None)["ok"] is False
    assert probe.placement_verdict(ref, [[0.3, 0.3, 0.3]] * 3, tolerance=None)["ok"] is False


def test_fixtures_cover_four_languages_with_non_latin_and_are_disjoint_from_the_frozen_set():
    langs = {l for l, _ in probe.TEXT_FIXTURES}
    assert len(langs) >= 4
    assert {"hi", "ar", "zh", "ja"} <= langs
    assert len(probe.TEXT_FIXTURES) >= 12
    manifest = json.loads((ROOT / "scripts/eval/corpus/edit-judge-frozen-manifest.json").read_text())
    frozen_families = data.frozen_families(manifest)
    for edit, _ in probe.PAIR_FIXTURES:
        replacement = edit.split("→")[-1].strip()
        assert data.family_key({"replacement": replacement}) not in frozen_families, replacement


def test_build_contract_shapes_follow_the_template():
    bert = _contract("bert_pair", "bert_segments")
    assert bert["pairTemplate"]["sequence"] == ["cls", "input", "sep", "output", "sep"]
    assert bert["specialsBudget"] == 3 and bert["tokenTypePolicy"]["needsSegmentIds"] is True
    rob = _contract("roberta_pair", "none")
    assert rob["pairTemplate"]["sequence"] == ["bos", "input", "eos", "eos", "output", "eos"]
    assert rob["specialsBudget"] == 4 and rob["tokenTypePolicy"]["kind"] == "none"
    assert bert["maxLength"] == rob["maxLength"] == probe.MAX_LENGTH == 128


def test_toolchain_pin_names_the_shipped_converters_versions():
    assert probe.EXPECTED_TOOLCHAIN == {"transformers": "4.50.0", "coremltools": "9.0", "numpy": "2.3.5"}
    # The pins and the requirements file are one fact: a drift here is a
    # venv that the probe refuses or, worse, one it accepts with a NumPy the
    # converter breaks on (apple/coremltools#2633).
    reqs = (ROOT / "scripts/eval/edit-judge-requirements.txt").read_text()
    for key, want in probe.EXPECTED_TOOLCHAIN.items():
        assert f"{key}=={want}\n" in reqs, key


def test_toolchain_problems_fail_closed_on_missing_and_wrong_keys():
    good = {"transformers": "4.50.0", "coremltools": "9.0", "numpy": "2.3.5", "torch": "anything"}
    assert probe.toolchain_problems(good) == []
    assert probe.toolchain_problems({**good, "numpy": "2.5.3"}) == ["numpy '2.5.3' is not the pinned '2.3.5'"]
    missing = dict(good)
    del missing["numpy"]
    assert probe.toolchain_problems(missing) == ["numpy None is not the pinned '2.3.5'"]


def test_upstream_tokenizer_is_pinned_in_the_runner_only():
    runner = (ROOT / "scripts/eval/alias_runner/Package.swift").read_text()
    assert 'url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"' in runner
    assert '.product(name: "Tokenizers", package: "swift-transformers")' in runner
    root = (ROOT / "Package.swift").read_text()
    assert "swift-transformers" not in root, "the app must not take the upstream tokenizer until parity is proven and the founder approves"
