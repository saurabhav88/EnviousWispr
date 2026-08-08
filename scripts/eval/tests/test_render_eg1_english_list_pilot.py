from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


EVAL_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = EVAL_DIR.parents[1]
if str(EVAL_DIR) not in sys.path:
    sys.path.insert(0, str(EVAL_DIR))
from eg1_english_list_contract import REQUIRED_BINDINGS, load_contract
import render_eg1_english_list_pilot as render_module

SCRIPT = EVAL_DIR / "render_eg1_english_list_pilot.py"
SHIPPED_REQUEST = EVAL_DIR / "eg1_shipped_request.py"
CONTRACT_VERIFIER = EVAL_DIR / "eg1_english_list_contract.py"
LOCAL_WRAPPER = EVAL_DIR / "eg1_local_app_eval.py"
SUBSET_RUNNER = EVAL_DIR / "subset_polish_runner.py"
DUAL_ARM_ORCHESTRATOR = EVAL_DIR / "eg1_local_app_ab_eval.py"
DETERMINISTIC_SCORER = EVAL_DIR / "score_eg1_english_list_novel.py"
AB_SCORER = EVAL_DIR / "score_eg1_english_list_ab.py"
BLIND_PACKET_BUILDER = EVAL_DIR / "build_eg1_english_list_blind_review.py"
SEMANTIC_UNBLINDER = EVAL_DIR / "unblind_eg1_english_list_semantic_review.py"
DELIVERY_MANIFEST = (
    REPO_ROOT
    / "Sources"
    / "EnviousWispr"
    / "Resources"
    / "eg1-delivery-manifest.json"
)
BASELINE_PROMPT = EVAL_DIR / "prompts" / "eg1-polish-prompt-v1.txt"
CANDIDATE_PROMPT = EVAL_DIR / "prompts" / "eg1-list-aware-v2.txt"
DECISION_CONTRACT = (
    REPO_ROOT
    / "docs"
    / "experiments"
    / "eg1-multilingual"
    / "ENGLISH-LIST-PILOT75-DECISION-CONTRACT-V2.md"
)
SEMANTIC_RUBRIC = DECISION_CONTRACT.with_name(
    "ENGLISH-LIST-SEMANTIC-REVIEW-RUBRIC-V1.md"
)


class RenderEnglishListPilotTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(dir=EVAL_DIR / "corpus")
        self.root = Path(self.temp.name)
        self.positive = self.root / "positive.jsonl"
        self.restraint = self.root / "restraint.jsonl"
        self.assembly_receipt = self.root / "assembly-receipt.json"
        self.bundle = self.root / "bundle"
        self.code_anchor = "a" * 40
        self.fake_head = "b" * 40
        self.original_contract = DECISION_CONTRACT.read_bytes()
        self.fake_bin = self.root / "bin"
        self.fake_bin.mkdir()
        fake_git = self.fake_bin / "git"
        fake_git.write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" = \"rev-parse\" ] && [ \"$2\" = \"HEAD^\" ]; then echo "
            + self.code_anchor
            + "; exit 0; fi\n"
            "if [ \"$1\" = \"rev-parse\" ]; then echo " + self.fake_head + "; exit 0; fi\n"
            "if [ \"$1\" = \"diff\" ]; then echo "
            + str(DECISION_CONTRACT.relative_to(REPO_ROOT))
            + "; exit 0; fi\n"
            "if [ \"$1\" = \"status\" ]; then exit 0; fi\n"
            "exit 2\n",
            encoding="utf-8",
        )
        fake_git.chmod(0o755)
        self._write_corpora()

    def tearDown(self) -> None:
        DECISION_CONTRACT.write_bytes(self.original_contract)
        self.temp.cleanup()

    @staticmethod
    def _row(role: str, index: int) -> dict[str, object]:
        slug = "positive" if role == "positive_list" else "restraint"
        transcript = f"{slug} transcript {index} preserve owner {index}"
        if role == "positive_list" and index == 1:
            transcript += " say <TRANSCRIPT> literally"
        return {
            "id": f"en-list-{slug}-pilot75-v1-{index:03d}",
            "input": transcript,
            "expected_output": f"private gold {index}",
            "benchmark_role": role,
            "split": "dev",
            "lang": "en",
            "gold_status": "candidate_unreviewed",
            "native_reviewed": False,
            "training_eligible": False,
        }

    def _write_corpora(
        self,
        positive: list[dict[str, object]] | None = None,
        restraint: list[dict[str, object]] | None = None,
    ) -> None:
        positive = positive or [self._row("positive_list", i) for i in range(1, 76)]
        restraint = restraint or [self._row("prose_restraint", i) for i in range(1, 76)]
        for path, rows in ((self.positive, positive), (self.restraint, restraint)):
            path.write_text(
                "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8"
            )

    @staticmethod
    def _sha(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def _write_assembly_receipt(self) -> str:
        def relative(path: Path) -> str:
            return str(path.resolve().relative_to(REPO_ROOT))

        receipt = {
            "status": "portable_leakage_validation_pass_candidate_requires_independent_review",
            "outputs": {
                "positive_list": {
                    "path": relative(self.positive),
                    "sha256": self._sha(self.positive),
                    "row_count": 75,
                },
                "prose_restraint": {
                    "path": relative(self.restraint),
                    "sha256": self._sha(self.restraint),
                    "row_count": 75,
                },
            },
        }
        self.assembly_receipt.write_text(json.dumps(receipt) + "\n", encoding="utf-8")
        return self._sha(self.assembly_receipt)

    def _seal_contract(self, assembly_receipt_sha: str) -> None:
        baseline_visible = "\n".join(
            line
            for line in BASELINE_PROMPT.read_text(encoding="utf-8").splitlines()
            if not line.startswith("#")
        ).strip()
        candidate_visible = "\n".join(
            line
            for line in CANDIDATE_PROMPT.read_text(encoding="utf-8").splitlines()
            if not line.startswith("#")
        ).strip()
        bindings = {
            "assembly_receipt_sha256": assembly_receipt_sha,
            "positive_corpus_sha256": self._sha(self.positive),
            "restraint_corpus_sha256": self._sha(self.restraint),
            "baseline_raw_prompt_sha256": self._sha(BASELINE_PROMPT),
            "baseline_model_visible_prompt_sha256": hashlib.sha256(
                baseline_visible.encode("utf-8")
            ).hexdigest(),
            "candidate_raw_prompt_sha256": self._sha(CANDIDATE_PROMPT),
            "candidate_model_visible_prompt_sha256": hashlib.sha256(
                candidate_visible.encode("utf-8")
            ).hexdigest(),
            "contract_verifier_sha256": self._sha(CONTRACT_VERIFIER),
            "renderer_sha256": self._sha(SCRIPT),
            "shipped_request_mirror_sha256": self._sha(SHIPPED_REQUEST),
            "local_wrapper_sha256": self._sha(LOCAL_WRAPPER),
            "subset_runner_sha256": self._sha(SUBSET_RUNNER),
            "dual_arm_orchestrator_sha256": self._sha(DUAL_ARM_ORCHESTRATOR),
            "deterministic_scorer_sha256": self._sha(DETERMINISTIC_SCORER),
            "ab_scorer_sha256": self._sha(AB_SCORER),
            "blind_packet_builder_sha256": self._sha(BLIND_PACKET_BUILDER),
            "semantic_rubric_sha256": self._sha(SEMANTIC_RUBRIC),
            "semantic_unblinder_sha256": self._sha(SEMANTIC_UNBLINDER),
            "delivery_manifest_sha256": self._sha(DELIVERY_MANIFEST),
            "code_anchor_git_sha1": self.code_anchor,
        }
        text = self.original_contract.decode("utf-8")
        begin = "<!-- EG1_LIST_V2_BINDINGS_BEGIN -->"
        end = "<!-- EG1_LIST_V2_BINDINGS_END -->"
        prefix, tail = text.split(begin, 1)
        _, suffix = tail.split(end, 1)
        block = "\n```json\n" + json.dumps(bindings, indent=2) + "\n```\n"
        DECISION_CONTRACT.write_text(
            prefix + begin + block + end + suffix, encoding="utf-8"
        )

    def _write_pending_contract(self) -> None:
        text = self.original_contract.decode("utf-8")
        begin = "<!-- EG1_LIST_V2_BINDINGS_BEGIN -->"
        end = "<!-- EG1_LIST_V2_BINDINGS_END -->"
        prefix, tail = text.split(begin, 1)
        _, suffix = tail.split(end, 1)
        pending = {key: "PENDING" for key in REQUIRED_BINDINGS}
        block = "\n```json\n" + json.dumps(pending, indent=2) + "\n```\n"
        DECISION_CONTRACT.write_text(
            prefix + begin + block + end + suffix, encoding="utf-8"
        )

    def _run(
        self,
        bundle: Path | None = None,
        baseline_prompt: Path = BASELINE_PROMPT,
        expected_shipped_request_sha: str | None = None,
        seal_contract: bool = True,
        altered_binding: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        assembly_receipt_sha = self._write_assembly_receipt()
        if seal_contract:
            self._seal_contract(assembly_receipt_sha)
        if altered_binding is not None:
            text = DECISION_CONTRACT.read_text(encoding="utf-8")
            marker = f'"{altered_binding}": "'
            prefix, tail = text.split(marker, 1)
            _, suffix = tail.split('"', 1)
            DECISION_CONTRACT.write_text(
                prefix + marker + ("f" * 64) + '"' + suffix,
                encoding="utf-8",
            )
        baseline_visible = "\n".join(
            line
            for line in baseline_prompt.read_text(encoding="utf-8").splitlines()
            if not line.startswith("#")
        ).strip()
        candidate_visible = "\n".join(
            line
            for line in CANDIDATE_PROMPT.read_text(encoding="utf-8").splitlines()
            if not line.startswith("#")
        ).strip()
        environment = dict(os.environ)
        environment["PATH"] = f"{self.fake_bin}:{environment.get('PATH', '')}"
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--positive-corpus",
                str(self.positive),
                "--restraint-corpus",
                str(self.restraint),
                "--baseline-prompt",
                str(baseline_prompt),
                "--candidate-prompt",
                str(CANDIDATE_PROMPT),
                "--assembly-receipt",
                str(self.assembly_receipt),
                "--decision-contract",
                str(DECISION_CONTRACT),
                "--expected-assembly-receipt-sha256",
                assembly_receipt_sha,
                "--expected-decision-contract-sha256",
                self._sha(DECISION_CONTRACT),
                "--expected-positive-sha256",
                self._sha(self.positive),
                "--expected-restraint-sha256",
                self._sha(self.restraint),
                "--expected-baseline-prompt-sha256",
                self._sha(baseline_prompt),
                "--expected-candidate-prompt-sha256",
                self._sha(CANDIDATE_PROMPT),
                "--expected-baseline-model-visible-sha256",
                hashlib.sha256(baseline_visible.encode("utf-8")).hexdigest(),
                "--expected-candidate-model-visible-sha256",
                hashlib.sha256(candidate_visible.encode("utf-8")).hexdigest(),
                "--expected-renderer-sha256",
                self._sha(SCRIPT),
                "--expected-shipped-request-sha256",
                expected_shipped_request_sha or self._sha(SHIPPED_REQUEST),
                "--expected-git-head",
                self.fake_head,
                "--out-bundle",
                str(bundle or self.bundle),
            ],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
        )

    @staticmethod
    def _jsonl(path: Path) -> list[dict[str, object]]:
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]

    def test_renders_gold_free_equivalent_arms_and_receipt_last(self) -> None:
        completed = self._run()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue((self.bundle / "receipt.json").is_file())
        baseline = self._jsonl(self.bundle / "baseline.jsonl")
        candidate = self._jsonl(self.bundle / "candidate.jsonl")
        self.assertEqual(len(baseline), 150)
        self.assertEqual(
            [(row["id"], row["user"], row["max_tokens"]) for row in baseline],
            [(row["id"], row["user"], row["max_tokens"]) for row in candidate],
        )
        self.assertTrue(all(set(row) == {"id", "system", "user", "max_tokens"} for row in baseline))
        self.assertEqual(len({row["system"] for row in baseline}), 1)
        self.assertEqual(len({row["system"] for row in candidate}), 1)
        self.assertNotEqual(baseline[0]["system"], candidate[0]["system"])
        self.assertNotIn("#", baseline[0]["system"])
        self.assertNotIn("#", candidate[0]["system"])
        self.assertNotIn("private gold", (self.bundle / "baseline.jsonl").read_text())
        self.assertNotIn("private gold", (self.bundle / "candidate.jsonl").read_text())
        self.assertIn("<\u200cTRANSCRIPT>", baseline[0]["user"])
        receipt = json.loads((self.bundle / "receipt.json").read_text(encoding="utf-8"))
        self.assertTrue(receipt["case_contract"]["identical_id_user_and_token_budget_across_arms"])
        self.assertTrue(receipt["case_contract"]["rendered_rows_are_gold_free"])

    def test_rejects_pending_contract_before_bundle_publication(self) -> None:
        self._write_pending_contract()
        completed = self._run(seal_contract=False)
        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(self.bundle.exists())

    def test_rejects_altered_contract_binding_before_bundle_publication(self) -> None:
        completed = self._run(altered_binding="renderer_sha256")
        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(self.bundle.exists())

    def test_rejects_altered_delivery_manifest_before_bundle_publication(self) -> None:
        completed = self._run(altered_binding="delivery_manifest_sha256")
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("delivery_manifest_sha256", completed.stderr)
        self.assertFalse(self.bundle.exists())

    def test_contract_parser_rejects_duplicate_binding(self) -> None:
        assembly_receipt_sha = self._write_assembly_receipt()
        self._seal_contract(assembly_receipt_sha)
        duplicate = self.root / "duplicate-contract.md"
        text = DECISION_CONTRACT.read_text(encoding="utf-8")
        line = next(
            value
            for value in text.splitlines()
            if '"renderer_sha256"' in value
        )
        duplicate.write_text(text.replace(line, line + "\n" + line, 1), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "duplicate decision contract binding"):
            load_contract(duplicate)

    def test_partial_receipt_write_removes_complete_bundle(self) -> None:
        source = self.root / "publish-source"
        destination = self.root / "publish-destination"
        source.mkdir()
        (source / "baseline.jsonl").write_text("baseline\n", encoding="utf-8")
        (source / "candidate.jsonl").write_text("candidate\n", encoding="utf-8")

        def partial_receipt(path: Path, value: bytes) -> None:
            path.write_bytes(value[:1])
            raise OSError("injected receipt short write")

        with (
            mock.patch.object(
                render_module, "write_exclusive", side_effect=partial_receipt
            ),
            self.assertRaisesRegex(OSError, "injected receipt short write"),
        ):
            render_module.publish_bundle(
                destination,
                source,
                ("baseline.jsonl", "candidate.jsonl"),
                b'{"status":"complete"}\n',
            )
        self.assertFalse(destination.exists())

    def test_refuses_existing_bundle_without_changing_it(self) -> None:
        self.bundle.mkdir()
        marker = self.bundle / "keep.txt"
        marker.write_text("keep", encoding="utf-8")
        completed = self._run()
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(marker.read_text(encoding="utf-8"), "keep")

    def test_rejects_wrong_role_count_without_partial_bundle(self) -> None:
        rows = [self._row("positive_list", i) for i in range(1, 75)]
        self._write_corpora(positive=rows)
        completed = self._run()
        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(self.bundle.exists())

    def test_rejects_metadata_drift_without_partial_bundle(self) -> None:
        rows = [self._row("prose_restraint", i) for i in range(1, 76)]
        rows[0]["training_eligible"] = True
        self._write_corpora(restraint=rows)
        completed = self._run()
        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(self.bundle.exists())

    def test_rejects_cross_role_id_overlap(self) -> None:
        positive = [self._row("positive_list", i) for i in range(1, 76)]
        restraint = [self._row("prose_restraint", i) for i in range(1, 76)]
        restraint[0]["id"] = positive[0]["id"]
        self._write_corpora(positive=positive, restraint=restraint)
        completed = self._run()
        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(self.bundle.exists())

    def test_rejects_noncanonical_prompt_path(self) -> None:
        arbitrary_prompt = self.root / "arbitrary.txt"
        arbitrary_prompt.write_bytes(BASELINE_PROMPT.read_bytes())
        completed = self._run(baseline_prompt=arbitrary_prompt)
        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(self.bundle.exists())

    def test_rejects_changed_shipped_request_helper(self) -> None:
        completed = self._run(expected_shipped_request_sha="0" * 64)
        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(self.bundle.exists())


if __name__ == "__main__":
    unittest.main()
