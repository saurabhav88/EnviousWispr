#!/usr/bin/env python3
"""Fail-closed tests for private D1 author and reviewer assignment metadata."""

from __future__ import annotations

import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path
from unittest import mock


EVAL_DIR = Path(__file__).resolve().parents[1]
TESTS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(EVAL_DIR))
sys.path.insert(0, str(TESTS_DIR))

import build_eg1_multilingual_d1 as d1  # noqa: E402
from test_build_eg1_multilingual_d1 import (  # noqa: E402
    CONTRACT_PATH,
    trusted_shared_concept_history,
    write_shared_concept_seal,
    write_json,
)


MODULE_PATH = EVAL_DIR / "build_eg1_d1_authoring_launch.py"
SPEC = importlib.util.spec_from_file_location("d1_authoring_launch", MODULE_PATH)
assert SPEC and SPEC.loader
launch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(launch)


def human(
    participant_id: str,
    language: str,
    roles: list[str],
) -> dict[str, object]:
    return {
        "participant_id": participant_id,
        "participant_type": "human_native",
        "languages": [language],
        "roles": roles,
        "availability_status": "confirmed",
        "identity_reference_id": f"identity:{participant_id}",
        "consent_reference_id": f"consent:{participant_id}",
    }


def synthetic(participant_id: str, language: str, index: int) -> dict[str, object]:
    return {
        "participant_id": participant_id,
        "participant_type": "synthetic_native",
        "languages": [language],
        "roles": ["author"],
        "availability_status": "confirmed",
        "model_id": f"fixture/model-{index}",
        "configuration_id": f"author-config-{index}",
        "critic_model_id": f"fixture/critic-{index}",
        "critic_configuration_id": f"critic-config-{index}",
    }


def make_roster(
    *, include_synthetic: bool = False, roster_id: str = "private-roster-001"
) -> dict[str, object]:
    participants: list[dict[str, object]] = []
    for language in d1.read_json(CONTRACT_PATH)["languages"]:
        participants.extend(
            [
                human(f"fixture-{language}-author", language, ["author"]),
                human(
                    f"fixture-{language}-reviewer",
                    language,
                    ["native_reviewer"],
                ),
            ]
        )
        if include_synthetic:
            participants.extend(
                synthetic(f"fixture-{language}-generator-{index}", language, index)
                for index in range(3)
            )
    return {
        "schema_version": launch.ROSTER_SCHEMA,
        "roster_id": roster_id,
        "status": "approved_for_assignment",
        "approved_by_id": "fixture-approver",
        "approved_at": "2026-07-15T19:00:00Z",
        "approval_reference_id": "approval:fixture-001",
        "participants": participants,
    }


class D1AuthoringLaunchTests(unittest.TestCase):
    def prepare(
        self,
        root: Path,
        *,
        roster: dict[str, object] | None = None,
        shared: bool = False,
    ) -> tuple[Path, Path, Path | None, Path]:
        shared_path = None
        if shared:
            slots = d1.build_slots(d1.read_json(CONTRACT_PATH))
            shared_path = write_shared_concept_seal(root / "shared-seal", slots)
        packet_dir = root / "packets"
        with trusted_shared_concept_history():
            d1.write_authoring_packets(
                contract_path=CONTRACT_PATH,
                output_dir=packet_dir,
                shared_registry_path=shared_path,
            )
        roster_path = root / "roster.json"
        write_json(roster_path, roster or make_roster())
        return packet_dir / "authoring-packet-receipt.json", roster_path, shared_path, root / "launch"

    def build(
        self,
        root: Path,
        *,
        roster: dict[str, object] | None = None,
        shared: bool = False,
    ) -> tuple[dict[str, object], list[dict[str, object]]]:
        packet_receipt, roster_path, shared_path, output = self.prepare(
            root, roster=roster, shared=shared
        )
        with trusted_shared_concept_history():
            receipt = launch.build_launch_bundle(
                contract_path=CONTRACT_PATH,
                packet_receipt_path=packet_receipt,
                roster_path=roster_path,
                shared_registry_path=shared_path,
                output_path=output,
                execution_git_head="f" * 40,
            )
        return receipt, d1.read_jsonl(output / "assignments.jsonl")

    def test_launches_only_1600_native_original_rows_before_shared_briefs(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            receipt, rows = self.build(Path(temp))
            self.assertEqual(
                receipt["status"],
                "native_original_authorship_ready_shared_concepts_blocked",
            )
            self.assertEqual(receipt["counts"]["ready_to_author"], 1600)
            self.assertEqual(receipt["counts"]["blocked_shared_concept_slots"], 400)
            self.assertFalse(receipt["gates"]["all_rows_native_review_approved"])
            self.assertFalse(receipt["gates"]["training_eligible"])
            self.assertFalse(receipt["gates"]["release_eligible"])
            ready = [row for row in rows if row["launch_status"] == "ready_to_author"]
            blocked = [row for row in rows if row["launch_status"] != "ready_to_author"]
            self.assertEqual(Counter(row["language"] for row in ready), Counter({
                "en": 320, "de": 320, "fr": 320, "es": 320, "ru": 320,
            }))
            self.assertTrue(all(row["origin_mode"] == "native_original" for row in ready))
            self.assertTrue(all(row["author_id"] is None for row in blocked))
            self.assertTrue(all(row["native_reviewer_id"] is None for row in blocked))
            self.assertTrue(all(row["prose_authored"] is False for row in rows))
            self.assertTrue(all(row["native_review_approved"] is False for row in rows))
            self.assertTrue(all(row["candidate_model_output_seen"] is False for row in rows))

    def test_sealed_shared_briefs_launch_all_2000_rows(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            receipt, rows = self.build(Path(temp), shared=True)
            self.assertEqual(receipt["status"], "all_authorship_assignments_ready")
            self.assertEqual(receipt["counts"]["ready_to_author"], 2000)
            self.assertEqual(receipt["counts"]["blocked_shared_concept_slots"], 0)
            self.assertTrue(all(row["launch_status"] == "ready_to_author" for row in rows))

    def test_assignments_are_deterministic_and_bind_independent_human_reviewers(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            receipt_a, rows_a = self.build(root / "a", roster=make_roster(include_synthetic=True))
            receipt_b, rows_b = self.build(root / "b", roster=make_roster(include_synthetic=True))
            self.assertEqual(rows_a, rows_b)
            self.assertEqual(
                receipt_a["artifacts"]["assignments.jsonl"]["sha256"],
                receipt_b["artifacts"]["assignments.jsonl"]["sha256"],
            )
            ready = [row for row in rows_a if row["launch_status"] == "ready_to_author"]
            self.assertTrue(any(row["author_type"] == "synthetic_native" for row in ready))
            self.assertTrue(all(row["native_reviewer_type"] == "human_native" for row in ready))
            self.assertTrue(
                all(row["native_reviewer_id"] != row["author_id"] for row in ready)
            )
            for language in d1.read_json(CONTRACT_PATH)["languages"]:
                language_rows = [row for row in ready if row["language"] == language]
                human_count = sum(
                    row["author_type"] == "human_native" for row in language_rows
                )
                self.assertGreaterEqual(human_count, len(language_rows) / 2)

    def test_missing_human_native_author_fails_before_output(self) -> None:
        roster = make_roster()
        roster["participants"] = [
            participant
            for participant in roster["participants"]
            if not (
                participant["languages"] == ["de"]
                and participant["roles"] == ["author"]
            )
        ]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            packet_receipt, roster_path, shared_path, output = self.prepare(
                root, roster=roster
            )
            with self.assertRaisesRegex(
                launch.ValidationFailure, "de: at least one human-native author"
            ):
                launch.build_launch_bundle(
                    contract_path=CONTRACT_PATH,
                    packet_receipt_path=packet_receipt,
                    roster_path=roster_path,
                    shared_registry_path=shared_path,
                    output_path=output,
                    execution_git_head="f" * 40,
                )
            self.assertFalse(output.exists())

    def test_author_cannot_be_the_only_native_reviewer(self) -> None:
        roster = make_roster()
        participants = roster["participants"]
        participants[:] = [
            participant
            for participant in participants
            if participant["languages"] != ["fr"]
        ]
        participants.append(
            human(
                "fixture-fr-only-person",
                "fr",
                ["author", "native_reviewer"],
            )
        )
        with self.assertRaisesRegex(
            launch.ValidationFailure, "has no independent native reviewer"
        ):
            launch.validate_roster(roster, d1.read_json(CONTRACT_PATH))

    def test_synthetic_author_and_critic_must_be_distinct(self) -> None:
        roster = make_roster(include_synthetic=True)
        generator = next(
            participant
            for participant in roster["participants"]
            if participant["participant_type"] == "synthetic_native"
        )
        generator["critic_model_id"] = generator["model_id"]
        generator["critic_configuration_id"] = generator["configuration_id"]
        with self.assertRaisesRegex(
            launch.ValidationFailure, "synthetic author and critic are identical"
        ):
            launch.validate_roster(roster, d1.read_json(CONTRACT_PATH))

    def test_roster_rejects_unapproved_or_pii_shaped_schema(self) -> None:
        contract = d1.read_json(CONTRACT_PATH)
        unapproved = make_roster()
        unapproved["status"] = "draft"
        with self.assertRaisesRegex(launch.ValidationFailure, "not approved"):
            launch.validate_roster(unapproved, contract)
        extra_field = make_roster()
        extra_field["participants"][0]["email"] = "fixture@example.invalid"
        with self.assertRaisesRegex(launch.ValidationFailure, "schema changed"):
            launch.validate_roster(extra_field, contract)

    def test_roster_rejects_unconfirmed_availability_and_invalid_consent(self) -> None:
        contract = d1.read_json(CONTRACT_PATH)
        unavailable = make_roster()
        unavailable["participants"][0]["availability_status"] = "invited"
        with self.assertRaisesRegex(launch.ValidationFailure, "not confirmed"):
            launch.validate_roster(unavailable, contract)
        invalid_consent = make_roster()
        invalid_consent["participants"][0]["consent_reference_id"] = "name@example.com"
        with self.assertRaisesRegex(launch.ValidationFailure, "opaque safe ID"):
            launch.validate_roster(invalid_consent, contract)

    def test_duplicate_human_identity_reference_is_rejected(self) -> None:
        roster = make_roster()
        roster["participants"][1]["identity_reference_id"] = roster["participants"][0][
            "identity_reference_id"
        ]
        with self.assertRaisesRegex(
            launch.ValidationFailure, "duplicate human identity reference"
        ):
            launch.validate_roster(roster, d1.read_json(CONTRACT_PATH))

    def test_packet_tamper_is_rejected_before_launch_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            packet_receipt, roster_path, shared_path, output = self.prepare(root)
            packet_path = packet_receipt.parent / "d1-authoring-en.jsonl"
            packet_path.write_bytes(packet_path.read_bytes() + b"{}\n")
            with self.assertRaisesRegex(launch.ValidationFailure, "packet hash changed"):
                launch.build_launch_bundle(
                    contract_path=CONTRACT_PATH,
                    packet_receipt_path=packet_receipt,
                    roster_path=roster_path,
                    shared_registry_path=shared_path,
                    output_path=output,
                    execution_git_head="f" * 40,
                )
            self.assertFalse(output.exists())

    def test_blocked_packet_receipt_cannot_be_upgraded_without_regeneration(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            packet_receipt, roster_path, _, output = self.prepare(root)
            slots = d1.build_slots(d1.read_json(CONTRACT_PATH))
            shared_path = write_shared_concept_seal(root / "shared-seal-late", slots)
            with self.assertRaisesRegex(
                launch.ValidationFailure, "packet receipt does not match"
            ):
                with trusted_shared_concept_history():
                    launch.build_launch_bundle(
                        contract_path=CONTRACT_PATH,
                        packet_receipt_path=packet_receipt,
                        roster_path=roster_path,
                        shared_registry_path=shared_path,
                        output_path=output,
                        execution_git_head="f" * 40,
                    )
            self.assertFalse(output.exists())

    def test_input_change_after_validation_is_rejected_before_publication(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            packet_receipt, roster_path, shared_path, output = self.prepare(root)
            original_verify = launch.verify_packet_set

            def mutate_after_validation(**kwargs: object) -> object:
                result = original_verify(**kwargs)
                roster_path.write_bytes(roster_path.read_bytes() + b"\n")
                return result

            with mock.patch.object(
                launch, "verify_packet_set", side_effect=mutate_after_validation
            ):
                with self.assertRaisesRegex(
                    launch.ValidationFailure, "launch input changed during publication"
                ):
                    launch.build_launch_bundle(
                        contract_path=CONTRACT_PATH,
                        packet_receipt_path=packet_receipt,
                        roster_path=roster_path,
                        shared_registry_path=shared_path,
                        output_path=output,
                        execution_git_head="f" * 40,
                    )
            self.assertFalse(output.exists())

    def test_private_paths_outside_the_repository_are_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "roster.json"
            path.write_text("{}\n")
            self.assertEqual(
                launch.validate_private_path(path, "private roster", must_exist=True),
                path.resolve(),
            )


if __name__ == "__main__":
    unittest.main()
