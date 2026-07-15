from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


EVAL_DIR = Path(__file__).resolve().parents[1]
if str(EVAL_DIR) not in sys.path:
    sys.path.insert(0, str(EVAL_DIR))
MODULE_PATH = EVAL_DIR / "eg1_local_app_ab_eval.py"
SPEC = importlib.util.spec_from_file_location("eg1_local_app_ab_eval", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class LocalAppABEvalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.render = self.root / "render"
        self.render.mkdir()
        self.contract = self.root / "contract.md"
        self._write_contract()
        self._write_render_bundle()

    def tearDown(self) -> None:
        self.temp.cleanup()

    @staticmethod
    def _prompt_rows(system: str) -> list[dict[str, object]]:
        return [
            {
                "id": f"case-{index:03d}",
                "system": system,
                "user": f"<TRANSCRIPT>\ntranscript {index}\n</TRANSCRIPT>",
                "max_tokens": 256,
            }
            for index in range(150)
        ]

    @staticmethod
    def _write_jsonl(path: Path, rows: list[dict[str, object]]) -> None:
        path.write_text(
            "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows),
            encoding="utf-8",
        )

    def _write_contract(self) -> None:
        bindings = {key: "0" * 64 for key in MODULE.load_contract.__globals__["REQUIRED_BINDINGS"]}
        bindings["code_anchor_git_sha1"] = "c" * 40
        bindings.update(
            {
                "contract_verifier_sha256": sha(MODULE.CONTRACT_VERIFIER),
                "dual_arm_orchestrator_sha256": sha(MODULE.SCRIPT_PATH),
                "local_wrapper_sha256": sha(MODULE.LOCAL_WRAPPER),
                "subset_runner_sha256": sha(MODULE.RUNNER),
                "shipped_request_mirror_sha256": sha(MODULE.SHIPPED_REQUEST),
                "delivery_manifest_sha256": "a" * 64,
            }
        )
        self.bindings = bindings
        self.contract.write_text(
            "contract\n<!-- EG1_LIST_V2_BINDINGS_BEGIN -->\n```json\n"
            + json.dumps(bindings, indent=2)
            + "\n```\n<!-- EG1_LIST_V2_BINDINGS_END -->\n",
            encoding="utf-8",
        )

    def _write_render_bundle(self) -> None:
        self._write_jsonl(self.render / "baseline.jsonl", self._prompt_rows("baseline"))
        self._write_jsonl(self.render / "candidate.jsonl", self._prompt_rows("candidate"))
        receipt = {
            "status": "gold_free_prompt_arms_ready_for_exact_mac_evaluation",
            "case_contract": {
                "total_count": 150,
                "identical_id_user_and_token_budget_across_arms": True,
                "only_system_prompt_differs_across_arms": True,
                "rendered_rows_are_gold_free": True,
            },
            "provenance": {
                "decision_contract": {"sha256": sha(self.contract)},
                "bindings": self.bindings,
            },
            "outputs": {
                "baseline": {
                    "path": "baseline.jsonl",
                    "sha256": sha(self.render / "baseline.jsonl"),
                },
                "candidate": {
                    "path": "candidate.jsonl",
                    "sha256": sha(self.render / "candidate.jsonl"),
                },
            },
        }
        (self.render / "receipt.json").write_text(
            json.dumps(receipt, sort_keys=True) + "\n", encoding="utf-8"
        )

    def test_load_render_bundle_binds_hashes_and_non_system_identity(self) -> None:
        _, baseline, candidate, hashes = MODULE.load_render_bundle(
            self.render, sha(self.render / "receipt.json"), sha(self.contract)
        )
        self.assertEqual(baseline, self.render / "baseline.jsonl")
        self.assertEqual(candidate, self.render / "candidate.jsonl")
        self.assertEqual(hashes["baseline"], sha(baseline))

    def test_load_render_bundle_rejects_tampered_arm(self) -> None:
        receipt_sha = sha(self.render / "receipt.json")
        with (self.render / "candidate.jsonl").open("a", encoding="utf-8") as handle:
            handle.write("{}\n")
        with self.assertRaisesRegex(ValueError, "differs from its receipt"):
            MODULE.load_render_bundle(self.render, receipt_sha, sha(self.contract))

    def test_validate_arm_output_rejects_error_and_reports_it(self) -> None:
        output = self.root / "output.jsonl"
        rows = [
            {"id": f"case-{index:03d}", "candidate": f"answer {index}"}
            for index in range(150)
        ]
        rows[7] = {"id": "case-007", "candidate": "", "error": "timeout"}
        self._write_jsonl(output, rows)
        result = MODULE.validate_arm_output(
            self.render / "baseline.jsonl", output, "baseline"
        )
        self.assertEqual(result["inference_error_ids"], ["case-007"])
        self.assertEqual(result["empty_output_ids"], ["case-007"])

    def test_same_server_includes_private_credential_without_exposing_it(self) -> None:
        first = MODULE.LocalServer(
            pid=1,
            parent_pid=2,
            app_bundle=Path("/tmp/App.app"),
            host="127.0.0.1",
            port=1234,
            credential="a" * 32,
        )
        second = MODULE.LocalServer(
            pid=1,
            parent_pid=2,
            app_bundle=Path("/tmp/App.app"),
            host="127.0.0.1",
            port=1234,
            credential="b" * 32,
        )
        self.assertFalse(MODULE.same_server(first, second))
        self.assertNotIn("a" * 32, first.public_summary())

    def test_same_server_rejects_model_path_or_manifest_drift(self) -> None:
        first_artifact = MODULE.ModelArtifactIdentity(
            entrypoint_path=Path("/tmp/model-a.gguf"),
            revision="v1",
            manifest_sha256="a" * 64,
            total_bytes=10,
            components=(("model-a.gguf", 10, "b" * 64),),
        )
        second_artifact = MODULE.ModelArtifactIdentity(
            entrypoint_path=Path("/tmp/model-b.gguf"),
            revision="v1",
            manifest_sha256="c" * 64,
            total_bytes=10,
            components=(("model-b.gguf", 10, "d" * 64),),
        )
        shared = {
            "pid": 1,
            "parent_pid": 2,
            "app_bundle": Path("/tmp/App.app"),
            "host": "127.0.0.1",
            "port": 1234,
            "credential": "z" * 32,
        }
        first = MODULE.LocalServer(
            **shared,
            model_path=first_artifact.entrypoint_path,
            model_artifact=first_artifact,
        )
        second = MODULE.LocalServer(
            **shared,
            model_path=second_artifact.entrypoint_path,
            model_artifact=second_artifact,
        )
        self.assertFalse(MODULE.same_server(first, second))

    def test_run_arm_rechecks_server_before_and_after_runner(self) -> None:
        app = self.root / "App.app"
        app.mkdir()
        output = self.root / "arm.jsonl"
        server = MODULE.LocalServer(
            pid=10,
            parent_pid=11,
            app_bundle=app,
            host="127.0.0.1",
            port=1234,
            credential="z" * 32,
            model_path=Path("/tmp/model.gguf"),
            model_artifact=MODULE.ModelArtifactIdentity(
                entrypoint_path=Path("/tmp/model.gguf"),
                revision="test",
                manifest_sha256="a" * 64,
                total_bytes=10,
                components=(("model.gguf", 10, "b" * 64),),
            ),
        )

        observed: dict[str, object] = {}

        def fake_run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
            observed["command"] = list(command)
            observed["environment"] = dict(kwargs["env"])
            observed["executable"] = kwargs["executable"]
            out_path = Path(command[command.index("--out") + 1])
            prompts = MODULE.parse_jsonl(
                (self.render / "baseline.jsonl").read_bytes(), "prompts"
            )
            self._write_jsonl(
                out_path,
                [
                    {"id": row["id"], "candidate": f"answer {index}"}
                    for index, row in enumerate(prompts)
                ],
            )
            return subprocess.CompletedProcess(command, 0, "", "")

        swift_arguments = (
            "--eg1-swift-launcher",
            "/locked/swift",
            "--eg1-swift-launcher-path-sha256",
            "a" * 64,
            "--eg1-swift-executable",
            "/locked/swift-target",
            "--eg1-swift-executable-path-sha256",
            "b" * 64,
            "--eg1-swift-executable-sha256",
            "c" * 64,
            "--eg1-swift-developer-dir",
            "/locked/developer",
            "--eg1-swift-environment-sha256",
            "d" * 64,
        )
        swift_environment = {
            "HOME": "/tmp",
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": "/tmp",
            "DEVELOPER_DIR": "/locked/developer",
        }
        python_launcher = Path(sys.executable).absolute()
        python_executable = python_launcher.resolve(strict=True)

        with (
            mock.patch.object(MODULE, "recheck_server") as recheck,
            mock.patch.object(MODULE.subprocess, "run", side_effect=fake_run),
        ):
            returncode, result = MODULE.run_arm(
                "baseline",
                self.render / "baseline.jsonl",
                output,
                server,
                app,
                swift_arguments,
                swift_environment,
                python_launcher,
                python_executable,
            )
        self.assertEqual(returncode, 0)
        self.assertEqual(result["row_count"], 150)
        self.assertEqual(recheck.call_count, 2)
        recheck.assert_has_calls([mock.call(server, app), mock.call(server, app)])
        command = observed["command"]
        self.assertEqual(command[1:4], ["-I", "-E", "-s"])
        self.assertEqual(
            command[command.index("--eg1-swift-executable-sha256") + 1],
            "c" * 64,
        )
        expected_environment = MODULE.runner_environment(server.credential)
        expected_environment.update(swift_environment)
        self.assertEqual(observed["environment"], expected_environment)
        self.assertEqual(observed["executable"], str(python_executable))

    def test_partial_receipt_write_removes_complete_ab_bundle(self) -> None:
        source = self.root / "publish-source"
        destination = self.root / "publish-destination"
        source.mkdir()
        (source / "baseline.jsonl").write_text("baseline\n", encoding="utf-8")
        (source / "candidate.jsonl").write_text("candidate\n", encoding="utf-8")

        def partial_receipt(path: Path, value: bytes) -> None:
            path.write_bytes(value[:1])
            raise OSError("injected receipt short write")

        with (
            mock.patch.object(MODULE, "write_exclusive", side_effect=partial_receipt),
            self.assertRaisesRegex(OSError, "injected receipt short write"),
        ):
            MODULE.publish_bundle(
                destination,
                source,
                ("baseline.jsonl", "candidate.jsonl"),
                b'{"status":"complete"}\n',
            )
        self.assertFalse(destination.exists())

    def test_main_publishes_explicit_arm_receipt_last(self) -> None:
        app = self.root / "App.app"
        app.mkdir()
        output = self.root / "ab-output"
        server = MODULE.LocalServer(
            pid=10,
            parent_pid=11,
            app_bundle=app,
            host="127.0.0.1",
            port=1234,
            credential="z" * 32,
            model_path=Path("/tmp/model.gguf"),
            model_artifact=MODULE.ModelArtifactIdentity(
                entrypoint_path=Path("/tmp/model.gguf"),
                revision="test",
                manifest_sha256="a" * 64,
                total_bytes=10,
                components=(("model.gguf", 10, "b" * 64),),
            ),
        )

        def fake_run_arm(
            arm: str,
            prompt_path: Path,
            output_path: Path,
            _server: MODULE.LocalServer,
            _app: Path,
            _swift_arguments: tuple[str, ...],
            _swift_environment: dict[str, str],
            _python_launcher: Path,
            _python_executable: Path,
        ) -> tuple[int, dict[str, object]]:
            prompts = MODULE.parse_jsonl(prompt_path.read_bytes(), f"{arm} prompts")
            rows = [{"id": row["id"], "candidate": f"{arm} answer"} for row in prompts]
            self._write_jsonl(output_path, rows)
            return 0, MODULE.validate_arm_output(prompt_path, output_path, arm)

        arguments = [
            str(MODULE_PATH),
            "--render-bundle",
            str(self.render),
            "--decision-contract",
            str(self.contract),
            "--app-bundle",
            str(app),
            "--out-bundle",
            str(output),
            "--expected-render-receipt-sha256",
            sha(self.render / "receipt.json"),
            "--expected-decision-contract-sha256",
            sha(self.contract),
            "--expected-orchestrator-sha256",
            sha(MODULE.SCRIPT_PATH),
            "--expected-local-wrapper-sha256",
            sha(MODULE.LOCAL_WRAPPER),
            "--expected-runner-sha256",
            sha(MODULE.RUNNER),
            "--expected-shipped-request-sha256",
            sha(MODULE.SHIPPED_REQUEST),
            "--expected-git-head",
            "a" * 40,
        ]
        swift_arguments, swift_environment = (
            MODULE.standalone_swift_runtime_contract()
        )
        python_paths = MODULE.standalone_python_runtime_paths()
        with (
            mock.patch.object(sys, "argv", arguments),
            mock.patch.object(MODULE, "CANONICAL_DECISION_CONTRACT", self.contract),
            mock.patch.object(MODULE, "require_git_state", return_value="a" * 40),
            mock.patch.object(
                MODULE, "validate_binding_commit", return_value="a" * 40
            ),
            mock.patch.object(MODULE, "discover_server", return_value=server),
            mock.patch.object(MODULE, "verify_ready"),
            mock.patch.object(MODULE, "recheck_server"),
            mock.patch.object(MODULE, "run_arm", side_effect=fake_run_arm),
            mock.patch.object(
                MODULE,
                "standalone_swift_runtime_contract",
                return_value=(swift_arguments, swift_environment),
            ) as swift_contract,
            mock.patch.object(
                MODULE,
                "standalone_python_runtime_paths",
                return_value=python_paths,
            ) as python_contract,
        ):
            self.assertEqual(MODULE.main(), 0)

        swift_contract.assert_called_once_with()
        python_contract.assert_called_once_with()

        receipt_text = (output / "receipt.json").read_text(encoding="utf-8")
        receipt = json.loads(receipt_text)
        self.assertEqual(
            receipt["status"], "connector_wire_exact_ab_complete_semantic_review_pending"
        )
        self.assertEqual(receipt["scope"]["arm_order"], ["baseline", "candidate"])
        self.assertFalse(receipt["scope"]["paste_equivalent"])
        self.assertFalse(receipt["scope"]["certifying_finalist_gate_evidence"])
        self.assertEqual(
            receipt["scope"]["runtime_binding"],
            "standalone_noncertifying_discovered_once_for_both_arms",
        )
        self.assertEqual(
            receipt["runtime"]["model_artifact"]["manifest_sha256"],
            receipt["provenance"]["bindings"]["delivery_manifest_sha256"],
        )
        process_identity = receipt["runtime"]["evaluation_process"]
        self.assertEqual(process_identity["status"], "standalone_noncertifying")
        swift_options = dict(zip(swift_arguments[::2], swift_arguments[1::2]))
        self.assertEqual(
            process_identity["swift"]["environment_sha256"],
            swift_options["--eg1-swift-environment-sha256"],
        )
        self.assertEqual(
            process_identity["swift"]["executable_sha256"],
            swift_options["--eg1-swift-executable-sha256"],
        )
        self.assertEqual(
            process_identity["python"]["launcher_path_sha256"],
            hashlib.sha256(str(python_paths[0]).encode("utf-8")).hexdigest(),
        )
        self.assertEqual(
            process_identity["python"]["executable_sha256"], sha(python_paths[1])
        )
        self.assertNotIn(swift_options["--eg1-swift-launcher"], receipt_text)
        self.assertNotIn(str(python_paths[0]), receipt_text)
        self.assertNotIn("z" * 32, receipt_text)

    def test_main_rejects_live_manifest_mismatch_before_running_an_arm(self) -> None:
        app = self.root / "App.app"
        app.mkdir()
        output = self.root / "ab-output-mismatch"
        server = MODULE.LocalServer(
            pid=10,
            parent_pid=11,
            app_bundle=app,
            host="127.0.0.1",
            port=1234,
            credential="z" * 32,
            model_path=Path("/tmp/model.gguf"),
            model_artifact=MODULE.ModelArtifactIdentity(
                entrypoint_path=Path("/tmp/model.gguf"),
                revision="test",
                manifest_sha256="c" * 64,
                total_bytes=10,
                components=(("model.gguf", 10, "b" * 64),),
            ),
        )
        arguments = [
            str(MODULE_PATH),
            "--render-bundle",
            str(self.render),
            "--decision-contract",
            str(self.contract),
            "--app-bundle",
            str(app),
            "--out-bundle",
            str(output),
            "--expected-render-receipt-sha256",
            sha(self.render / "receipt.json"),
            "--expected-decision-contract-sha256",
            sha(self.contract),
            "--expected-orchestrator-sha256",
            sha(MODULE.SCRIPT_PATH),
            "--expected-local-wrapper-sha256",
            sha(MODULE.LOCAL_WRAPPER),
            "--expected-runner-sha256",
            sha(MODULE.RUNNER),
            "--expected-shipped-request-sha256",
            sha(MODULE.SHIPPED_REQUEST),
            "--expected-git-head",
            "a" * 40,
        ]
        with (
            mock.patch.object(sys, "argv", arguments),
            mock.patch.object(MODULE, "CANONICAL_DECISION_CONTRACT", self.contract),
            mock.patch.object(MODULE, "require_git_state", return_value="a" * 40),
            mock.patch.object(
                MODULE, "validate_binding_commit", return_value="a" * 40
            ),
            mock.patch.object(MODULE, "discover_server", return_value=server),
            mock.patch.object(MODULE, "verify_ready"),
            mock.patch.object(MODULE, "run_arm") as run_arm,
            self.assertRaisesRegex(ValueError, "delivery_manifest_sha256"),
        ):
            MODULE.main()

        run_arm.assert_not_called()
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
