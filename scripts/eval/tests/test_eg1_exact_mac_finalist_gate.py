from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


EVAL_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = EVAL_DIR / "eg1_exact_mac_finalist_gate.py"
SPEC = importlib.util.spec_from_file_location("eg1_exact_mac_finalist_gate", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def file_sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ExactMacFinalistGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.private_key = Ed25519PrivateKey.from_private_bytes(bytes(range(1, 33)))
        self.private_key_path = self.root / "attestation-private.pem"
        self.public_key_path = self.root / "attestation-public.pem"
        self.private_key_path.write_bytes(
            self.private_key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
        )
        self.public_key_path.write_bytes(
            self.private_key.public_key().public_bytes(
                serialization.Encoding.PEM,
                serialization.PublicFormat.SubjectPublicKeyInfo,
            )
        )
        self.corpora: dict[str, Path] = {}
        self.ids: dict[str, list[str]] = {}
        self.inputs: dict[str, list[str]] = {}
        counts = {"development": 800, "frozen": 1600, "type_b_v2": 1890}
        id_fields = {"development": "case_id", "frozen": "case_id", "type_b_v2": "id"}
        for suite in MODULE.SUITES:
            path = self.root / f"{suite}.jsonl"
            ids = [f"{suite}-{index:04d}" for index in range(counts[suite])]
            inputs = [
                "got it" if index == 0 else f"safe fixture input for {case_id}"
                for index, case_id in enumerate(ids)
            ]
            rows = [
                {
                    id_fields[suite]: case_id,
                    "asr_input": input_text,
                    "language": "en",
                    "safe_synthetic_fixture": True,
                }
                for case_id, input_text in zip(ids, inputs)
            ]
            self._write_jsonl(path, rows)
            self.corpora[suite] = path
            self.ids[suite] = ids
            self.inputs[suite] = inputs

        self.systems = {
            "baseline": "shipped exact-Mac system prompt",
            "finalist": "shipped exact-Mac system prompt",
        }
        runtime = {
            "app_executable_sha256": digest("app-executable"),
            "llama_server_sha256": digest("llama-server"),
            "app_system_prompt_resource_sha256": digest("app-system-prompt-resource"),
            "shipped_runtime_flags_sha256": MODULE.shipped_runtime_flags_sha256(),
            "swift_runtime_identity_sha256": MODULE.swift_runtime_identity_sha256(),
            "python_runtime_identity_sha256": MODULE.python_runtime_identity_sha256(),
            "external_toolchain_identity_sha256": (
                MODULE.external_toolchain_identity_sha256()
            ),
        }
        tooling = MODULE.current_tooling_hashes()
        self.lock = {
            "schema_version": MODULE.LOCK_SCHEMA,
            "status": "locked_for_exact_mac_finalist_gate",
            "lock_id": "synthetic-finalist-lock-v1",
            "gate_contract_sha256": file_sha(MODULE.CONTRACT_PATH),
            "execution_git_head": "a" * 40,
            "tracked_worktree_clean_required": True,
            "tooling": tooling,
            "runtime": runtime,
            "arms": {
                arm: {
                    "designation": (
                        "current_shipping_baseline"
                        if arm == "baseline"
                        else "locked_finalist"
                    ),
                    "model_id": MODULE.MODEL_ID,
                    "model_artifact_sha256": digest(f"{arm}-model-artifact"),
                    "delivery_manifest_sha256": digest(f"{arm}-delivery-manifest"),
                    "evaluation_config_sha256": (
                        MODULE.executed_evaluation_config_sha256(
                            digest(self.systems[arm])
                        )
                    ),
                    "system_prompt_source_sha256": digest(
                        "shipped-system-prompt-source"
                    ),
                    "system_prompt_sha256": digest(self.systems[arm]),
                    "app_bundle_path_sha256": digest(f"{arm}-app-path"),
                    "app_bundle_manifest_sha256": digest(
                        f"{arm}-app-bundle-manifest"
                    ),
                    "app_build_provenance_sha256": digest(
                        f"{arm}-app-build-provenance"
                    ),
                }
                for arm in MODULE.ARMS
            },
            "suites": {
                suite: {
                    "corpus_sha256": file_sha(self.corpora[suite]),
                    "case_count": counts[suite],
                    "case_id_field": id_fields[suite],
                    "input_field": "asr_input",
                    "language_field": "language",
                }
                for suite in MODULE.SUITES
            },
            "authorization": {
                "one_locked_finalist": True,
                "frozen_opened_only_after_lock": True,
                "type_b_v2_one_shot": True,
            },
            "attestation": {
                "algorithm": "ed25519",
                "key_id": "synthetic-custodian-v1",
                "public_key_sha256": file_sha(self.public_key_path),
            },
        }
        self.lock_path = self.root / "lock.json"
        self._write_json(self.lock_path, self.lock)
        self.lock_sha = file_sha(self.lock_path)
        self.receipts: dict[tuple[str, str], Path] = {}
        for arm in MODULE.ARMS:
            for suite in MODULE.SUITES:
                self._write_receipt_bundle(arm, suite)

    def tearDown(self) -> None:
        self.temp.cleanup()

    @staticmethod
    def _write_json(path: Path, value: object) -> None:
        path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    @staticmethod
    def _write_jsonl(path: Path, rows: list[dict[str, object]]) -> None:
        path.write_text(
            "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows),
            encoding="utf-8",
        )

    def _write_signed_receipt(
        self, path: Path, receipt: dict[str, object]
    ) -> None:
        receipt.pop("attestation", None)
        payload = MODULE.receipt_attestation_payload(receipt)
        signature = self.private_key.sign(payload)
        receipt["attestation"] = {
            "algorithm": self.lock["attestation"]["algorithm"],
            "key_id": self.lock["attestation"]["key_id"],
            "public_key_sha256": self.lock["attestation"]["public_key_sha256"],
            "payload_sha256": MODULE.sha256_bytes(payload),
            "signature_base64": base64.b64encode(signature).decode("ascii"),
        }
        self._write_json(path, receipt)

    def _write_receipt_bundle(self, arm: str, suite: str) -> None:
        bundle = self.root / f"{arm}-{suite}"
        bundle.mkdir()
        prompt_path = bundle / "prompts.jsonl"
        raw_output_path = bundle / "raw-output.jsonl"
        output_path = bundle / "output.jsonl"
        shipped = MODULE.load_shipped_request_module()
        prompt_rows = [
            {
                "id": case_id,
                "controlled_language": "en",
                "action": (
                    "short_input_bypass"
                    if shipped.input_would_bypass_polish(input_text, "en")
                    else "dispatch_eg1"
                ),
                "system": (
                    None
                    if shipped.input_would_bypass_polish(input_text, "en")
                    else self.systems[arm]
                ),
                "user": (
                    None
                    if shipped.input_would_bypass_polish(input_text, "en")
                    else shipped.build_user_message(input_text)
                ),
                "max_tokens": (
                    None
                    if shipped.input_would_bypass_polish(input_text, "en")
                    else shipped.output_token_budget(input_text)
                ),
            }
            for case_id, input_text in zip(self.ids[suite], self.inputs[suite])
        ]
        raw_output_rows = [
            {
                "id": case_id,
                "candidate": f"safe synthetic output {index}",
                "latencyMs": 10,
                "attempts": 1,
                "finishReason": "stop",
            }
            for index, (case_id, prompt_row) in enumerate(
                zip(self.ids[suite], prompt_rows)
            )
            if prompt_row["action"] == "dispatch_eg1"
        ]
        output_rows, fallback_count = MODULE.build_delivered_output_rows(
            expected_cases=list(
                zip(self.ids[suite], self.inputs[suite], ["en"] * len(self.ids[suite]))
            ),
            prompt_rows=prompt_rows,
            raw_rows=raw_output_rows,
            apply_message_output_validation=shipped.apply_message_output_validation,
        )
        self._write_jsonl(prompt_path, prompt_rows)
        self._write_jsonl(raw_output_path, raw_output_rows)
        self._write_jsonl(output_path, output_rows)
        app_pid = 100 if arm == "baseline" else 101
        server_pid = 200 if arm == "baseline" else 201
        receipt = {
            "schema_version": MODULE.RECEIPT_SCHEMA,
            "lock_manifest_sha256": self.lock_sha,
            "arm": arm,
            "suite": suite,
            "execution_git_head": self.lock["execution_git_head"],
            "tracked_worktree_clean": True,
            "tooling": self.lock["tooling"],
            "producer": {
                "schema_version": "eg1-exact-mac-receipt-producer-v1",
                "script_sha256": self.lock["tooling"][
                    "exact_mac_receipt_producer_sha256"
                ],
                "receipt_written_by_key_holding_process": True,
                "non_exportable_external_signer_verified": False,
                "loaded_runtime_bytes_verified": False,
            },
            "runtime": {
                **self.lock["runtime"],
                **{
                    field: self.lock["arms"][arm][field]
                    for field in MODULE.ARM_RUNTIME_FIELDS
                },
                "session_id": f"{arm}-session-v1",
                "app_pid": app_pid,
                "server_pid": server_pid,
                "parent_pid": app_pid,
                "loopback_host": "127.0.0.1",
                "workers": 1,
                "stable_process_and_path_identity_before_after": True,
                "loaded_executable_and_model_bytes_attested": False,
                "credential_present": True,
                "credential_recorded": False,
            },
            "model": {
                key: value
                for key, value in self.lock["arms"][arm].items()
                if key not in {"designation", *MODULE.ARM_RUNTIME_FIELDS}
            },
            "corpus": self.lock["suites"][suite],
            "rendered_prompts": {
                "file": prompt_path.name,
                "sha256": file_sha(prompt_path),
                "row_count": len(prompt_rows),
            },
            "raw_generation_output": {
                "file": raw_output_path.name,
                "sha256": file_sha(raw_output_path),
                "row_count": len(raw_output_rows),
                "generation_error_count": 0,
                "empty_output_count": 0,
            },
            "generation_output": {
                "file": output_path.name,
                "sha256": file_sha(output_path),
                "row_count": len(output_rows),
                "generation_error_count": 0,
                "empty_output_count": 0,
                "post_validation_fallback_count": fallback_count,
            },
        }
        receipt_path = bundle / "receipt.json"
        self._write_signed_receipt(receipt_path, receipt)
        self.receipts[(arm, suite)] = receipt_path

    def _receipt_paths(self) -> list[Path]:
        return [self.receipts[(arm, suite)] for arm in MODULE.ARMS for suite in MODULE.SUITES]

    def _write_evidence_pin(self) -> None:
        self.evidence_pin = self.root / "evidence-pin.json"
        self._write_json(
            self.evidence_pin,
            {
                "schema_version": MODULE.EVIDENCE_PIN_SCHEMA,
                "lock_manifest_sha256": file_sha(self.lock_path),
                "receipts": [
                    {
                        "arm": arm,
                        "suite": suite,
                        "receipt_sha256": file_sha(self.receipts[(arm, suite)]),
                    }
                    for arm in MODULE.ARMS
                    for suite in MODULE.SUITES
                ],
            },
        )
        self.evidence_pin_sha = file_sha(self.evidence_pin)

    def _validate_gate(
        self,
        *,
        lock_path: Path,
        corpus_paths: dict[str, Path],
        receipt_paths: list[Path],
    ) -> tuple[dict[str, object], dict[Path, str]]:
        self._write_evidence_pin()
        return MODULE.validate_gate(
            lock_path=lock_path,
            corpus_paths=corpus_paths,
            receipt_paths=receipt_paths,
            attestation_public_key_path=self.public_key_path,
            evidence_pin_path=self.evidence_pin,
            expected_evidence_pin_sha256=self.evidence_pin_sha,
        )

    def _validate(self, receipt_paths: list[Path] | None = None) -> dict[str, object]:
        with mock.patch.object(MODULE, "require_git_state") as git_state:
            manifest, _ = self._validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=receipt_paths or self._receipt_paths(),
            )
        self.assertEqual(git_state.call_count, 2)
        return manifest

    def _load_receipt(self, arm: str, suite: str) -> tuple[Path, dict[str, object]]:
        path = self.receipts[(arm, suite)]
        return path, json.loads(path.read_text(encoding="utf-8"))

    def test_valid_complete_gate_binds_two_arms_and_three_suites(self) -> None:
        manifest = self._validate()
        self.assertEqual(
            manifest["status"],
            "custodian_signed_operator_pinned_controlled_evidence_complete",
        )
        self.assertEqual(set(manifest["arms"]), set(MODULE.ARMS))
        self.assertEqual(set(manifest["suites"]), set(MODULE.SUITES))
        self.assertFalse(manifest["publication"]["raw_text_in_manifest"])
        self.assertFalse(
            manifest["publication"]["loaded_executable_and_model_bytes_verified"]
        )
        self.assertFalse(manifest["publication"]["signature_proves_producer_execution"])
        self.assertFalse(manifest["publication"]["independent_pin_custody_verified"])
        self.assertTrue(
            manifest["publication"]["external_tool_paths_and_bytes_verified"]
        )
        self.assertFalse(manifest["publication"]["claims_exact_mac_evidence_complete"])
        self.assertFalse(
            manifest["publication"]["claims_literal_end_user_delivery_parity"]
        )

    def test_reconstructed_delivery_applies_all_three_post_generation_guards(self) -> None:
        shipped = MODULE.load_shipped_request_module()
        expected_cases = [
            ("expansion", "please clean this short sentence now", "en"),
            (
                "content-drop",
                "one two three four five six seven eight nine ten eleven twelve",
                "en",
            ),
            (
                "question",
                "Can you please schedule this meeting for Friday afternoon",
                "en",
            ),
        ]
        prompt_rows = [
            {
                "id": case_id,
                "controlled_language": language,
                "action": "dispatch_eg1",
                "system": self.systems["baseline"],
                "user": shipped.build_user_message(input_text),
                "max_tokens": shipped.output_token_budget(input_text),
            }
            for case_id, input_text, language in expected_cases
        ]
        raw_rows = [
            {
                "id": "expansion",
                "candidate": "x" * 300,
                "latencyMs": 10,
                "attempts": 1,
                "finishReason": "stop",
            },
            {
                "id": "content-drop",
                "candidate": "too short",
                "latencyMs": 11,
                "attempts": 1,
                "finishReason": "stop",
            },
            {
                "id": "question",
                "candidate": "The meeting is scheduled for Friday afternoon.",
                "latencyMs": 12,
                "attempts": 1,
                "finishReason": "stop",
            },
        ]
        delivered, fallback_count = MODULE.build_delivered_output_rows(
            expected_cases=expected_cases,
            prompt_rows=prompt_rows,
            raw_rows=raw_rows,
            apply_message_output_validation=shipped.apply_message_output_validation,
        )
        self.assertEqual(fallback_count, 3)
        self.assertEqual(
            [row["candidate"] for row in delivered],
            [input_text for _, input_text, _ in expected_cases],
        )
        self.assertEqual(
            [row["fallbackReason"] for row in delivered],
            ["expansion", "content_drop", "question_to_answer"],
        )
        self.assertTrue(
            all(row["deliveryPath"] == "post_validation_fallback" for row in delivered)
        )

    def test_raw_output_rejects_delivery_metadata(self) -> None:
        value = (
            json.dumps(
                {
                    "id": "raw-1",
                    "candidate": "safe output",
                    "latencyMs": 1,
                    "attempts": 1,
                    "deliveryPath": "model",
                }
            )
            + "\n"
        ).encode("utf-8")
        with self.assertRaisesRegex(MODULE.FinalistGateError, "unknown output fields"):
            MODULE.validate_generation_output(
                value, expected_ids=["raw-1"], label="raw generation output"
            )

    def test_reconstructed_delivery_requires_compiled_swift_for_unsafe_grapheme(self) -> None:
        shipped = MODULE.load_shipped_request_module()
        original = "please keep this e\u0301 exactly"
        with (
            mock.patch.object(
                shipped,
                "_query_swift_character_count",
                side_effect=ValueError("compiled Swift oracle unavailable"),
            ),
            self.assertRaisesRegex(
                MODULE.FinalistGateError, "trusted compiled Swift parity oracle"
            ),
        ):
            MODULE.build_delivered_output_rows(
                expected_cases=[("unsafe", original, "en")],
                prompt_rows=[{"id": "unsafe", "action": "dispatch_eg1"}],
                raw_rows=[
                    {
                        "id": "unsafe",
                        "candidate": original,
                        "latencyMs": 1,
                        "attempts": 1,
                    }
                ],
                apply_message_output_validation=(
                    shipped.apply_message_output_validation
                ),
            )

    def test_coherently_resigned_tampered_delivered_candidate_fails(self) -> None:
        receipt_path, receipt = self._load_receipt("baseline", "development")
        output_path = receipt_path.parent / receipt["generation_output"]["file"]
        rows = [json.loads(line) for line in output_path.read_text().splitlines()]
        rows[5]["candidate"] = "coherently signed but not app-equivalent"
        self._write_jsonl(output_path, rows)
        receipt["generation_output"]["sha256"] = file_sha(output_path)
        self._write_signed_receipt(receipt_path, receipt)
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(MODULE.FinalistGateError, "delivery sequence"),
        ):
            self._validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=self._receipt_paths(),
            )

    def test_missing_receipt_fails_closed(self) -> None:
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(MODULE.FinalistGateError, "exactly one generation receipt"),
        ):
            self._validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=self._receipt_paths()[:-1],
            )

    def test_duplicate_receipt_path_fails_closed(self) -> None:
        paths = self._receipt_paths()
        paths[-1] = paths[0]
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(MODULE.FinalistGateError, "receipt path is duplicated"),
        ):
            self._validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=paths,
            )

    def test_coherently_truncated_output_fails_closed(self) -> None:
        receipt_path, receipt = self._load_receipt("finalist", "frozen")
        output_path = receipt_path.parent / receipt["generation_output"]["file"]
        rows = [json.loads(line) for line in output_path.read_text().splitlines()]
        self._write_jsonl(output_path, rows[:-1])
        receipt["generation_output"].update(
            {
                "sha256": file_sha(output_path),
                "row_count": len(rows) - 1,
            }
        )
        self._write_signed_receipt(receipt_path, receipt)
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(MODULE.FinalistGateError, "receipt row count is invalid"),
        ):
            self._validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=self._receipt_paths(),
            )

    def test_duplicate_output_id_fails_closed_even_with_updated_hash(self) -> None:
        receipt_path, receipt = self._load_receipt("baseline", "development")
        output_path = receipt_path.parent / receipt["generation_output"]["file"]
        rows = [json.loads(line) for line in output_path.read_text().splitlines()]
        rows[-1]["id"] = rows[0]["id"]
        self._write_jsonl(output_path, rows)
        receipt["generation_output"]["sha256"] = file_sha(output_path)
        self._write_signed_receipt(receipt_path, receipt)
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(MODULE.FinalistGateError, "delivery sequence"),
        ):
            self._validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=self._receipt_paths(),
            )

    def test_output_error_and_empty_counts_cannot_be_accepted(self) -> None:
        receipt_path, receipt = self._load_receipt("finalist", "type_b_v2")
        output_path = receipt_path.parent / receipt["generation_output"]["file"]
        rows = [json.loads(line) for line in output_path.read_text().splitlines()]
        rows[3]["candidate"] = ""
        rows[3]["error"] = "synthetic timeout"
        self._write_jsonl(output_path, rows)
        receipt["generation_output"].update(
            {
                "sha256": file_sha(output_path),
                "generation_error_count": 1,
                "empty_output_count": 1,
            }
        )
        self._write_signed_receipt(receipt_path, receipt)
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(MODULE.FinalistGateError, "delivery sequence"),
        ):
            self._validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=self._receipt_paths(),
            )

    def test_swapped_model_identity_fails_before_output_acceptance(self) -> None:
        receipt_path, receipt = self._load_receipt("finalist", "development")
        receipt["model"] = {
            key: value
            for key, value in self.lock["arms"]["baseline"].items()
            if key not in {"designation", *MODULE.ARM_RUNTIME_FIELDS}
        }
        self._write_signed_receipt(receipt_path, receipt)
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(MODULE.FinalistGateError, "model/prompt hashes differ"),
        ):
            self._validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=self._receipt_paths(),
            )

    def test_runtime_session_cannot_change_between_suites(self) -> None:
        receipt_path, receipt = self._load_receipt("baseline", "frozen")
        receipt["runtime"]["session_id"] = "baseline-session-v2"
        receipt["runtime"]["app_pid"] = 102
        receipt["runtime"]["parent_pid"] = 102
        receipt["runtime"]["server_pid"] = 202
        self._write_signed_receipt(receipt_path, receipt)
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(MODULE.FinalistGateError, "session changed between suites"),
        ):
            self._validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=self._receipt_paths(),
            )

    def test_receipt_requires_locked_producer_code_identity(self) -> None:
        receipt_path, receipt = self._load_receipt("baseline", "development")
        receipt["producer"]["script_sha256"] = digest("untrusted-producer")
        self._write_signed_receipt(receipt_path, receipt)
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(MODULE.FinalistGateError, "writer metadata differs"),
        ):
            self._validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=self._receipt_paths(),
            )

    def test_matching_pin_and_metadata_cannot_replace_valid_receipt_signature(self) -> None:
        receipt_path, receipt = self._load_receipt("baseline", "development")
        receipt["runtime"]["session_id"] = "manually-forged-session-v1"
        receipt["attestation"]["payload_sha256"] = MODULE.sha256_bytes(
            MODULE.receipt_attestation_payload(receipt)
        )
        self._write_json(receipt_path, receipt)
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(MODULE.FinalistGateError, "signature is not valid"),
        ):
            self._validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=self._receipt_paths(),
            )

    def test_forgeable_producer_metadata_is_insufficient_without_operator_pin(self) -> None:
        self._write_evidence_pin()
        receipt_path, receipt = self._load_receipt("baseline", "development")
        receipt_path.write_text(
            json.dumps(receipt, ensure_ascii=False, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(
                MODULE.FinalistGateError, "operator-predeclared evidence pin"
            ),
        ):
            MODULE.validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=self._receipt_paths(),
                attestation_public_key_path=self.public_key_path,
                evidence_pin_path=self.evidence_pin,
                expected_evidence_pin_sha256=self.evidence_pin_sha,
            )

    def test_per_arm_bundle_hash_is_checked_without_forcing_arms_to_match(self) -> None:
        self.assertNotEqual(
            self.lock["arms"]["baseline"]["app_bundle_manifest_sha256"],
            self.lock["arms"]["finalist"]["app_bundle_manifest_sha256"],
        )
        receipt_path, receipt = self._load_receipt("finalist", "development")
        receipt["runtime"]["app_bundle_manifest_sha256"] = self.lock["arms"][
            "baseline"
        ]["app_bundle_manifest_sha256"]
        self._write_signed_receipt(receipt_path, receipt)
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(MODULE.FinalistGateError, "per-arm bundle hash"),
        ):
            self._validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=self._receipt_paths(),
            )

    def test_matching_wrong_token_budget_in_both_arms_fails(self) -> None:
        for arm in MODULE.ARMS:
            receipt_path, receipt = self._load_receipt(arm, "development")
            prompt_path = receipt_path.parent / receipt["rendered_prompts"]["file"]
            rows = [json.loads(line) for line in prompt_path.read_text().splitlines()]
            rows[9]["max_tokens"] = 9999
            self._write_jsonl(prompt_path, rows)
            receipt["rendered_prompts"]["sha256"] = file_sha(prompt_path)
            self._write_signed_receipt(receipt_path, receipt)
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(MODULE.FinalistGateError, "differs from the shipped request"),
        ):
            self._validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=self._receipt_paths(),
            )

    def test_matching_wrong_prompt_text_in_both_arms_fails(self) -> None:
        for arm in MODULE.ARMS:
            receipt_path, receipt = self._load_receipt(arm, "development")
            prompt_path = receipt_path.parent / receipt["rendered_prompts"]["file"]
            rows = [json.loads(line) for line in prompt_path.read_text().splitlines()]
            rows[1]["user"] = "<TRANSCRIPT>\nwrong corpus text\n</TRANSCRIPT>"
            self._write_jsonl(prompt_path, rows)
            receipt["rendered_prompts"]["sha256"] = file_sha(prompt_path)
            self._write_signed_receipt(receipt_path, receipt)
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(MODULE.FinalistGateError, "differs from its corpus"),
        ):
            self._validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=self._receipt_paths(),
            )

    def test_token_limit_finish_reason_fails_closed(self) -> None:
        receipt_path, receipt = self._load_receipt("baseline", "development")
        output_path = receipt_path.parent / receipt["raw_generation_output"]["file"]
        rows = [json.loads(line) for line in output_path.read_text().splitlines()]
        rows[0]["finishReason"] = "length"
        self._write_jsonl(output_path, rows)
        receipt["raw_generation_output"]["sha256"] = file_sha(output_path)
        self._write_signed_receipt(receipt_path, receipt)
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(MODULE.FinalistGateError, "truncated output"),
        ):
            self._validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=self._receipt_paths(),
            )

    def test_rendered_prompt_preserves_input_the_shipped_app_bypasses(self) -> None:
        shipped = MODULE.load_shipped_request_module()
        input_text = "word " * 1700
        prompt = {
            "id": "too-long",
            "controlled_language": "en",
            "action": "context_bypass",
            "system": None,
            "user": None,
            "max_tokens": None,
        }
        value = (json.dumps(prompt, sort_keys=True) + "\n").encode("utf-8")
        requests, rows = MODULE.validate_rendered_prompts(
            value,
            expected_cases=[("too-long", input_text, "en")],
            expected_system_sha=digest(self.systems["baseline"]),
            build_user_message=shipped.build_user_message,
            output_token_budget=shipped.output_token_budget,
            input_would_bypass_polish=shipped.input_would_bypass_polish,
            input_would_bypass_context=shipped.input_would_bypass_context,
            label="rendered prompts",
        )
        self.assertEqual(requests, [])
        self.assertEqual(rows[0]["action"], "context_bypass")

    def test_lock_rejects_same_model_artifact_for_both_arms(self) -> None:
        self.lock["arms"]["finalist"]["model_artifact_sha256"] = self.lock["arms"][
            "baseline"
        ]["model_artifact_sha256"]
        self._write_json(self.lock_path, self.lock)
        with self.assertRaisesRegex(MODULE.FinalistGateError, "artifacts must be distinct"):
            MODULE.load_lock(self.lock_path)

    def test_lock_rejects_config_hash_not_derived_from_executed_settings(self) -> None:
        self.lock["arms"]["finalist"]["evaluation_config_sha256"] = digest(
            "unused-free-form-config"
        )
        self._write_json(self.lock_path, self.lock)
        with self.assertRaisesRegex(MODULE.FinalistGateError, "not the executed config"):
            MODULE.load_lock(self.lock_path)

    def test_lock_rejects_swift_or_macos_runtime_drift(self) -> None:
        self.lock["runtime"]["swift_runtime_identity_sha256"] = digest(
            "different-swift-or-macos-runtime"
        )
        self._write_json(self.lock_path, self.lock)
        with self.assertRaisesRegex(MODULE.FinalistGateError, "runtime identity has drifted"):
            MODULE.load_lock(self.lock_path)

    def test_lock_rejects_python_runtime_drift(self) -> None:
        self.lock["runtime"]["python_runtime_identity_sha256"] = digest(
            "different-python-runtime"
        )
        self._write_json(self.lock_path, self.lock)
        with self.assertRaisesRegex(MODULE.FinalistGateError, "runtime identity has drifted"):
            MODULE.load_lock(self.lock_path)

    def test_lock_rejects_external_toolchain_drift(self) -> None:
        self.lock["runtime"]["external_toolchain_identity_sha256"] = digest(
            "different-external-toolchain"
        )
        self._write_json(self.lock_path, self.lock)
        with self.assertRaisesRegex(
            MODULE.FinalistGateError, "external toolchain identity has drifted"
        ):
            MODULE.load_lock(self.lock_path)

    def test_path_shadow_cannot_replace_pinned_openssl(self) -> None:
        shadow_dir = self.root / "shadow-bin"
        shadow_dir.mkdir()
        marker = self.root / "shadow-executed"
        shadow = shadow_dir / "openssl"
        shadow.write_text(f"#!/bin/sh\ntouch '{marker}'\nexit 0\n", encoding="utf-8")
        shadow.chmod(0o755)
        with mock.patch.dict(os.environ, {"PATH": str(shadow_dir)}):
            self.assertFalse(
                MODULE.verify_ed25519_signature(b"payload", b"0" * 64, b"invalid")
            )
        self.assertFalse(marker.exists())
        self.assertNotEqual(MODULE.pinned_external_tool("openssl"), shadow)

    def test_all_approved_external_tools_have_canonical_pinned_bytes(self) -> None:
        identity = MODULE.external_toolchain_identity()
        self.assertEqual(set(identity), set(MODULE.EXTERNAL_TOOL_CANDIDATES))
        for name in sorted(identity):
            with self.subTest(name=name):
                path = MODULE.pinned_external_tool(name)
                self.assertTrue(path.is_absolute())
                self.assertFalse(path.is_symlink())
                self.assertEqual(MODULE.sha256_file(path), identity[name]["executable_sha256"])

    def test_pinned_external_tool_fails_closed_after_byte_drift(self) -> None:
        fake = self.root / "pinned-openssl"
        fake.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        fake.chmod(0o755)
        candidates = dict(MODULE.EXTERNAL_TOOL_CANDIDATES)
        candidates["openssl"] = (fake,)
        try:
            with mock.patch.object(MODULE, "EXTERNAL_TOOL_CANDIDATES", candidates):
                MODULE.external_toolchain_identity.cache_clear()
                self.assertEqual(MODULE.pinned_external_tool("openssl"), fake.resolve())
                fake.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
                with self.assertRaisesRegex(MODULE.FinalistGateError, "has drifted"):
                    MODULE.pinned_external_tool("openssl")
        finally:
            MODULE.external_toolchain_identity.cache_clear()

    def test_lock_symlink_fails_closed(self) -> None:
        symlink = self.root / "lock-symlink.json"
        symlink.symlink_to(self.lock_path)
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(MODULE.FinalistGateError, "lock.*symlink"),
        ):
            self._validate_gate(
                lock_path=symlink,
                corpus_paths=self.corpora,
                receipt_paths=self._receipt_paths(),
            )

    def test_receipt_symlink_fails_closed(self) -> None:
        paths = self._receipt_paths()
        symlink = self.root / "receipt-symlink.json"
        symlink.symlink_to(paths[-1])
        paths[-1] = symlink
        with (
            mock.patch.object(MODULE, "require_git_state"),
            self.assertRaisesRegex(MODULE.FinalistGateError, "receipt.*symlink"),
        ):
            self._validate_gate(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                receipt_paths=paths,
            )

    def test_dangling_output_symlink_fails_without_writing_target(self) -> None:
        self._write_evidence_pin()
        output = self.root / "validated.json"
        dangling_target = self.root / "must-not-be-created.json"
        output.symlink_to(dangling_target)
        arguments = [
            str(MODULE_PATH),
            "--lock-manifest",
            str(self.lock_path),
            "--attestation-public-key",
            str(self.public_key_path),
            "--manifest-out",
            str(output),
            "--evidence-pin-manifest",
            str(self.evidence_pin),
            "--expected-evidence-pin-sha256",
            self.evidence_pin_sha,
        ]
        with (
            mock.patch.object(sys, "argv", arguments),
            mock.patch.object(MODULE, "require_isolated_cli"),
        ):
            self.assertEqual(MODULE.main(), 2)
        self.assertFalse(dangling_target.exists())

    def test_exclusive_write_preserves_file_created_by_another_process(self) -> None:
        output = self.root / "validated.json"
        output.write_bytes(b"other process evidence")
        with self.assertRaises(FileExistsError):
            MODULE.write_exclusive(output, b"new evidence")
        self.assertEqual(output.read_bytes(), b"other process evidence")

    def test_main_publishes_only_safe_hash_receipt(self) -> None:
        self._write_evidence_pin()
        output = self.root / "validated.json"
        arguments = [
            str(MODULE_PATH),
            "--lock-manifest",
            str(self.lock_path),
            "--attestation-public-key",
            str(self.public_key_path),
        ]
        for suite in MODULE.SUITES:
            arguments.extend(["--corpus", f"{suite}={self.corpora[suite]}"])
        for path in self._receipt_paths():
            arguments.extend(["--generation-receipt", str(path)])
        arguments.extend(
            [
                "--evidence-pin-manifest",
                str(self.evidence_pin),
                "--expected-evidence-pin-sha256",
                self.evidence_pin_sha,
            ]
        )
        arguments.extend(["--manifest-out", str(output)])
        with (
            mock.patch.object(sys, "argv", arguments),
            mock.patch.object(MODULE, "require_git_state"),
            mock.patch.object(MODULE, "require_isolated_cli"),
        ):
            self.assertEqual(MODULE.main(), 0)
        manifest_text = output.read_text(encoding="utf-8")
        manifest = json.loads(manifest_text)
        self.assertFalse(manifest["publication"]["raw_text_in_manifest"])
        self.assertFalse(manifest["publication"]["claims_exact_mac_evidence_complete"])
        self.assertNotIn("safe synthetic output", manifest_text)
        self.assertNotIn("<TRANSCRIPT>", manifest_text)


if __name__ == "__main__":
    unittest.main()
