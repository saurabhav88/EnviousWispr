"""Harness-contract tests for the alias veto (#996): policy on a tiny synthetic resource."""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts/eval"))

from edit_judge_veto import AliasVeto, normalise_token  # noqa: E402


def _resource(tmp_path: Path) -> Path:
    d = tmp_path / "edit-judge-veto-test"
    d.mkdir(parents=True)
    files = {}
    for lang, rows in {"en": [("basil", 3.65), ("elena", 3.75), ("bluetooth", 3.75), ("pinecone", 2.07), ("lowkey", 2.74), ("rare", 2.2)], "de": [("ampel", 3.5)]}.items():
        path = d / f"{lang}.tsv"
        path.write_text("".join(f"{w}\t{z:.2f}\n" for w, z in sorted(rows)), encoding="utf-8")
        files[lang] = {"path": path.name, "words": len(rows), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    dpath = d / "en-dictionary.txt"
    dpath.write_text("mastodont\nsnowplow\n", encoding="utf-8")
    files["en-dictionary"] = {"path": dpath.name, "words": 2, "sha256": hashlib.sha256(dpath.read_bytes()).hexdigest()}
    manifest = {"version": "edit-judge-veto-test", "policy": {"zipf_list_min": 2.0, "zipf_single_min": 3.0, "zipf_joined_min": 2.0, "dictionary_min_letters": 3}, "languages": ["en", "de"], "files": files}
    (d / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return d


def test_single_token_common_word_is_vetoed_and_rare_word_is_not(tmp_path):
    v = AliasVeto(_resource(tmp_path))
    assert v.veto("basil", "en").vetoed
    assert v.veto("Elena", "en").vetoed  # casefold
    assert v.veto("rare", "en").vetoed is False  # 2.2 < single floor 3.0
    assert v.veto("kubernetes", "en").vetoed is False
    assert v.veto("mastodont", "en").vetoed  # dictionary
    assert v.veto("ampel", "en").vetoed is False  # German word is not checked for an English row
    assert v.veto("ampel", "de").vetoed
    assert v.veto("basil", "de").vetoed  # English is always checked too


def test_multi_token_joined_form_rule(tmp_path):
    v = AliasVeto(_resource(tmp_path))
    assert v.veto("pine cone", "en").vetoed  # joined 2.07 >= joined floor 2.0
    assert v.veto("low key", "en").vetoed
    assert v.veto("blue tooth", "en").vetoed
    assert v.veto("snow plow", "en").vetoed  # joined form in the dictionary
    assert v.veto("post hog", "en").vetoed is False
    assert v.veto("cuber netties", "en").vetoed is False
    assert v.veto("ra re", "en").vetoed  # joined 'rare' 2.2 >= 2.0: the joined floor is lower than the single floor


def test_uncovered_language_abstains_and_apply_moves_safe_mass(tmp_path):
    v = AliasVeto(_resource(tmp_path))
    d = v.veto("hello", "sw")
    assert d.covered is False and d.vetoed is False
    assert v.apply([0.1, 0.2, 0.7], "hello", "sw") == pytest.approx([0.1, 0.9, 0.0])  # uncovered: no alias
    assert v.apply([0.1, 0.2, 0.7], "basil", "en") == pytest.approx([0.1, 0.9, 0.0])  # vetoed
    assert v.apply([0.1, 0.2, 0.7], "cuber netties", "en") == [0.1, 0.2, 0.7]  # untouched
    assert v.covers("en-US") and not v.covers("sw")


def test_resource_digest_mismatch_is_refused(tmp_path):
    d = _resource(tmp_path)
    (d / "en.tsv").write_text("basil\t3.65\n", encoding="utf-8")
    with pytest.raises(RuntimeError, match="digest"):
        AliasVeto(d)


def test_identity_names_version_digest_and_policy(tmp_path):
    v = AliasVeto(_resource(tmp_path))
    ident = v.identity()
    assert ident["veto_version"] == "edit-judge-veto-test"
    assert len(ident["veto_manifest_sha256"]) == 64
    assert ident["veto_policy"]["zipf_single_min"] == 3.0


def test_normalise_token_strips_punctuation_and_case():
    assert normalise_token("  Basil,") == "basil"
    assert normalise_token("(Élena)") == "élena"
    assert normalise_token("...") == ""


def test_normalise_token_keeps_combining_marks_and_vowel_signs():
    # Devanagari vowel signs and Arabic marks are part of the word; only edge punctuation goes.
    assert normalise_token("वैष्णवी") == "वैष्णवी"
    assert normalise_token("शुभांगी,") == "शुभांगी"
    assert normalise_token("«نورة»") == "نورة"
    assert normalise_token("café") == "café"  # NFC composes the decomposed accent
    assert normalise_token("\"Élena\"") == "élena"


def test_loader_refuses_advertised_language_without_table_or_empty_table(tmp_path):
    d = _resource(tmp_path)
    manifest = json.loads((d / "manifest.json").read_text())
    manifest["languages"].append("fr")
    (d / "manifest.json").write_text(json.dumps(manifest))
    with pytest.raises(RuntimeError, match="advertised languages"):
        AliasVeto(d)
    d2 = _resource(tmp_path / "second")
    (d2 / "de.tsv").write_text("", encoding="utf-8")
    m2 = json.loads((d2 / "manifest.json").read_text())
    m2["files"]["de"]["sha256"] = hashlib.sha256(b"").hexdigest()
    (d2 / "manifest.json").write_text(json.dumps(m2))
    with pytest.raises(RuntimeError, match="empty"):
        AliasVeto(d2)


def test_identity_binds_the_implementation_file(tmp_path):
    v = AliasVeto(_resource(tmp_path))
    ident = v.identity()
    assert ident["veto_implementation_sha256"] == hashlib.sha256((ROOT / "scripts/eval/edit_judge_veto.py").read_bytes()).hexdigest()


def test_qualification_needs_the_fresh_bound_not_a_dev_threshold():
    import calibrate_edit_judge as cal

    assert cal.qualifies(True, 0.96) is True
    assert cal.qualifies(True, 0.95) is True
    assert cal.qualifies(True, 0.8847) is False  # dev passes, fresh fails: the v5 case
    assert cal.qualifies(True, None) is False
    assert cal.qualifies(False, 0.99) is False


def test_prior_exposure_refuses_renamed_and_relabelled_copies(tmp_path):
    import calibrate_edit_judge as cal
    import edit_judge_data as data

    run = tmp_path / "run"
    c = run / "calibrations" / "one"
    c.mkdir(parents=True)
    row = {"id": "A", "stratum": "domain", "language": "en", "pasted": "ctx orig", "edited": "ctx repl", "original": "orig", "replacement": "repl", "correction": True, "safe_alias": True, "label_source": "t"}
    (c / "training-manifest.json").write_text(json.dumps({"partitions": {"calibration": data.partition_manifest([row])}}))
    hashes, families = cal.prior_exposure(run)
    assert len(hashes) == 1 and families == {"repl"}
    renamed = dict(row, id="B", correction=False, safe_alias=False)
    same_family = dict(row, id="C", pasted="new ctx orig", edited="new ctx repl")
    fresh = {"id": "D", "stratum": "domain", "language": "en", "pasted": "x zz", "edited": "x yy", "original": "zz", "replacement": "yy", "correction": True, "safe_alias": True, "label_source": "t"}
    assert cal.exposed_rows([renamed, same_family, fresh], hashes, families) == ["B", "C"]
    assert cal.prior_exposure(tmp_path / "no-run") == (set(), set())


def test_granted_unsafe_groups_by_family_not_template():
    import calibrate_edit_judge as cal

    decisions = [
        {"family": "keycloak", "safe_alias": True, "label_safe": False},
        {"family": "keycloak", "safe_alias": True, "label_safe": False},
        {"family": "하준우", "safe_alias": True, "label_safe": False},
        {"family": "keycloak", "safe_alias": False, "label_safe": False},
        {"family": "tailscale", "safe_alias": True, "label_safe": True},
    ]
    assert cal.granted_unsafe_by_family(decisions) == [("keycloak", 2), ("하준우", 1)]
