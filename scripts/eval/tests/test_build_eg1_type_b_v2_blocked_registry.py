from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

from scripts.eval import multilingual_benchmark_v2 as BENCHMARK


EVAL_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = EVAL_DIR / "build_eg1_type_b_v2_blocked_registry.py"
SPEC = importlib.util.spec_from_file_location(
    "build_eg1_type_b_v2_blocked_registry", MODULE_PATH
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

REAL_REPO_ROOT = MODULE.REPO_ROOT
PRIVATE_SOURCE_RELATIVE_PATHS = (
    Path("scripts/eval/corpus/type_b_approved_1890.jsonl"),
    Path("scripts/eval/corpus/type_b_overflow_900.jsonl"),
    Path("scripts/eval/corpus/type_b_all_v1.jsonl"),
    Path("scripts/eval/runs/bakeoff-1265/train_sft_v2.jsonl"),
)
PRIVATE_SOURCES_PRESENT = all(
    (REAL_REPO_ROOT / relative_path).is_file()
    for relative_path in PRIVATE_SOURCE_RELATIVE_PATHS
)
CLEAN_ARCHIVE_CHILD = "EG1_CLEAN_ARCHIVE_DISCOVERY_CHILD"


def verbatim_matches(patterns: set[str], value: bytes) -> set[bytes]:
    transitions: list[dict[int, int]] = [{}]
    failures = [0]
    outputs: list[list[bytes]] = [[]]
    for pattern in sorted(pattern.encode("utf-8") for pattern in patterns if pattern):
        state = 0
        for byte in pattern:
            state = transitions[state].setdefault(byte, len(transitions))
            if state == len(transitions):
                transitions.append({})
                failures.append(0)
                outputs.append([])
        outputs[state].append(pattern)
    queue = list(transitions[0].values())
    for state in queue:
        failures[state] = 0
    cursor = 0
    while cursor < len(queue):
        state = queue[cursor]
        cursor += 1
        for byte, target in transitions[state].items():
            queue.append(target)
            fallback = failures[state]
            while fallback and byte not in transitions[fallback]:
                fallback = failures[fallback]
            failures[target] = transitions[fallback].get(byte, 0)
            outputs[target].extend(outputs[failures[target]])
    matches: set[bytes] = set()
    state = 0
    for byte in value:
        while state and byte not in transitions[state]:
            state = failures[state]
        state = transitions[state].get(byte, 0)
        matches.update(outputs[state])
    return matches


class BuildTypeBV2BlockedRegistryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        self.expected_head = "a" * 40
        self.real_validate_git_state = MODULE.validate_git_state
        self._create_synthetic_repository()
        benchmark_artifacts = {
            name: {
                "role": artifact["validator_source_role"],
                "row_count": artifact["row_count"],
            }
            for name, artifact in self.synthetic_artifacts.items()
        }
        for patcher in (
            mock.patch.object(MODULE, "REPO_ROOT", self.synthetic_repo),
            mock.patch.object(MODULE, "SCRIPT_PATH", self.synthetic_builder_path),
            mock.patch.object(MODULE, "CONTRACT_PATH", self.synthetic_contract_path),
            mock.patch.object(
                MODULE,
                "ALLOCATION_CONTRACT_PATH",
                self.synthetic_allocation_path,
            ),
            mock.patch.object(
                MODULE, "ALLOCATOR_BUILDER_PATH", self.synthetic_allocator_path
            ),
            mock.patch.object(MODULE, "EXPECTED_COUNTS", self.synthetic_counts),
            mock.patch.object(
                MODULE,
                "EXPECTED_VALIDATOR_ARTIFACTS",
                self.synthetic_artifacts,
            ),
            mock.patch.object(BENCHMARK, "REPO_ROOT", self.synthetic_repo),
            mock.patch.object(
                BENCHMARK, "BLOCKED_REGISTRY_COUNTS", self.synthetic_counts
            ),
            mock.patch.object(
                BENCHMARK, "BLOCKED_REGISTRY_ARTIFACTS", benchmark_artifacts
            ),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.git_state_patcher = mock.patch.object(
            MODULE, "validate_git_state", return_value=self.expected_head
        )
        self.validate_git_state = self.git_state_patcher.start()
        self.addCleanup(self.git_state_patcher.stop)

    def _create_synthetic_repository(self) -> None:
        self.synthetic_repo = self.root / "synthetic-repo"
        self.synthetic_repo.mkdir()
        self.synthetic_builder_path = self.synthetic_repo / Path(
            "scripts/eval/build_eg1_type_b_v2_blocked_registry.py"
        )
        self.synthetic_contract_path = self.synthetic_repo / Path(
            "scripts/eval/contracts/eg1_type_b_v2_blocked_registry_v1.json"
        )
        self.synthetic_allocation_path = self.synthetic_repo / Path(
            "scripts/eval/contracts/eg1_type_b_v2_allocation_v1.json"
        )
        self.synthetic_allocator_path = self.synthetic_repo / Path(
            "scripts/eval/build_eg1_type_b_v2_manifest.py"
        )
        for destination, source in (
            (self.synthetic_builder_path, MODULE_PATH),
            (
                self.synthetic_allocator_path,
                REAL_REPO_ROOT / "scripts/eval/build_eg1_type_b_v2_manifest.py",
            ),
        ):
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)

        source_rows = {
            "type_b_approved_1890": [
                {
                    "id": f"SYN-APP-{index:03d}",
                    "asr_input": f"Invented calendar request number {index}",
                    "expected_output": f"Invented calendar request number {index}.",
                    "origin": f"synthetic-approved-family-{index}",
                }
                for index in range(1, 24)
            ],
            "type_b_overflow_900": [
                {
                    "id": f"SYN-OVER-{index:03d}",
                    "asr_input": f"Invented overflow note number {index}",
                    "expected_output": f"Invented overflow note number {index}.",
                    "origin": f"synthetic-overflow-family-{index}",
                }
                for index in range(1, 3)
            ],
            "type_b_all_v1": [
                {
                    "id": "SYN-ALL-001",
                    "asr_input": "Invented legacy reminder",
                    "expected_output": "Invented legacy reminder.",
                    "origin": "synthetic-all-family-1",
                }
            ],
            "shipping_sft_v2": [
                {
                    "id": "synthetic-training-row-001",
                    "input": "!!!",
                    "output": "...",
                }
            ],
        }
        source_definitions = (
            (
                "prior_benchmark",
                "type_b_approved_1890",
                PRIVATE_SOURCE_RELATIVE_PATHS[0],
                "id",
                "asr_input",
                "expected_output",
                "origin_proxy",
                "origin",
            ),
            (
                "legacy_benchmark",
                "type_b_overflow_900",
                PRIVATE_SOURCE_RELATIVE_PATHS[1],
                "id",
                "asr_input",
                "expected_output",
                "origin_proxy",
                "origin",
            ),
            (
                "legacy_benchmark",
                "type_b_all_v1",
                PRIVATE_SOURCE_RELATIVE_PATHS[2],
                "id",
                "asr_input",
                "expected_output",
                "origin_proxy",
                "origin",
            ),
            (
                "training",
                "shipping_sft_v2",
                PRIVATE_SOURCE_RELATIVE_PATHS[3],
                "id",
                "input",
                "output",
                "row_proxy_only",
                None,
            ),
        )
        source_specs: list[dict] = []
        source_bytes: dict[str, bytes] = {}
        for (
            role,
            name,
            relative_path,
            id_field,
            input_field,
            output_field,
            family_basis,
            family_field,
        ) in source_definitions:
            rows = source_rows[name]
            value = MODULE.encode_jsonl(rows)
            destination = self.synthetic_repo / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(value)
            source_bytes[name] = value
            source_specs.append(
                {
                    "role": role,
                    "name": name,
                    "path": str(relative_path),
                    "sha256": MODULE.sha256_bytes(value),
                    "row_count": len(rows),
                    "field_presence_counts": {
                        field: len(rows) for field in sorted(rows[0])
                    },
                    "id_field": id_field,
                    "input_field": input_field,
                    "output_field": output_field,
                    "family_basis": family_basis,
                    "family_field": family_field,
                }
            )

        decisions = [
            {
                "source_case_id": row["id"],
                "decision": "replace",
                "reason_code": "semantic_family_clearance_not_proven",
                "replacement_reserve_slot_id": f"tb2-reserve-{index:04d}",
            }
            for index, row in enumerate(
                source_rows["type_b_approved_1890"], start=1
            )
        ]
        coverage, families, text_hashes, source_lookup, source_receipts = (
            MODULE.build_registry(source_specs, source_bytes)
        )
        decision_rows = MODULE.build_decisions(decisions, source_lookup)
        artifact_rows = {
            "blocked_family_registry.jsonl": families,
            "blocked_text_hashes.jsonl": text_hashes,
            "source_coverage.jsonl": coverage,
            "provisional_decisions.jsonl": decision_rows,
        }
        artifact_bytes = {
            name: MODULE.encode_jsonl(rows) for name, rows in artifact_rows.items()
        }
        self.synthetic_artifacts = {
            name: {
                "sha256": MODULE.sha256_bytes(value),
                "row_count": len(artifact_rows[name]),
                "validator_source_role": MODULE.EXPECTED_VALIDATOR_SOURCE_BINDINGS.get(
                    name
                ),
            }
            for name, value in artifact_bytes.items()
        }
        self.synthetic_counts = {
            "sources": len(source_receipts),
            "source_rows": len(coverage),
            "blocked_families": len(families),
            "normalized_input_hashes": sum(
                row["field_kind"] == "input" for row in text_hashes
            ),
            "normalized_output_hashes": sum(
                row["field_kind"] == "output" for row in text_hashes
            ),
            "normalized_empty_input_rows": sum(
                row["normalized_empty_input_rows"] for row in source_receipts
            ),
            "normalized_empty_output_rows": sum(
                row["normalized_empty_output_rows"] for row in source_receipts
            ),
            "provisional_decisions": len(decision_rows),
            "replace": len(decision_rows),
            "retain": 0,
        }
        allocation = {
            "schema_version": "eg1-type-b-v2-allocation-v1",
            "source_sha256": {
                source["path"]: source["sha256"] for source in source_specs
            },
            "provisional_case_ids": [
                decision["source_case_id"] for decision in decisions
            ],
        }
        self.synthetic_allocation_path.parent.mkdir(parents=True, exist_ok=True)
        self.synthetic_allocation_path.write_text(
            json.dumps(allocation, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        contract = {
            "schema_version": MODULE.CONTRACT_SCHEMA,
            "registry_id": MODULE.EXPECTED_REGISTRY_ID,
            "status": "sealed",
            "normalization_policy_id": MODULE.NORMALIZATION_POLICY_ID,
            "allocator": {
                "allocation_contract_path": str(
                    self.synthetic_allocation_path.relative_to(self.synthetic_repo)
                ),
                "allocation_contract_sha256": MODULE.sha256_bytes(
                    self.synthetic_allocation_path.read_bytes()
                ),
                "builder_path": str(
                    self.synthetic_allocator_path.relative_to(self.synthetic_repo)
                ),
                "builder_sha256": MODULE.sha256_bytes(
                    self.synthetic_allocator_path.read_bytes()
                ),
            },
            "counts": self.synthetic_counts,
            "sources": source_specs,
            "expected_validator_artifacts": self.synthetic_artifacts,
            "candidate_clearance_contract": (
                MODULE.EXPECTED_CANDIDATE_CLEARANCE_CONTRACT
            ),
            "decision_policy": {
                "allowed_decisions": ["replace"],
                "required_reason_code": "semantic_family_clearance_not_proven",
                "candidate_model_output_seen": False,
                "fresh_benchmark_prose_authored": False,
                "decisions": decisions,
            },
            "publication": {
                "artifact_names": MODULE.EXPECTED_ARTIFACT_NAMES,
                "validator_source_roles": MODULE.EXPECTED_VALIDATOR_SOURCE_BINDINGS,
                "exclusive_bundle": True,
                "receipt_last": True,
                "private_text_allowed": False,
            },
        }
        self.synthetic_contract_path.write_text(
            json.dumps(contract, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.synthetic_source_values = {
            value
            for name, rows in source_rows.items()
            for row in rows
            for key, value in row.items()
            if isinstance(value, str)
            and (
                key in {"asr_input", "expected_output", "input", "output"}
                or (name == "shipping_sft_v2" and key == "id")
            )
        }

    def arguments(self, bundle: Path | None = None) -> list[str]:
        return [
            str(MODULE_PATH),
            "--out-bundle",
            str(bundle or self.bundle),
            "--expected-git-head",
            self.expected_head,
        ]

    def build(self, bundle: Path | None = None) -> None:
        with mock.patch.object(sys, "argv", self.arguments(bundle)):
            self.assertEqual(MODULE.main(), 0)

    @staticmethod
    def jsonl(path: Path) -> list[dict]:
        return [json.loads(line) for line in path.read_text().splitlines() if line]

    def registry_sources(
        self, bundle: Path | None = None
    ) -> list[BENCHMARK.LeakageSource]:
        bundle = bundle or self.bundle
        return [
            BENCHMARK.LeakageSource(
                role,
                name,
                path,
                BENCHMARK.sha256_file(path),
            )
            for role, name, path in (
                (
                    "blocked_family_registry",
                    "type-b-v2-families",
                    bundle / "blocked_family_registry.jsonl",
                ),
                (
                    "blocked_text_hash_registry",
                    "type-b-v2-text-hashes",
                    bundle / "blocked_text_hashes.jsonl",
                ),
            )
        ]

    def validate_bundle(
        self,
        *,
        sources: list[BENCHMARK.LeakageSource] | None = None,
        bundle: Path | None = None,
        committed_byte_overrides: dict[str, bytes | None] | None = None,
    ) -> dict:
        bundle = bundle or self.bundle
        receipt_path = bundle / "receipt.json"
        receipt = json.loads(receipt_path.read_text())
        committed_bytes = {
            relative_path: (MODULE.REPO_ROOT / relative_path).read_bytes()
            for relative_path in (
                receipt["contract"]["path"],
                receipt["builder"]["path"],
                receipt["allocator"]["allocation_contract_path"],
                receipt["allocator"]["builder_path"],
            )
        }
        committed_bytes.update(committed_byte_overrides or {})
        with mock.patch.object(
            BENCHMARK,
            "_git_committed_file_bytes",
            side_effect=lambda head, path: (
                committed_bytes.get(path) if head == self.expected_head else None
            ),
        ):
            return BENCHMARK.validate_blocked_registry_receipt(
                receipt_path,
                sources=sources or self.registry_sources(bundle),
            )

    def test_builds_portable_synthetic_metadata_only_registry(self) -> None:
        self.build()
        receipt = json.loads((self.bundle / "receipt.json").read_text())
        coverage = self.jsonl(self.bundle / "source_coverage.jsonl")
        families = self.jsonl(self.bundle / "blocked_family_registry.jsonl")
        text_hashes = self.jsonl(self.bundle / "blocked_text_hashes.jsonl")
        decisions = self.jsonl(self.bundle / "provisional_decisions.jsonl")

        self.assertEqual(receipt["counts"], MODULE.EXPECTED_COUNTS)
        self.assertEqual(len(coverage), self.synthetic_counts["source_rows"])
        self.assertEqual(len(families), self.synthetic_counts["blocked_families"])
        self.assertEqual(
            len(text_hashes),
            self.synthetic_counts["normalized_input_hashes"]
            + self.synthetic_counts["normalized_output_hashes"],
        )
        self.assertEqual(
            len(decisions), self.synthetic_counts["provisional_decisions"]
        )
        self.assertEqual(receipt["counts"]["normalized_empty_input_rows"], 1)
        self.assertEqual(receipt["counts"]["normalized_empty_output_rows"], 1)
        source_receipts = {row["name"]: row for row in receipt["sources"]}
        self.assertEqual(
            source_receipts["shipping_sft_v2"]["normalized_empty_input_rows"], 1
        )
        self.assertEqual(
            source_receipts["shipping_sft_v2"]["normalized_empty_output_rows"], 1
        )
        for source_name in (
            "type_b_approved_1890",
            "type_b_overflow_900",
            "type_b_all_v1",
        ):
            self.assertEqual(
                source_receipts[source_name]["normalized_empty_input_rows"], 0
            )
            self.assertEqual(
                source_receipts[source_name]["normalized_empty_output_rows"], 0
            )
        self.assertEqual({row["decision"] for row in decisions}, {"replace"})
        self.assertEqual(
            {row["reason_code"] for row in decisions},
            {"semantic_family_clearance_not_proven"},
        )
        self.assertEqual(
            [row["replacement_reserve_slot_id"] for row in decisions],
            [f"tb2-reserve-{index:04d}" for index in range(1, 24)],
        )
        self.assertEqual(
            len({row["registry_entry_id"] for row in coverage}),
            self.synthetic_counts["source_rows"],
        )
        self.assertEqual(
            len({row["semantic_family_id"] for row in families}),
            self.synthetic_counts["blocked_families"],
        )
        self.assertTrue(receipt["privacy"]["metadata_only"])
        self.assertFalse(receipt["privacy"]["private_source_text_published"])
        self.assertFalse(receipt["privacy"]["private_source_row_ids_published_raw"])
        self.assertTrue(receipt["privacy"]["safe_provisional_case_ids_published"])
        self.assertFalse(receipt["privacy"]["other_source_row_ids_published_raw"])
        self.assertFalse(receipt["authorship_gate"]["candidate_model_output_seen"])
        self.assertFalse(receipt["authorship_gate"]["fresh_benchmark_prose_authored"])
        self.assertFalse(receipt["authorship_gate"]["fresh_authorship_authorized"])
        self.assertEqual(receipt["authorship_gate"]["fresh_slots_required"], 1890)
        self.assertEqual(
            receipt["candidate_clearance_contract"],
            MODULE.EXPECTED_CANDIDATE_CLEARANCE_CONTRACT,
        )
        self.assertEqual(
            receipt["artifacts"]["blocked_family_registry.jsonl"][
                "validator_source_role"
            ],
            "blocked_family_registry",
        )
        self.assertEqual(
            receipt["artifacts"]["blocked_text_hashes.jsonl"][
                "validator_source_role"
            ],
            "blocked_text_hash_registry",
        )
        self.assertEqual(self.validate_git_state.call_count, 2)

        published = b"".join(
            (self.bundle / name).read_bytes()
            for name in MODULE.EXPECTED_ARTIFACT_NAMES
        )
        for invented_value in self.synthetic_source_values:
            self.assertNotIn(invented_value.encode(), published)

        for name, artifact in receipt["artifacts"].items():
            value = (self.bundle / name).read_bytes()
            self.assertEqual(artifact["sha256"], hashlib.sha256(value).hexdigest())

    def test_family_registry_requires_clearance_for_preassigned_candidate_id(self) -> None:
        self.build()
        family_path = self.bundle / "blocked_family_registry.jsonl"
        source = BENCHMARK.LeakageSource(
            "blocked_family_registry",
            "type-b-v2",
            family_path,
            hashlib.sha256(family_path.read_bytes()).hexdigest(),
        )
        candidate = {
            "case_id": "synthetic-compatibility-probe",
            "asr_input": "fresh compatibility input",
            "gold_output": "Fresh compatibility output.",
            "semantic_family_id": "tb2fam-preassigned-candidate",
            "provenance": {
                "native_author": {"reviewer_id": "author-1"},
            },
        }
        missing = BENCHMARK.exact_leakage_errors([candidate], [source])
        candidate["provenance"]["blocked_family_clearances"] = [
            {
                "registry_sha256": source.sha256,
                "candidate_semantic_family_id": candidate["semantic_family_id"],
                "reviewer_id": "family-reviewer-1",
                "independent_of_author": True,
                "status": "cleared",
                "reviewed_on": "2026-07-15",
            }
        ]
        cleared = BENCHMARK.exact_leakage_errors([candidate], [source])
        self.assertTrue(
            any("missing valid blocked-family clearance" in error for error in missing)
        )
        self.assertEqual(cleared, [])

    def test_benchmark_accepts_authenticated_receipt_after_head_advances(self) -> None:
        control_repo = self.root / "control-repo"
        control_repo.mkdir()
        producing_contract = json.loads(MODULE.CONTRACT_PATH.read_text())
        control_paths = (
            MODULE.CONTRACT_PATH.relative_to(MODULE.REPO_ROOT),
            MODULE.SCRIPT_PATH.relative_to(MODULE.REPO_ROOT),
            MODULE.ALLOCATION_CONTRACT_PATH.relative_to(MODULE.REPO_ROOT),
            MODULE.ALLOCATOR_BUILDER_PATH.relative_to(MODULE.REPO_ROOT),
        )
        source_paths = tuple(
            Path(source["path"]) for source in producing_contract["sources"]
        )
        for relative_path in (*control_paths, *source_paths):
            destination = control_repo / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(MODULE.REPO_ROOT / relative_path, destination)

        def git(*args: str) -> str:
            result = subprocess.run(
                ["git", *args],
                cwd=control_repo,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            return result.stdout.strip()

        git("init")
        git("config", "user.name", "EG-1 Test")
        git("config", "user.email", "eg1-test@example.invalid")
        git("add", ".")
        git("commit", "-m", "producing controls")
        producing_head = git("rev-parse", "HEAD")
        self.expected_head = producing_head
        self.validate_git_state.return_value = producing_head
        self.build()

        for index, relative_path in enumerate(control_paths, start=1):
            current_path = control_repo / relative_path
            current_path.write_bytes(
                current_path.read_bytes()
                + (
                    f"\n# later control change {index}\n".encode()
                    if current_path.suffix == ".py"
                    else b"\n"
                )
            )
            git("add", str(relative_path))
            git("commit", "-m", f"later control change {index}")
            self.assertNotEqual(git("rev-parse", "HEAD"), producing_head)
            with mock.patch.object(BENCHMARK, "REPO_ROOT", control_repo):
                receipt = BENCHMARK.validate_blocked_registry_receipt(
                    self.bundle / "receipt.json",
                    sources=self.registry_sources(),
                )
            self.assertEqual(receipt["execution_git_head"], producing_head)
            self.assertEqual(
                receipt["artifacts"], MODULE.EXPECTED_VALIDATOR_ARTIFACTS
            )

    def test_benchmark_rejects_coherent_arbitrary_family_registry(self) -> None:
        self.build()
        family_path = self.bundle / "blocked_family_registry.jsonl"
        families = self.jsonl(family_path)
        families[0]["semantic_family_id"] = "tb2fam-coherently-forged"
        family_path.write_text(
            "".join(json.dumps(row, sort_keys=True) + "\n" for row in families),
            encoding="utf-8",
        )
        forged_sha = BENCHMARK.sha256_file(family_path)
        receipt_path = self.bundle / "receipt.json"
        receipt = json.loads(receipt_path.read_text())
        receipt["artifacts"]["blocked_family_registry.jsonl"]["sha256"] = forged_sha
        receipt_path.write_text(
            json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        sources = self.registry_sources()

        with self.assertRaises(BENCHMARK.BenchmarkValidationError) as raised:
            self.validate_bundle(sources=sources)
        self.assertIn("differs from tracked contract", str(raised.exception))

    def test_benchmark_rejects_coherent_coverage_and_decision_tampering(self) -> None:
        for artifact_name in (
            "source_coverage.jsonl",
            "provisional_decisions.jsonl",
        ):
            with self.subTest(artifact_name=artifact_name):
                bundle = self.root / artifact_name.removesuffix(".jsonl")
                self.build(bundle)
                artifact_path = bundle / artifact_name
                rows = self.jsonl(artifact_path)
                if artifact_name == "source_coverage.jsonl":
                    rows[0]["registry_entry_id"] = "tb2entry-coherently-forged"
                else:
                    for row in rows:
                        row["decision"] = "retain"
                        row["reason_code"] = "coherently_forged"
                artifact_path.write_text(
                    "".join(
                        json.dumps(row, sort_keys=True) + "\n" for row in rows
                    ),
                    encoding="utf-8",
                )
                receipt_path = bundle / "receipt.json"
                receipt = json.loads(receipt_path.read_text())
                receipt["artifacts"][artifact_name][
                    "sha256"
                ] = BENCHMARK.sha256_file(artifact_path)
                receipt_path.write_text(
                    json.dumps(receipt, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
                with self.assertRaises(BENCHMARK.BenchmarkValidationError) as raised:
                    self.validate_bundle(bundle=bundle)
                self.assertIn("differs from tracked contract", str(raised.exception))

    def test_benchmark_rejects_invalid_or_mismatched_producing_commit(self) -> None:
        self.build()
        receipt_path = self.bundle / "receipt.json"
        original = json.loads(receipt_path.read_text())
        receipt = json.loads(json.dumps(original))
        receipt["execution_git_head"] = "b" * 40
        receipt_path.write_text(
            json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        with self.assertRaises(BENCHMARK.BenchmarkValidationError) as raised:
            self.validate_bundle()
        self.assertIn("execution commit does not contain", str(raised.exception))

        receipt_path.write_text(
            json.dumps(original, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        with self.assertRaises(BENCHMARK.BenchmarkValidationError) as raised:
            self.validate_bundle(
                committed_byte_overrides={
                    original["builder"]["path"]: None,
                }
            )
        self.assertIn("execution commit does not contain", str(raised.exception))

        with self.assertRaises(BENCHMARK.BenchmarkValidationError) as raised:
            self.validate_bundle(
                committed_byte_overrides={
                    original["builder"]["path"]: b"forged producing builder\n",
                }
            )
        self.assertIn("receipt builder binding is invalid", str(raised.exception))

    def test_benchmark_rejects_swapped_or_duplicate_registry_roles(self) -> None:
        self.build()
        family_path = self.bundle / "blocked_family_registry.jsonl"
        text_path = self.bundle / "blocked_text_hashes.jsonl"
        cases = {
            "swapped": [
                BENCHMARK.LeakageSource(
                    "blocked_family_registry",
                    "families",
                    text_path,
                    BENCHMARK.sha256_file(text_path),
                ),
                BENCHMARK.LeakageSource(
                    "blocked_text_hash_registry",
                    "hashes",
                    family_path,
                    BENCHMARK.sha256_file(family_path),
                ),
            ],
            "duplicate-family": [
                BENCHMARK.LeakageSource(
                    "blocked_family_registry",
                    "families-a",
                    family_path,
                    BENCHMARK.sha256_file(family_path),
                ),
                BENCHMARK.LeakageSource(
                    "blocked_family_registry",
                    "families-b",
                    family_path,
                    BENCHMARK.sha256_file(family_path),
                ),
            ],
            "missing-family": [
                BENCHMARK.LeakageSource(
                    "blocked_text_hash_registry",
                    "hashes",
                    text_path,
                    BENCHMARK.sha256_file(text_path),
                )
            ],
        }
        for name, sources in cases.items():
            with self.subTest(name=name):
                with self.assertRaises(BENCHMARK.BenchmarkValidationError):
                    self.validate_bundle(sources=sources)

    def test_benchmark_rejects_receipt_status_role_and_source_drift(self) -> None:
        self.build()
        receipt_path = self.bundle / "receipt.json"
        original = json.loads(receipt_path.read_text())

        def wrong_status(receipt: dict) -> None:
            receipt["status"] = "draft"

        def wrong_role(receipt: dict) -> None:
            receipt["artifacts"]["blocked_family_registry.jsonl"][
                "validator_source_role"
            ] = "blocked_text_hash_registry"

        def wrong_source(receipt: dict) -> None:
            receipt["sources"][0]["sha256"] = "0" * 64

        for name, mutate in (
            ("status", wrong_status),
            ("role", wrong_role),
            ("source", wrong_source),
        ):
            with self.subTest(name=name):
                receipt = json.loads(json.dumps(original))
                mutate(receipt)
                receipt_path.write_text(
                    json.dumps(receipt, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
                with self.assertRaises(BENCHMARK.BenchmarkValidationError):
                    self.validate_bundle()

    def test_benchmark_rejects_tampered_per_source_coverage_counts(self) -> None:
        self.build()
        receipt_path = self.bundle / "receipt.json"
        original = json.loads(receipt_path.read_text())
        count_fields = (
            "blocked_family_count",
            "unique_normalized_input_hashes",
            "unique_normalized_output_hashes",
            "normalized_empty_input_rows",
            "normalized_empty_output_rows",
        )
        for count_field in count_fields:
            with self.subTest(count_field=count_field):
                receipt = json.loads(json.dumps(original))
                source = next(
                    source
                    for source in receipt["sources"]
                    if source[count_field] > 0
                )
                source[count_field] -= 1
                receipt_path.write_text(
                    json.dumps(receipt, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
                with self.assertRaises(BENCHMARK.BenchmarkValidationError) as raised:
                    self.validate_bundle()
                self.assertIn("differs from source coverage", str(raised.exception))

    def test_benchmark_rejects_boolean_per_source_coverage_counts(self) -> None:
        self.build()
        receipt_path = self.bundle / "receipt.json"
        original = json.loads(receipt_path.read_text())
        for numeric_value in (0, 1):
            with self.subTest(numeric_value=numeric_value):
                receipt = json.loads(json.dumps(original))
                source, count_field = next(
                    (source, count_field)
                    for source in receipt["sources"]
                    for count_field in (
                        "blocked_family_count",
                        "unique_normalized_input_hashes",
                        "unique_normalized_output_hashes",
                        "normalized_empty_input_rows",
                        "normalized_empty_output_rows",
                    )
                    if source[count_field] == numeric_value
                )
                source[count_field] = bool(numeric_value)
                receipt_path.write_text(
                    json.dumps(receipt, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
                with self.assertRaises(BENCHMARK.BenchmarkValidationError) as raised:
                    self.validate_bundle()
                self.assertIn("differs from source coverage", str(raised.exception))

    def test_benchmark_rejects_source_drift_and_zero_family_records(self) -> None:
        for mutation in ("drift", "zero"):
            with self.subTest(mutation=mutation):
                bundle = self.root / mutation
                self.build(bundle)
                family_path = bundle / "blocked_family_registry.jsonl"
                if mutation == "drift":
                    family_path.write_bytes(family_path.read_bytes() + b"\n")
                else:
                    family_path.write_text("", encoding="utf-8")
                sources = self.registry_sources(bundle)
                with self.assertRaises(BENCHMARK.BenchmarkValidationError) as raised:
                    self.validate_bundle(bundle=bundle, sources=sources)
                message = str(raised.exception)
                if mutation == "drift":
                    self.assertIn("differs from receipt", message)
                else:
                    self.assertIn("zero family records", message)

    def test_text_hash_registry_blocks_source_text_through_existing_validator(self) -> None:
        self.build()
        hash_path = self.bundle / "blocked_text_hashes.jsonl"
        source = BENCHMARK.LeakageSource(
            "blocked_text_hash_registry",
            "type-b-v2-text-hashes",
            hash_path,
            hashlib.sha256(hash_path.read_bytes()).hexdigest(),
        )
        synthetic_row = json.loads(
            MODULE.REPO_ROOT.joinpath(
                "scripts/eval/corpus/type_b_approved_1890.jsonl"
            ).read_text().splitlines()[0]
        )
        errors = BENCHMARK.exact_leakage_errors(
            [
                {
                    "case_id": "synthetic-hash-probe",
                    "asr_input": synthetic_row["asr_input"],
                    "gold_output": "Synthetic unrelated output.",
                    "semantic_family_id": "tb2fam-synthetic-hash-probe",
                }
            ],
            [source],
        )
        self.assertTrue(any("input exact-hash-leaks" in error for error in errors))

    def test_normalization_matches_existing_v2_leakage_validator(self) -> None:
        probes = (
            "Caf\u00e9\u2014LIST!",
            "\uff26\uff55\uff4c\uff4c\uff57\uff49\uff44\uff54\uff48  １２３",
            "punctuation-only: !?\u2014\ud83d\ude80",
            "\u041c\u043e\u0441\u043a\u0432\u0430, \u043c\u0430\u0439",
        )
        for probe in probes:
            with self.subTest(probe=probe):
                self.assertEqual(
                    MODULE.normalize_text(probe), BENCHMARK.normalize_text(probe)
                )

    def test_is_byte_deterministic(self) -> None:
        self.build()
        second = self.root / "second"
        self.build(second)
        for name in MODULE.EXPECTED_ARTIFACT_NAMES:
            self.assertEqual((self.bundle / name).read_bytes(), (second / name).read_bytes())

    def test_rejects_source_drift_before_publication(self) -> None:
        original_read = MODULE.read_once

        def drift(path: Path) -> tuple[bytes, str]:
            value, digest = original_read(path)
            if path.name == "type_b_approved_1890.jsonl":
                value += b"\n"
                digest = hashlib.sha256(value).hexdigest()
            return value, digest

        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.object(MODULE, "read_once", side_effect=drift),
        ):
            with self.assertRaisesRegex(ValueError, "source changed"):
                MODULE.main()
        self.assertFalse(self.bundle.exists())

    def test_rejects_source_drift_during_publication_and_cleans_bundle(self) -> None:
        original_read = MODULE.read_once
        reads = 0

        def drift(path: Path) -> tuple[bytes, str]:
            nonlocal reads
            value, digest = original_read(path)
            if path.name == "type_b_approved_1890.jsonl":
                reads += 1
                if reads == 2:
                    value += b"\n"
                    digest = hashlib.sha256(value).hexdigest()
            return value, digest

        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.object(MODULE, "read_once", side_effect=drift),
        ):
            with self.assertRaisesRegex(RuntimeError, "source changed during publication"):
                MODULE.main()
        self.assertFalse(self.bundle.exists())

    def test_rejects_source_schema_drift(self) -> None:
        original_read = MODULE.read_once

        def drift(path: Path) -> tuple[bytes, str]:
            value, digest = original_read(path)
            if path.name == "type_b_approved_1890.jsonl":
                lines = value.decode().splitlines()
                row = json.loads(lines[0])
                row["new_field"] = "schema drift"
                lines[0] = json.dumps(row)
                value = ("\n".join(lines) + "\n").encode()
            return value, digest

        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.object(MODULE, "read_once", side_effect=drift),
        ):
            with self.assertRaisesRegex(ValueError, "schema changed"):
                MODULE.main()
        self.assertFalse(self.bundle.exists())

    def test_rejects_duplicate_source_row_id(self) -> None:
        original_read = MODULE.read_once

        def duplicate(path: Path) -> tuple[bytes, str]:
            value, digest = original_read(path)
            if path.name == "type_b_overflow_900.jsonl":
                lines = value.decode().splitlines()
                first = json.loads(lines[0])
                second = json.loads(lines[1])
                second["id"] = first["id"]
                lines[1] = json.dumps(second)
                value = ("\n".join(lines) + "\n").encode()
            return value, digest

        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.object(MODULE, "read_once", side_effect=duplicate),
        ):
            with self.assertRaisesRegex(ValueError, "duplicate row ID"):
                MODULE.main()
        self.assertFalse(self.bundle.exists())

    def test_rejects_unresolved_source_row(self) -> None:
        original_read = MODULE.read_once

        def unresolved(path: Path) -> tuple[bytes, str]:
            value, digest = original_read(path)
            if path.name == "train_sft_v2.jsonl":
                lines = value.decode().splitlines()
                row = json.loads(lines[0])
                row["input"] = ""
                lines[0] = json.dumps(row)
                value = ("\n".join(lines) + "\n").encode()
            return value, digest

        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.object(MODULE, "read_once", side_effect=unresolved),
        ):
            with self.assertRaisesRegex(ValueError, "input is unresolved"):
                MODULE.main()
        self.assertFalse(self.bundle.exists())

    def test_rejects_decision_coverage_gap(self) -> None:
        original_read = MODULE.read_once

        def gap(path: Path) -> tuple[bytes, str]:
            value, digest = original_read(path)
            if path == MODULE.CONTRACT_PATH:
                contract = json.loads(value)
                contract["decision_policy"]["decisions"].pop()
                value = (json.dumps(contract) + "\n").encode()
                digest = hashlib.sha256(value).hexdigest()
            return value, digest

        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.object(MODULE, "read_once", side_effect=gap),
        ):
            with self.assertRaisesRegex(ValueError, "decision coverage differs"):
                MODULE.main()
        self.assertFalse(self.bundle.exists())

    def test_rejects_unresolved_provisional_decision(self) -> None:
        original_read = MODULE.read_once

        def unresolved(path: Path) -> tuple[bytes, str]:
            value, digest = original_read(path)
            if path == MODULE.CONTRACT_PATH:
                contract = json.loads(value)
                contract["decision_policy"]["decisions"][0]["decision"] = "pending"
                value = (json.dumps(contract) + "\n").encode()
                digest = hashlib.sha256(value).hexdigest()
            return value, digest

        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.object(MODULE, "read_once", side_effect=unresolved),
        ):
            with self.assertRaisesRegex(ValueError, "is unresolved"):
                MODULE.main()
        self.assertFalse(self.bundle.exists())

    def test_rejects_duplicate_provisional_decision(self) -> None:
        original_read = MODULE.read_once

        def duplicate(path: Path) -> tuple[bytes, str]:
            value, digest = original_read(path)
            if path == MODULE.CONTRACT_PATH:
                contract = json.loads(value)
                decisions = contract["decision_policy"]["decisions"]
                decisions[-1]["source_case_id"] = decisions[0]["source_case_id"]
                value = (json.dumps(contract) + "\n").encode()
                digest = hashlib.sha256(value).hexdigest()
            return value, digest

        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.object(MODULE, "read_once", side_effect=duplicate),
        ):
            with self.assertRaisesRegex(ValueError, "duplicate case IDs"):
                MODULE.main()
        self.assertFalse(self.bundle.exists())

    def test_rejects_allocator_source_inventory_drift(self) -> None:
        contract = json.loads(MODULE.CONTRACT_PATH.read_text())
        allocation = json.loads(MODULE.ALLOCATION_CONTRACT_PATH.read_text())
        allocation["source_sha256"].pop(next(iter(allocation["source_sha256"])))
        with self.assertRaisesRegex(ValueError, "differs from allocator source inventory"):
            MODULE.validate_contract(
                contract,
                allocation,
                allocation_contract_sha=contract["allocator"]["allocation_contract_sha256"],
                allocator_builder_sha=contract["allocator"]["builder_sha256"],
            )

    def test_rejects_candidate_clearance_contract_drift(self) -> None:
        contract = json.loads(MODULE.CONTRACT_PATH.read_text())
        allocation = json.loads(MODULE.ALLOCATION_CONTRACT_PATH.read_text())
        contract["candidate_clearance_contract"]["required_status"] = "pending"
        with self.assertRaisesRegex(
            ValueError, "candidate clearance contract changed"
        ):
            MODULE.validate_contract(
                contract,
                allocation,
                allocation_contract_sha=contract["allocator"][
                    "allocation_contract_sha256"
                ],
                allocator_builder_sha=contract["allocator"]["builder_sha256"],
            )

    def test_rejects_validator_source_binding_drift(self) -> None:
        contract = json.loads(MODULE.CONTRACT_PATH.read_text())
        allocation = json.loads(MODULE.ALLOCATION_CONTRACT_PATH.read_text())
        contract["publication"]["validator_source_roles"].pop(
            "blocked_text_hashes.jsonl"
        )
        with self.assertRaisesRegex(ValueError, "publication contract changed"):
            MODULE.validate_contract(
                contract,
                allocation,
                allocation_contract_sha=contract["allocator"][
                    "allocation_contract_sha256"
                ],
                allocator_builder_sha=contract["allocator"]["builder_sha256"],
            )

    def test_rejects_expected_validator_artifact_drift(self) -> None:
        contract = json.loads(MODULE.CONTRACT_PATH.read_text())
        allocation = json.loads(MODULE.ALLOCATION_CONTRACT_PATH.read_text())
        contract["expected_validator_artifacts"][
            "blocked_family_registry.jsonl"
        ]["sha256"] = "0" * 64
        with self.assertRaisesRegex(
            ValueError, "expected validator artifacts changed"
        ):
            MODULE.validate_contract(
                contract,
                allocation,
                allocation_contract_sha=contract["allocator"][
                    "allocation_contract_sha256"
                ],
                allocator_builder_sha=contract["allocator"]["builder_sha256"],
            )

    def test_partial_receipt_write_removes_entire_bundle(self) -> None:
        original_write = MODULE.write_exclusive

        def fail_receipt(path: Path, value: bytes) -> None:
            if path.name == "receipt.json":
                path.write_bytes(value[:1])
                raise OSError("synthetic partial receipt")
            original_write(path, value)

        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.object(MODULE, "write_exclusive", side_effect=fail_receipt),
        ):
            with self.assertRaisesRegex(OSError, "synthetic partial receipt"):
                MODULE.main()
        self.assertFalse(self.bundle.exists())

    def test_git_binding_rejects_dirty_tracked_state(self) -> None:
        with mock.patch.object(
            MODULE,
            "git_output",
            side_effect=[
                (self.expected_head + "\n").encode(),
                b" M scripts/eval/build_eg1_type_b_v2_blocked_registry.py\n",
            ],
        ):
            with self.assertRaisesRegex(ValueError, "tracked worktree must be clean"):
                self.real_validate_git_state(self.expected_head)

    def test_refuses_existing_bundle_without_touching_it(self) -> None:
        self.bundle.mkdir()
        marker = self.bundle / "keep"
        marker.write_text("keep")
        with mock.patch.object(sys, "argv", self.arguments()):
            with self.assertRaises(SystemExit):
                MODULE.main()
        self.assertEqual(marker.read_text(), "keep")


class CleanArchiveEvalDiscoveryTests(unittest.TestCase):
    def test_clean_archive_eval_discovery_has_only_explicit_private_integration_skips(
        self,
    ) -> None:
        if os.environ.get(CLEAN_ARCHIVE_CHILD) == "1":
            return
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive_path = root / "tracked.tar"
            checkout = root / "checkout"
            checkout.mkdir()
            subprocess.run(
                [
                    "git",
                    "archive",
                    "--format=tar",
                    "-o",
                    str(archive_path),
                    "HEAD",
                ],
                cwd=REAL_REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            with tarfile.open(archive_path) as archive:
                archive.extractall(checkout, filter="data")

            changed = subprocess.run(
                ["git", "diff", "--name-only", "HEAD"],
                cwd=REAL_REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            ).stdout.splitlines()
            for relative in changed:
                source = REAL_REPO_ROOT / relative
                destination = checkout / relative
                if source.is_file():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, destination)
                elif destination.exists():
                    destination.unlink()

            environment = os.environ.copy()
            environment[CLEAN_ARCHIVE_CHILD] = "1"
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            result = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "unittest",
                    "discover",
                    "-v",
                    "-s",
                    "scripts/eval/tests",
                ],
                cwd=checkout,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("OK (skipped=2)", output)
            self.assertEqual(
                output.count(
                    "requires all four ignored real-private Type B source files"
                ),
                1,
                output,
            )
            self.assertEqual(
                output.count(
                    "set EG1_REPLAY_PRIVATE_INTEGRATION=1 for the local private-artifact gate"
                ),
                1,
                output,
            )


@unittest.skipUnless(
    PRIVATE_SOURCES_PRESENT,
    "requires all four ignored real-private Type B source files",
)
class RealPrivateTypeBV2BlockedRegistryIntegrationTests(unittest.TestCase):
    def test_real_private_counts_receipt_hashes_and_privacy_intersection(self) -> None:
        expected_counts = {
            "sources": 4,
            "source_rows": 11236,
            "blocked_families": 7198,
            "normalized_input_hashes": 6872,
            "normalized_output_hashes": 6861,
            "normalized_empty_input_rows": 1,
            "normalized_empty_output_rows": 1,
            "provisional_decisions": 23,
            "replace": 23,
            "retain": 0,
        }
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "real-private-bundle"
            execution_head = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=REAL_REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            ).stdout.strip()
            arguments = [
                str(MODULE_PATH),
                "--out-bundle",
                str(bundle),
                "--expected-git-head",
                execution_head,
            ]
            with (
                mock.patch.object(sys, "argv", arguments),
                mock.patch.object(
                    MODULE, "validate_git_state", return_value=execution_head
                ),
            ):
                self.assertEqual(MODULE.main(), 0)

            receipt = json.loads((bundle / "receipt.json").read_text())
            self.assertEqual(receipt["execution_git_head"], execution_head)
            self.assertEqual(receipt["counts"], expected_counts)
            self.assertEqual(receipt["artifacts"], MODULE.EXPECTED_VALIDATOR_ARTIFACTS)
            for artifact_name, artifact in receipt["artifacts"].items():
                self.assertEqual(
                    artifact["sha256"],
                    hashlib.sha256((bundle / artifact_name).read_bytes()).hexdigest(),
                )

            private_values: set[str] = set()
            for relative_path in PRIVATE_SOURCE_RELATIVE_PATHS[:3]:
                for line in (REAL_REPO_ROOT / relative_path).read_text(
                    encoding="utf-8"
                ).splitlines():
                    row = json.loads(line)
                    private_values.update((row["asr_input"], row["expected_output"]))
            for line in (REAL_REPO_ROOT / PRIVATE_SOURCE_RELATIVE_PATHS[3]).read_text(
                encoding="utf-8"
            ).splitlines():
                row = json.loads(line)
                private_values.update((row["id"], row["input"], row["output"]))
            published = b"".join(
                (bundle / name).read_bytes() for name in MODULE.EXPECTED_ARTIFACT_NAMES
            )
            matches = verbatim_matches(private_values, published)
            self.assertEqual(len(private_values), 18301)
            self.assertEqual(matches, set())


if __name__ == "__main__":
    unittest.main()
