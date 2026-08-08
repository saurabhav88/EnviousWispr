from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


EVAL_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = EVAL_DIR / "build_eg1_type_b_v2_authoring_packets.py"
CONTRACT_PATH = EVAL_DIR / "contracts/eg1_type_b_v2_authoring_workflow_v1.json"
SPEC = importlib.util.spec_from_file_location("type_b_authoring", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def encode_json(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def encode_jsonl(rows: list[dict]) -> bytes:
    return b"".join(
        (json.dumps(row, sort_keys=True) + "\n").encode() for row in rows
    )


def sha(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


class SyntheticInputs:
    """Disposable metadata-only fixtures; never benchmark prose or private rows."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.allocation = root / "allocation"
        self.registry = root / "registry"
        self.allocation.mkdir()
        self.registry.mkdir()
        self.contract = json.loads(CONTRACT_PATH.read_text())
        counts = {
            "target_total": 24,
            "provisional_retained": 2,
            "fresh_required": 22,
            "replacement_reserves": 2,
            "fresh_authorship_total": 24,
            "all_slot_records": 26,
        }
        self.contract["production_inputs"]["allocation"]["counts"] = counts
        self.contract["production_inputs"]["blocked_registry"][
            "fresh_slots_required"
        ] = 24
        self.contract["production_inputs"]["blocked_registry"]["counts"] = {
            "sources": 4,
            "source_rows": 8,
            "blocked_families": 4,
            "normalized_input_hashes": 3,
            "normalized_output_hashes": 3,
            "normalized_empty_input_rows": 0,
            "normalized_empty_output_rows": 0,
            "provisional_decisions": 2,
            "replace": 2,
            "retain": 0,
        }
        categories = ["lists", "minimal_edit", "self_correction"]
        self.manifest_rows = []
        for index in range(22):
            self.manifest_rows.append(
                self.row(
                    slot=f"fresh-{index:02d}",
                    family=f"family-fresh-{index:02d}",
                    source="fresh_model_blind_required",
                    category=categories[index % len(categories)],
                    source_case=None,
                    authored=False,
                )
            )
        for index in range(2):
            self.manifest_rows.append(
                self.row(
                    slot=f"provisional-{index}",
                    family=f"family-provisional-{index}",
                    source="provisional_retained_requires_blind_family_review",
                    category=categories[index],
                    source_case=f"synthetic-source-{index}",
                    authored=True,
                )
            )
        self.reserve_rows = []
        for index in range(2):
            row = self.row(
                slot=f"reserve-{index}",
                family=f"family-reserve-{index}",
                source="fresh_replacement_reserve_model_blind_required",
                category=categories[index],
                source_case=None,
                authored=False,
            )
            row["reserved_for_source_case_id"] = f"synthetic-source-{index}"
            self.reserve_rows.append(row)
        self.family_rows = [
            {
                "schema_version": "eg1-type-b-v2-blocked-family-v1",
                "semantic_family_id": f"blocked-family-{index}",
            }
            for index in range(4)
        ]
        self.text_rows = [
            {
                "schema_version": "eg1-type-b-v2-blocked-text-hash-v1",
                "field_kind": "input" if index % 2 == 0 else "output",
                "normalized_text_sha256": hashlib.sha256(
                    f"synthetic-hash-{index}".encode()
                ).hexdigest(),
            }
            for index in range(6)
        ]
        self.coverage_rows = [
            {
                "schema_version": "eg1-type-b-v2-source-coverage-v1",
                "registry_entry_id": f"synthetic-coverage-{index}",
                "source_row_id_sha256": hashlib.sha256(
                    f"synthetic-source-row-{index}".encode()
                ).hexdigest(),
            }
            for index in range(8)
        ]
        self.decision_rows = [
            {
                "schema_version": "eg1-type-b-v2-provisional-decision-v1",
                "source_case_id": f"synthetic-source-{index}",
                "replacement_reserve_slot_id": f"reserve-{index}",
                "decision": "replace",
                "reason_code": "semantic_family_clearance_not_proven",
                "candidate_model_output_seen": False,
                "fresh_benchmark_prose_authored": False,
            }
            for index in range(2)
        ]
        self.write_artifacts()
        self.write_receipts()

    @staticmethod
    def row(
        *, slot: str, family: str, source: str, category: str,
        source_case: str | None, authored: bool,
    ) -> dict:
        return {
            "slot_id": slot,
            "semantic_family_id": family,
            "source": source,
            "source_case_id": source_case,
            "category": category,
            "length_bucket": 1,
            "tier": "synthetic-tier",
            "subset": "synthetic-subset",
            "trap": category == "self_correction",
            "author_lane": "legacy-placeholder",
            "reviewer_lane": "legacy-placeholder",
            "text_authored": authored,
            "benchmark_eligible": False,
            "training_eligible": False,
            "candidate_model_output_seen": False,
        }

    def write_artifacts(self) -> None:
        self.manifest_bytes = encode_jsonl(self.manifest_rows)
        self.reserve_bytes = encode_jsonl(self.reserve_rows)
        self.family_bytes = encode_jsonl(self.family_rows)
        self.text_bytes = encode_jsonl(self.text_rows)
        self.coverage_bytes = encode_jsonl(self.coverage_rows)
        self.decision_bytes = encode_jsonl(self.decision_rows)
        (self.allocation / "manifest.jsonl").write_bytes(self.manifest_bytes)
        (self.allocation / "replacement_reserves.jsonl").write_bytes(
            self.reserve_bytes
        )
        (self.registry / "blocked_family_registry.jsonl").write_bytes(
            self.family_bytes
        )
        (self.registry / "blocked_text_hashes.jsonl").write_bytes(self.text_bytes)
        (self.registry / "source_coverage.jsonl").write_bytes(self.coverage_bytes)
        (self.registry / "provisional_decisions.jsonl").write_bytes(
            self.decision_bytes
        )

    def write_receipts(self) -> None:
        allocation_expected = self.contract["production_inputs"]["allocation"]
        allocation_expected.update(
            {
                "manifest_sha256": sha(self.manifest_bytes),
                "replacement_reserves_sha256": sha(self.reserve_bytes),
            }
        )
        self.allocation_receipt = {
            "status": "type_b_v2_slots_sealed_text_generation_blocked",
            "seed": 1265,
            "candidate_model_output_seen": False,
            "execution_git_head": allocation_expected["execution_git_head"],
            "publication": "exclusive_bundle_receipt_last",
            **allocation_expected["counts"],
            "allocation_contract": {
                "sha256": allocation_expected["allocation_contract_sha256"]
            },
            "builder": {"sha256": allocation_expected["builder_sha256"]},
            "manifest": {"path": "manifest.jsonl", "sha256": sha(self.manifest_bytes)},
            "replacement_reserve_manifest": {
                "path": "replacement_reserves.jsonl",
                "sha256": sha(self.reserve_bytes),
            },
            "eligibility_gate": {"all_rows_benchmark_eligible_now": False},
        }
        allocation_receipt_bytes = encode_json(self.allocation_receipt)
        (self.allocation / "receipt.json").write_bytes(allocation_receipt_bytes)
        allocation_expected["receipt_sha256"] = sha(allocation_receipt_bytes)

        registry_expected = self.contract["production_inputs"]["blocked_registry"]
        registry_expected["family_artifact"].update(
            {"sha256": sha(self.family_bytes), "row_count": len(self.family_rows)}
        )
        registry_expected["text_hash_artifact"].update(
            {"sha256": sha(self.text_bytes), "row_count": len(self.text_rows)}
        )
        registry_expected["source_coverage_artifact"].update(
            {
                "sha256": sha(self.coverage_bytes),
                "row_count": len(self.coverage_rows),
            }
        )
        registry_expected["provisional_decisions_artifact"].update(
            {
                "sha256": sha(self.decision_bytes),
                "row_count": len(self.decision_rows),
            }
        )
        registry_expected["decision_summary"] = {
            "reason_code": "semantic_family_clearance_not_proven",
            "replace": 2,
            "retain": 0,
            "same_cell_reserves_bound": 2,
        }
        self.registry_receipt = {
            "schema_version": registry_expected["receipt_schema"],
            "status": "sources_sealed_all_provisional_replaced_authorship_blocked",
            "execution_git_head": registry_expected["execution_git_head"],
            "registry_id": registry_expected["registry_id"],
            "publication": "exclusive_bundle_receipt_last",
            "counts": registry_expected["counts"],
            "allocator": {
                "allocation_contract_sha256": registry_expected[
                    "allocation_contract_sha256"
                ],
                "builder_sha256": registry_expected["allocator_builder_sha256"],
            },
            "decision_summary": registry_expected["decision_summary"],
            "privacy": {
                "metadata_only": True,
                "private_source_text_published": False,
                "private_source_row_ids_published_raw": False,
                "other_source_row_ids_published_raw": False,
            },
            "authorship_gate": {
                "candidate_model_output_seen": False,
                "fresh_authorship_authorized": False,
                "fresh_benchmark_prose_authored": False,
                "fresh_slots_required": 24,
            },
            "candidate_clearance_contract": {
                "provenance_field": "blocked_family_clearances",
                "registry_artifact": "blocked_family_registry.jsonl",
                "registry_binding_field": "registry_sha256",
                "candidate_binding_field": "candidate_semantic_family_id",
                "required_status": "cleared",
                "independent_review_required": True,
            },
            "artifacts": {
                "blocked_family_registry.jsonl": {
                    "sha256": sha(self.family_bytes),
                    "row_count": len(self.family_rows),
                    "validator_source_role": "blocked_family_registry",
                },
                "blocked_text_hashes.jsonl": {
                    "sha256": sha(self.text_bytes),
                    "row_count": len(self.text_rows),
                    "validator_source_role": "blocked_text_hash_registry",
                },
                "source_coverage.jsonl": {
                    "sha256": sha(self.coverage_bytes),
                    "row_count": len(self.coverage_rows),
                    "validator_source_role": None,
                },
                "provisional_decisions.jsonl": {
                    "sha256": sha(self.decision_bytes),
                    "row_count": len(self.decision_rows),
                    "validator_source_role": None,
                },
            },
        }
        registry_receipt_bytes = encode_json(self.registry_receipt)
        (self.registry / "receipt.json").write_bytes(registry_receipt_bytes)
        registry_expected["receipt_sha256"] = sha(registry_receipt_bytes)

    def reseal(self) -> None:
        self.write_artifacts()
        self.write_receipts()


class TypeBAuthoringWorkflowTests(unittest.TestCase):
    def build(self, root: Path, fixtures: SyntheticInputs, name: str = "out") -> dict:
        output = root / name
        return MODULE.build_bundle(
            contract=fixtures.contract,
            contract_sha=sha(encode_json(fixtures.contract)),
            allocation_receipt_path=fixtures.allocation / "receipt.json",
            registry_receipt_path=fixtures.registry / "receipt.json",
            output=output,
            execution_git_head="f" * 40,
        )

    @staticmethod
    def rows(path: Path) -> list[dict]:
        return [json.loads(line) for line in path.read_text().splitlines() if line]

    def test_seals_all_final_assignments_and_reserve_custody_without_prose(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixtures = SyntheticInputs(root)
            receipt = self.build(root, fixtures)
            assignments = self.rows(root / "out/assignment_custody.jsonl")
            packets = self.rows(root / "out/authoring_packets.jsonl")
            requirements = json.loads(
                (root / "out/merge_gate_requirements.json").read_text()
            )

            self.assertEqual(receipt["counts"]["final_assignments"], 24)
            self.assertEqual(receipt["counts"]["all_custody_records"], 26)
            self.assertEqual(receipt["counts"]["activated_replacement_reserve"], 2)
            self.assertEqual(receipt["counts"]["replaced_provisional_custody"], 2)
            self.assertEqual(len(assignments), 26)
            replacement_pairs: dict[str, set[str]] = {}
            for row in assignments:
                if row["replacement_pair_id"] is not None:
                    replacement_pairs.setdefault(
                        row["replacement_pair_id"], set()
                    ).add(row["custody_state"])
            self.assertEqual(len(replacement_pairs), 2)
            self.assertEqual(
                set(map(frozenset, replacement_pairs.values())),
                {
                    frozenset(
                        {
                            "replaced_provisional_custody",
                            "activated_replacement_reserve",
                        }
                    )
                },
            )
            self.assertEqual([row["slot_count"] for row in packets], [12, 12])
            self.assertTrue(all(len(row["category_counts"]) >= 2 for row in packets))
            self.assertEqual(
                len(
                    {
                        member
                        for packet in packets
                        for member in packet["assignment_fingerprints"]
                    }
                ),
                24,
            )
            self.assertTrue(all(row["authoring_enabled"] is False for row in assignments))
            self.assertTrue(all(row["prose_authored"] is False for row in assignments))
            self.assertTrue(
                all(row["candidate_model_output_seen"] is False for row in assignments)
            )
            active = [row for row in assignments if row["lane_ids"] is not None]
            self.assertEqual(len(active), 24)
            self.assertTrue(all(len(set(row["lane_ids"].values())) == 3 for row in active))
            self.assertTrue(
                all(set(row["human_identities"].values()) == {None} for row in active)
            )
            self.assertEqual(requirements["status"], "pending")
            self.assertFalse(requirements["merge_eligible"])
            self.assertTrue(
                all(
                    row["status"] == "pending"
                    and row["observed"] is None
                    and row["satisfied"] is False
                    for row in requirements["requirements"]
                )
            )
            self.assertEqual(
                set(path.name for path in (root / "out").iterdir()),
                set(MODULE.EXPECTED_ARTIFACTS),
            )

    def test_output_is_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixtures = SyntheticInputs(root)
            self.build(root, fixtures, "out-a")
            self.build(root, fixtures, "out-b")
            for name in MODULE.EXPECTED_ARTIFACTS:
                self.assertEqual(
                    (root / "out-a" / name).read_bytes(),
                    (root / "out-b" / name).read_bytes(),
                )

    def test_exact_1890_topology_is_126_mixed_fifteen_slot_packets(self) -> None:
        contract = json.loads(CONTRACT_PATH.read_text())
        categories = [f"synthetic-category-{index:02d}" for index in range(17)]
        manifest: list[dict] = []
        for index in range(1867):
            category = (
                categories[0]
                if index < 292
                else categories[1 + ((index - 292) % (len(categories) - 1))]
            )
            manifest.append(
                SyntheticInputs.row(
                    slot=f"fresh-{index:04d}",
                    family=f"fresh-family-{index:04d}",
                    source="fresh_model_blind_required",
                    category=category,
                    source_case=None,
                    authored=False,
                )
            )
        reserves: list[dict] = []
        decisions: list[dict] = []
        for index in range(23):
            source_case = f"synthetic-provisional-{index:02d}"
            manifest.append(
                SyntheticInputs.row(
                    slot=f"provisional-{index:02d}",
                    family=f"provisional-family-{index:02d}",
                    source="provisional_retained_requires_blind_family_review",
                    category=categories[1 + (index % (len(categories) - 1))],
                    source_case=source_case,
                    authored=True,
                )
            )
            reserve = SyntheticInputs.row(
                slot=f"reserve-{index:02d}",
                family=f"reserve-family-{index:02d}",
                source="fresh_replacement_reserve_model_blind_required",
                category=categories[1 + (index % (len(categories) - 1))],
                source_case=None,
                authored=False,
            )
            reserve["reserved_for_source_case_id"] = source_case
            reserves.append(reserve)
            decisions.append(
                {
                    "source_case_id": source_case,
                    "replacement_reserve_slot_id": reserve["slot_id"],
                }
            )

        assignments, packets, requirements = MODULE.build_outputs(
            contract, manifest, reserves, decisions
        )
        self.assertEqual(len(assignments), 1913)
        self.assertEqual(len(packets), 126)
        self.assertEqual({packet["slot_count"] for packet in packets}, {15})
        self.assertTrue(all(len(packet["category_counts"]) >= 2 for packet in packets))
        self.assertLessEqual(
            max(
                packet["category_counts"].get(categories[0], 0)
                for packet in packets
            ),
            3,
        )
        self.assertEqual(
            sum(packet["slot_count"] for packet in packets),
            1890,
        )
        self.assertFalse(requirements["merge_eligible"])

    def test_failed_pre_receipt_check_removes_partial_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixtures = SyntheticInputs(root)
            with self.assertRaisesRegex(RuntimeError, "synthetic Git drift"):
                MODULE.build_bundle(
                    contract=fixtures.contract,
                    contract_sha=sha(encode_json(fixtures.contract)),
                    allocation_receipt_path=fixtures.allocation / "receipt.json",
                    registry_receipt_path=fixtures.registry / "receipt.json",
                    output=root / "out",
                    execution_git_head="f" * 40,
                    pre_receipt_check=lambda: (_ for _ in ()).throw(
                        RuntimeError("synthetic Git drift")
                    ),
                )
            self.assertFalse((root / "out").exists())

    def test_raw_source_ids_and_legacy_lane_placeholders_are_not_published(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixtures = SyntheticInputs(root)
            self.build(root, fixtures)
            published = b"".join(
                (root / "out" / name).read_bytes() for name in MODULE.EXPECTED_ARTIFACTS
            )
            for forbidden in (
                b"synthetic-source-0",
                b"synthetic-source-1",
                b"legacy-placeholder",
            ):
                self.assertNotIn(forbidden, published)

    def test_candidate_output_or_eligibility_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixtures = SyntheticInputs(root)
            fixtures.manifest_rows[0]["candidate_model_output_seen"] = True
            fixtures.reseal()
            with self.assertRaisesRegex(MODULE.ValidationFailure, "eligibility must remain blocked"):
                self.build(root, fixtures)

    def test_missing_duplicate_or_swapped_reserve_custody_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixtures = SyntheticInputs(root)
            fixtures.reserve_rows[1]["reserved_for_source_case_id"] = (
                fixtures.reserve_rows[0]["reserved_for_source_case_id"]
            )
            fixtures.reseal()
            with self.assertRaisesRegex(MODULE.ValidationFailure, "custody is missing"):
                self.build(root, fixtures)

    def test_all_provisional_decisions_must_match_exact_reserve_mapping(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixtures = SyntheticInputs(root)
            first = fixtures.decision_rows[0]["replacement_reserve_slot_id"]
            second = fixtures.decision_rows[1]["replacement_reserve_slot_id"]
            fixtures.decision_rows[0]["replacement_reserve_slot_id"] = second
            fixtures.decision_rows[1]["replacement_reserve_slot_id"] = first
            fixtures.reseal()
            with self.assertRaisesRegex(
                MODULE.ValidationFailure, "exactly bind all replacement reserves"
            ):
                self.build(root, fixtures)

    def test_forged_allocation_receipt_is_rejected_by_exact_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixtures = SyntheticInputs(root)
            receipt_path = fixtures.allocation / "receipt.json"
            forged = json.loads(receipt_path.read_text())
            forged["fresh_required"] = 999
            receipt_path.write_bytes(encode_json(forged))
            with self.assertRaisesRegex(MODULE.ValidationFailure, "allocation receipt hash"):
                self.build(root, fixtures)

    def test_registry_family_and_text_artifacts_cannot_be_swapped(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixtures = SyntheticInputs(root)
            family = fixtures.registry / "blocked_family_registry.jsonl"
            family.write_bytes(fixtures.text_bytes)
            with self.assertRaisesRegex(MODULE.ValidationFailure, "artifact hash"):
                self.build(root, fixtures)

    def test_registry_schema_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixtures = SyntheticInputs(root)
            fixtures.family_rows[0]["schema_version"] = "forged-schema"
            fixtures.reseal()
            with self.assertRaisesRegex(MODULE.ValidationFailure, "family registry schema"):
                self.build(root, fixtures)

    def test_source_coverage_and_decision_artifacts_are_authenticated(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixtures = SyntheticInputs(root)
            (fixtures.registry / "source_coverage.jsonl").write_bytes(
                fixtures.decision_bytes
            )
            with self.assertRaisesRegex(MODULE.ValidationFailure, "artifact hash"):
                self.build(root, fixtures)

    def test_text_hash_registry_cannot_be_mislabeled_as_family_registry(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixtures = SyntheticInputs(root)
            receipt_path = fixtures.registry / "receipt.json"
            receipt = json.loads(receipt_path.read_text())
            receipt["artifacts"]["blocked_text_hashes.jsonl"][
                "validator_source_role"
            ] = "blocked_family_registry"
            receipt_bytes = encode_json(receipt)
            receipt_path.write_bytes(receipt_bytes)
            fixtures.contract["production_inputs"]["blocked_registry"][
                "receipt_sha256"
            ] = sha(receipt_bytes)
            with self.assertRaisesRegex(MODULE.ValidationFailure, "validator source role"):
                self.build(root, fixtures)

    def test_missing_input_is_rejected_and_no_bundle_is_left(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixtures = SyntheticInputs(root)
            (fixtures.registry / "blocked_text_hashes.jsonl").unlink()
            with self.assertRaisesRegex(MODULE.ValidationFailure, "cannot be read"):
                self.build(root, fixtures)
            self.assertFalse((root / "out").exists())

    def test_type_b_003_contract_is_exact_and_pending(self) -> None:
        contract = json.loads(CONTRACT_PATH.read_text())
        MODULE.validate_contract(contract, strict=False)
        gates = contract["merge_gate_requirements"]
        self.assertEqual(gates["author_source_identity_minimum"], 8)
        self.assertEqual(gates["human_native_original_fraction_minimum"], 0.5)
        self.assertEqual(gates["synthetic_generator_family_minimum"], 3)
        self.assertEqual(gates["synthetic_provider_fraction_maximum_overall"], 0.2)
        self.assertEqual(
            gates["synthetic_provider_fraction_maximum_per_category"], 0.25
        )
        self.assertEqual(gates["stratified_double_coding_fraction_minimum"], 0.15)
        self.assertEqual(gates["stratified_double_coding_fraction_maximum"], 0.2)
        self.assertEqual(gates["high_risk_double_review_fraction"], 1.0)
        self.assertEqual(gates["wave_stop_if_raw_agreement_below"], 0.95)
        self.assertEqual(gates["wave_stop_if_reliability_below"], 0.8)
        self.assertEqual(gates["all_statuses"], "pending")

    def test_git_gate_rejects_wrong_or_dirty_commit(self) -> None:
        with mock.patch.object(MODULE, "git_output") as git_output:
            git_output.side_effect = [b"1" * 40]
            with self.assertRaisesRegex(MODULE.ValidationFailure, "differs"):
                MODULE.validate_git_state("2" * 40)
        with mock.patch.object(MODULE, "git_output") as git_output:
            git_output.side_effect = [b"3" * 40, b" M sealed-file\n"]
            with self.assertRaisesRegex(MODULE.ValidationFailure, "must be clean"):
                MODULE.validate_git_state("3" * 40)

    def test_contract_refuses_claimed_satisfaction(self) -> None:
        contract = json.loads(CONTRACT_PATH.read_text())
        contract["merge_gate_requirements"]["all_statuses"] = "satisfied"
        with self.assertRaisesRegex(MODULE.ValidationFailure, "TYPE-B-003"):
            MODULE.validate_contract(contract, strict=False)

    def test_contract_refuses_changed_production_receipt_binding(self) -> None:
        contract = json.loads(CONTRACT_PATH.read_text())
        contract["production_inputs"]["allocation"]["receipt_sha256"] = "0" * 64
        with self.assertRaisesRegex(MODULE.ValidationFailure, "allocation receipt binding"):
            MODULE.validate_contract(contract, strict=False)

    def test_production_contract_stays_blocked_without_final_clean_receipt(self) -> None:
        contract = json.loads(CONTRACT_PATH.read_text())
        contract["status"] = (
            "pending_clean_blocked_registry_receipt_authorship_blocked"
        )
        registry = contract["production_inputs"]["blocked_registry"]
        registry["status"] = "pending_final_clean_receipt"
        registry["receipt_sha256"] = None
        registry["execution_git_head"] = None
        for name in (
            "family_artifact",
            "text_hash_artifact",
            "source_coverage_artifact",
            "provisional_decisions_artifact",
        ):
            registry[name]["sha256"] = None
        MODULE.validate_contract(contract, strict=False)
        self.assertEqual(registry["status"], "pending_final_clean_receipt")
        self.assertIsNone(registry["receipt_sha256"])
        self.assertIsNone(registry["execution_git_head"])
        for name in (
            "family_artifact",
            "text_hash_artifact",
            "source_coverage_artifact",
            "provisional_decisions_artifact",
        ):
            self.assertIsNone(registry[name]["sha256"])
        with self.assertRaisesRegex(
            MODULE.ValidationFailure, "blocked pending the final clean registry receipt"
        ):
            MODULE.require_production_ready(contract)

    def test_contract_only_final_binding_shape_can_unlock_publication(self) -> None:
        contract = json.loads(CONTRACT_PATH.read_text())
        contract["status"] = "sealed_registry_bound_metadata_only_authorship_blocked"
        registry = contract["production_inputs"]["blocked_registry"]
        registry["status"] = "sealed_final_clean_receipt"
        registry["receipt_sha256"] = "a" * 64
        registry["execution_git_head"] = "b" * 40
        for index, name in enumerate(
            (
                "family_artifact",
                "text_hash_artifact",
                "source_coverage_artifact",
                "provisional_decisions_artifact",
            ),
            1,
        ):
            registry[name]["sha256"] = f"{index:x}" * 64
        MODULE.validate_contract(contract, strict=False)
        MODULE.require_production_ready(contract)


if __name__ == "__main__":
    unittest.main()
