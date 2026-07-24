#!/usr/bin/env python3
"""Tests for the metadata-only D1 shared-concept producer and seal gate.

All prose and identity references below are disposable validator fixtures in
temporary directories. They are not D1 data or real approvals.
"""

from __future__ import annotations

import copy
from collections import Counter
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


EVAL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVAL_DIR))

import build_eg1_multilingual_d1 as d1  # noqa: E402
import build_eg1_d1_shared_concept_registry as shared  # noqa: E402


CONTRACT_PATH = EVAL_DIR / "eg1_multilingual_d1_contract_v1.json"


def completion_for(concept_rows: list[dict[str, object]]) -> dict[str, object]:
    concepts: list[dict[str, object]] = []
    for row in concept_rows:
        concept_id = str(row["cross_language_concept_id"])
        brief = f"Disposable language-neutral scenario fixture {concept_id}"
        concepts.append(
            {
                "cross_language_concept_id": concept_id,
                "brief_id": row["brief_id"],
                "brief": brief,
                "brief_sha256": shared.sha256_bytes(brief.encode()),
                "concept_author_reference_id": f"author:{concept_id.lower()}",
                "concept_reviewer_reference_id": f"reviewer:{concept_id.lower()}",
                "review_reference_id": f"review:{concept_id.lower()}",
                "reviewed_at": "2026-07-15T20:00:00Z",
                "language_neutrality_approved": True,
                "meaning_safety_approved": True,
                "family_separation_approved": True,
                "candidate_model_output_seen": False,
            }
        )
    return {
        "schema_version": shared.COMPLETION_SCHEMA,
        "registry_id": "fixture-shared-concepts",
        "status": "approved_for_sealing",
        "approval": {
            "approved_for_authoring": True,
            "approved_by_reference_id": "approver:fixture",
            "approval_reference_id": "approval:fixture",
            "approved_at": "2026-07-15T20:00:00Z",
        },
        "concepts": concepts,
    }


class SharedConceptRegistryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.contract_bytes = CONTRACT_PATH.read_bytes()
        cls.contract = json.loads(cls.contract_bytes)
        cls.contract_sha = shared.sha256_bytes(cls.contract_bytes)
        cls.slots = d1.build_slots(cls.contract)
        cls.concept_rows = shared.build_concept_slots(cls.contract, cls.slots)

    def allocation_artifacts(self) -> tuple[dict[str, bytes], dict[str, object]]:
        return shared.build_allocation_artifacts(
            contract_path=CONTRACT_PATH,
            contract_bytes=self.contract_bytes,
            contract_sha256=self.contract_sha,
            d1_builder_sha256="d" * 64,
            producer_sha256="e" * 64,
            execution_git_head="f" * 40,
        )

    def fixture_registry_state(
        self,
        registry: dict[str, object],
        receipt: dict[str, object],
        *,
        allocation_is_ancestor: bool = True,
    ) -> tuple[list[str], dict[str, dict[str, str]]]:
        historical_hashes = {
            "scripts/eval/eg1_multilingual_d1_contract_v1.json": self.contract_sha,
            "scripts/eval/build_eg1_multilingual_d1.py": shared.sha256_bytes(
                shared.D1_BUILDER_PATH.read_bytes()
            ),
            "scripts/eval/build_eg1_d1_shared_concept_registry.py": shared.sha256_bytes(
                shared.SCRIPT_PATH.read_bytes()
            ),
        }
        with (
            mock.patch.object(
                d1,
                "_historical_shared_concept_control_sha256",
                side_effect=lambda _head, path: historical_hashes.get(path),
            ),
            mock.patch.object(
                d1,
                "_shared_concept_commit_is_ancestor",
                side_effect=lambda _ancestor, descendant="HEAD": (
                    True if descendant == "HEAD" else allocation_is_ancestor
                ),
            ),
        ):
            return d1.shared_concept_registry_state(
                self.slots,
                registry,
                seal_receipt=receipt,
                registry_sha256=shared.sha256_bytes(shared.encode_json(registry)),
                current_contract_sha256=self.contract_sha,
            )

    def sealed_registry(self) -> tuple[dict[str, object], dict[str, object]]:
        completion = completion_for(self.concept_rows)
        artifacts, receipt = shared.build_seal_artifacts(
            contract_path=CONTRACT_PATH,
            contract_bytes=self.contract_bytes,
            contract_sha256=self.contract_sha,
            d1_builder_sha256=shared.sha256_bytes(shared.D1_BUILDER_PATH.read_bytes()),
            producer_sha256=shared.sha256_bytes(shared.SCRIPT_PATH.read_bytes()),
            execution_git_head="f" * 40,
            allocation_receipt={"execution_git_head": "e" * 40},
            allocation_receipt_sha256="a" * 64,
            concept_rows=self.concept_rows,
            completion=completion,
            completion_sha256=shared.sha256_bytes(shared.encode_json(completion)),
        )
        return (
            shared.parse_object(artifacts["shared-concept-registry.json"], "fixture"),
            receipt,
        )

    def test_allocation_is_balanced_metadata_only_and_training_blocked(self) -> None:
        artifacts, receipt = self.allocation_artifacts()
        rows = shared.parse_jsonl(
            artifacts["shared-concept-slots.jsonl"], "fixture allocation"
        )
        template = shared.parse_object(
            artifacts["private-completion-template.json"], "fixture template"
        )
        self.assertEqual(len(rows), 80)
        self.assertEqual(
            Counter(
                binding["language"]
                for row in rows
                for binding in row["family_bindings"]
            ),
            Counter({"en": 80, "de": 80, "fr": 80, "es": 80, "ru": 80}),
        )
        self.assertEqual(
            sum(len(row["family_bindings"]) for row in rows),
            400,
        )
        self.assertTrue(
            all(
                len({binding["family_id"] for binding in row["family_bindings"]}) == 5
                for row in rows
            )
        )
        self.assertEqual(
            set(row["allocated_shape"]["stratum"] for row in rows),
            {"core", "positive_list", "matched_restraint"},
        )
        for row in rows:
            custody = row["custody"]
            self.assertIsNone(custody["concept_author_reference_id"])
            self.assertIsNone(custody["concept_reviewer_reference_id"])
            self.assertFalse(custody["language_neutrality_approved"])
            self.assertFalse(custody["meaning_safety_approved"])
            self.assertFalse(custody["family_separation_approved"])
            self.assertFalse(custody["candidate_model_output_seen"])
            self.assertNotIn("brief", row)
        self.assertTrue(all(row["brief"] is None for row in template["concepts"]))
        self.assertIsNone(template["registry_id"])
        self.assertFalse(template["approval"]["approved_for_authoring"])
        self.assertEqual(receipt["publication"], shared.PUBLICATION)
        self.assertFalse(receipt["gates"]["training_eligible"])
        self.assertFalse(receipt["gates"]["release_eligible"])

    def test_valid_private_completion_seals_but_never_claims_training_ready(self) -> None:
        completion = completion_for(self.concept_rows)
        artifacts, receipt = shared.build_seal_artifacts(
            contract_path=CONTRACT_PATH,
            contract_bytes=self.contract_bytes,
            contract_sha256=self.contract_sha,
            d1_builder_sha256=shared.sha256_bytes(shared.D1_BUILDER_PATH.read_bytes()),
            producer_sha256=shared.sha256_bytes(shared.SCRIPT_PATH.read_bytes()),
            execution_git_head="f" * 40,
            allocation_receipt={"execution_git_head": "e" * 40},
            allocation_receipt_sha256="a" * 64,
            concept_rows=self.concept_rows,
            completion=completion,
            completion_sha256=shared.sha256_bytes(shared.encode_json(completion)),
        )
        registry = shared.parse_object(
            artifacts["shared-concept-registry.json"], "sealed registry"
        )
        errors, bindings = self.fixture_registry_state(registry, receipt)
        self.assertEqual(errors, [])
        self.assertEqual(len(bindings), 80)
        self.assertEqual(receipt["counts"]["shared_rows"], 400)
        self.assertEqual(receipt["counts"]["independent_concept_reviews"], 80)
        self.assertFalse(receipt["gates"]["native_row_reviews_complete"])
        self.assertFalse(receipt["gates"]["training_eligible"])
        self.assertFalse(receipt["gates"]["release_eligible"])

    def test_completion_rejects_fake_or_nonindependent_custody(self) -> None:
        base = completion_for(self.concept_rows)
        mutations = {
            "unapproved registry": lambda value: value.update(status="draft"),
            "same author reviewer": lambda value: value["concepts"][0].update(
                concept_reviewer_reference_id=value["concepts"][0][
                    "concept_author_reference_id"
                ]
            ),
            "language neutrality false": lambda value: value["concepts"][0].update(
                language_neutrality_approved=False
            ),
            "meaning safety false": lambda value: value["concepts"][0].update(
                meaning_safety_approved=False
            ),
            "family separation false": lambda value: value["concepts"][0].update(
                family_separation_approved=False
            ),
            "candidate output seen": lambda value: value["concepts"][0].update(
                candidate_model_output_seen=True
            ),
            "PII-shaped reviewer": lambda value: value["concepts"][0].update(
                concept_reviewer_reference_id="reviewer@example.invalid"
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                candidate = copy.deepcopy(base)
                mutate(candidate)
                with self.assertRaises(shared.ValidationFailure):
                    shared.validate_completion(candidate, self.concept_rows)

    def test_review_receipts_are_unique_and_precede_final_approval(self) -> None:
        base = completion_for(self.concept_rows)
        reused = copy.deepcopy(base)
        reused["concepts"][1]["review_reference_id"] = reused["concepts"][0][
            "review_reference_id"
        ]
        with self.assertRaisesRegex(shared.ValidationFailure, "is reused"):
            shared.validate_completion(reused, self.concept_rows)

        impossible_chronology = copy.deepcopy(base)
        impossible_chronology["approval"]["approved_at"] = "2020-01-01T00:00:00Z"
        with self.assertRaisesRegex(
            shared.ValidationFailure, "review occurs after final approval"
        ):
            shared.validate_completion(impossible_chronology, self.concept_rows)

    def test_completion_rejects_coverage_schema_hash_and_duplicate_brief_failures(self) -> None:
        base = completion_for(self.concept_rows)
        candidates: list[dict[str, object]] = []
        missing = copy.deepcopy(base)
        missing["concepts"].pop()
        candidates.append(missing)
        extra_field = copy.deepcopy(base)
        extra_field["concepts"][0]["name"] = "must not be accepted"
        candidates.append(extra_field)
        bad_hash = copy.deepcopy(base)
        bad_hash["concepts"][0]["brief_sha256"] = "0" * 64
        candidates.append(bad_hash)
        duplicate_brief = copy.deepcopy(base)
        duplicate_brief["concepts"][1]["brief"] = duplicate_brief["concepts"][0][
            "brief"
        ]
        duplicate_brief["concepts"][1]["brief_sha256"] = duplicate_brief["concepts"][0][
            "brief_sha256"
        ]
        candidates.append(duplicate_brief)
        for candidate in candidates:
            with self.assertRaises(shared.ValidationFailure):
                shared.validate_completion(candidate, self.concept_rows)

    def test_downstream_rejects_legacy_or_tampered_producer_claims(self) -> None:
        registry, receipt = self.sealed_registry()
        legacy = copy.deepcopy(registry)
        legacy.pop("producer_binding")
        errors, _ = self.fixture_registry_state(legacy, receipt)
        self.assertTrue(any("producer" in error or "schema" in error for error in errors))

        tampered = copy.deepcopy(registry)
        tampered["concepts"][0]["brief"] += " tampered"
        tampered["concepts"][0]["brief_sha256"] = shared.sha256_bytes(
            tampered["concepts"][0]["brief"].encode()
        )
        errors, _ = self.fixture_registry_state(tampered, receipt)
        self.assertIn("shared-concept registry payload binding is invalid", errors)

        forged_coverage = copy.deepcopy(registry)
        forged_coverage["producer_binding"]["language_rows"]["de"] = 79
        errors, _ = self.fixture_registry_state(forged_coverage, receipt)
        self.assertIn(
            "shared-concept producer coverage differs from D1 allocation", errors
        )

    def test_coherent_forgery_cannot_replace_historical_sealer_evidence(self) -> None:
        registry, receipt = self.sealed_registry()
        coherent_forgery = copy.deepcopy(registry)
        coherent_forgery["concepts"][0]["brief"] += " forged"
        coherent_forgery["concepts"][0]["brief_sha256"] = shared.sha256_bytes(
            coherent_forgery["concepts"][0]["brief"].encode()
        )
        forged_payload = {
            field: coherent_forgery[field]
            for field in d1.SHARED_CONCEPT_REGISTRY_FIELDS - {"producer_binding"}
        }
        coherent_forgery["producer_binding"]["registry_payload_sha256"] = (
            d1.canonical_json_sha256(forged_payload)
        )
        forged_receipt = copy.deepcopy(receipt)
        forged_receipt["artifacts"]["shared-concept-registry.json"]["sha256"] = (
            shared.sha256_bytes(shared.encode_json(coherent_forgery))
        )
        forged_receipt_payload = dict(forged_receipt)
        forged_receipt_payload.pop("receipt_payload_sha256")
        forged_receipt["receipt_payload_sha256"] = d1.canonical_json_sha256(
            forged_receipt_payload
        )
        errors, _ = d1.shared_concept_registry_state(
            self.slots,
            coherent_forgery,
            seal_receipt=forged_receipt,
            registry_sha256=shared.sha256_bytes(
                shared.encode_json(coherent_forgery)
            ),
            current_contract_sha256=self.contract_sha,
        )
        self.assertTrue(
            any("historical" in error or "current history" in error for error in errors),
            errors,
        )

    def test_allocation_commit_must_precede_the_seal_commit(self) -> None:
        registry, receipt = self.sealed_registry()
        errors, _ = self.fixture_registry_state(
            registry, receipt, allocation_is_ancestor=False
        )
        self.assertIn(
            "shared-concept allocation commit is not an ancestor of the seal commit",
            errors,
        )

    def test_publication_is_exclusive_receipt_last_and_cleans_partial_bundle(self) -> None:
        artifacts, receipt = self.allocation_artifacts()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "bundle"

            def fail_before_receipt() -> None:
                self.assertTrue((output / "shared-concept-slots.jsonl").is_file())
                self.assertFalse((output / "receipt.json").exists())
                raise shared.ValidationFailure("synthetic pre-receipt failure")

            with self.assertRaises(shared.ValidationFailure):
                shared.publish_bundle(
                    output_bundle=output,
                    artifact_bytes=artifacts,
                    receipt=receipt,
                    expected_filenames=shared.ALLOCATION_FILENAMES,
                    before_receipt=fail_before_receipt,
                )
            self.assertFalse(output.exists())

            shared.publish_bundle(
                output_bundle=output,
                artifact_bytes=artifacts,
                receipt=receipt,
                expected_filenames=shared.ALLOCATION_FILENAMES,
                before_receipt=lambda: None,
            )
            self.assertEqual(
                {path.name for path in output.iterdir()},
                set(shared.ALLOCATION_FILENAMES),
            )
            with self.assertRaisesRegex(shared.ValidationFailure, "already exists"):
                shared.publish_bundle(
                    output_bundle=output,
                    artifact_bytes=artifacts,
                    receipt=receipt,
                    expected_filenames=shared.ALLOCATION_FILENAMES,
                    before_receipt=lambda: None,
                )

    def test_persisted_artifact_mutation_blocks_receipt_and_cleans_bundle(self) -> None:
        artifacts, receipt = self.allocation_artifacts()
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "bundle"

            def mutate_artifact() -> None:
                (output / "shared-concept-slots.jsonl").write_bytes(b"tampered\n")

            with self.assertRaisesRegex(
                shared.ValidationFailure, "published artifact changed"
            ):
                shared.publish_bundle(
                    output_bundle=output,
                    artifact_bytes=artifacts,
                    receipt=receipt,
                    expected_filenames=shared.ALLOCATION_FILENAMES,
                    before_receipt=mutate_artifact,
                )
            self.assertFalse(output.exists())

    def test_old_allocation_remains_valid_after_real_later_control_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            eval_dir = root / "scripts" / "eval"
            eval_dir.mkdir(parents=True)
            contract_path = eval_dir / "eg1_multilingual_d1_contract_v1.json"
            d1_path = eval_dir / "build_eg1_multilingual_d1.py"
            producer_path = eval_dir / "build_eg1_d1_shared_concept_registry.py"
            contract_path.write_bytes(self.contract_bytes)
            d1_path.write_text("# producing D1 control\n", encoding="utf-8")
            producer_path.write_text("# producing registry control\n", encoding="utf-8")
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(
                ["git", "config", "user.email", "fixture@example.invalid"],
                cwd=root,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "Fixture"], cwd=root, check=True
            )
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(
                ["git", "commit", "-q", "-m", "producing controls"],
                cwd=root,
                check=True,
            )
            producing_head = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=root,
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            ).stdout.strip()
            bundle = root / "private-allocation"
            bundle.mkdir()
            with (
                mock.patch.object(shared, "REPO_ROOT", root),
                mock.patch.object(shared, "SCRIPT_PATH", producer_path),
                mock.patch.object(shared, "D1_BUILDER_PATH", d1_path),
            ):
                artifacts, receipt = shared.build_allocation_artifacts(
                    contract_path=contract_path,
                    contract_bytes=self.contract_bytes,
                    contract_sha256=self.contract_sha,
                    d1_builder_sha256=shared.sha256_bytes(d1_path.read_bytes()),
                    producer_sha256=shared.sha256_bytes(producer_path.read_bytes()),
                    execution_git_head=producing_head,
                )
                for name, value in artifacts.items():
                    (bundle / name).write_bytes(value)
                (bundle / "receipt.json").write_bytes(shared.encode_json(receipt))

                producer_path.write_text(
                    "# producing registry control\n# later validator change\n",
                    encoding="utf-8",
                )
                d1_path.write_text(
                    "# producing D1 control\n# later non-slot change\n", encoding="utf-8"
                )
                subprocess.run(
                    ["git", "add", str(producer_path), str(d1_path)],
                    cwd=root,
                    check=True,
                )
                subprocess.run(
                    ["git", "commit", "-q", "-m", "advance controls"],
                    cwd=root,
                    check=True,
                )
                validated, rows, _ = shared.validate_allocation_bundle(
                    contract_path=contract_path,
                    allocation_bundle=bundle,
                )
                self.assertEqual(validated["execution_git_head"], producing_head)
                self.assertEqual(len(rows), 80)

                contract_path.write_bytes(self.contract_bytes + b"\n")
                subprocess.run(["git", "add", str(contract_path)], cwd=root, check=True)
                subprocess.run(
                    ["git", "commit", "-q", "-m", "drift contract"],
                    cwd=root,
                    check=True,
                )
                with self.assertRaisesRegex(
                    shared.ValidationFailure, "contract changed"
                ):
                    shared.validate_allocation_bundle(
                        contract_path=contract_path,
                        allocation_bundle=bundle,
                    )


if __name__ == "__main__":
    unittest.main()
