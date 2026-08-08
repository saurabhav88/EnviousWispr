#!/usr/bin/env python3
"""Tests for the D1 allocation and fail-closed export gate.

The generated strings below are disposable validator fixtures. They are not
training examples and are written only inside a temporary test directory.
"""

from __future__ import annotations

import copy
from contextlib import contextmanager
import json
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from collections import Counter
from pathlib import Path


EVAL_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = EVAL_DIR.parents[1]
sys.path.insert(0, str(EVAL_DIR))

import build_eg1_multilingual_d1 as d1  # noqa: E402
import build_eg1_d1_authoring_launch as launch  # noqa: E402
import build_eg1_d1_shared_concept_registry as shared_registry  # noqa: E402


CONTRACT_PATH = EVAL_DIR / "eg1_multilingual_d1_contract_v1.json"
PROMPT_PATH = EVAL_DIR / "prompts" / "eg1-list-aware-v2.txt"
SCRIPT_PATH = EVAL_DIR / "build_eg1_multilingual_d1.py"


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_jsonl(path: Path, rows: list[dict[str, object]]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


@contextmanager
def trusted_shared_concept_history(contract_path: Path = CONTRACT_PATH):
    hashes = {
        "scripts/eval/eg1_multilingual_d1_contract_v1.json": d1.sha256_file(
            contract_path
        ),
        "scripts/eval/build_eg1_multilingual_d1.py": d1.sha256_file(SCRIPT_PATH),
        "scripts/eval/build_eg1_d1_shared_concept_registry.py": d1.sha256_file(
            shared_registry.SCRIPT_PATH
        ),
    }
    with (
        mock.patch.object(
            d1,
            "_historical_shared_concept_control_sha256",
            side_effect=lambda _head, path: hashes.get(path),
        ),
        mock.patch.object(
            d1, "_shared_concept_commit_is_ancestor", return_value=True
        ),
    ):
        yield


def make_contract(*, training: bool, release: bool) -> dict[str, object]:
    contract = copy.deepcopy(d1.read_json(CONTRACT_PATH))
    contract["prompt"]["path"] = str(PROMPT_PATH)
    contract["approval"] = {
        "training_export_allowed": training,
        "release_export_allowed": release,
        "approved_by": "test-reviewer" if training else None,
        "approval_reference": "test-only" if training else None,
    }
    if release:
        contract["prompt"]["development_only"] = False
    return contract


def make_registry(*, sealed: bool) -> dict[str, object]:
    groups = {
        name: {
            "status": "complete" if sealed else "pending",
            "source_artifact_sha256": "a" * 64 if sealed else None,
        }
        for name in d1.read_json(CONTRACT_PATH)["blocked_registry_required_groups"]
    }
    return {
        "schema_version": d1.REGISTRY_SCHEMA,
        "registry_id": "test-registry",
        "status": "sealed" if sealed else "draft",
        "required_groups": groups,
        "exact_family_ids": [],
        "family_prefixes": ["LF-", "LFT-"],
        "semantic_origin_ids": [],
        "normalized_input_sha256": [],
        "normalized_output_sha256": [],
    }


def make_shared_concept_seal(
    slots: list[dict[str, object]],
    *,
    sealed: bool = True,
    contract_path: Path = CONTRACT_PATH,
) -> tuple[dict[str, object], dict[str, object]]:
    contract = d1.read_json(contract_path)
    concept_rows = shared_registry.build_concept_slots(contract, slots)
    completion = {
        "schema_version": shared_registry.COMPLETION_SCHEMA,
        "registry_id": "test-shared-concepts",
        "status": "approved_for_sealing",
        "approval": {
            "approved_for_authoring": True,
            "approved_by_reference_id": "fixture-approver",
            "approval_reference_id": "approval:fixture-shared",
            "approved_at": "2026-07-15T19:00:00Z",
        },
        "concepts": [],
    }
    for row in concept_rows:
        concept_id = row["cross_language_concept_id"]
        brief = f"TEST-BYTES::{concept_id}"
        completion["concepts"].append(
            {
                "cross_language_concept_id": concept_id,
                "brief_id": row["brief_id"],
                "brief": brief,
                "brief_sha256": d1.sha256_bytes(brief.encode("utf-8")),
                "concept_author_reference_id": f"author:{concept_id.lower()}",
                "concept_reviewer_reference_id": f"reviewer:{concept_id.lower()}",
                "review_reference_id": f"review:{concept_id.lower()}",
                "reviewed_at": "2026-07-15T19:00:00Z",
                "language_neutrality_approved": True,
                "meaning_safety_approved": True,
                "family_separation_approved": True,
                "candidate_model_output_seen": False,
            }
        )
    completion_sha = d1.sha256_bytes(shared_registry.encode_json(completion))
    artifacts, receipt = shared_registry.build_seal_artifacts(
        contract_path=contract_path,
        contract_bytes=contract_path.read_bytes(),
        contract_sha256=d1.sha256_file(contract_path),
        d1_builder_sha256=d1.sha256_file(SCRIPT_PATH),
        producer_sha256=d1.sha256_file(shared_registry.SCRIPT_PATH),
        execution_git_head="f" * 40,
        allocation_receipt={"execution_git_head": "e" * 40},
        allocation_receipt_sha256="a" * 64,
        concept_rows=concept_rows,
        completion=completion,
        completion_sha256=completion_sha,
    )
    registry = shared_registry.parse_object(
        artifacts["shared-concept-registry.json"], "fixture registry"
    )
    receipt["contract"]["path"] = (
        "scripts/eval/eg1_multilingual_d1_contract_v1.json"
    )
    receipt_payload = dict(receipt)
    receipt_payload.pop("receipt_payload_sha256")
    receipt["receipt_payload_sha256"] = d1.canonical_json_sha256(receipt_payload)
    if not sealed:
        registry["status"] = "draft"
        registry["approval"] = {
            "approved_for_authoring": False,
            "approved_by": None,
            "approval_reference": None,
        }
        payload = {
            field: registry[field]
            for field in d1.SHARED_CONCEPT_REGISTRY_FIELDS - {"producer_binding"}
        }
        registry["producer_binding"]["registry_payload_sha256"] = (
            d1.canonical_json_sha256(payload)
        )
        registry_bytes = shared_registry.encode_json(registry)
        receipt["artifacts"]["shared-concept-registry.json"]["sha256"] = (
            d1.sha256_bytes(registry_bytes)
        )
        receipt_payload = dict(receipt)
        receipt_payload.pop("receipt_payload_sha256")
        receipt["receipt_payload_sha256"] = d1.canonical_json_sha256(receipt_payload)
    return registry, receipt


def make_shared_concept_registry(
    slots: list[dict[str, object]], *, sealed: bool = True
) -> dict[str, object]:
    return make_shared_concept_seal(slots, sealed=sealed)[0]


def write_shared_concept_seal(
    bundle: Path,
    slots: list[dict[str, object]],
    *,
    sealed: bool = True,
    contract_path: Path = CONTRACT_PATH,
) -> Path:
    registry, receipt = make_shared_concept_seal(
        slots, sealed=sealed, contract_path=contract_path
    )
    bundle.mkdir()
    registry_path = bundle / "shared-concept-registry.json"
    registry_path.write_bytes(shared_registry.encode_json(registry))
    (bundle / "receipt.json").write_bytes(shared_registry.encode_json(receipt))
    return registry_path


def make_launch_roster(contract: dict[str, object]) -> dict[str, object]:
    participants: list[dict[str, object]] = []
    for language in contract["languages"]:
        participants.extend(
            [
                {
                    "participant_id": f"fixture-{language}-author",
                    "participant_type": "human_native",
                    "languages": [language],
                    "roles": ["author"],
                    "availability_status": "confirmed",
                    "identity_reference_id": f"identity:{language}:author",
                    "consent_reference_id": f"consent:{language}:author",
                },
                {
                    "participant_id": f"fixture-{language}-reviewer",
                    "participant_type": "human_native",
                    "languages": [language],
                    "roles": ["native_reviewer"],
                    "availability_status": "confirmed",
                    "identity_reference_id": f"identity:{language}:reviewer",
                    "consent_reference_id": f"consent:{language}:reviewer",
                },
            ]
        )
    return {
        "schema_version": launch.ROSTER_SCHEMA,
        "roster_id": "fixture-private-roster",
        "status": "approved_for_assignment",
        "approved_by_id": "fixture-approver",
        "approved_at": "2026-07-15T19:00:00Z",
        "approval_reference_id": "approval:fixture",
        "participants": participants,
    }


def write_launch_bundle(
    root: Path,
    *,
    contract_path: Path,
    packet_dir: Path,
    shared_path: Path,
) -> tuple[Path, Path]:
    roster_path = root / "launch-roster.json"
    write_json(roster_path, make_launch_roster(d1.read_json(contract_path)))
    launch_dir = root / "authoring-launch"
    with trusted_shared_concept_history(contract_path):
        launch.build_launch_bundle(
            contract_path=contract_path,
            packet_receipt_path=packet_dir / "authoring-packet-receipt.json",
            roster_path=roster_path,
            shared_registry_path=shared_path,
            output_path=launch_dir,
            execution_git_head="f" * 40,
        )
    return launch_dir / "assignments.jsonl", launch_dir / "receipt.json"


def shared_bindings(
    slots: list[dict[str, object]], registry: dict[str, object]
) -> dict[str, dict[str, str]]:
    _, receipt = make_shared_concept_seal(slots)
    registry_sha = d1.sha256_bytes(shared_registry.encode_json(registry))
    with trusted_shared_concept_history():
        errors, bindings = d1.shared_concept_registry_state(
            slots,
            registry,
            seal_receipt=receipt,
            registry_sha256=registry_sha,
            current_contract_sha256=d1.sha256_file(CONTRACT_PATH),
        )
    if errors:
        raise AssertionError(errors)
    return bindings


def evaluate_with_trusted_history(**arguments: object):
    contract_path = arguments["contract_path"]
    assert isinstance(contract_path, Path)
    with trusted_shared_concept_history(contract_path):
        return d1.evaluate(**arguments)


def make_rows(slots: list[dict[str, object]], *, approved: bool) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    bindings = shared_bindings(slots, make_shared_concept_registry(slots))
    for slot in slots:
        family_id = str(slot["family_id"])
        language = str(slot["language"])
        stratum = str(slot["stratum"])
        if stratum == "positive_list":
            marker = "{index}." if slot["list_type"] == "explicit_numbering" else "-"
            lines = [
                f"{marker.format(index=index) if '{index}' in marker else marker} item {index} {family_id}"
                for index in range(1, int(slot["item_count"]) + 1)
            ]
            output = "\n".join(lines)
            formatting = "numbered" if slot["list_type"] == "explicit_numbering" else "bullets"
            input_text = f"positive request {language} {family_id} alpha beta gamma"
        elif stratum == "matched_restraint":
            output = f"Ordinary restraint prose for {family_id}."
            formatting = "prose"
            input_text = f"narrative restraint {language} {family_id} ordinary sentence"
        else:
            output = f"Clean core prose for {family_id}."
            formatting = "prose"
            input_text = f"raw core dictation {language} {family_id} unique sentence"
        high_risk = slot["safety_risk"] in {"medical", "legal", "financial"}
        row = dict(slot)
        row.update(
            {
                "semantic_origin_id": f"ORIGIN-{family_id}",
                "semantic_scenario_id": f"SCENARIO-{family_id}",
                "authoring_template_id": f"TEMPLATE-{family_id}",
                "source_provenance": {
                    "source_id": f"SOURCE-{family_id}",
                    "author_id": f"fixture-{language}-author",
                    "author_type": "human_native",
                    "author_language": language,
                    "origin_mode": slot["origin_mode"],
                },
                "input": input_text,
                "output": output,
                "checks": {
                    "meaning": [f"meaning-{family_id}"],
                    "entities": [],
                    "numbers": [],
                    "timing": ["preserve timing"] if high_risk else [],
                    "attribution": ["preserve attribution"] if high_risk else [],
                    "formatting": formatting,
                    "compound_scope": ["preserve shared scope"],
                },
                "native_reviewed": approved,
                "native_review": {
                    "status": "approved" if approved else "pending",
                    "reviewer_id": f"fixture-{language}-reviewer" if approved else None,
                    "reviewer_type": "human_native" if approved else None,
                    "reviewer_language": language if approved else None,
                    "reviewed_at": "2026-07-15T05:00:00Z" if approved else None,
                    "notes": "test fixture",
                },
            }
        )
        concept_id = slot["cross_language_concept_id"]
        if concept_id:
            row.update(bindings[str(concept_id)])
        else:
            row.update({field: None for field in d1.SHARED_CONCEPT_ROW_FIELDS})
        rows.append(row)
    return rows


def make_leakage_receipt(
    rows_path: Path, registry_path: Path, prompt_sha256: str
) -> dict[str, object]:
    return {
        "schema_version": d1.LEAKAGE_SCHEMA,
        "status": "pass",
        "candidate_rows_sha256": d1.sha256_file(rows_path),
        "blocked_registry_sha256": d1.sha256_file(registry_path),
        "prompt_sha256": prompt_sha256,
        "checks": {
            name: {"status": "pass", "matches": 0}
            for name in d1.read_json(CONTRACT_PATH)["leakage_receipt_required_checks"]
        },
    }


class D1BuilderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.contract = d1.read_json(CONTRACT_PATH)
        cls.slots = d1.build_slots(cls.contract)
        cls.shared_bindings = shared_bindings(
            cls.slots, make_shared_concept_registry(cls.slots)
        )

    def test_full_plan_is_deterministic_and_balanced(self) -> None:
        self.assertFalse(self.contract["approval"]["training_export_allowed"])
        self.assertFalse(self.contract["approval"]["release_export_allowed"])
        self.assertTrue(self.contract["prompt"]["development_only"])
        registry_template = d1.read_json(
            REPO_ROOT
            / "docs"
            / "experiments"
            / "eg1-multilingual"
            / "D1-BLOCKED-FAMILY-REGISTRY-TEMPLATE-V1.json"
        )
        self.assertEqual(registry_template["status"], "draft")
        self.assertEqual(self.slots, d1.build_slots(self.contract))
        self.assertEqual(len(self.slots), 2000)
        for language in self.contract["languages"]:
            rows = [slot for slot in self.slots if slot["language"] == language]
            self.assertEqual(len(rows), 400)
            self.assertEqual(
                Counter(slot["stratum"] for slot in rows),
                Counter({"core": 120, "positive_list": 140, "matched_restraint": 140}),
            )
            positives = [slot for slot in rows if slot["stratum"] == "positive_list"]
            restraints = [slot for slot in rows if slot["stratum"] == "matched_restraint"]
            self.assertEqual(Counter(slot["item_count"] for slot in positives), Counter({2: 35, 3: 35, 5: 35, 7: 35}))
            self.assertEqual(set(Counter(slot["list_type"] for slot in positives).values()), {28})
            self.assertEqual(set(Counter(slot["domain"] for slot in positives).values()), {28})
            self.assertEqual(set(Counter(slot["length_bucket"] for slot in positives).values()), {35})
            self.assertEqual(set(Counter(slot["restraint_type"] for slot in restraints).values()), {20})
            self.assertEqual(Counter(slot["origin_mode"] for slot in rows), Counter({"native_original": 320, "shared_concept_independent_rewrite": 80}))
            self.assertEqual(
                set(Counter((slot["item_count"], slot["list_type"]) for slot in positives).values()),
                {7},
            )
            self.assertEqual(
                set(Counter((slot["item_count"], slot["domain"]) for slot in positives).values()),
                {7},
            )
            domain_length_counts = Counter(
                (slot["domain"], slot["length_bucket"]) for slot in positives
            ).values()
            self.assertGreaterEqual(min(domain_length_counts), 6)
            self.assertLessEqual(max(domain_length_counts), 8)
        self.assertEqual(d1.verify_plan(self.contract, self.slots), [])

    def test_draft_accepts_pending_review_but_training_does_not(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            contract_path = root / "contract.json"
            rows_path = root / "rows.jsonl"
            registry_path = root / "registry.json"
            receipt_path = root / "receipt.json"
            report_path = root / "training-report.json"
            output_path = root / "training.jsonl"
            contract = make_contract(training=True, release=False)
            write_json(contract_path, contract)
            shared_path = write_shared_concept_seal(
                root / "shared-seal", self.slots, contract_path=contract_path
            )
            write_jsonl(rows_path, make_rows(self.slots, approved=False))
            write_json(registry_path, make_registry(sealed=True))
            write_json(
                receipt_path,
                make_leakage_receipt(rows_path, registry_path, contract["prompt"]["sha256"]),
            )
            draft, _ = evaluate_with_trusted_history(
                contract_path=contract_path,
                rows_path=rows_path,
                registry_path=registry_path,
                shared_concept_registry_path=shared_path,
                purpose="draft",
                leakage_receipt_path=None,
            )
            self.assertEqual(draft["status"], "pass")
            self.assertFalse(draft["eligible_for_training_export"])
            training, _ = evaluate_with_trusted_history(
                contract_path=contract_path,
                rows_path=rows_path,
                registry_path=registry_path,
                shared_concept_registry_path=shared_path,
                purpose="training",
                leakage_receipt_path=None,
            )
            self.assertEqual(training["status"], "fail")
            self.assertTrue(any("native review" in item for item in training["promotion_blockers"]))
            self.assertIn(
                "approved authoring launch assignment binding is missing",
                training["promotion_blockers"],
            )
            process = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "validate",
                    "--contract",
                    str(contract_path),
                    "--rows",
                    str(rows_path),
                    "--blocked-registry",
                    str(registry_path),
                    "--shared-concept-registry",
                    str(shared_path),
                    "--purpose",
                    "training",
                    "--leakage-receipt",
                    str(receipt_path),
                    "--report",
                    str(report_path),
                    "--output",
                    str(output_path),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(process.returncode, 2)
            self.assertFalse(output_path.exists())

    def test_draft_never_claims_training_or_release_eligibility(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            contract_path = root / "contract.json"
            rows_path = root / "rows.jsonl"
            registry_path = root / "registry.json"
            contract = make_contract(training=False, release=False)
            write_json(contract_path, contract)
            shared_path = write_shared_concept_seal(
                root / "shared-seal", self.slots, contract_path=contract_path
            )
            write_jsonl(rows_path, make_rows(self.slots, approved=True))
            write_json(registry_path, make_registry(sealed=True))
            report, _ = evaluate_with_trusted_history(
                contract_path=contract_path,
                rows_path=rows_path,
                registry_path=registry_path,
                shared_concept_registry_path=shared_path,
                purpose="draft",
                leakage_receipt_path=None,
            )
            self.assertEqual(report["status"], "pass")
            self.assertFalse(report["eligible_for_training_export"])
            self.assertFalse(report["eligible_for_release_export"])

    def test_unsealed_blocked_registry_stops_training(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            contract_path = root / "contract.json"
            rows_path = root / "rows.jsonl"
            registry_path = root / "registry.json"
            receipt_path = root / "receipt.json"
            contract = make_contract(training=True, release=False)
            write_json(contract_path, contract)
            shared_path = write_shared_concept_seal(
                root / "shared-seal", self.slots, contract_path=contract_path
            )
            write_jsonl(rows_path, make_rows(self.slots, approved=True))
            write_json(registry_path, make_registry(sealed=False))
            write_json(receipt_path, make_leakage_receipt(rows_path, registry_path, contract["prompt"]["sha256"]))
            report, _ = evaluate_with_trusted_history(
                contract_path=contract_path,
                rows_path=rows_path,
                registry_path=registry_path,
                shared_concept_registry_path=shared_path,
                purpose="training",
                leakage_receipt_path=receipt_path,
            )
            self.assertEqual(report["status"], "fail")
            self.assertTrue(any("registry" in item for item in report["promotion_blockers"]))

    def test_approved_rows_and_sealed_receipts_export_training_data(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            contract_path = root / "contract.json"
            rows_path = root / "rows.jsonl"
            registry_path = root / "registry.json"
            receipt_path = root / "receipt.json"
            report_path = root / "report.json"
            output_path = root / "training.jsonl"
            contract = make_contract(training=True, release=False)
            write_json(contract_path, contract)
            shared_path = write_shared_concept_seal(
                root / "shared-seal", self.slots, contract_path=contract_path
            )
            write_jsonl(rows_path, make_rows(self.slots, approved=True))
            write_json(registry_path, make_registry(sealed=True))
            write_json(receipt_path, make_leakage_receipt(rows_path, registry_path, contract["prompt"]["sha256"]))
            packet_dir = root / "packets"
            with trusted_shared_concept_history(contract_path):
                d1.write_authoring_packets(
                    contract_path=contract_path,
                    output_dir=packet_dir,
                    shared_registry_path=shared_path,
                )
            launch_assignments, launch_receipt = write_launch_bundle(
                root,
                contract_path=contract_path,
                packet_dir=packet_dir,
                shared_path=shared_path,
            )
            report, ordered_rows = evaluate_with_trusted_history(
                contract_path=contract_path,
                rows_path=rows_path,
                registry_path=registry_path,
                shared_concept_registry_path=shared_path,
                purpose="training",
                leakage_receipt_path=receipt_path,
                launch_assignments_path=launch_assignments,
                launch_receipt_path=launch_receipt,
            )
            self.assertEqual(report["status"], "pass", report["errors"])
            self.assertEqual(len(ordered_rows), 2000)
            self.assertEqual(report["metrics"]["native_reviewed_count"], 2000)

    def test_launch_replay_rejects_tampered_shared_seal_receipt_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            contract_path = root / "contract.json"
            rows_path = root / "rows.jsonl"
            registry_path = root / "registry.json"
            contract = make_contract(training=False, release=False)
            write_json(contract_path, contract)
            shared_path = write_shared_concept_seal(
                root / "shared-seal", self.slots, contract_path=contract_path
            )
            write_jsonl(rows_path, make_rows(self.slots, approved=True))
            write_json(registry_path, make_registry(sealed=True))
            packet_dir = root / "packets"
            with trusted_shared_concept_history(contract_path):
                d1.write_authoring_packets(
                    contract_path=contract_path,
                    output_dir=packet_dir,
                    shared_registry_path=shared_path,
                )
            launch_assignments, launch_receipt = write_launch_bundle(
                root,
                contract_path=contract_path,
                packet_dir=packet_dir,
                shared_path=shared_path,
            )
            tampered_receipt = d1.read_json(launch_receipt)
            tampered_receipt["inputs"]["shared_concept_seal_receipt_sha256"] = "0" * 64
            write_json(launch_receipt, tampered_receipt)

            report, _ = evaluate_with_trusted_history(
                contract_path=contract_path,
                rows_path=rows_path,
                registry_path=registry_path,
                shared_concept_registry_path=shared_path,
                purpose="draft",
                leakage_receipt_path=None,
                launch_assignments_path=launch_assignments,
                launch_receipt_path=launch_receipt,
            )

            self.assertEqual(report["status"], "fail")
            self.assertIn(
                "authoring launch shared-concept seal receipt hash does not match",
                report["errors"],
            )

    def test_release_export_needs_separate_approval_and_nondevelopment_prompt(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            contract_path = root / "contract.json"
            rows_path = root / "rows.jsonl"
            registry_path = root / "registry.json"
            receipt_path = root / "receipt.json"
            contract = make_contract(training=True, release=False)
            write_json(contract_path, contract)
            shared_path = write_shared_concept_seal(
                root / "shared-seal", self.slots, contract_path=contract_path
            )
            write_jsonl(rows_path, make_rows(self.slots, approved=True))
            write_json(registry_path, make_registry(sealed=True))
            write_json(receipt_path, make_leakage_receipt(rows_path, registry_path, contract["prompt"]["sha256"]))
            report, _ = evaluate_with_trusted_history(
                contract_path=contract_path,
                rows_path=rows_path,
                registry_path=registry_path,
                shared_concept_registry_path=shared_path,
                purpose="release",
                leakage_receipt_path=receipt_path,
            )
            self.assertEqual(report["status"], "fail")
            self.assertIn("D1 contract has no release-export approval", report["promotion_blockers"])
            self.assertIn("development-only prompt cannot produce release data", report["promotion_blockers"])

    def test_blocked_origin_and_reused_pair_template_are_rejected(self) -> None:
        rows = make_rows(self.slots, approved=True)
        positive = next(row for row in rows if row["stratum"] == "positive_list")
        restraint = next(row for row in rows if row["pair_id"] == positive["pair_id"] and row["stratum"] == "matched_restraint")
        restraint["authoring_template_id"] = positive["authoring_template_id"]
        registry = make_registry(sealed=True)
        positive["semantic_origin_id"] = "LF-001"
        synthetic = next(row for row in rows if row["family_id"] != positive["family_id"])
        synthetic["source_provenance"]["author_type"] = "synthetic_native"
        synthetic["source_provenance"].update(
            {
                "author_model_id": "same-model",
                "author_configuration_id": "same-config",
                "critic_model_id": "same-model",
                "critic_configuration_id": "same-config",
            }
        )
        errors, _, _ = d1.validate_candidate_rows(
            self.contract, self.slots, rows, registry, self.shared_bindings
        )
        self.assertTrue(any("semantic origin is blocked" in item for item in errors))
        self.assertTrue(any("reuse an authoring template" in item for item in errors))
        self.assertTrue(any("synthetic author and critic are identical" in item for item in errors))

    def test_positive_list_markers_must_match_the_allocated_list_type(self) -> None:
        rows = make_rows(self.slots, approved=True)
        numbered = next(
            row
            for row in rows
            if row["stratum"] == "positive_list"
            and row["list_type"] == "explicit_numbering"
        )
        numbered["output"] = "\n".join(
            f"- wrong bullet {index} {numbered['family_id']}"
            for index in range(1, numbered["item_count"] + 1)
        )
        bulleted = next(
            row
            for row in rows
            if row["stratum"] == "positive_list"
            and row["list_type"] != "explicit_numbering"
        )
        bulleted["output"] = "\n".join(
            f"{index}. wrong number {bulleted['family_id']}"
            for index in range(1, bulleted["item_count"] + 1)
        )
        errors, _, _ = d1.validate_candidate_rows(
            self.contract,
            self.slots,
            rows,
            make_registry(sealed=True),
            self.shared_bindings,
        )
        self.assertTrue(
            any(
                numbered["family_id"] in item and "numbered markers" in item
                for item in errors
            )
        )
        self.assertTrue(
            any(
                bulleted["family_id"] in item and "bullet markers" in item
                for item in errors
            )
        )

    def test_preservation_checks_require_typed_nonempty_metadata(self) -> None:
        rows = make_rows(self.slots, approved=True)
        empty_meaning = rows[0]
        empty_meaning["checks"]["meaning"] = []

        malformed_lists = rows[1]
        malformed_lists["checks"]["entities"] = None
        malformed_lists["checks"]["numbers"] = [""]
        malformed_lists["checks"]["compound_scope"] = True
        malformed_lists["checks"]["unexpected"] = []

        high_risk = next(
            row
            for row in rows
            if row["safety_risk"] in {"medical", "legal", "financial"}
            and row["family_id"]
            not in {empty_meaning["family_id"], malformed_lists["family_id"]}
        )
        high_risk["checks"]["timing"] = "preserve timing"
        high_risk["checks"]["attribution"] = [""]

        prose = next(
            row
            for row in rows
            if row["stratum"] == "core"
            and row["family_id"]
            not in {
                empty_meaning["family_id"],
                malformed_lists["family_id"],
                high_risk["family_id"],
            }
        )
        prose["checks"]["formatting"] = "bullets"

        errors, _, _ = d1.validate_candidate_rows(
            self.contract,
            self.slots,
            rows,
            make_registry(sealed=True),
            self.shared_bindings,
        )
        self.assertTrue(
            any(
                empty_meaning["family_id"] in item
                and "checks.meaning must be nonempty" in item
                for item in errors
            )
        )
        for field in ("entities", "numbers", "compound_scope"):
            self.assertTrue(
                any(
                    malformed_lists["family_id"] in item
                    and f"checks.{field} must be a list" in item
                    for item in errors
                )
            )
        self.assertTrue(
            any(
                malformed_lists["family_id"] in item
                and "checks have unknown fields" in item
                for item in errors
            )
        )
        self.assertTrue(
            any(
                high_risk["family_id"] in item
                and "high-risk row needs timing and attribution checks" in item
                for item in errors
            )
        )
        self.assertTrue(
            any(
                prose["family_id"] in item and "formatting check must be prose" in item
                for item in errors
            )
        )


if __name__ == "__main__":
    unittest.main()
