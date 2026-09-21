"""Tests for the edit-judge authoring pipeline (#996 chunk 4a-ii).

Pure helpers only: template assembly and its counted repairs, screening
against an exclusion index, the blind prompt's information boundary, label
parsing and the unanimity join. File wiring is exercised by the CLI in the
receipts, not here.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import edit_judge_authoring as authoring  # noqa: E402
import edit_judge_data as data  # noqa: E402

KINDS = {
    "phonetic_person_name": {"kind": "phonetic_person_name", "stratum": "person", "correction": True},
    "tense_aspect": {"kind": "tense_aspect", "stratum": "grammar_punctuation", "correction": False},
}
SRC = "authored by test-writer 2026-09-19 for #996 tests"


def _row(i: int, kind: str, template: str, original: str, replacement: str) -> dict:
    return {"id": f"T-{i:03d}", "kind": kind, "language": "en", "template": template, "original": original, "replacement": replacement, "frame": "frame", "label_source": SRC}


def test_assemble_builds_both_sentences_from_one_template_and_resolves_kind():
    full, why, repair = authoring.assemble(_row(1, "phonetic_person_name", "Ask {X} to review the draft.", "Sarah", "Saira"), KINDS["phonetic_person_name"])
    assert why is None and repair is None
    assert full["pasted"] == "Ask Sarah to review the draft." and full["edited"] == "Ask Saira to review the draft."
    assert full["correction"] is True and full["stratum"] == "person" and full["safe_alias"] is False


@pytest.mark.parametrize("template,expected_repair", [("Ask {X to review.", "repaired_marker"), ("Ask {{X}} to review.", "repaired_double_marker")])
def test_the_two_author_slips_are_repaired_and_counted(template, expected_repair):
    full, why, repair = authoring.assemble(_row(1, "phonetic_person_name", template, "Sarah", "Saira"), KINDS["phonetic_person_name"])
    assert why is None and repair == expected_repair
    assert full["pasted"] == "Ask Sarah to review."


@pytest.mark.parametrize("template,original,replacement,reason", [
    ("Ask {X} and {X} to review.", "Sarah", "Saira", "template_marker_count"),
    ("Ask {X} to review {the} draft.", "Sarah", "Saira", "stray_brace"),
    ("Ask {X} to review.", "Sarah", "Sarah", "original_equals_replacement"),
    ("Ask {X} to review, Saira.", "Sarah", "Saira", "run_repeated_in_template"),
])
def test_invalid_templates_are_rejected_with_a_named_reason(template, original, replacement, reason):
    full, why, _ = authoring.assemble(_row(1, "phonetic_person_name", template, original, replacement), KINDS["phonetic_person_name"])
    assert full is None and why == reason


def test_screen_rejects_unknown_kinds_and_excluded_families_and_keeps_the_rest():
    excl = authoring.Exclusion()
    excl.add_rows("earlier", [{"language": "en", "pasted": "x a y", "edited": "x Saira y", "original": "a", "replacement": "Saira"}])
    rows = [
        _row(1, "phonetic_person_name", "Ask {X} to review the draft.", "Sarah", "Saira"),  # family Saira already taken
        _row(2, "phonetic_person_name", "Loop {X} in on the thread.", "Pree Anka", "Priyanka"),
        _row(3, "no_such_kind", "Loop {X} in.", "a", "b"),
        _row(4, "tense_aspect", "She {X} the report yesterday.", "finish", "finished"),
    ]
    kept, counts, rejects = authoring.screen(rows, KINDS, excl, probe_families={data.family_key({"replacement": "finished"})})
    assert [r["id"] for r in kept] == ["T-002"]
    assert counts["excluded_overlap"] == 1 and counts["unknown_kind"] == 1 and counts["excluded_probe"] == 1 and counts["kept"] == 1
    assert {r["reason"] for r in rejects} == {"overlap", "unknown_kind", "probe"}


def test_blind_prompt_carries_rows_under_opaque_ids_never_kind_label_frame_or_provenance():
    full, _, _ = authoring.assemble(_row(1, "phonetic_person_name", "Ask {X} to review.", "Sarah", "Saira"), KINDS["phonetic_person_name"])
    full["id"] = "XS-N-001"  # an author id whose letters hint at the batch
    id_map = authoring.review_ids([full], seed=1)
    prompt = authoring.blind_prompt([full], id_map)
    block = prompt.split("```jsonl\n", 1)[1]
    obj = json.loads(block.strip().splitlines()[0])
    assert set(obj) == {"id", "language", "pasted", "edited", "original", "replacement"}
    assert obj["id"] == "R-0001" and "XS-N-001" not in prompt
    assert "phonetic_person_name" not in prompt and SRC not in prompt and '"correction"' not in block


def test_review_ids_are_a_shuffled_bijection_and_refuse_duplicate_rows():
    rows = [{"id": f"XS-G-{i:03d}"} for i in range(1, 51)]
    id_map = authoring.review_ids(rows, seed=7)
    assert sorted(id_map.values()) == [f"R-{n:04d}" for n in range(1, 51)]
    assert [id_map[r["id"]] for r in rows] != [f"R-{n:04d}" for n in range(1, 51)]  # not author order
    with pytest.raises(ValueError, match="duplicate"):
        authoring.review_ids(rows + [rows[0]], seed=7)


def test_parse_labels_refuses_the_same_id_voted_twice():
    with pytest.raises(ValueError, match="twice"):
        authoring.parse_labels('```jsonl\n{"id": "R-0001", "correction": true}\n{"id": "R-0001", "correction": false}\n```', {"R-0001"})


def test_join_refuses_fewer_than_two_labellers_and_non_boolean_votes():
    full, _, _ = authoring.assemble(_row(1, "phonetic_person_name", "Ask {X} to review.", "Sarah", "Saira"), KINDS["phonetic_person_name"])
    with pytest.raises(ValueError, match="at least 2"):
        authoring.join_unanimous([full], {"a": {"T-001": {"correction": True}}})
    with pytest.raises(ValueError, match="at least 2"):
        authoring.join_unanimous([full], {})
    with pytest.raises(ValueError, match="non-boolean"):
        authoring.join_unanimous([full], {"a": {"T-001": {"correction": True}}, "b": {"T-001": {"correction": "yes"}}})


def test_dedupe_collapses_agreeing_duplicates_and_quarantines_conflicting_ones():
    a, _, _ = authoring.assemble(_row(1, "phonetic_person_name", "Ask {X} to review.", "Sarah", "Saira"), KINDS["phonetic_person_name"])
    b, _, _ = authoring.assemble(_row(2, "phonetic_person_name", "Ask {X} to review.", "Sarah", "Saira"), KINDS["phonetic_person_name"])
    c, _, _ = authoring.assemble(_row(3, "tense_aspect", "Ask {X} to review.", "Sarah", "Saira"), KINDS["tense_aspect"])  # same case, opposite label
    kept, quarantined = authoring.dedupe([a, b])
    assert [r["id"] for r in kept] == ["T-001"] and quarantined == []
    kept2, quarantined2 = authoring.dedupe([a, b, c])
    assert kept2 == [] and len(quarantined2) == 1 and {m["id"] for m in quarantined2[0]["members"]} == {"T-001", "T-002", "T-003"}


def test_exclusion_split_must_exist_and_match_its_manifest(tmp_path):
    excl = authoring.Exclusion()
    with pytest.raises(FileNotFoundError):
        excl.add_split(tmp_path / "nope")
    split = tmp_path / "dev-x"
    split.mkdir()
    full, _, _ = authoring.assemble(_row(1, "phonetic_person_name", "Ask {X} to review.", "Sarah", "Saira"), KINDS["phonetic_person_name"])
    for part in ("train", "dev", "calibration"):
        data.write_jsonl(split / f"{part}.jsonl", [full])
    manifest = {"partitions": {p: {"path": f"{p}.jsonl", "file_sha256": data.sha256_file(split / f"{p}.jsonl")} for p in ("train", "dev", "calibration")}}
    (split / "split-manifest.json").write_text(json.dumps(manifest))
    excl.add_split(split)
    assert excl.excludes(full) and len(excl.digests) == 3
    (split / "dev.jsonl").write_text("")
    with pytest.raises(ValueError, match="digest"):
        authoring.Exclusion().add_split(split)


def test_parse_labels_keeps_only_known_ids_with_boolean_labels():
    text = '```jsonl\n{"id": "T-001", "correction": true, "confidence": 5, "note": "ok"}\n{"id": "T-999", "correction": false}\n{"id": "T-002", "correction": "yes"}\nnot json\n```'
    labels, bad = authoring.parse_labels(text, {"T-001", "T-002"})
    assert list(labels) == ["T-001"] and labels["T-001"]["correction"] is True
    assert bad == 2


def test_join_keeps_a_row_only_when_every_labeller_agrees_with_the_author():
    rows = []
    for i, (kind, t, o, r) in enumerate([("phonetic_person_name", "Ask {X} to review.", "Sarah", "Saira"), ("tense_aspect", "She {X} it.", "finish", "finished"), ("tense_aspect", "He {X} it.", "run", "ran")], 1):
        full, _, _ = authoring.assemble(_row(i, kind, t, o, r), KINDS[kind])
        rows.append(full)
    labels = {
        "a": {"T-001": {"correction": True}, "T-002": {"correction": False}, "T-003": {"correction": True}},
        "b": {"T-001": {"correction": True}, "T-002": {"correction": False}},
    }
    kept, dropped, by_kind = authoring.join_unanimous(rows, labels)
    assert [r["id"] for r in kept] == ["T-001", "T-002"]
    assert all(r["review_status"] == authoring.BLIND_LABEL_STATUS for r in kept)
    assert kept[0]["label_source"].endswith("blind labels agree: a, b")
    assert {d["id"]: d["reason"] for d in dropped} == {"T-003": "unlabelled"}
    # A disagreement is recorded with both votes, never silently dropped.
    labels["b"]["T-003"] = {"correction": False, "note": "grammar"}
    kept2, dropped2, _ = authoring.join_unanimous(rows, labels)
    assert [r["id"] for r in kept2] == ["T-001", "T-002"]
    assert dropped2[0]["reason"] == "disagree" and dropped2[0]["votes"] == {"a": True, "b": False}


def test_parse_block_takes_the_last_fenced_block_and_counts_bad_lines():
    rows, bad = authoring.parse_block("```json\n{\"id\": 1}\n```\ntext\n```jsonl\n{\"id\": 2}\n{broken\n```")
    assert rows == [{"id": 2}] and bad == 1


def test_mined_name_rows_take_one_garble_per_name_and_skip_common_words():
    pool = [
        {"canonical": "schonberger", "shipped_aliases": ["schunberger", "x"]},
        {"canonical": "brown", "shipped_aliases": ["braun"]},  # common English word: skipped
        {"canonical": "notaname", "shipped_aliases": ["notanam"]},
        {"canonical": "zzzzzzz", "shipped_aliases": ["qqqqqqq"]},  # a name whose only alias is unrelated: skipped
    ]
    rows = authoring.mined_name_rows(pool, {"schonberger", "brown", "zzzzzzz"}, ["Ask {X} today."], 10, 1)
    assert [(r["original"], r["replacement"]) for r in rows] == [("Schunberger", "Schonberger")]
    assert rows[0]["review_status"] == authoring.MINED_REVIEW_STATUS == "mined-heuristic-labelled"
    assert rows[0]["label_source"].startswith("authored by parakeet-tts-roundtrip") and "no row-level review" in rows[0]["label_source"]
    assert (rows[0]["mined_canonical"], rows[0]["mined_alias"]) == ("schonberger", "schunberger")
    assert authoring.MINED_REVIEW_STATUS in data.REVIEWED_STATUSES


def _labelled_rows(tmp_path):
    rows = []
    for i, (kind, t, o, r) in enumerate([("phonetic_person_name", "Ask {X} to review.", "Sarah", "Saira"), ("tense_aspect", "She {X} it.", "finish", "finished")], 1):
        full, _, _ = authoring.assemble(_row(i, kind, t, o, r), KINDS[kind])
        rows.append(full)
    path = tmp_path / "rows.jsonl"
    data.write_jsonl(path, rows)
    return rows, path


def _answer(session_dir: Path, votes: dict[str, bool]) -> None:
    id_map = json.loads((session_dir / "id-map.json").read_text())["map"]
    lines = [json.dumps({"id": id_map[k], "correction": v, "confidence": 5, "note": ""}) for k, v in votes.items()]
    (session_dir / "batch-000-answer.md").write_text("```jsonl\n" + "\n".join(lines) + "\n```\n")


def test_cli_labelling_session_is_bound_end_to_end(tmp_path):
    rows, rows_path = _labelled_rows(tmp_path)
    out = tmp_path / "labels"
    assert authoring.main(["label-prepare", str(rows_path), str(out), "a", "--batch-size", "10"]) == 0
    assert authoring.main(["label-prepare", str(rows_path), str(out), "b", "--batch-size", "10"]) == 0
    # Control 1: repreparing into an existing session is refused and leaves it untouched.
    before = (out / "a" / "session.json").read_text()
    assert authoring.main(["label-prepare", str(rows_path), str(out), "a"]) == 2
    assert (out / "a" / "session.json").read_text() == before
    _answer(out / "a", {"T-001": True, "T-002": False})
    _answer(out / "b", {"T-001": True, "T-002": False})
    assert authoring.main(["label-collect", str(rows_path), str(out), "a"]) == 0
    assert authoring.main(["label-collect", str(rows_path), str(out), "b"]) == 0
    joined = tmp_path / "joined.jsonl"
    assert authoring.main(["join", str(rows_path), str(out), str(joined), "a", "b"]) == 0
    assert len(data.read_jsonl(joined)) == 2
    # Control 2: changing row content while keeping the ids is refused at collect AND at join.
    rows[0]["pasted"] = "Ask Sara to review."
    data.write_jsonl(rows_path, rows)
    assert authoring.main(["label-collect", str(rows_path), str(out), "a"]) == 2
    assert authoring.main(["join", str(rows_path), str(out), str(joined), "a", "b"]) == 2
    # Control 3: a labels file substituted or edited after collection is refused.
    rows[0]["pasted"] = "Ask Sarah to review."  # restore the prepared content
    data.write_jsonl(rows_path, rows)
    assert authoring.main(["join", str(rows_path), str(out), str(joined), "a", "b"]) == 0
    (out / "a-labels.jsonl").write_text((out / "b-labels.jsonl").read_text().replace('"correction": false', '"correction": true'))
    assert authoring.main(["join", str(rows_path), str(out), str(joined), "a", "b"]) == 2
    # A single labeller cannot mint unanimity through the CLI either.
    assert authoring.main(["join", str(rows_path), str(out), str(joined), "b", "b"]) == 2
