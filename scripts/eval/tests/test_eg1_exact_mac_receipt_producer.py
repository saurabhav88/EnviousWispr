import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from contextlib import redirect_stderr
from unittest import mock

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


EVAL_DIR = Path(__file__).resolve().parents[1]
if str(EVAL_DIR) not in sys.path:
    sys.path.insert(0, str(EVAL_DIR))

import eg1_exact_mac_finalist_gate as GATE  # noqa: E402
import eg1_local_app_eval as LOCAL  # noqa: E402


MODULE_PATH = EVAL_DIR / "eg1_exact_mac_receipt_producer.py"
SPEC = importlib.util.spec_from_file_location(
    "eg1_exact_mac_receipt_producer_test", MODULE_PATH
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)
REAL_SUBPROCESS_RUN = subprocess.run


def digest(value: bytes | str) -> str:
    if isinstance(value, str):
        value = value.encode("utf-8")
    return hashlib.sha256(value).hexdigest()


def file_sha(path: Path) -> str:
    return digest(path.read_bytes())


class ExactMacReceiptProducerTests(unittest.TestCase):
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
        for suite in GATE.SUITES:
            ids = [f"{suite}-{index:04d}" for index in range(counts[suite])]
            inputs = [
                "got it" if index == 0 else f"safe fixture input for {case_id}"
                for index, case_id in enumerate(ids)
            ]
            path = self.root / f"{suite}.jsonl"
            self._write_jsonl(
                path,
                [
                    {
                        id_fields[suite]: case_id,
                        "asr_input": input_text,
                        "language": "en",
                        "safe_synthetic_fixture": True,
                    }
                    for case_id, input_text in zip(ids, inputs)
                ],
            )
            self.corpora[suite] = path
            self.ids[suite] = ids
            self.inputs[suite] = inputs

        self.app = self.root / "Baseline.app"
        macos = self.app / "Contents" / "MacOS"
        resources = self.app / "Contents" / "Resources"
        signature = self.app / "Contents" / "_CodeSignature"
        macos.mkdir(parents=True)
        resources.mkdir(parents=True)
        signature.mkdir(parents=True)
        (macos / "EnviousWispr").write_bytes(b"synthetic app executable")
        (resources / "llama-server").write_bytes(b"synthetic llama server")

        self.system = self.root / "baseline-system.txt"
        self.system.write_text(
            "# synthetic source metadata\nbaseline exact-Mac system prompt\n",
            encoding="utf-8",
        )
        self.app_prompt_path = self.app / GATE.APP_SYSTEM_PROMPT_RELATIVE_PATH
        self.app_prompt_path.write_text(
            "baseline exact-Mac system prompt\n", encoding="utf-8"
        )
        artifact = LOCAL.ModelArtifactIdentity(
            entrypoint_path=self.root / "model-00001-of-00008.gguf",
            revision="synthetic-baseline",
            manifest_sha256=digest("baseline-delivery-manifest"),
            total_bytes=1024,
            components=(("model-00001-of-00008.gguf", 1024, digest("baseline-shard")),),
        )
        self.server = LOCAL.LocalServer(
            pid=200,
            parent_pid=100,
            app_bundle=self.app.resolve(),
            host="127.0.0.1",
            port=50340,
            credential="synthetic-private-credential-never-recorded",
            model_path=artifact.entrypoint_path,
            model_artifact=artifact,
        )
        self.provenance_path = self.app / GATE.APP_BUILD_PROVENANCE_RELATIVE_PATH
        provenance = {
            "schema_version": GATE.APP_BUILD_PROVENANCE_SCHEMA,
            "build_git_head": "a" * 40,
            "app_executable_sha256": file_sha(macos / "EnviousWispr"),
            "llama_server_sha256": file_sha(resources / "llama-server"),
            "delivery_manifest_sha256": artifact.manifest_sha256,
            "system_prompt_source_sha256": file_sha(self.system),
            "system_prompt_sha256": digest("baseline exact-Mac system prompt"),
            "evaluation_config_sha256": GATE.executed_evaluation_config_sha256(
                digest("baseline exact-Mac system prompt")
            ),
            "app_system_prompt_resource_sha256": file_sha(self.app_prompt_path),
            **{
                field: file_sha(path)
                for field, path in GATE.APP_BUILD_SOURCE_PATHS.items()
            },
        }
        self._write_json(self.provenance_path, provenance)
        (signature / "CodeResources").write_bytes(
            plistlib.dumps(
                {
                    "files2": {
                        "Resources/eg1-exact-mac-build-provenance.json": {
                            "hash2": b"synthetic-code-signature-inventory"
                        },
                        "Resources/eg1-exact-mac-system-prompt.txt": {
                            "hash2": b"synthetic-prompt-signature-inventory"
                        }
                    }
                }
            )
        )
        runtime_identity = MODULE.app_identity(self.server)
        tooling = GATE.current_tooling_hashes()
        arms = {
            "baseline": {
                "designation": "current_shipping_baseline",
                "model_id": GATE.MODEL_ID,
                "model_artifact_sha256": MODULE.model_artifact_sha256(self.server),
                "delivery_manifest_sha256": artifact.manifest_sha256,
                "evaluation_config_sha256": GATE.executed_evaluation_config_sha256(
                    digest("baseline exact-Mac system prompt")
                ),
                "system_prompt_source_sha256": file_sha(self.system),
                "system_prompt_sha256": digest("baseline exact-Mac system prompt"),
                "app_bundle_path_sha256": runtime_identity["app_bundle_path_sha256"],
                "app_bundle_manifest_sha256": runtime_identity[
                    "app_bundle_manifest_sha256"
                ],
                "app_build_provenance_sha256": runtime_identity[
                    "app_build_provenance_sha256"
                ],
            },
            "finalist": {
                "designation": "locked_finalist",
                "model_id": GATE.MODEL_ID,
                "model_artifact_sha256": digest("finalist-artifact"),
                "delivery_manifest_sha256": digest("finalist-delivery-manifest"),
                "evaluation_config_sha256": GATE.executed_evaluation_config_sha256(
                    digest("baseline exact-Mac system prompt")
                ),
                "system_prompt_source_sha256": file_sha(self.system),
                "system_prompt_sha256": digest("baseline exact-Mac system prompt"),
                "app_bundle_path_sha256": digest("finalist-app-path"),
                "app_bundle_manifest_sha256": digest("finalist-bundle-manifest"),
                "app_build_provenance_sha256": digest("finalist-build-provenance"),
            },
        }
        self.lock = {
            "schema_version": GATE.LOCK_SCHEMA,
            "status": "locked_for_exact_mac_finalist_gate",
            "lock_id": "synthetic-producer-lock-v1",
            "gate_contract_sha256": file_sha(GATE.CONTRACT_PATH),
            "execution_git_head": "a" * 40,
            "tracked_worktree_clean_required": True,
            "tooling": tooling,
            "runtime": {
                field: runtime_identity[field] for field in GATE.RUNTIME_HASH_FIELDS
            },
            "arms": arms,
            "suites": {
                suite: {
                    "corpus_sha256": file_sha(self.corpora[suite]),
                    "case_count": counts[suite],
                    "case_id_field": id_fields[suite],
                    "input_field": "asr_input",
                    "language_field": "language",
                }
                for suite in GATE.SUITES
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

    def _runner(self, command: list[str], **kwargs: object) -> subprocess.CompletedProcess:
        tool_name = Path(command[0]).name
        if tool_name == "xcrun":
            return REAL_SUBPROCESS_RUN(command, **kwargs)
        if tool_name == "codesign":
            self.assertEqual(
                kwargs.get("env"), GATE.sanitized_external_tool_environment()
            )
            return subprocess.CompletedProcess(command, 0)
        if tool_name == "openssl":
            return REAL_SUBPROCESS_RUN(
                command,
                check=False,
                env=GATE.sanitized_external_tool_environment(),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        self.assertEqual(command[1:4], ["-I", "-E", "-s"])
        self.assertEqual(
            kwargs.get("executable"), str(GATE.resolve_python_runtime_paths()[1])
        )
        swift_launcher, swift_executable = GATE.pinned_swift_runtime_paths()
        swift_environment = GATE.sanitized_external_tool_environment(swift=True)
        expected_environment = MODULE.runner_environment(self.server.credential)
        expected_environment.update(swift_environment)
        self.assertEqual(kwargs.get("env"), expected_environment)
        self.assertEqual(
            command[command.index("--eg1-swift-launcher") + 1],
            str(swift_launcher),
        )
        self.assertEqual(
            command[command.index("--eg1-swift-launcher-path-sha256") + 1],
            GATE.swift_runtime_identity()["swift_launcher_path_sha256"],
        )
        self.assertEqual(
            command[command.index("--eg1-swift-executable") + 1],
            str(swift_executable),
        )
        self.assertEqual(
            command[command.index("--eg1-swift-executable-path-sha256") + 1],
            GATE.swift_runtime_identity()["swift_executable_path_sha256"],
        )
        self.assertEqual(
            command[command.index("--eg1-swift-executable-sha256") + 1],
            GATE.swift_runtime_identity()["swift_executable_sha256"],
        )
        self.assertEqual(
            command[command.index("--eg1-swift-developer-dir") + 1],
            swift_environment.get("DEVELOPER_DIR", "none"),
        )
        self.assertEqual(
            command[command.index("--eg1-swift-environment-sha256") + 1],
            GATE.swift_environment_sha256(swift_environment),
        )
        prompts = Path(command[command.index("--prompts") + 1])
        output = Path(command[command.index("--out") + 1])
        rows = [json.loads(line) for line in prompts.read_text(encoding="utf-8").splitlines()]
        self._write_jsonl(
            output,
            [
                {
                    "id": row["id"],
                    "candidate": f"safe synthetic output {index}",
                    "latencyMs": 10,
                    "attempts": 1,
                    "finishReason": "stop",
                }
                for index, row in enumerate(rows)
            ],
        )
        return subprocess.CompletedProcess(command, 0)

    def test_producer_observes_runtime_and_publishes_validator_accepted_receipt(self) -> None:
        output = self.root / "baseline-development-bundle"
        with (
            mock.patch.object(GATE, "require_git_state"),
            mock.patch.object(MODULE, "discover_server", side_effect=[self.server, self.server]),
            mock.patch.object(MODULE, "verify_ready"),
            mock.patch.object(MODULE, "CANONICAL_SHIPPED_PROMPT", self.system),
            mock.patch.object(MODULE, "runtime_session_id", return_value="mac-session-v1"),
            mock.patch.object(MODULE.subprocess, "run", side_effect=self._runner),
        ):
            receipt = MODULE.produce_receipt(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                arm="baseline",
                suite="development",
                app_bundle=self.app,
                system_prompt_path=self.system,
                attestation_private_key_path=self.private_key_path,
                attestation_public_key_path=self.public_key_path,
                output_bundle=output,
            )

        self.assertTrue((output / "receipt.json").is_file())
        receipt_text = (output / "receipt.json").read_text(encoding="utf-8")
        self.assertNotIn(self.server.credential, receipt_text)
        self.assertEqual(receipt["producer"]["script_sha256"], file_sha(MODULE_PATH))
        self.assertTrue(receipt["producer"]["receipt_written_by_key_holding_process"])
        self.assertFalse(receipt["producer"]["loaded_runtime_bytes_verified"])
        prompt_lines = (output / "prompts.jsonl").read_text(
            encoding="utf-8"
        ).splitlines()
        first_prompt = json.loads(prompt_lines[0])
        second_prompt = json.loads(prompt_lines[1])
        self.assertEqual(first_prompt["action"], "short_input_bypass")
        self.assertIsNone(first_prompt["system"])
        self.assertEqual(second_prompt["system"], "baseline exact-Mac system prompt")
        raw_lines = (output / "raw-output.jsonl").read_text(
            encoding="utf-8"
        ).splitlines()
        delivered_lines = (output / "output.jsonl").read_text(
            encoding="utf-8"
        ).splitlines()
        self.assertEqual(len(raw_lines), 799)
        self.assertEqual(len(delivered_lines), 800)
        first_delivered = json.loads(delivered_lines[0])
        self.assertEqual(first_delivered["candidate"], "got it")
        self.assertEqual(first_delivered["deliveryPath"], "short_input_bypass")

        lock, lock_sha, tooling = GATE.load_lock(self.lock_path)
        cases, snapshots = GATE.load_corpora(lock, self.corpora)
        shipped = GATE.load_shipped_request_module()
        record = GATE.validate_receipt(
            output / "receipt.json",
            lock=lock,
            lock_sha=lock_sha,
            tooling=tooling,
            cases_by_suite=cases,
            build_user_message=shipped.build_user_message,
            output_token_budget=shipped.output_token_budget,
            input_would_bypass_polish=shipped.input_would_bypass_polish,
            input_would_bypass_context=shipped.input_would_bypass_context,
            apply_message_output_validation=shipped.apply_message_output_validation,
            attestation_public_key=self.public_key_path.read_bytes(),
            used_files=set(snapshots),
            snapshots=snapshots,
        )
        self.assertEqual((record["arm"], record["suite"]), ("baseline", "development"))

    def test_model_identity_ignores_revision_metadata_but_tracks_weight_bytes(self) -> None:
        artifact = self.server.model_artifact
        assert artifact is not None
        repackaged = LOCAL.ModelArtifactIdentity(
            entrypoint_path=artifact.entrypoint_path,
            revision="metadata-only-revision-change",
            manifest_sha256=digest("different-manifest-metadata"),
            total_bytes=artifact.total_bytes,
            components=artifact.components,
        )
        alternate = LOCAL.LocalServer(
            pid=self.server.pid,
            parent_pid=self.server.parent_pid,
            app_bundle=self.server.app_bundle,
            host=self.server.host,
            port=self.server.port,
            credential=self.server.credential,
            model_path=self.server.model_path,
            model_artifact=repackaged,
        )
        self.assertEqual(
            MODULE.model_artifact_sha256(self.server),
            MODULE.model_artifact_sha256(alternate),
        )

    def test_build_generated_app_prompt_must_match_canonical_eval_prompt(self) -> None:
        self.app_prompt_path.write_text(
            "different prompt compiled into app\n", encoding="utf-8"
        )
        prompt_sha = file_sha(self.app_prompt_path)
        self.lock["runtime"]["app_system_prompt_resource_sha256"] = prompt_sha
        provenance = json.loads(self.provenance_path.read_text(encoding="utf-8"))
        provenance["app_system_prompt_resource_sha256"] = prompt_sha
        self._write_json(self.provenance_path, provenance)
        self.lock["arms"]["baseline"]["app_build_provenance_sha256"] = file_sha(
            self.provenance_path
        )
        self._write_json(self.lock_path, self.lock)
        with (
            mock.patch.object(GATE, "require_git_state"),
            mock.patch.object(MODULE, "discover_server", return_value=self.server),
            mock.patch.object(MODULE, "verify_ready"),
            mock.patch.object(MODULE, "CANONICAL_SHIPPED_PROMPT", self.system),
            mock.patch.object(MODULE.subprocess, "run", side_effect=self._runner),
            self.assertRaisesRegex(
                MODULE.ReceiptProducerError, "compiled system prompt differs"
            ),
        ):
            MODULE.produce_receipt(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                arm="baseline",
                suite="development",
                app_bundle=self.app,
                system_prompt_path=self.system,
                attestation_private_key_path=self.private_key_path,
                attestation_public_key_path=self.public_key_path,
                output_bundle=self.root / "not-created",
            )

    def test_runner_failure_publishes_no_partial_bundle_or_receipt(self) -> None:
        output = self.root / "failed-bundle"
        failed = subprocess.CompletedProcess(["synthetic-runner"], 2)
        with (
            mock.patch.object(GATE, "require_git_state"),
            mock.patch.object(MODULE, "discover_server", return_value=self.server),
            mock.patch.object(MODULE, "verify_ready"),
            mock.patch.object(MODULE, "CANONICAL_SHIPPED_PROMPT", self.system),
            mock.patch.object(MODULE, "runtime_session_id", return_value="mac-session-v1"),
            mock.patch.object(
                MODULE.subprocess,
                "run",
                side_effect=lambda command, **kwargs: (
                    failed if str(command[0]) == sys.executable else self._runner(command, **kwargs)
                ),
            ),
            self.assertRaisesRegex(MODULE.ReceiptProducerError, "runner failed"),
        ):
            MODULE.produce_receipt(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                arm="baseline",
                suite="development",
                app_bundle=self.app,
                system_prompt_path=self.system,
                attestation_private_key_path=self.private_key_path,
                attestation_public_key_path=self.public_key_path,
                output_bundle=output,
            )
        self.assertFalse(output.exists())

    def test_current_app_without_embedded_build_provenance_is_blocked(self) -> None:
        self.provenance_path.unlink()
        with (
            mock.patch.object(GATE, "require_git_state"),
            mock.patch.object(MODULE, "discover_server", return_value=self.server),
            mock.patch.object(MODULE, "verify_ready"),
            mock.patch.object(MODULE, "CANONICAL_SHIPPED_PROMPT", self.system),
            mock.patch.object(MODULE.subprocess, "run", side_effect=self._runner),
            self.assertRaisesRegex(
                MODULE.ReceiptProducerError, "current builds are not certifiable"
            ),
        ):
            MODULE.produce_receipt(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                arm="baseline",
                suite="development",
                app_bundle=self.app,
                system_prompt_path=self.system,
                attestation_private_key_path=self.private_key_path,
                attestation_public_key_path=self.public_key_path,
                output_bundle=self.root / "not-created",
            )

    def test_invalid_app_code_signature_blocks_provenance(self) -> None:
        def invalid_codesign(
            command: list[str], **kwargs: object
        ) -> subprocess.CompletedProcess:
            if Path(command[0]).name == "codesign":
                return subprocess.CompletedProcess(command, 1)
            return self._runner(command, **kwargs)

        with (
            mock.patch.object(GATE, "require_git_state"),
            mock.patch.object(MODULE, "discover_server", return_value=self.server),
            mock.patch.object(MODULE, "verify_ready"),
            mock.patch.object(MODULE, "CANONICAL_SHIPPED_PROMPT", self.system),
            mock.patch.object(MODULE.subprocess, "run", side_effect=invalid_codesign),
            self.assertRaisesRegex(MODULE.ReceiptProducerError, "signature is invalid"),
        ):
            MODULE.produce_receipt(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                arm="baseline",
                suite="development",
                app_bundle=self.app,
                system_prompt_path=self.system,
                attestation_private_key_path=self.private_key_path,
                attestation_public_key_path=self.public_key_path,
                output_bundle=self.root / "not-created",
            )

    def test_tampered_provenance_resource_is_blocked(self) -> None:
        provenance = json.loads(self.provenance_path.read_text(encoding="utf-8"))
        provenance["pipeline_source_sha256"] = digest("tampered-pipeline-source")
        self._write_json(self.provenance_path, provenance)
        with (
            mock.patch.object(GATE, "require_git_state"),
            mock.patch.object(MODULE, "discover_server", return_value=self.server),
            mock.patch.object(MODULE, "verify_ready"),
            mock.patch.object(MODULE, "CANONICAL_SHIPPED_PROMPT", self.system),
            mock.patch.object(MODULE.subprocess, "run", side_effect=self._runner),
            self.assertRaisesRegex(
                MODULE.ReceiptProducerError, "differs from the locked arm"
            ),
        ):
            MODULE.produce_receipt(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                arm="baseline",
                suite="development",
                app_bundle=self.app,
                system_prompt_path=self.system,
                attestation_private_key_path=self.private_key_path,
                attestation_public_key_path=self.public_key_path,
                output_bundle=self.root / "not-created",
            )

    def test_provenance_resource_missing_from_signature_inventory_is_blocked(self) -> None:
        code_resources = self.app / "Contents" / "_CodeSignature" / "CodeResources"
        code_resources.write_bytes(plistlib.dumps({"files2": {}}))
        with (
            mock.patch.object(GATE, "require_git_state"),
            mock.patch.object(MODULE, "discover_server", return_value=self.server),
            mock.patch.object(MODULE, "verify_ready"),
            mock.patch.object(MODULE, "CANONICAL_SHIPPED_PROMPT", self.system),
            mock.patch.object(MODULE.subprocess, "run", side_effect=self._runner),
            self.assertRaisesRegex(MODULE.ReceiptProducerError, "not covered"),
        ):
            MODULE.produce_receipt(
                lock_path=self.lock_path,
                corpus_paths=self.corpora,
                arm="baseline",
                suite="development",
                app_bundle=self.app,
                system_prompt_path=self.system,
                attestation_private_key_path=self.private_key_path,
                attestation_public_key_path=self.public_key_path,
                output_bundle=self.root / "not-created",
            )

    def test_model_visible_prompt_strips_source_comments_and_trailing_newline(self) -> None:
        self.assertEqual(
            MODULE.model_visible_system_prompt(self.system.read_bytes()),
            "baseline exact-Mac system prompt",
        )

    def test_renderer_preserves_context_bypass_in_all_case_evidence(self) -> None:
        shipped = GATE.load_shipped_request_module()
        evidence, runner, rows = MODULE.render_prompts(
            [("too-long", "word " * 1700, "en")],
            "baseline exact-Mac system prompt",
            shipped,
        )
        self.assertTrue(evidence)
        self.assertEqual(runner, b"")
        self.assertEqual(rows[0]["action"], "context_bypass")
        self.assertIsNone(rows[0]["user"])

    def test_cli_handles_normal_runtime_discovery_failure(self) -> None:
        args = SimpleNamespace(
            lock_manifest=self.lock_path,
            corpus=[f"{suite}={path}" for suite, path in self.corpora.items()],
            arm="baseline",
            suite="development",
            app_bundle=self.app,
            system_prompt=self.system,
            attestation_private_key=self.private_key_path,
            attestation_public_key=self.public_key_path,
            out_bundle=self.root / "not-created",
        )
        error_output = io.StringIO()
        with (
            mock.patch.object(MODULE, "parse_args", return_value=args),
            mock.patch.object(
                MODULE,
                "produce_receipt",
                side_effect=LOCAL.LocalServerDiscoveryError("synthetic discovery failure"),
            ),
            redirect_stderr(error_output),
        ):
            self.assertEqual(MODULE.main(), 2)
        self.assertIn("exact-Mac receipt production failed", error_output.getvalue())


if __name__ == "__main__":
    unittest.main()
