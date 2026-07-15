#!/usr/bin/env python3
"""Synthetic-only tests for the EG-1 multilingual V2 benchmark contract."""

from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path


EVAL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVAL_DIR))

import multilingual_benchmark_v2 as benchmark  # noqa: E402


def _list_contract(behavior: str) -> tuple[str, int | None]:
    if behavior in {"explicit_two_item_list", "scoped_two_item_list"}:
        return "activate_bullets", 2
    if behavior == "natural_three_to_five_item_bullet_list":
        return "activate_bullets", 3
    if behavior == "spoken_ordinals_numbered_list":
        return "activate_numbered", 3
    if behavior in benchmark.RESTRAINT_BEHAVIORS:
        return "restrain_prose", None
    return "no_list_requirement", None


def synthetic_row(
    case_id: str,
    *,
    split: str = "development",
    language: str = "en",
    domain: str = "work_admin",
    behavior: str = "filler_removal",
    difficulty: str = "routine",
    safety_risk: str = "standard",
    family_id: str | None = None,
    contrast_set_id: str | None = None,
    with_validator: bool = False,
    source_type: str = "native_original",
) -> dict:
    contract, item_count = _list_contract(behavior)
    author_id = f"author-{language}"
    validator = None
    if with_validator:
        validator = {
            "reviewer_id": f"validator-{language}",
            "locale": f"{language}-native",
            "native_attested": True,
            "status": "approved",
            "reviewed_on": "2026-07-15",
            "independent_of_author": True,
        }
    return {
        "schema_version": benchmark.SCHEMA_VERSION,
        "case_id": case_id,
        "semantic_family_id": family_id or f"family-{case_id}",
        "split": split,
        "language": language,
        "domain": domain,
        "behavior": behavior,
        "contrast_set_id": contrast_set_id,
        "difficulty": difficulty,
        "safety_risk": safety_risk,
        "asr_input": f"synthetic raw input unique to {case_id}",
        "gold_output": f"Synthetic gold output unique to {case_id}.",
        "requirements": {
            "meaning": f"Preserve the synthetic intent for {case_id}.",
            "entities": [f"Entity-{case_id}"],
            "numbers": [],
            "timing": [],
            "attribution": [],
            "formatting": {
                "list_contract": contract,
                "expected_item_count": item_count,
                "shared_scope": "",
            },
        },
        "provenance": {
            "source_type": source_type,
            "source_ref": f"synthetic-fixture:{case_id}",
            "native_author": {
                "reviewer_id": author_id,
                "locale": f"{language}-native",
                "native_attested": True,
                "status": "complete",
                "reviewed_on": "2026-07-15",
            },
            "independent_native_validator": validator,
        },
    }


def synthetic_release_corpus() -> list[dict]:
    rows: list[dict] = []
    for split in benchmark.SPLITS:
        per_behavior = benchmark.RELEASE_COUNTS[split]["per_behavior"]
        for language in benchmark.LANGUAGES:
            for behavior_index, behavior in enumerate(benchmark.BEHAVIORS):
                for index in range(per_behavior):
                    domain = benchmark.DOMAINS[index % len(benchmark.DOMAINS)]
                    if domain == "medical":
                        safety = "medical"
                    elif domain == "legal_financial":
                        safety = "legal" if (behavior_index + index) % 2 == 0 else "financial"
                    else:
                        safety = "standard"
                    case_id = f"SYN-{split[:3]}-{language}-{behavior_index:02d}-{index:02d}"
                    row = synthetic_row(
                        case_id,
                        split=split,
                        language=language,
                        domain=domain,
                        behavior=behavior,
                        difficulty=benchmark.DIFFICULTIES[
                            (((behavior_index % 4) if behavior_index >= 8 else behavior_index) + index)
                            % 3
                        ],
                        safety_risk=safety,
                        contrast_set_id=(
                            f"contrast-{split}-{language}-{behavior_index % 4}-{index}"
                            if behavior_index >= 8
                            else None
                        ),
                        with_validator=split == "frozen",
                        source_type=(
                            "shared_concept_local_rewrite"
                            if index % 5 == 4
                            else "native_original"
                        ),
                    )
                    if behavior == "natural_three_to_five_item_bullet_list":
                        row["requirements"]["formatting"]["expected_item_count"] = 3 + index % 3
                    rows.append(row)
    return rows


def synthetic_rating(
    rating_id: str,
    case_id: str,
    reviewer_id: str,
    *,
    review_round: str = "initial",
    repeat_of_rating_id: str | None = None,
    meaning_preserved: bool = True,
    damage_severity: str = "S0",
    language: str = "en",
) -> dict:
    axes = {axis: True for axis in benchmark.RATING_AXES}
    axes["meaning_preserved"] = meaning_preserved
    return {
        "schema_version": benchmark.RATING_SCHEMA_VERSION,
        "rating_id": rating_id,
        "case_id": case_id,
        "opaque_model_label": "M1",
        "blind_assignment_id": f"assignment-{rating_id}",
        "blinded": True,
        "reviewer_id": reviewer_id,
        "reviewer_locale": f"{language}-synthetic",
        "reviewer_native_attested": True,
        "review_round": review_round,
        "repeat_of_rating_id": repeat_of_rating_id,
        "axes": axes,
        "damage_severity": damage_severity,
        "reason": f"Synthetic rating reason for {rating_id}.",
    }


def synthetic_rating_workflow(
    *, disagree: bool = False, include_adjudication: bool = False, include_repeat: bool = True
) -> tuple[list[dict], list[dict]]:
    corpus = [
        synthetic_row("RATE-CASE-1", split="frozen", with_validator=True),
        synthetic_row("RATE-CASE-2", split="frozen", with_validator=True),
    ]
    ratings = [
        synthetic_rating("RATE-1-A", "RATE-CASE-1", "reviewer-en-1"),
        synthetic_rating(
            "RATE-1-B",
            "RATE-CASE-1",
            "reviewer-en-2",
            meaning_preserved=not disagree,
            damage_severity="S2" if disagree else "S0",
        ),
        synthetic_rating("RATE-2-A", "RATE-CASE-2", "reviewer-en-1"),
        synthetic_rating("RATE-2-B", "RATE-CASE-2", "reviewer-en-2"),
    ]
    if include_adjudication:
        ratings.append(
            synthetic_rating(
                "RATE-1-C",
                "RATE-CASE-1",
                "reviewer-en-3",
                review_round="adjudication",
            )
        )
    if include_repeat:
        ratings.extend(
            [
                synthetic_rating(
                    "RATE-1-REPEAT",
                    "RATE-CASE-1",
                    "reviewer-en-1",
                    review_round="repeat",
                    repeat_of_rating_id="RATE-1-A",
                ),
                synthetic_rating(
                    "RATE-2-REPEAT",
                    "RATE-CASE-2",
                    "reviewer-en-2",
                    review_round="repeat",
                    repeat_of_rating_id="RATE-2-B",
                ),
            ]
        )
    return corpus, ratings


class MultilingualBenchmarkV2Tests(unittest.TestCase):
    def test_development_row_can_be_pending_independent_validation(self) -> None:
        benchmark.validate_rows([synthetic_row("DEV-001")])

    def test_frozen_row_fails_closed_without_independent_native_validation(self) -> None:
        row = synthetic_row("FRZ-001", split="frozen")
        with self.assertRaises(benchmark.BenchmarkValidationError) as raised:
            benchmark.validate_rows([row])
        self.assertIn("frozen row missing independent native validation", str(raised.exception))

    def test_native_validator_must_be_independent_person(self) -> None:
        row = synthetic_row("FRZ-002", split="frozen", with_validator=True)
        row["provenance"]["independent_native_validator"]["reviewer_id"] = row["provenance"][
            "native_author"
        ]["reviewer_id"]
        with self.assertRaises(benchmark.BenchmarkValidationError) as raised:
            benchmark.validate_rows([row])
        self.assertIn("must be different people", str(raised.exception))

    def test_semantic_family_cannot_cross_development_and_frozen(self) -> None:
        development = synthetic_row("FAM-DEV", family_id="shared-family")
        frozen = synthetic_row(
            "FAM-FRZ",
            split="frozen",
            family_id="shared-family",
            with_validator=True,
        )
        with self.assertRaises(benchmark.BenchmarkValidationError) as raised:
            benchmark.validate_rows([development, frozen])
        self.assertIn("allocate whole families", str(raised.exception))

    def test_behavior_and_list_contract_must_agree(self) -> None:
        row = synthetic_row(
            "LIST-001",
            behavior="explicit_two_item_list",
            contrast_set_id="contrast-list-001",
        )
        row["requirements"]["formatting"] = {
            "list_contract": "restrain_prose",
            "expected_item_count": None,
            "shared_scope": "",
        }
        with self.assertRaises(benchmark.BenchmarkValidationError) as raised:
            benchmark.validate_rows([row])
        self.assertIn("requires list_contract activate_bullets", str(raised.exception))

    def test_malformed_preservation_array_fails_without_crashing(self) -> None:
        row = synthetic_row("BAD-ARRAY")
        row["requirements"]["entities"] = [{"not": "a string"}]
        with self.assertRaises(benchmark.BenchmarkValidationError) as raised:
            benchmark.validate_rows([row], release_profile=True)
        self.assertIn("must contain only non-empty strings", str(raised.exception))

    def test_list_activation_requires_matched_restraint_contrast(self) -> None:
        activation = synthetic_row(
            "PAIR-POS",
            behavior="explicit_two_item_list",
            contrast_set_id="pair-001",
        )
        with self.assertRaises(benchmark.BenchmarkValidationError) as raised:
            benchmark.validate_rows([activation])
        self.assertIn("expected one activation and one restraint", str(raised.exception))

        restraint = synthetic_row(
            "PAIR-NEG",
            behavior="two_item_prose_restraint",
            contrast_set_id="pair-001",
        )
        benchmark.validate_rows([activation, restraint])

    def test_release_profile_accepts_only_complete_synthetic_matrix(self) -> None:
        rows = synthetic_release_corpus()
        self.assertEqual(len(rows), 2400)
        benchmark.validate_rows(rows, release_profile=True)

    def test_release_profile_rejects_missing_stratum_row(self) -> None:
        rows = synthetic_release_corpus()
        rows.pop()
        with self.assertRaises(benchmark.BenchmarkValidationError) as raised:
            benchmark.validate_rows(rows, release_profile=True)
        self.assertIn("release profile", str(raised.exception))

    def test_release_profile_rejects_behavior_clustering_inside_domain_marginals(self) -> None:
        rows = synthetic_release_corpus()
        filler_personal = next(
            row
            for row in rows
            if row["split"] == "development"
            and row["language"] == "en"
            and row["behavior"] == "filler_removal"
            and row["domain"] == "personal_home"
        )
        correction_work = next(
            row
            for row in rows
            if row["split"] == "development"
            and row["language"] == "en"
            and row["behavior"] == "self_correction"
            and row["domain"] == "work_admin"
        )
        filler_personal["domain"], correction_work["domain"] = (
            correction_work["domain"],
            filler_personal["domain"],
        )
        with self.assertRaises(benchmark.BenchmarkValidationError) as raised:
            benchmark.validate_rows(rows, release_profile=True)
        self.assertIn(
            "development/en/filler_removal/work_admin has 3, expected 2",
            str(raised.exception),
        )

    def test_content_hash_is_order_independent(self) -> None:
        rows = [synthetic_row("HASH-001"), synthetic_row("HASH-002")]
        benchmark.validate_rows(rows)
        self.assertEqual(
            benchmark.benchmark_content_sha256(rows),
            benchmark.benchmark_content_sha256(list(reversed(rows))),
        )

    def test_manifest_bytes_are_deterministic_for_identical_inputs(self) -> None:
        rows = [synthetic_row("MANIFEST-001"), synthetic_row("MANIFEST-002")]
        benchmark.validate_rows(rows)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            corpus_path = root / "corpus.jsonl"
            corpus_path.write_text(
                "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows),
                encoding="utf-8",
            )
            manifest = benchmark.build_manifest(
                rows=rows,
                corpus_path=corpus_path,
                sources=[],
                receipt_path=None,
                release_profile=False,
            )
            first = root / "first.manifest.json"
            second = root / "second.manifest.json"
            benchmark.write_manifest(first, manifest)
            benchmark.write_manifest(second, manifest)
            self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_exact_leakage_screen_rejects_external_input_match(self) -> None:
        row = synthetic_row("LEAK-001")
        with tempfile.TemporaryDirectory() as tmp:
            source_path = Path(tmp) / "training.jsonl"
            source_path.write_text(
                json.dumps({"input": row["asr_input"], "output": "different output"}) + "\n",
                encoding="utf-8",
            )
            source = benchmark.LeakageSource(
                "training", "synthetic", source_path, benchmark.sha256_file(source_path)
            )
            errors = benchmark.exact_leakage_errors([row], [source])
        self.assertTrue(any("input exact-leaks" in error for error in errors))

    def test_exact_leakage_normalization_ignores_punctuation_but_keeps_unicode_words(self) -> None:
        row = synthetic_row("LEAK-PUNCT")
        row["asr_input"] = "Bitte sende Grüße an Müller und Мир heute"
        self.assertEqual(
            benchmark.normalize_text("Bitte, sende Grüße_an Müller... und Мир heute!"),
            benchmark.normalize_text(row["asr_input"]),
        )
        with tempfile.TemporaryDirectory() as tmp:
            source_path = Path(tmp) / "prior.jsonl"
            source_path.write_text(
                json.dumps(
                    {"asr_input": "Bitte, sende Grüße_an Müller... und Мир heute!"},
                    ensure_ascii=False,
                )
                + "\n",
                encoding="utf-8",
            )
            source = benchmark.LeakageSource(
                "prior_eval", "synthetic", source_path, benchmark.sha256_file(source_path)
            )
            errors = benchmark.exact_leakage_errors([row], [source])
        self.assertTrue(any("input exact-leaks" in error for error in errors))

    def test_blocked_family_registry_accepts_json_string_entries(self) -> None:
        row = synthetic_row("BLOCK-001", family_id="blocked-family")
        with tempfile.TemporaryDirectory() as tmp:
            source_path = Path(tmp) / "blocked.json"
            source_path.write_text(json.dumps(["blocked-family"]), encoding="utf-8")
            source = benchmark.LeakageSource(
                "blocked_family_registry",
                "synthetic",
                source_path,
                benchmark.sha256_file(source_path),
            )
            errors = benchmark.exact_leakage_errors([row], [source])
        self.assertTrue(any("blocked by blocked_family_registry" in error for error in errors))

    def test_leakage_receipt_is_bound_to_all_sources_and_methods(self) -> None:
        row = synthetic_row("RECEIPT-001")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_path = root / "training.jsonl"
            source_path.write_text(
                json.dumps({"input": "unrelated synthetic source"}) + "\n",
                encoding="utf-8",
            )
            source = benchmark.LeakageSource(
                "training", "synthetic", source_path, benchmark.sha256_file(source_path)
            )
            methods = {
                "exact_normalized": {"status": "pass", "violations": 0},
                "token_ngram_jaccard": {
                    "status": "pass",
                    "violations": 0,
                    "threshold": 0.8,
                    "max_observed": 0.2,
                },
                "character_ngram_jaccard": {
                    "status": "pass",
                    "violations": 0,
                    "threshold": 0.85,
                    "max_observed": 0.3,
                },
                "embedding_cosine": {
                    "status": "pass",
                    "violations": 0,
                    "threshold": 0.9,
                    "max_observed": 0.4,
                },
            }
            receipt = {
                "schema_version": "eg1-multilingual-leakage-receipt-v1",
                "benchmark_content_sha256": benchmark.benchmark_content_sha256([row]),
                "screening_policy_id": "synthetic-policy-v1",
                "sources": [
                    {
                        "role": source.role,
                        "name": source.name,
                        "sha256": source.sha256,
                        "methods": methods,
                    }
                ],
            }
            receipt_path = root / "receipt.json"
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            benchmark.validate_leakage_receipt(receipt_path, rows=[row], sources=[source])

            broken = copy.deepcopy(receipt)
            del broken["sources"][0]["methods"]["embedding_cosine"]
            receipt_path.write_text(json.dumps(broken), encoding="utf-8")
            with self.assertRaises(benchmark.BenchmarkValidationError) as raised:
                benchmark.validate_leakage_receipt(receipt_path, rows=[row], sources=[source])
            self.assertIn("embedding_cosine", str(raised.exception))

    def test_schema_files_are_valid_json_and_pin_all_scoring_axes(self) -> None:
        corpus_schema = json.loads(
            (EVAL_DIR / "multilingual_benchmark_v2.schema.json").read_text(encoding="utf-8")
        )
        rating_schema = json.loads(
            (EVAL_DIR / "multilingual_benchmark_v2_rating.schema.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(corpus_schema["properties"]["schema_version"]["const"], benchmark.SCHEMA_VERSION)
        required_axes = set(rating_schema["properties"]["axes"]["required"])
        self.assertEqual(
            required_axes,
            {
                "same_language",
                "meaning_preserved",
                "requested_cleanup_completed",
                "native_grammar_morphology",
                "entities_preserved",
                "numbers_preserved",
                "timing_preserved",
                "attribution_preserved",
                "list_contract_satisfied",
                "no_damaging_extra_edits",
            },
        )

    def test_rating_workflow_accepts_two_native_reviewers_and_ten_percent_repeat(self) -> None:
        corpus, ratings = synthetic_rating_workflow()
        stats = benchmark.validate_rating_rows(
            ratings, corpus_rows=corpus, expected_model_labels=["M1"]
        )
        self.assertEqual(stats["initial_rating_count"], 4)
        self.assertEqual(stats["distinct_repeated_initial_count"], 2)
        self.assertEqual(stats["required_repeat_count"], 1)

    def test_rating_workflow_requires_distinct_initial_reviewers(self) -> None:
        corpus, ratings = synthetic_rating_workflow()
        ratings[1]["reviewer_id"] = ratings[0]["reviewer_id"]
        with self.assertRaises(benchmark.BenchmarkValidationError) as raised:
            benchmark.validate_rating_rows(
                ratings, corpus_rows=corpus, expected_model_labels=["M1"]
            )
        self.assertIn("two distinct native initial reviewers", str(raised.exception))

    def test_rating_workflow_requires_third_reviewer_for_every_disagreement(self) -> None:
        corpus, ratings = synthetic_rating_workflow(disagree=True)
        with self.assertRaises(benchmark.BenchmarkValidationError) as raised:
            benchmark.validate_rating_rows(
                ratings, corpus_rows=corpus, expected_model_labels=["M1"]
            )
        self.assertIn("third-reviewer adjudication", str(raised.exception))

        corpus, ratings = synthetic_rating_workflow(
            disagree=True, include_adjudication=True
        )
        benchmark.validate_rating_rows(
            ratings, corpus_rows=corpus, expected_model_labels=["M1"]
        )

    def test_rating_workflow_rejects_initial_reviewer_as_adjudicator(self) -> None:
        corpus, ratings = synthetic_rating_workflow(
            disagree=True, include_adjudication=True
        )
        adjudication = next(
            rating for rating in ratings if rating["review_round"] == "adjudication"
        )
        adjudication["reviewer_id"] = "reviewer-en-1"
        with self.assertRaises(benchmark.BenchmarkValidationError) as raised:
            benchmark.validate_rating_rows(
                ratings, corpus_rows=corpus, expected_model_labels=["M1"]
            )
        self.assertIn("distinct from both initial reviewers", str(raised.exception))

    def test_rating_workflow_requires_repeat_coverage(self) -> None:
        corpus, ratings = synthetic_rating_workflow(include_repeat=False)
        with self.assertRaises(benchmark.BenchmarkValidationError) as raised:
            benchmark.validate_rating_rows(
                ratings, corpus_rows=corpus, expected_model_labels=["M1"]
            )
        self.assertIn("repeat coverage is 0/4", str(raised.exception))

    def test_rating_workflow_rejects_repeats_cherry_picked_by_reviewer(self) -> None:
        corpus, ratings = synthetic_rating_workflow()
        ratings = [rating for rating in ratings if rating["rating_id"] != "RATE-2-REPEAT"]
        with self.assertRaises(benchmark.BenchmarkValidationError) as raised:
            benchmark.validate_rating_rows(
                ratings, corpus_rows=corpus, expected_model_labels=["M1"]
            )
        self.assertIn(
            "repeat coverage for reviewer reviewer-en-2 is 0/2",
            str(raised.exception),
        )

    def test_rating_workflow_rejects_repeats_cherry_picked_by_language_arm(self) -> None:
        corpus = [
            synthetic_row("RATE-EN-1", split="frozen", with_validator=True),
            synthetic_row("RATE-EN-2", split="frozen", with_validator=True),
            synthetic_row(
                "RATE-DE-1", split="frozen", language="de", with_validator=True
            ),
            synthetic_row(
                "RATE-DE-2", split="frozen", language="de", with_validator=True
            ),
        ]
        ratings: list[dict] = []
        for case_id, language in (
            ("RATE-EN-1", "en"),
            ("RATE-EN-2", "en"),
            ("RATE-DE-1", "de"),
            ("RATE-DE-2", "de"),
        ):
            ratings.extend(
                [
                    synthetic_rating(
                        f"{case_id}-A", case_id, "reviewer-bilingual-1", language=language
                    ),
                    synthetic_rating(
                        f"{case_id}-B", case_id, "reviewer-bilingual-2", language=language
                    ),
                ]
            )
        ratings.extend(
            [
                synthetic_rating(
                    "RATE-EN-REPEAT-A",
                    "RATE-EN-1",
                    "reviewer-bilingual-1",
                    review_round="repeat",
                    repeat_of_rating_id="RATE-EN-1-A",
                ),
                synthetic_rating(
                    "RATE-EN-REPEAT-B",
                    "RATE-EN-2",
                    "reviewer-bilingual-2",
                    review_round="repeat",
                    repeat_of_rating_id="RATE-EN-2-B",
                ),
            ]
        )
        with self.assertRaises(benchmark.BenchmarkValidationError) as raised:
            benchmark.validate_rating_rows(
                ratings, corpus_rows=corpus, expected_model_labels=["M1"]
            )
        self.assertIn(
            "repeat coverage for language/model de:M1 is 0/4",
            str(raised.exception),
        )

    def test_rating_workflow_recomputes_manifest_and_rejects_tampered_counts(self) -> None:
        rows = synthetic_release_corpus()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            corpus_path = root / "release.jsonl"
            corpus_path.write_text(
                "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows),
                encoding="utf-8",
            )
            sources: list[benchmark.LeakageSource] = []
            for role in benchmark.LEAKAGE_ROLES:
                source_path = root / f"{role}.jsonl"
                source_path.write_text(
                    json.dumps({"family_id": f"unrelated-{role}"}) + "\n",
                    encoding="utf-8",
                )
                sources.append(
                    benchmark.LeakageSource(
                        role, role, source_path, benchmark.sha256_file(source_path)
                    )
                )
            receipt_path = root / "receipt.json"
            receipt_path.write_text("{}\n", encoding="utf-8")
            manifest = benchmark.build_manifest(
                rows=rows,
                corpus_path=corpus_path,
                sources=sources,
                receipt_path=receipt_path,
                release_profile=True,
            )
            manifest_path = root / "benchmark.manifest.json"
            benchmark.write_manifest(manifest_path, manifest)
            benchmark.validate_benchmark_manifest_for_ratings(
                manifest_path, rows=rows, corpus_path=corpus_path
            )

            manifest["counts"]["split_language"]["frozen"]["en"] = 999
            benchmark.write_manifest(manifest_path, manifest)
            with self.assertRaises(benchmark.BenchmarkValidationError) as raised:
                benchmark.validate_benchmark_manifest_for_ratings(
                    manifest_path, rows=rows, corpus_path=corpus_path
                )
            self.assertIn("corpus-derived field counts is invalid", str(raised.exception))

    def test_rating_manifest_pins_exact_benchmark_manifest_sha256(self) -> None:
        corpus, ratings = synthetic_rating_workflow()
        stats = benchmark.validate_rating_rows(
            ratings, corpus_rows=corpus, expected_model_labels=["M1"]
        )
        with tempfile.TemporaryDirectory() as tmp:
            ratings_path = Path(tmp) / "ratings.jsonl"
            ratings_path.write_text(
                "".join(json.dumps(row) + "\n" for row in ratings), encoding="utf-8"
            )
            manifest = benchmark.build_rating_manifest(
                ratings=ratings,
                ratings_path=ratings_path,
                benchmark_manifest={
                    "benchmark_content_sha256": benchmark.benchmark_content_sha256(corpus)
                },
                benchmark_manifest_sha256="a" * 64,
                expected_model_labels=["M1"],
                workflow_stats=stats,
            )
        self.assertEqual(manifest["benchmark_manifest_sha256"], "a" * 64)


if __name__ == "__main__":
    unittest.main()
