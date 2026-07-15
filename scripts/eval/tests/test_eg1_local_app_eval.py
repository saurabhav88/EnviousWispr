import dataclasses
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


EVAL_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = EVAL_DIR / "eg1_local_app_eval.py"
SPEC = importlib.util.spec_from_file_location("eg1_local_app_eval", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class EG1LocalAppEvalTests(unittest.TestCase):
    def test_parses_model_path_with_spaces(self):
        path = MODULE.parse_model_path(
            "llama-server -m /Users/test/Library/Application Support/"
            "EnviousWispr/Models/eg-1/model.gguf --host 127.0.0.1"
        )
        self.assertEqual(
            path,
            Path(
                "/Users/test/Library/Application Support/"
                "EnviousWispr/Models/eg-1/model.gguf"
            ),
        )

    def test_verifies_every_manifest_component_and_entrypoint(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            app = root / "EnviousWispr Local.app"
            resources = app / "Contents" / "Resources"
            resources.mkdir(parents=True)
            models = root / "Models"
            models.mkdir()
            first = models / "first.gguf"
            second = models / "second.gguf"
            first.write_bytes(b"first shard")
            second.write_bytes(b"second shard")
            files = []
            for path in (first, second):
                value = path.read_bytes()
                files.append(
                    {
                        "installPath": path.name,
                        "sizeBytes": len(value),
                        "sha256": hashlib.sha256(value).hexdigest(),
                    }
                )
            manifest = {
                "identity": {"name": "eg-1", "revision": "test-revision"},
                "admission": {
                    "layout": "componentSet",
                    "entrypointFile": first.name,
                },
                "files": files,
                "totalBytes": sum(item["sizeBytes"] for item in files),
            }
            manifest_path = resources / "eg1-delivery-manifest.json"
            manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
            artifact = MODULE.verify_model_artifact(app, first)
            self.assertEqual(artifact.entrypoint_path, first.resolve())
            self.assertEqual(artifact.revision, "test-revision")
            self.assertEqual(len(artifact.components), 2)
            self.assertTrue(artifact.public_receipt()["all_component_hashes_verified"])

            second.write_bytes(b"tamper shard")
            with self.assertRaisesRegex(
                MODULE.LocalServerDiscoveryError, "component hash is invalid"
            ):
                MODULE.verify_model_artifact(app, first)

    def test_parses_loopback_server_without_public_credential(self):
        secret = "private-value-that-must-never-be-printed"
        host, port, parsed = MODULE.parse_server_flags(
            "llama-server -m model.gguf --host 127.0.0.1 --port 50340 "
            f"--api-key {secret} -fa on"
        )
        server = MODULE.LocalServer(
            pid=10,
            parent_pid=9,
            app_bundle=Path("/tmp/EnviousWispr Local.app"),
            host=host,
            port=port,
            credential=parsed,
        )

        self.assertEqual(host, "127.0.0.1")
        self.assertEqual(port, 50340)
        self.assertEqual(parsed, secret)
        self.assertNotIn(secret, repr(server))
        self.assertNotIn(secret, server.public_summary())
        self.assertIn("credential_present=true", server.public_summary())
        self.assertNotIn("credential_length", server.public_summary())

    def test_rejects_non_loopback_host_without_echoing_value(self):
        command = (
            "llama-server --host 0.0.0.0 --port 50340 "
            "--api-key private-value-that-must-never-be-printed"
        )
        with self.assertRaises(MODULE.LocalServerDiscoveryError) as caught:
            MODULE.parse_server_flags(command)

        self.assertNotIn("0.0.0.0", str(caught.exception))
        self.assertNotIn("private-value", str(caught.exception))

    def test_rejects_duplicate_or_short_credentials(self):
        with self.assertRaises(MODULE.LocalServerDiscoveryError):
            MODULE.parse_server_flags(
                "llama-server --host 127.0.0.1 --port 50340 "
                "--api-key short --api-key second"
            )
        with self.assertRaises(MODULE.LocalServerDiscoveryError):
            MODULE.parse_server_flags(
                "llama-server --host 127.0.0.1 --port 50340 --api-key short"
            )

    def test_dataclass_credential_is_not_in_repr(self):
        field = next(
            item for item in dataclasses.fields(MODULE.LocalServer) if item.name == "credential"
        )
        self.assertFalse(field.repr)

    def test_runner_environment_does_not_inherit_proxy_or_python_settings(self):
        environment = MODULE.runner_environment("private-value")
        self.assertEqual(environment["OPENAI_API_KEY"], "private-value")
        self.assertEqual(environment["NO_PROXY"], "127.0.0.1")
        self.assertEqual(environment["no_proxy"], "127.0.0.1")
        self.assertNotIn("HTTP_PROXY", environment)
        self.assertNotIn("ALL_PROXY", environment)
        self.assertNotIn("PYTHONPATH", environment)

    def test_shipping_flags_pass_and_each_altered_flag_fails(self):
        valid = (
            "llama-server -c 16384 -fa on --cache-type-k q8_0 "
            "--cache-type-v q8_0"
        )
        MODULE.validate_shipped_runtime_flags(valid)

        for flag, replacement in {
            "-c 16384": "-c 8192",
            "-fa on": "-fa off",
            "--cache-type-k q8_0": "--cache-type-k f16",
            "--cache-type-v q8_0": "--cache-type-v f16",
        }.items():
            with self.subTest(flag=flag):
                with self.assertRaises(MODULE.LocalServerDiscoveryError):
                    MODULE.validate_shipped_runtime_flags(valid.replace(flag, replacement))

    def test_health_probe_is_authenticated_and_proxy_disabled(self):
        secret = "private-value-that-must-never-be-printed"
        server = MODULE.LocalServer(
            pid=10,
            parent_pid=9,
            app_bundle=Path("/tmp/EnviousWispr Local.app"),
            host="127.0.0.1",
            port=50340,
            credential=secret,
        )
        response = mock.MagicMock()
        response.__enter__.return_value.status = 200
        opener = mock.MagicMock()
        opener.open.return_value = response

        with mock.patch.object(MODULE.urllib.request, "build_opener", return_value=opener) as build:
            MODULE.verify_ready(server)

        request = opener.open.call_args.args[0]
        self.assertEqual(request.get_header("Authorization"), f"Bearer {secret}")
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 2)
        self.assertEqual(build.call_count, 1)
        handler = build.call_args.args[0]
        self.assertEqual(handler.proxies, {})


if __name__ == "__main__":
    unittest.main()
