from __future__ import annotations

from collections import deque
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import numpy as np


EVAL_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = EVAL_DIR / "screen_eg1_replay_semantic_neighbors.py"
INVENTORY_BUILDER_PATH = EVAL_DIR / "build_eg1_replay_inventory.py"
NORMALIZER_PATH = EVAL_DIR / "eg1_replay_normalizer_v1.py"
sys.path.insert(0, str(EVAL_DIR))
SPEC = importlib.util.spec_from_file_location(
    "screen_eg1_replay_semantic_neighbors", MODULE_PATH
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
PRODUCTION_FULL_RECEIPT_SHA256 = "0" * 64


def encode_rows(rows: list[dict[str, object]]) -> bytes:
    return b"".join(MODULE.canonical_json(row) for row in rows)


class FakeEmbeddingBackend:
    def __init__(self, _model_dir: Path, embedding: dict[str, object]) -> None:
        self.runtime_versions = dict(embedding["runtime_versions"])
        self.max_seq_length = int(embedding["max_seq_length"])
        self.dimension = int(embedding["embedding_dimension"])

    def preflight_token_lengths(self, texts: list[str]) -> int:
        return max(len(text.split()) + 2 for text in texts)

    def encode_documents(self, texts: list[str]) -> np.ndarray:
        vectors = []
        for text in texts:
            digest = hashlib.sha256(text.encode("utf-8")).digest()
            vector = np.array(
                [digest[index] - 127.5 for index in range(self.dimension)],
                dtype=np.float32,
            )
            vectors.append(vector / np.linalg.norm(vector))
        return np.asarray(vectors, dtype=np.float32)


class SemanticScreenFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.builder = self.root / "scripts/eval/screen_eg1_replay_semantic_neighbors.py"
        self.inventory_builder = (
            self.root / "scripts/eval/build_eg1_replay_inventory.py"
        )
        self.normalizer = self.root / "scripts/eval/eg1_replay_normalizer_v1.py"
        self.contract = (
            self.root / "scripts/eval/contracts/eg1_replay_semantic_screen_v1.json"
        )
        self.inventory_bundle = (
            self.root / "scripts/eval/runs/eg1-replay-inventory-v1"
        )
        self.output_parent = self.root / "scripts/eval/runs"
        self.replay_path = (
            self.root / "scripts/eval/runs/bakeoff-1265/train_sft_v2.jsonl"
        )
        self.reference_path = self.root / "scripts/eval/corpus/type_b_all_v1.jsonl"
        self.model_revision = "synthetic-model-revision"
        self.model_dir = self.root / "models" / self.model_revision
        self.trusted_receipts: dict[Path, str] = {}
        for path in (
            self.builder.parent,
            self.contract.parent,
            self.inventory_bundle,
            self.replay_path.parent,
            self.reference_path.parent,
            self.model_dir,
        ):
            path.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(MODULE_PATH, self.builder)
        shutil.copyfile(INVENTORY_BUILDER_PATH, self.inventory_builder)
        shutil.copyfile(NORMALIZER_PATH, self.normalizer)
        (self.root / ".gitignore").write_text(
            "/scripts/eval/runs/\n/scripts/eval/corpus/*.jsonl\n/models/\n",
            encoding="utf-8",
        )
        self.replay_rows = [
            {
                "id": f"synthetic-replay-id-{index}",
                "source": "synthetic-private-source",
                "input": f"synthetic input phrase {index}",
                "output": f"Synthetic polished phrase {index}.",
            }
            for index in range(4)
        ]
        self.reference_rows = [
            {
                "id": f"synthetic-reference-id-{index}",
                "asr_input": f"synthetic historical input {index}",
                "expected_output": f"Synthetic historical output {index}.",
            }
            for index in range(6)
        ]
        self.replay_path.write_bytes(encode_rows(self.replay_rows))
        self.reference_path.write_bytes(encode_rows(self.reference_rows))
        self.inventory_rows = [
            {
                "row_fingerprint_sha256": MODULE.fingerprint_row(row),
                "decision": "candidate_only" if index < 3 else "duplicate_group_quarantined",
                "reason_codes": [] if index < 3 else ["synthetic_quarantine"],
                "training_eligible": False,
            }
            for index, row in enumerate(self.replay_rows)
        ]
        inventory_bytes = encode_rows(self.inventory_rows)
        (self.inventory_bundle / "inventory.jsonl").write_bytes(inventory_bytes)
        coordinator = {
            "schema_version": "eg1-replay-inventory-v1",
            "execution_git_head": "c" * 40,
            "sources": [
                {
                    "role": "replay_training_original",
                    "path": str(self.replay_path.relative_to(self.root)),
                    "sha256": MODULE.sha256_bytes(self.replay_path.read_bytes()),
                    "row_count": len(self.replay_rows),
                },
                {
                    "role": "historical_type_b_all",
                    "path": str(self.reference_path.relative_to(self.root)),
                    "sha256": MODULE.sha256_bytes(self.reference_path.read_bytes()),
                    "row_count": len(self.reference_rows),
                },
            ],
            "inventory": {
                "path": "inventory.jsonl",
                "sha256": MODULE.sha256_bytes(inventory_bytes),
                "row_count": len(self.inventory_rows),
            },
            "observed_counts": {
                "total_replay_rows": len(self.inventory_rows),
                "candidate_only": 3,
                "training_eligible": 0,
                "unresolved": 0,
            },
        }
        coordinator["receipt_payload_sha256"] = MODULE.sha256_bytes(
            MODULE.canonical_json(coordinator)
        )
        self.coordinator_receipt = coordinator
        (self.inventory_bundle / "receipt.json").write_bytes(
            MODULE.canonical_json(coordinator)
        )
        (self.model_dir / "config.json").write_bytes(b'{"synthetic":true}\n')
        (self.model_dir / "weights.bin").write_bytes(b"synthetic-model-weights")
        self._write_contract()
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(
            ["git", "config", "user.email", "semantic-screen@example.invalid"],
            cwd=self.root,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Semantic Screen Test"],
            cwd=self.root,
            check=True,
        )
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run(
            ["git", "commit", "-q", "-m", "synthetic controls"],
            cwd=self.root,
            check=True,
        )
        self.expected_head = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=self.root,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        ).stdout.strip()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _write_contract(self) -> None:
        model = MODULE.model_tree_receipt(self.model_dir)
        receipt_bytes = (self.inventory_bundle / "receipt.json").read_bytes()
        inventory_bytes = (self.inventory_bundle / "inventory.jsonl").read_bytes()
        contract = {
            "schema_version": MODULE.SCHEMA_VERSION,
            "status": "screening_only_manual_approval_required",
            "tool_bindings": {
                "screening_builder": {
                    "path": str(self.builder.relative_to(self.root)),
                    "sha256": MODULE.sha256_bytes(self.builder.read_bytes()),
                },
                "inventory_builder": {
                    "path": str(self.inventory_builder.relative_to(self.root)),
                    "sha256": MODULE.sha256_bytes(self.inventory_builder.read_bytes()),
                },
                "inventory_normalizer": {
                    "path": str(self.normalizer.relative_to(self.root)),
                    "sha256": MODULE.sha256_bytes(self.normalizer.read_bytes()),
                },
            },
            "inventory_binding": {
                "bundle_path": str(self.inventory_bundle.relative_to(self.root)),
                "receipt_filename": "receipt.json",
                "receipt_sha256": MODULE.sha256_bytes(receipt_bytes),
                "receipt_payload_sha256": self.coordinator_receipt[
                    "receipt_payload_sha256"
                ],
                "execution_git_head": self.coordinator_receipt["execution_git_head"],
                "inventory_filename": "inventory.jsonl",
                "inventory_sha256": MODULE.sha256_bytes(inventory_bytes),
                "inventory_rows": len(self.inventory_rows),
                "candidate_only_rows": 3,
            },
            "sources": {
                "replay_training_original": {
                    "path": str(self.replay_path.relative_to(self.root)),
                    "sha256": MODULE.sha256_bytes(self.replay_path.read_bytes()),
                    "row_count": len(self.replay_rows),
                    "input_field": "input",
                    "output_field": "output",
                },
                "historical_type_b_all": {
                    "path": str(self.reference_path.relative_to(self.root)),
                    "sha256": MODULE.sha256_bytes(self.reference_path.read_bytes()),
                    "row_count": len(self.reference_rows),
                    "input_field": "asr_input",
                    "output_field": "expected_output",
                },
            },
            "embedding": {
                "repo_id": "synthetic/embedding-model",
                "revision": self.model_revision,
                **model,
                "embedding_dimension": 8,
                "pooling": "last_token",
                "prompt_name": "document",
                "device": "synthetic",
                "model_dtype": "float32",
                "output_precision": "float32",
                "normalize_embeddings": True,
                "max_seq_length": 128,
                "batch_size": 2,
                "comparison_batch_size": 2,
                "comparison_axes": list(MODULE.COMPARISON_AXES),
                "score_decimals": 6,
                "top_k": 3,
                "runtime_versions": {"synthetic_backend": "1"},
            },
            "policy": {
                "candidate_selector": "candidate_only",
                "neighbor_queue_scope": "all_candidates",
                "embedding_auto_approval": False,
                "semantic_family_approval": "pending",
                "meaning_safety_approval": "pending",
                "native_editorial_approval": "pending",
                "training_eligible": False,
                "training_export_enabled": False,
                "tracked_output_contains_private_text_or_raw_ids": False,
            },
            "expected_counts": {
                "inventory_rows": len(self.inventory_rows),
                "candidate_only_rows": 3,
                "reference_rows": len(self.reference_rows),
                "full_review_queue_rows": 3,
                "training_eligible_rows": 0,
            },
        }
        self.contract.write_text(
            json.dumps(contract, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )

    def _build(
        self, output_name: str = "semantic-full", smoke_candidates: int | None = None
    ) -> tuple[Path, dict[str, object]]:
        output = self.output_parent / output_name
        receipt = MODULE.build_bundle(
            self.contract,
            self.inventory_bundle,
            self.model_dir,
            output,
            self.expected_head,
            smoke_candidates=smoke_candidates,
            repo_root=self.root,
            script_path=self.builder,
            backend_factory=FakeEmbeddingBackend,
        )
        self.trusted_receipts[output] = MODULE.sha256_bytes(
            (output / MODULE.RECEIPT_FILENAME).read_bytes()
        )
        return output, receipt

    def _validate(
        self, output: Path, trusted_receipt_sha256: str | None = None
    ) -> dict[str, object]:
        return MODULE.validate_published_bundle(
            self.contract,
            self.inventory_bundle,
            self.model_dir,
            output,
            trusted_receipt_sha256=(
                trusted_receipt_sha256 or self.trusted_receipts[output]
            ),
            repo_root=self.root,
            script_path=self.builder,
        )

    def test_builds_metadata_only_pending_review_queue(self) -> None:
        output, receipt = self._build()
        rows = [
            json.loads(line)
            for line in (output / MODULE.QUEUE_FILENAME)
            .read_text(encoding="utf-8")
            .splitlines()
        ]
        self.assertEqual(len(rows), 3)
        self.assertEqual(receipt["run_scope"]["mode"], "full")
        self.assertEqual(receipt["approval_gates"]["training_export"], "prohibited")
        self.assertTrue(all(row["training_eligible"] is False for row in rows))
        self.assertTrue(
            all(row["semantic_family_approval"] == "pending" for row in rows)
        )
        self.assertTrue(
            all(
                set(neighbor["component_cosines"]) == set(MODULE.COMPARISON_AXES)
                for row in rows
                for neighbor in row["neighbors"]
            )
        )
        self.assertEqual(self._validate(output), receipt)

    def test_is_byte_deterministic_and_smoke_is_explicitly_incomplete(self) -> None:
        first, _ = self._build("first-full")
        second, _ = self._build("second-full")
        for filename in (MODULE.QUEUE_FILENAME, MODULE.RECEIPT_FILENAME):
            self.assertEqual(
                (first / filename).read_bytes(), (second / filename).read_bytes()
            )
        smoke, receipt = self._build("smoke", smoke_candidates=1)
        self.assertEqual(receipt["run_scope"]["mode"], "smoke")
        self.assertFalse(receipt["run_scope"]["complete_candidate_population"])
        self.assertEqual(receipt["artifact"]["row_count"], 1)
        self._validate(smoke)

    def test_bundle_does_not_publish_synthetic_source_values(self) -> None:
        output, _ = self._build()
        published = b"".join(path.read_bytes() for path in output.iterdir())
        values = {
            str(value).encode("utf-8")
            for row in [*self.replay_rows, *self.reference_rows]
            for value in row.values()
        }
        self.assertTrue(values)
        self.assertTrue(all(value not in published for value in values))

    def test_source_inventory_receipt_and_model_tamper_fail_closed(self) -> None:
        output, _ = self._build()
        cases = (
            self.replay_path,
            self.inventory_bundle / "inventory.jsonl",
            self.inventory_bundle / "receipt.json",
            self.model_dir / "weights.bin",
        )
        for path in cases:
            original = path.read_bytes()
            path.write_bytes(original + b"tamper")
            with self.assertRaises(ValueError):
                self._validate(output)
            path.write_bytes(original)
        self._validate(output)

    def test_validator_rejects_fabricated_approval_and_artifact_count(self) -> None:
        output, _ = self._build()
        receipt_path = output / MODULE.RECEIPT_FILENAME
        original = json.loads(receipt_path.read_text(encoding="utf-8"))
        for mutate in (
            lambda value: value["approval_gates"].__setitem__(
                "manual_semantic_family_review", "approved"
            ),
            lambda value: value["artifact"].__setitem__("row_count", 999),
        ):
            receipt = json.loads(json.dumps(original))
            mutate(receipt)
            receipt.pop("receipt_payload_sha256")
            receipt["receipt_payload_sha256"] = MODULE.sha256_bytes(
                MODULE.canonical_json(receipt)
            )
            receipt_path.write_bytes(MODULE.canonical_json(receipt))
            with self.assertRaises(ValueError):
                self._validate(
                    output,
                    MODULE.sha256_bytes(receipt_path.read_bytes()),
                )
        receipt_path.write_bytes(MODULE.canonical_json(original))
        self._validate(output)

    def test_validator_rejects_unknown_candidate_and_reference_fingerprints(self) -> None:
        output, _ = self._build()
        queue_path = output / MODULE.QUEUE_FILENAME
        receipt_path = output / MODULE.RECEIPT_FILENAME
        original_queue = queue_path.read_bytes()
        original_receipt = receipt_path.read_bytes()
        for field_path in ("candidate", "reference"):
            rows = [json.loads(line) for line in original_queue.splitlines()]
            if field_path == "candidate":
                rows[0]["candidate_row_fingerprint_sha256"] = "f" * 64
            else:
                rows[0]["neighbors"][0]["reference_row_fingerprint_sha256"] = "f" * 64
            queue_bytes = encode_rows(rows)
            receipt = json.loads(original_receipt)
            receipt["artifact"]["sha256"] = MODULE.sha256_bytes(queue_bytes)
            receipt.pop("receipt_payload_sha256")
            receipt["receipt_payload_sha256"] = MODULE.sha256_bytes(
                MODULE.canonical_json(receipt)
            )
            queue_path.write_bytes(queue_bytes)
            receipt_path.write_bytes(MODULE.canonical_json(receipt))
            with self.assertRaises(ValueError):
                self._validate(
                    output,
                    MODULE.sha256_bytes(receipt_path.read_bytes()),
                )
        queue_path.write_bytes(original_queue)
        receipt_path.write_bytes(original_receipt)
        self._validate(output)

    def test_dirty_git_and_receipt_write_failure_fail_closed(self) -> None:
        original_builder = self.builder.read_bytes()
        self.builder.write_bytes(original_builder + b"\n# dirty\n")
        with self.assertRaises(ValueError):
            self._build("dirty-git")
        self.builder.write_bytes(original_builder)

        real_write = MODULE.write_exclusive

        def fail_receipt(path: Path, value: bytes) -> None:
            if path.name == MODULE.RECEIPT_FILENAME:
                raise OSError("synthetic receipt write failure")
            real_write(path, value)

        output = self.output_parent / "failed-publication"
        with mock.patch.object(MODULE, "write_exclusive", side_effect=fail_receipt):
            with self.assertRaises(OSError):
                self._build("failed-publication")
        self.assertFalse(output.exists())

    def test_trusted_receipt_rejects_coherent_score_forgery_and_extra_files(self) -> None:
        output, _ = self._build()
        queue_path = output / MODULE.QUEUE_FILENAME
        receipt_path = output / MODULE.RECEIPT_FILENAME
        original_queue = queue_path.read_bytes()
        original_receipt = receipt_path.read_bytes()
        rows = [json.loads(line) for line in original_queue.splitlines()]
        neighbor = rows[0]["neighbors"][0]
        axis = next(
            name
            for name, score in neighbor["component_cosines"].items()
            if score < neighbor["max_cosine"]
        )
        neighbor["component_cosines"][axis] = round(
            neighbor["component_cosines"][axis] - 0.000001, 6
        )
        queue_bytes = encode_rows(rows)
        receipt = json.loads(original_receipt)
        receipt["artifact"]["sha256"] = MODULE.sha256_bytes(queue_bytes)
        receipt.pop("receipt_payload_sha256")
        receipt["receipt_payload_sha256"] = MODULE.sha256_bytes(
            MODULE.canonical_json(receipt)
        )
        queue_path.write_bytes(queue_bytes)
        receipt_path.write_bytes(MODULE.canonical_json(receipt))
        with self.assertRaises(ValueError):
            self._validate(output)
        queue_path.write_bytes(original_queue)
        receipt_path.write_bytes(original_receipt)
        extra = output / "undeclared-private-export.jsonl"
        extra.write_bytes(b"synthetic undeclared artifact")
        with self.assertRaises(ValueError):
            self._validate(output)
        extra.unlink()
        self._validate(output)

    def test_cli_error_is_generic_and_does_not_echo_source_content(self) -> None:
        sentinel = "synthetic-secret-cli-sentinel"
        original = self.replay_path.read_bytes()
        self.replay_path.write_bytes(original + sentinel.encode("utf-8"))
        output = self.output_parent / "cli-failure"
        result = subprocess.run(
            [
                sys.executable,
                str(self.builder),
                "--contract",
                str(self.contract),
                "--inventory-bundle",
                str(self.inventory_bundle),
                "--model-dir",
                str(self.model_dir),
                "--out-bundle",
                str(output),
                "--expected-git-head",
                self.expected_head,
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr.strip(), "semantic screening failed closed")
        self.assertNotIn(sentinel, result.stderr)


def contains_any_pattern(patterns: set[bytes], haystack: bytes) -> bool:
    """Return whether any byte pattern occurs, without reporting private values."""
    transitions: list[dict[int, int]] = [{}]
    failures = [0]
    outputs = [False]
    for pattern in patterns:
        state = 0
        for byte in pattern:
            next_state = transitions[state].get(byte)
            if next_state is None:
                next_state = len(transitions)
                transitions[state][byte] = next_state
                transitions.append({})
                failures.append(0)
                outputs.append(False)
            state = next_state
        outputs[state] = True
    pending: deque[int] = deque()
    for state in transitions[0].values():
        pending.append(state)
    while pending:
        state = pending.popleft()
        for byte, child in transitions[state].items():
            pending.append(child)
            failure = failures[state]
            while failure and byte not in transitions[failure]:
                failure = failures[failure]
            failures[child] = transitions[failure].get(byte, 0)
            outputs[child] = outputs[child] or outputs[failures[child]]
    state = 0
    for byte in haystack:
        while state and byte not in transitions[state]:
            state = failures[state]
        state = transitions[state].get(byte, 0)
        if outputs[state]:
            return True
    return False


@unittest.skipUnless(
    os.environ.get("EG1_REPLAY_PRIVATE_INTEGRATION") == "1",
    "set EG1_REPLAY_PRIVATE_INTEGRATION=1 for the local private-artifact gate",
)
class RealPrivateSemanticScreenIntegration(unittest.TestCase):
    def test_full_bundle_is_bound_metadata_only_and_still_pending(self) -> None:
        repo_root = MODULE.REPO_ROOT
        inventory_bundle = repo_root / "scripts/eval/runs/eg1-replay-inventory-v1"
        model_dir = Path(os.environ["EG1_REPLAY_MODEL_DIR"])
        bundle = Path(os.environ["EG1_REPLAY_SEMANTIC_BUNDLE"])
        receipt = MODULE.validate_published_bundle(
            MODULE.DEFAULT_CONTRACT,
            inventory_bundle,
            model_dir,
            bundle,
            trusted_receipt_sha256=PRODUCTION_FULL_RECEIPT_SHA256,
            repo_root=repo_root,
            script_path=MODULE.SCRIPT_PATH,
        )
        self.assertEqual(receipt["run_scope"]["mode"], "full")
        self.assertEqual(receipt["artifact"]["row_count"], 4051)
        self.assertEqual(receipt["approval_gates"]["training_eligible_rows"], 0)
        contract = json.loads(MODULE.DEFAULT_CONTRACT.read_text(encoding="utf-8"))
        private_values: set[bytes] = set()
        for source in contract["sources"].values():
            source_rows = MODULE.rows_from_bytes(
                repo_root.joinpath(source["path"]).read_bytes(), "source"
            )
            private_fields = {"id", source["input_field"], source["output_field"]}
            private_values.update(
                value.encode("utf-8")
                for row in source_rows
                for field, value in row.items()
                if field in private_fields and isinstance(value, str) and value
            )
        published = b"".join(
            (bundle / filename).read_bytes()
            for filename in (MODULE.QUEUE_FILENAME, MODULE.RECEIPT_FILENAME)
        )
        self.assertTrue(private_values)
        self.assertFalse(contains_any_pattern(private_values, published))


if __name__ == "__main__":
    unittest.main()
