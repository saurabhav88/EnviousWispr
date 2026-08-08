import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import numpy as np

EVAL_DIR = Path(__file__).resolve().parents[1]
if str(EVAL_DIR) not in sys.path:
    sys.path.insert(0, str(EVAL_DIR))

import scan_eg1_multilingual_development_leakage as scanner


CONTRACT = scanner.validate_contract(json.loads(scanner.DEFAULT_CONTRACT.read_text()))


def producer_repo(root: Path, scanner_source: str) -> tuple[str, str, dict[str, bytes], str]:
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
    subprocess.run(
        ["git", "config", "user.email", "test@example.invalid"], cwd=root, check=True
    )
    contents = {
        scanner.PRODUCER_CONTROL_PATHS["scanner_sha256"]: scanner_source.encode(),
        scanner.REPLAY_BACKEND_PATH: b"REPLAY = 'producer'\n",
        scanner.V2_PATH_RELATIVE: b"V2 = 'producer'\n",
        scanner.REPLAY_INVENTORY_PATH_RELATIVE: b"INVENTORY = 'producer'\n",
        scanner.REPLAY_NORMALIZER_PATH_RELATIVE: b"NORMALIZER = 'producer'\n",
    }
    contract_relative = "scripts/eval/contracts/test-scanner-contract.json"
    bindings = {
        "replay_backend_binding": scanner.REPLAY_BACKEND_PATH,
        "multilingual_validator_binding": scanner.V2_PATH_RELATIVE,
        "replay_inventory_binding": scanner.REPLAY_INVENTORY_PATH_RELATIVE,
        "replay_normalizer_binding": scanner.REPLAY_NORMALIZER_PATH_RELATIVE,
    }
    contract = {
        field: {
            "path": relative,
            "sha256": scanner.sha256_bytes(contents[relative]),
        }
        for field, relative in bindings.items()
    }
    contents[contract_relative] = scanner.canonical_json(contract)
    for relative, data in contents.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    subprocess.run(["git", "add", "."], cwd=root, check=True)
    subprocess.run(["git", "commit", "-qm", "producer"], cwd=root, check=True)
    producer = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True
    ).strip()
    (root / scanner.V2_PATH_RELATIVE).write_bytes(b"V2 = 'descendant'\n")
    subprocess.run(["git", "add", "."], cwd=root, check=True)
    subprocess.run(["git", "commit", "-qm", "descendant"], cwd=root, check=True)
    descendant = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True
    ).strip()
    return producer, descendant, contents, contract_relative


def producer_receipt(
    producing_head: str,
    contents: dict[str, bytes],
    contract_relative: str,
) -> dict:
    controls = {
        label: scanner.sha256_bytes(contents[relative])
        for label, relative in {
            "contract_sha256": contract_relative,
            **scanner.PRODUCER_CONTROL_PATHS,
        }.items()
    }
    status = "synthetic_not_quality_evidence"
    return {
        "status": status,
        "contract_sha256": controls["contract_sha256"],
        "scanner_provenance": {
            "scanner_id": scanner.SCHEMA_VERSION,
            "scanner_path": scanner.PRODUCER_CONTROL_PATHS["scanner_sha256"],
            "scanner_sha256": controls["scanner_sha256"],
            "replay_backend_path": scanner.REPLAY_BACKEND_PATH,
            "replay_backend_sha256": controls["replay_backend_sha256"],
            "replay_inventory_path": scanner.REPLAY_INVENTORY_PATH_RELATIVE,
            "replay_inventory_sha256": controls["replay_inventory_sha256"],
            "replay_normalizer_path": scanner.REPLAY_NORMALIZER_PATH_RELATIVE,
            "replay_normalizer_sha256": controls["replay_normalizer_sha256"],
            "multilingual_validator_path": scanner.V2_PATH_RELATIVE,
            "multilingual_validator_sha256": controls["multilingual_validator_sha256"],
            "producing_git_head": producing_head,
            "execution_status": status,
            "operator_attested_execution": False,
            "assurance_scope": "development_only_nonrelease",
        },
    }


class FakeEmbedding:
    runtime_versions = {"fake": "1"}

    def encode_documents(self, texts):
        rows = []
        for text in texts:
            value = np.array([len(text), sum(map(ord, text)) % 97, 1.0], dtype=np.float32)
            rows.append(value / np.linalg.norm(value))
        return np.asarray(rows)


class LeakageScannerTests(unittest.TestCase):
    def test_true_token_and_character_ngrams(self):
        self.assertEqual(scanner.token_ngrams("one two three four", 3), {("one", "two", "three"), ("two", "three", "four")})
        self.assertEqual(scanner.character_ngrams("abcd", 3), {"abc", "bcd"})

    def test_streamed_jaccard_counts_every_boundary_violation(self):
        maximum, violations = scanner.pairwise_jaccard_stats(
            ["one two three", "one two four"],
            ["one two three", "one two four"],
            width=2,
            characters=False,
            threshold=1.0,
        )
        self.assertEqual(maximum, 1.0)
        self.assertEqual(violations, 2)

    def test_unrelated_short_texts_do_not_score_perfectly(self):
        maximum, violations = scanner.pairwise_jaccard_stats(["a"], ["b"], width=3, characters=False, threshold=0.8)
        self.assertEqual(maximum, 0.0)
        self.assertEqual(violations, 0)

    def test_shared_source_parser_rejects_unsafe_identity(self):
        with self.assertRaisesRegex(ValueError, "invalid source identity"):
            scanner.parse_bound_specs(["training:../unsafe=/tmp/nope"], "source")

    def test_threshold_boundary_fails_and_just_below_passes(self):
        self.assertEqual(scanner.threshold_status(0.8, 0.8), "failed")
        self.assertEqual(scanner.threshold_status(0.799999, 0.8), "passed")

    def test_contract_tamper_is_rejected(self):
        tampered = json.loads(scanner.DEFAULT_CONTRACT.read_text())
        tampered["embedding"]["revision"] = "forged"
        with self.assertRaisesRegex(ValueError, "identity changed"):
            scanner.validate_contract(tampered)

    def test_replay_backend_binding_tamper_is_rejected(self):
        tampered = json.loads(scanner.DEFAULT_CONTRACT.read_text())
        tampered["replay_backend_binding"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "backend binding changed"):
            scanner.validate_contract(tampered)

    def test_multilingual_validator_binding_tamper_is_rejected(self):
        tampered = json.loads(scanner.DEFAULT_CONTRACT.read_text())
        tampered["multilingual_validator_binding"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "validator binding changed"):
            scanner.validate_contract(tampered)

    def test_pinned_loader_rejects_shadow_bytes_before_execution(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            shadow = Path(directory) / "multilingual_benchmark_v2.py"
            shadow.write_text("raise RuntimeError('must not execute')\n")
            with self.assertRaisesRegex(RuntimeError, "differs before import"):
                scanner.load_pinned_module("forged_v2", shadow, scanner.V2_SHA256)

    def test_pinned_loader_replaces_unauthenticated_cross_suite_cache(self):
        import hashlib
        import tempfile
        import types

        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "pinned_dependency.py"
            source.write_text("VALUE = 'trusted'\n", encoding="utf-8")
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            name = "eg1_cross_suite_cached_dependency_test"
            cached = types.ModuleType(name)
            cached.__file__ = str(source)
            cached.VALUE = "untrusted"
            sys.modules[name] = cached
            try:
                loaded = scanner.load_pinned_module(name, source, digest)
            finally:
                sys.modules.pop(name, None)
            self.assertIsNot(loaded, cached)
            self.assertEqual(loaded.VALUE, "trusted")
            self.assertEqual(loaded._EG1_AUTHENTICATED_SOURCE_SHA256, digest)

    def test_replay_import_closure_bindings_reject_tamper(self):
        for field in ("replay_inventory_binding", "replay_normalizer_binding"):
            tampered = json.loads(scanner.DEFAULT_CONTRACT.read_text())
            tampered[field]["sha256"] = "0" * 64
            with self.assertRaisesRegex(ValueError, "replay (inventory|normalizer) binding changed"):
                scanner.validate_contract(tampered)

    def test_unicode_exact_uses_canonical_normalization(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.jsonl"
            source.write_text('{"input":"Café mañana"}\n', encoding="utf-8")
            results, status = scanner.scan(
                contract=CONTRACT,
                benchmark_rows=[{"asr_input": "CAFE\u0301 man\u0303ana", "gold_output": "other"}],
                sources={("training", "train"): source},
                backend_name="synthetic_test_only",
                embedding_backend=scanner.SyntheticEmbeddingBackend(),
            )
            self.assertEqual(status, "failed")
            self.assertEqual(results[0]["methods"]["exact_normalized"]["matches"], 1)

    def test_synthetic_backend_computes_deterministically(self):
        backend = scanner.SyntheticEmbeddingBackend()
        first = backend.encode_documents(["same text", "different"])
        second = backend.encode_documents(["same text", "different"])
        np.testing.assert_array_equal(first, second)
        self.assertAlmostEqual(float(first[0] @ first[0]), 1.0, places=6)

    def test_raw_sources_run_all_four_methods_and_synthetic_is_nonquality(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            training = root / "training.jsonl"
            prior = root / "prior.jsonl"
            training.write_text('{"input":"unrelated alpha sentence","output":"unrelated beta sentence"}\n')
            prior.write_text('{"asr_input":"separate gamma phrase","gold_output":"separate delta phrase"}\n')
            results, status = scanner.scan(
                contract=CONTRACT,
                benchmark_rows=[{"asr_input": "unique spoken request", "gold_output": "Unique spoken request."}],
                sources={("training", "train"): training, ("prior_eval", "prior"): prior},
                backend_name="synthetic_test_only",
                embedding_backend=scanner.SyntheticEmbeddingBackend(),
            )
            self.assertEqual(status, "synthetic_not_quality_evidence")
            self.assertEqual(set(results[0]["methods"]), set(scanner.METHODS))
            self.assertIsInstance(results[0]["methods"]["embedding_cosine"]["maximum_score"], float)

    def test_production_remains_noncertifying_without_calibrated_thresholds(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.jsonl"
            source.write_text('{"input":"totally separate source"}\n')
            results, status = scanner.scan(
                contract=CONTRACT,
                benchmark_rows=[{"asr_input": "candidate text", "gold_output": "Candidate text."}],
                sources={("training", "train"): source},
                backend_name="production",
                embedding_backend=FakeEmbedding(),
            )
            self.assertEqual(status, "calibration_required_noncertifying")
            self.assertEqual(results[0]["methods"]["embedding_cosine"]["status"], "calibration_required")
            self.assertIsNone(results[0]["methods"]["embedding_cosine"]["threshold"])

    def test_registry_fuzzy_methods_require_authenticated_zero_raw_text(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            registry = Path(directory) / "registry.jsonl"
            registry.write_text('{"normalized_sha256":"' + "a" * 64 + '"}\n')
            results, _ = scanner.scan(
                contract=CONTRACT,
                benchmark_rows=[{"asr_input": "candidate text", "gold_output": "Candidate text."}],
                sources={("blocked_text_hash_registry", "hashes"): registry},
                backend_name="synthetic_test_only",
                embedding_backend=scanner.SyntheticEmbeddingBackend(),
            )
            method = results[0]["methods"]["embedding_cosine"]
            self.assertEqual(method, {"status": "not_applicable_no_raw_text", "authenticated_raw_text_count": 0})

    def test_blocked_hash_registry_detects_normalized_exact_match(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            registry = Path(directory) / "registry.jsonl"
            digest = scanner.sha256_bytes(scanner.v2.normalize_text("Candidate TEXT").encode())
            registry.write_text(json.dumps({"normalized_sha256": digest}) + "\n")
            results, status = scanner.scan(
                contract=CONTRACT,
                benchmark_rows=[{"asr_input": "candidate text", "gold_output": "other output"}],
                sources={("blocked_text_hash_registry", "hashes"): registry},
                backend_name="synthetic_test_only",
                embedding_backend=scanner.SyntheticEmbeddingBackend(),
            )
            self.assertEqual(status, "failed")
            self.assertEqual(results[0]["methods"]["exact_normalized"]["matches"], 1)

    def test_source_evidence_binds_identity_hash_count_and_receipt_hash(self):
        import hashlib
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = {}
            receipts = {}
            entries = []
            for role in scanner.v2.REQUIRED_FROZEN_LEAKAGE_ROLES:
                source = root / f"{role}.jsonl"
                source.write_text('{"value":"alpha"}\n')
                source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
                receipt = root / f"{role}-receipt.json"
                receipt.write_text(json.dumps({"schema_version": scanner.LEAKAGE_SOURCE_RECEIPT_SCHEMA, "status": "exhaustive_source_operator_attested", "role": role, "name": role, "source_sha256": source_sha, "record_count": 1, "producing_git_head": "c" * 40, "producer_id": "producer-1", "operator_attested_exhaustive": True, "candidate_model_output_seen": False, "assurance_scope": scanner.ASSURANCE_SCOPE}))
                sources[(role, role)] = source
                receipts[(role, role)] = receipt
                entries.append({"role": role, "name": role, "sha256": source_sha, "record_count": 1, "producer_receipt_sha256": hashlib.sha256(receipt.read_bytes()).hexdigest()})
            inventory = root / "inventory.json"
            inventory.write_text(json.dumps({"schema_version": scanner.LEAKAGE_INVENTORY_SCHEMA, "status": "exhaustive_source_inventory_operator_attested", "inventory_id": "inventory-1", "producing_git_head": "c" * 40, "operator_attested_exhaustive": True, "candidate_model_output_seen": False, "assurance_scope": scanner.ASSURANCE_SCOPE, "sources": entries}))
            with mock.patch.object(scanner, "require_git_ancestor"):
                scanner.validate_source_evidence(inventory, receipts, sources, "c" * 40)
                next(iter(receipts.values())).write_text("{}")
                with self.assertRaisesRegex(ValueError, "binding is stale|receipt hash is stale|producing Git head"):
                    scanner.validate_source_evidence(inventory, receipts, sources, "c" * 40)

    def test_receipt_serialization_is_deterministic(self):
        value = {"z": [3, 2, 1], "a": "é"}
        self.assertEqual(scanner.canonical_json(value), scanner.canonical_json(value))
        self.assertEqual(scanner.canonical_json(value), b'{"a":"\xc3\xa9","z":[3,2,1]}\n')

    def test_snapshot_detects_mid_scan_mutation(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "evidence.json"
            path.write_text("before")
            before = scanner.snapshot_files([path])
            path.write_text("after")
            self.assertNotEqual(before, scanner.snapshot_files([path]))

    def test_producer_closure_survives_descendant_control_update(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            producer, descendant, contents, contract_relative = producer_repo(
                repo, "CONTROL = 'producer'\n"
            )
            receipt = producer_receipt(producer, contents, contract_relative)
            with mock.patch.object(scanner, "REPO_ROOT", repo):
                closure = scanner.authenticate_producing_closure(
                    receipt,
                    producing_head=producer,
                    expected_head=descendant,
                    contract_relative=contract_relative,
                )
                self.assertEqual(
                    closure["controls"]["multilingual_validator_sha256"],
                    scanner.sha256_bytes(contents[scanner.V2_PATH_RELATIVE]),
                )
                self.assertNotEqual(
                    closure["blobs"][scanner.V2_PATH_RELATIVE],
                    (repo / scanner.V2_PATH_RELATIVE).read_bytes(),
                )

    def test_producer_hash_tamper_rejected_before_historical_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            producer, descendant, contents, contract_relative = producer_repo(
                repo, "CONTROL = 'producer'\n"
            )
            receipt = producer_receipt(producer, contents, contract_relative)
            receipt["scanner_provenance"]["scanner_sha256"] = "0" * 64
            with mock.patch.object(scanner, "REPO_ROOT", repo), mock.patch.object(
                scanner, "run_historical_receipt_verification"
            ) as execute, self.assertRaisesRegex(ValueError, "producer closure"):
                scanner.authenticate_producing_closure(
                    receipt,
                    producing_head=producer,
                    expected_head=descendant,
                    contract_relative=contract_relative,
                )
            execute.assert_not_called()

    def test_nonancestor_producer_rejected_before_historical_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            producer, descendant, contents, contract_relative = producer_repo(
                repo, "CONTROL = 'producer'\n"
            )
            tree = subprocess.check_output(
                ["git", "rev-parse", f"{producer}^{{tree}}"], cwd=repo, text=True
            ).strip()
            orphan = subprocess.check_output(
                ["git", "commit-tree", tree, "-m", "orphan"], cwd=repo, text=True
            ).strip()
            receipt = producer_receipt(orphan, contents, contract_relative)
            with mock.patch.object(scanner, "REPO_ROOT", repo), mock.patch.object(
                scanner, "run_historical_receipt_verification"
            ) as execute, self.assertRaisesRegex(ValueError, "not an ancestor"):
                scanner.authenticate_producing_closure(
                    receipt,
                    producing_head=orphan,
                    expected_head=descendant,
                    contract_relative=contract_relative,
                )
            execute.assert_not_called()

    def test_historical_runner_uses_captured_bytes_and_cleans_clone(self):
        historical_source = """
from pathlib import Path
def verify_receipt(receipt_path, sources, model_dir, **_kwargs):
    if Path(receipt_path).read_bytes() != b'captured-receipt':
        raise ValueError('historical runner observed mutable original')
    if next(iter(sources.values())).read_bytes() != b'captured-source':
        raise ValueError('historical runner observed mutable source')
    if (Path(model_dir) / 'weights.bin').read_bytes() != b'captured-model':
        raise ValueError('historical runner observed mutable model')
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "repo"
            repo.mkdir()
            producer, _descendant, contents, contract_relative = producer_repo(
                repo, historical_source
            )
            evidence = root / "evidence"
            evidence.mkdir()
            receipt = evidence / "receipt.json"
            benchmark = evidence / "benchmark.json"
            inventory = evidence / "inventory.json"
            blocked = evidence / "blocked.json"
            source = evidence / "source.jsonl"
            receipt.write_bytes(b"captured-receipt")
            benchmark.write_bytes(b"benchmark")
            inventory.write_bytes(b"inventory")
            blocked.write_bytes(b"blocked")
            source.write_bytes(b"captured-source")
            model = root / "model"
            model.mkdir()
            (model / "weights.bin").write_bytes(b"captured-model")
            captures = scanner.capture_files(
                [receipt, benchmark, inventory, blocked, source]
            )
            fixed_temporary = root / "historical-temp"
            fixed_temporary.mkdir()
            real_run = subprocess.run

            def swap_during_child(arguments, *args, **kwargs):
                if arguments[0] == sys.executable and "-I" in arguments:
                    receipt.write_bytes(b"attacker-receipt")
                    source.write_bytes(b"attacker-source")
                    (model / "weights.bin").write_bytes(b"attacker-model")
                    try:
                        return real_run(arguments, *args, **kwargs)
                    finally:
                        receipt.write_bytes(b"captured-receipt")
                        source.write_bytes(b"captured-source")
                        (model / "weights.bin").write_bytes(b"captured-model")
                return real_run(arguments, *args, **kwargs)

            with mock.patch.object(scanner, "REPO_ROOT", repo), mock.patch.object(
                scanner.tempfile, "mkdtemp", return_value=str(fixed_temporary)
            ), mock.patch.object(
                scanner.subprocess, "run", side_effect=swap_during_child
            ):
                scanner.run_historical_receipt_verification(
                    producing_head=producer,
                    producer_closure={"blobs": contents},
                    contract_relative=contract_relative,
                    receipt_path=receipt,
                    benchmark_path=benchmark,
                    sources={("training", "train"): source},
                    inventory_path=inventory,
                    source_receipt_paths={},
                    blocked_registry_receipt_path=blocked,
                    blocked_bundle_paths=[blocked],
                    model_dir=model,
                    evidence_captures=captures,
                    model_fingerprint={
                        "weights.bin": scanner.sha256_bytes(b"captured-model")
                    },
                    receipt_sha256=scanner.sha256_bytes(b"captured-receipt"),
                )
            self.assertFalse(fixed_temporary.exists())
            self.assertEqual(receipt.read_bytes(), b"captured-receipt")
            self.assertEqual(source.read_bytes(), b"captured-source")
            self.assertEqual((model / "weights.bin").read_bytes(), b"captured-model")

    def test_verify_receipt_dispatches_ancestor_to_historical_runner(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = {
                name: root / name
                for name in (
                    "receipt.json",
                    "benchmark.json",
                    "inventory.json",
                    "blocked.json",
                )
            }
            for path in files.values():
                path.write_text("{}\n", encoding="utf-8")
            receipt = {
                "schema_version": scanner.RECEIPT_SCHEMA_VERSION,
                "status": "synthetic_not_quality_evidence",
                "backend": "synthetic_test_only",
                "benchmark_sha256": "a" * 64,
                "benchmark_content_sha256": "a" * 64,
                "contract_sha256": "a" * 64,
                "source_inventory_sha256": "a" * 64,
                "blocked_registry_receipt_sha256": "a" * 64,
                "scanner_provenance": {"producing_git_head": "a" * 40},
                "embedding_runtime": {},
                "results": [],
                "contains_raw_text": False,
            }
            files["receipt.json"].write_bytes(scanner.canonical_json(receipt))
            controls = {"scanner_sha256": "b" * 64}
            closure = {"controls": {}, "blobs": {}}
            with mock.patch.object(
                scanner, "validate_git_controls", return_value=controls
            ), mock.patch.object(
                scanner, "require_git_ancestor"
            ), mock.patch.object(
                scanner, "authenticate_producing_closure", return_value=closure
            ) as authenticate, mock.patch.object(
                scanner,
                "run_historical_receipt_verification",
                side_effect=ValueError("leakage receipt is non-certifying"),
            ) as historical, self.assertRaisesRegex(ValueError, "non-certifying"):
                scanner.verify_receipt(
                    files["receipt.json"],
                    contract_path=scanner.DEFAULT_CONTRACT,
                    benchmark_path=files["benchmark.json"],
                    sources={},
                    inventory_path=files["inventory.json"],
                    source_receipt_paths={},
                    blocked_registry_receipt_path=files["blocked.json"],
                    expected_head="b" * 40,
                    model_dir=None,
                )
            self.assertEqual(authenticate.call_count, 2)
            historical.assert_called_once()

    def test_historical_dispatch_rejects_dirty_or_shadowed_current_controls(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q", "-b", "main"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=repo, check=True)
            subprocess.run(
                ["git", "config", "user.email", "test@example.invalid"],
                cwd=repo,
                check=True,
            )
            current_controls = {
                scanner.PRODUCER_CONTROL_PATHS["scanner_sha256"]: scanner.SCRIPT_PATH.read_bytes(),
                scanner.REPLAY_BACKEND_PATH: (scanner.REPO_ROOT / scanner.REPLAY_BACKEND_PATH).read_bytes(),
                scanner.V2_PATH_RELATIVE: (scanner.REPO_ROOT / scanner.V2_PATH_RELATIVE).read_bytes(),
                scanner.REPLAY_INVENTORY_PATH_RELATIVE: (scanner.REPO_ROOT / scanner.REPLAY_INVENTORY_PATH_RELATIVE).read_bytes(),
                scanner.REPLAY_NORMALIZER_PATH_RELATIVE: (scanner.REPO_ROOT / scanner.REPLAY_NORMALIZER_PATH_RELATIVE).read_bytes(),
                "scripts/eval/contracts/scanner.json": scanner.DEFAULT_CONTRACT.read_bytes(),
            }
            for relative, data in current_controls.items():
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "current"], cwd=repo, check=True)
            expected_head = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=repo, text=True
            ).strip()
            evidence = root / "evidence"
            evidence.mkdir()
            paths = {
                name: evidence / name
                for name in ("receipt.json", "benchmark.json", "inventory.json", "blocked.json")
            }
            for path in paths.values():
                path.write_text("{}\n", encoding="utf-8")
            receipt = {
                "schema_version": scanner.RECEIPT_SCHEMA_VERSION,
                "status": "synthetic_not_quality_evidence",
                "backend": "synthetic_test_only",
                "benchmark_sha256": "a" * 64,
                "benchmark_content_sha256": "a" * 64,
                "contract_sha256": "a" * 64,
                "source_inventory_sha256": "a" * 64,
                "blocked_registry_receipt_sha256": "a" * 64,
                "scanner_provenance": {"producing_git_head": "a" * 40},
                "embedding_runtime": {},
                "results": [],
                "contains_raw_text": False,
            }
            paths["receipt.json"].write_bytes(scanner.canonical_json(receipt))
            scanner_path = repo / scanner.PRODUCER_CONTROL_PATHS["scanner_sha256"]
            contract_path = repo / "scripts/eval/contracts/scanner.json"

            def verify() -> None:
                scanner.verify_receipt(
                    paths["receipt.json"],
                    contract_path=contract_path,
                    benchmark_path=paths["benchmark.json"],
                    sources={},
                    inventory_path=paths["inventory.json"],
                    source_receipt_paths={},
                    blocked_registry_receipt_path=paths["blocked.json"],
                    expected_head=expected_head,
                    model_dir=None,
                )

            with mock.patch.object(scanner, "REPO_ROOT", repo), mock.patch.object(
                scanner, "SCRIPT_PATH", scanner_path
            ), mock.patch.object(
                scanner, "authenticate_producing_closure"
            ) as authenticate, mock.patch.object(
                scanner, "run_historical_receipt_verification"
            ) as historical:
                scanner_path.write_bytes(scanner_path.read_bytes() + b"# dirty\n")
                with self.assertRaisesRegex(ValueError, "tracked worktree must be clean"):
                    verify()
                scanner_path.write_bytes(
                    current_controls[scanner.PRODUCER_CONTROL_PATHS["scanner_sha256"]]
                )
                shadow = repo / "scripts/eval/untracked_shadow.py"
                shadow.write_text("raise RuntimeError('shadow')\n", encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "untracked scripts/eval Python shadow"):
                    verify()
            authenticate.assert_not_called()
            historical.assert_not_called()

    def test_all_candidate_source_text_field_combinations_are_scanned(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.jsonl"
            source.write_text('{"input":"candidate gold","output":"candidate asr"}\n')
            results, status = scanner.scan(
                contract=CONTRACT,
                benchmark_rows=[{"asr_input": "candidate asr", "gold_output": "candidate gold"}],
                sources={("training", "train"): source},
                backend_name="synthetic_test_only",
                embedding_backend=scanner.SyntheticEmbeddingBackend(),
            )
            self.assertEqual(status, "failed")
            self.assertEqual(results[0]["methods"]["exact_normalized"]["matches"], 2)
            self.assertEqual(results[0]["methods"]["exact_normalized"]["comparison_count"], 4)

    def test_verify_receipt_recomputes_and_rejects_coherent_forgery(self):
        import hashlib
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            benchmark = root / "benchmark.json"
            benchmark.write_text(json.dumps([{"case_id": "case-1", "asr_input": "candidate", "gold_output": "Candidate."}]))
            source = root / "source.jsonl"
            source.write_text('{"input":"unrelated alpha","output":"unrelated beta"}\n')
            source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
            source_receipt = root / "source-receipt.json"
            source_receipt.write_text(json.dumps({"role": "training", "name": "train", "source_sha256": source_sha, "record_count": 1}))
            inventory = root / "inventory.json"
            inventory.write_text(json.dumps({"operator_attested_exhaustive": True, "sources": [{"role": "training", "name": "train", "sha256": source_sha, "record_count": 1, "producer_receipt_sha256": hashlib.sha256(source_receipt.read_bytes()).hexdigest()}]}))
            blocked = root / "blocked.json"
            blocked.write_text("{}")
            sources = {("training", "train"): source}
            results, status = scanner.scan(contract=CONTRACT, benchmark_rows=scanner.read_records(benchmark, "benchmark"), sources=sources, backend_name="synthetic_test_only", embedding_backend=scanner.SyntheticEmbeddingBackend())
            controls = {"scanner_sha256": "a" * 64, "contract_sha256": scanner.sha256_bytes(scanner.DEFAULT_CONTRACT.read_bytes()), "replay_backend_sha256": scanner.REPLAY_BACKEND_SHA256, "replay_inventory_sha256": scanner.REPLAY_INVENTORY_SHA256, "replay_normalizer_sha256": scanner.REPLAY_NORMALIZER_SHA256, "multilingual_validator_sha256": scanner.V2_SHA256}
            receipt_value = {
                "schema_version": scanner.RECEIPT_SCHEMA_VERSION,
                "status": status,
                "backend": "synthetic_test_only",
                "benchmark_sha256": hashlib.sha256(benchmark.read_bytes()).hexdigest(),
                "benchmark_content_sha256": scanner.v2.benchmark_content_sha256(scanner.read_records(benchmark, "benchmark")),
                "contract_sha256": controls["contract_sha256"],
                "source_inventory_sha256": hashlib.sha256(inventory.read_bytes()).hexdigest(),
                "blocked_registry_receipt_sha256": hashlib.sha256(blocked.read_bytes()).hexdigest(),
                "results": results,
                "scanner_provenance": {"scanner_id": scanner.SCHEMA_VERSION, "scanner_path": str(scanner.SCRIPT_PATH.relative_to(scanner.REPO_ROOT)), "scanner_sha256": controls["scanner_sha256"], "replay_backend_path": scanner.REPLAY_BACKEND_PATH, "replay_backend_sha256": controls["replay_backend_sha256"], "replay_inventory_path": scanner.REPLAY_INVENTORY_PATH_RELATIVE, "replay_inventory_sha256": controls["replay_inventory_sha256"], "replay_normalizer_path": scanner.REPLAY_NORMALIZER_PATH_RELATIVE, "replay_normalizer_sha256": controls["replay_normalizer_sha256"], "multilingual_validator_path": scanner.V2_PATH_RELATIVE, "multilingual_validator_sha256": controls["multilingual_validator_sha256"], "producing_git_head": "d" * 40, "execution_status": status, "operator_attested_execution": False, "assurance_scope": "development_only_nonrelease"},
                "embedding_runtime": {"model_tree": None, "runtime_versions": scanner.SyntheticEmbeddingBackend.runtime_versions},
                "contains_raw_text": False,
            }
            receipt = root / "receipt.json"
            receipt.write_bytes(scanner.canonical_json(receipt_value))
            kwargs = dict(contract_path=scanner.DEFAULT_CONTRACT, benchmark_path=benchmark, sources=sources, inventory_path=inventory, source_receipt_paths={("training", "train"): source_receipt}, blocked_registry_receipt_path=blocked, expected_head="d" * 40, model_dir=None)
            with mock.patch.object(scanner, "validate_git_controls", return_value=controls) as git_controls, mock.patch.object(scanner, "require_git_ancestor"), mock.patch.object(scanner, "validate_source_evidence"), mock.patch.object(scanner, "validate_blocked_receipt_path"):
                with self.assertRaisesRegex(ValueError, "non-certifying"):
                    scanner.verify_receipt(receipt, **kwargs)
                git_controls.assert_any_call("d" * 40, scanner.DEFAULT_CONTRACT)
                receipt_value["results"][0]["methods"]["exact_normalized"]["matches"] = 99
                receipt.write_bytes(scanner.canonical_json(receipt_value))
                with self.assertRaisesRegex(ValueError, "recomputation differs"):
                    scanner.verify_receipt(receipt, **kwargs)

    def test_verify_receipt_rejects_unknown_schema_field(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "receipt.json"
            receipt.write_text(json.dumps({"schema_version": scanner.RECEIPT_SCHEMA_VERSION, "contains_raw_text": False, "unexpected": True}))
            with mock.patch.object(scanner, "validate_git_controls", return_value={"scanner_sha256": "a" * 64, "contract_sha256": "b" * 64}), mock.patch.object(scanner, "validate_source_evidence"):
                with self.assertRaisesRegex(ValueError, "schema is invalid"):
                    scanner.verify_receipt(receipt, contract_path=scanner.DEFAULT_CONTRACT, benchmark_path=receipt, sources={}, inventory_path=receipt, source_receipt_paths={}, blocked_registry_receipt_path=receipt, expected_head="c" * 40, model_dir=None)

    def test_verify_production_rejects_model_tree_tamper_before_backend_load(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = root / "receipt.json"
            receipt.write_text(json.dumps({
                "schema_version": scanner.RECEIPT_SCHEMA_VERSION,
                "status": "calibration_required_noncertifying",
                "backend": "production",
                "benchmark_sha256": "a" * 64,
                "benchmark_content_sha256": "a" * 64,
                "contract_sha256": "b" * 64,
                "source_inventory_sha256": "a" * 64,
                "blocked_registry_receipt_sha256": "a" * 64,
                "scanner_provenance": {"producing_git_head": "c" * 40},
                "embedding_runtime": {},
                "results": [],
                "contains_raw_text": False,
            }))
            with mock.patch.object(scanner, "validate_git_controls", return_value={"scanner_sha256": "a" * 64, "contract_sha256": "b" * 64}), mock.patch.object(scanner, "require_git_ancestor"), mock.patch.object(scanner, "validate_source_evidence"):
                with self.assertRaisesRegex(ValueError, "model tree changed"):
                    scanner.verify_receipt(receipt, contract_path=scanner.DEFAULT_CONTRACT, benchmark_path=receipt, sources={}, inventory_path=receipt, source_receipt_paths={}, blocked_registry_receipt_path=receipt, expected_head="c" * 40, model_dir=root)

    def test_blocked_v2_reopen_is_bounded_by_captured_bytes(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "blocked.json"
            original = json.dumps({"execution_git_head": "c" * 40}).encode()
            path.write_bytes(original)
            def mutate(*args, **kwargs):
                path.write_text(json.dumps({"execution_git_head": "c" * 40, "changed": True}))
            with mock.patch.object(scanner, "require_git_ancestor"), mock.patch.object(scanner.v2, "validate_blocked_registry_receipt", side_effect=mutate):
                with self.assertRaisesRegex(ValueError, "changed during"):
                    scanner.validate_blocked_receipt_path(path, original, [], "d" * 40)

    def test_publication_failure_removes_empty_dir_and_retry_succeeds(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "bundle"
            with self.assertRaisesRegex(ValueError, "mutation"):
                scanner.publish_receipt(out, b"{}\n", lambda: (_ for _ in ()).throw(ValueError("mutation")))
            self.assertFalse(out.exists())
            scanner.publish_receipt(out, b"{}\n", lambda: None)
            self.assertEqual((out / "receipt.json").read_bytes(), b"{}\n")

    def test_publication_does_not_delete_unowned_race_winner(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "bundle"
            out.mkdir()
            marker = out / "other-process"
            marker.write_text("owned elsewhere")
            with self.assertRaises(FileExistsError):
                scanner.publish_receipt(out, b"{}\n", lambda: None)
            self.assertEqual(marker.read_text(), "owned elsewhere")

    def test_training_schema_variants_populate_all_embedding_axes(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "training.jsonl"
            source.write_text('{"asr_input":"source spoken","gold_output":"source polished"}\n')
            results, _ = scanner.scan(contract=CONTRACT, benchmark_rows=[{"asr_input": "candidate spoken", "gold_output": "candidate polished"}], sources={("training", "train"): source}, backend_name="synthetic_test_only", embedding_backend=scanner.SyntheticEmbeddingBackend())
            axes = results[0]["methods"]["embedding_cosine"]["axes"]
            self.assertEqual(set(axes), {"input_input", "output_output", "input_output", "output_input"})
            self.assertTrue(all(value["comparison_count"] > 0 for value in axes.values()))


if __name__ == "__main__":
    unittest.main()
