#!/usr/bin/env python3
"""Score the sealed EG-1 English list A/B with explicit arm binding."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any, Callable

import score_eg1_english_list_novel as deterministic
from eg1_english_list_contract import (
    load_contract,
    require_binding,
    validate_binding_commit,
)


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
EVAL_DIR = SCRIPT_PATH.parent
CONTRACT_VERIFIER = EVAL_DIR / "eg1_english_list_contract.py"
DETERMINISTIC_SCORER = Path(deterministic.__file__).resolve()
CANONICAL_DECISION_CONTRACT = (
    REPO_ROOT
    / "docs"
    / "experiments"
    / "eg1-multilingual"
    / "ENGLISH-LIST-PILOT75-DECISION-CONTRACT-V2.md"
)
EXPECTED_ARMS = ("baseline", "candidate")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--positive-corpus", required=True, type=Path)
    parser.add_argument("--restraint-corpus", required=True, type=Path)
    parser.add_argument("--ab-bundle", required=True, type=Path)
    parser.add_argument("--expected-ab-receipt-sha256", required=True)
    parser.add_argument("--out", required=True, type=Path)
    return parser.parse_args()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_once(path: Path, label: str) -> tuple[bytes, str]:
    try:
        value = path.read_bytes()
    except OSError as error:
        raise ValueError(f"cannot read {label}") from error
    return value, sha256_bytes(value)


def parse_json(value: bytes, label: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise ValueError(f"{label} is invalid JSON") from error
    if not isinstance(parsed, dict):
        raise ValueError(f"{label} is not an object")
    return parsed


def require_sha(actual: str, expected: Any, label: str) -> None:
    if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError(f"expected {label} SHA-256 is invalid")
    if actual != expected:
        raise ValueError(f"{label} differs from its bound SHA-256")


def resolve_recorded_path(value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} path is invalid")
    path = Path(value)
    if path.is_absolute():
        return path
    if ".." in path.parts:
        raise ValueError(f"{label} path escapes the repository")
    return REPO_ROOT / path


def direct_child(bundle: Path, value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} path is invalid")
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts or len(relative.parts) != 1:
        raise ValueError(f"{label} path is not a direct bundle child")
    path = bundle / relative
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"{label} is unavailable")
    return path


def publish_exclusive(
    path: Path, value: bytes, before_link: Callable[[], None] | None = None
) -> None:
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temp = Path(temp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        if before_link is not None:
            before_link()
        os.link(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def load_bound_inputs(
    positive: Path,
    restraint: Path,
    bundle: Path,
    expected_ab_receipt_sha: str,
) -> tuple[dict[str, Any], Path, Path, Path, str]:
    ab_receipt_path = bundle / "receipt.json"
    ab_bytes, ab_sha = read_once(ab_receipt_path, "A/B receipt")
    require_sha(ab_sha, expected_ab_receipt_sha, "A/B receipt")
    ab = parse_json(ab_bytes, "A/B receipt")
    if ab.get("status") != "connector_wire_exact_ab_complete_semantic_review_pending":
        raise ValueError("A/B receipt is not healthy and scoreable")
    scope = ab.get("scope")
    if (
        not isinstance(scope, dict)
        or scope.get("arm_order") != list(EXPECTED_ARMS)
        or scope.get("same_server_identity_before_and_after_each_arm") is not True
        or scope.get("both_arms_zero_errors_and_empty_outputs") is not True
        or scope.get("connector_wire_exact") is not True
        or scope.get("paste_equivalent") is not False
    ):
        raise ValueError("A/B runtime scope is invalid")

    try:
        provenance = ab["provenance"]
        source_records = provenance["sources"]
        contract_record = source_records["decision_contract"]
    except (KeyError, TypeError) as error:
        raise ValueError("A/B receipt does not bind the decision contract") from error
    contract_path = resolve_recorded_path(
        contract_record.get("path"), "decision contract"
    )
    if contract_path.resolve() != CANONICAL_DECISION_CONTRACT.resolve():
        raise ValueError("A/B receipt does not bind the canonical V2 contract")
    contract_bytes, contract_sha = read_once(contract_path, "decision contract")
    require_sha(contract_sha, contract_record.get("sha256"), "decision contract")
    loaded_bytes, loaded_sha, bindings = load_contract(contract_path)
    if loaded_bytes != contract_bytes or loaded_sha != contract_sha:
        raise RuntimeError("decision contract changed while loading")
    if provenance.get("bindings") != bindings:
        raise ValueError("A/B receipt bindings differ from the executable contract")
    for key, path in (
        ("contract_verifier_sha256", CONTRACT_VERIFIER),
        ("deterministic_scorer_sha256", DETERMINISTIC_SCORER),
        ("ab_scorer_sha256", SCRIPT_PATH),
    ):
        _, actual_sha = read_once(path, key)
        require_binding(bindings, key, actual_sha)
    execution_head = validate_binding_commit(
        bindings, contract_path, REPO_ROOT
    )
    if provenance.get("git_head") != execution_head:
        raise ValueError("A/B receipt Git head differs from the contract binding commit")

    arm_paths: dict[str, Path] = {}
    for arm in EXPECTED_ARMS:
        try:
            record = ab["arms"][arm]
        except (KeyError, TypeError) as error:
            raise ValueError(f"A/B receipt is missing {arm}") from error
        if not isinstance(record, dict):
            raise ValueError(f"A/B receipt {arm} record is invalid")
        if (
            record.get("inference_error_count") != 0
            or record.get("empty_output_count") != 0
            or record.get("runner_returncode") != 0
            or record.get("row_count") != 150
        ):
            raise ValueError(f"A/B receipt {arm} failed inference health")
        path = direct_child(bundle, record.get("path"), f"{arm} output")
        value, actual_sha = read_once(path, f"{arm} output")
        require_sha(actual_sha, record.get("sha256"), f"{arm} output")
        rows = deterministic.read_jsonl(path)
        if any("model_id" in row for row in rows):
            raise ValueError(f"{arm} output may not override receipt-bound arm identity")
        arm_paths[arm] = path

    try:
        render_record = ab["provenance"]["render_receipt"]
    except (KeyError, TypeError) as error:
        raise ValueError("A/B receipt does not bind the render receipt") from error
    render_path = resolve_recorded_path(render_record.get("path"), "render receipt")
    render_bytes, render_sha = read_once(render_path, "render receipt")
    require_sha(render_sha, render_record.get("sha256"), "render receipt")
    render = parse_json(render_bytes, "render receipt")
    try:
        render_bindings = render["provenance"]["bindings"]
    except (KeyError, TypeError) as error:
        raise ValueError("render receipt does not carry contract bindings") from error
    if render_bindings != bindings:
        raise ValueError("render receipt bindings differ from the executable contract")
    try:
        positive_source = render["sources"]["positive_corpus"]
        restraint_source = render["sources"]["restraint_corpus"]
    except (KeyError, TypeError) as error:
        raise ValueError("render receipt does not bind both corpora") from error
    for supplied, source, label in (
        (positive, positive_source, "positive corpus"),
        (restraint, restraint_source, "restraint corpus"),
    ):
        recorded = resolve_recorded_path(source.get("path"), label)
        if recorded.resolve() != supplied.resolve():
            raise ValueError(f"supplied {label} is not receipt-bound")
        _, actual_sha = read_once(supplied, label)
        require_sha(actual_sha, source.get("sha256"), label)

    ab["_verified_contract"] = {
        "path": str(contract_path),
        "sha256": contract_sha,
        "bindings": bindings,
        "git_head": execution_head,
    }
    return ab, arm_paths["baseline"], arm_paths["candidate"], render_path, ab_sha


def role_losses(model: dict[str, Any], role: str, key: str) -> int:
    return sum(
        row["inference_ok"] and not row[key]
        for row in model["case_results"]
        if row["role"] == role
    )


def mechanical_gate(report: dict[str, Any]) -> dict[str, Any]:
    baseline = report["models"]["baseline"]
    candidate = report["models"]["candidate"]
    comparison = next(
        item
        for item in report["paired_comparisons"]
        if item["left_model"] == "baseline" and item["right_model"] == "candidate"
    )
    positive = comparison["positive_strict"]
    net_gain = positive["right_only"] - positive["left_only"]
    baseline_by_id = {row["id"]: row for row in baseline["case_results"]}
    candidate_by_id = {row["id"]: row for row in candidate["case_results"]}
    restraint_ids = [
        case_id
        for case_id, row in baseline_by_id.items()
        if row["role"] == "prose_restraint"
    ]
    candidate_only_false_lists = [
        case_id
        for case_id in restraint_ids
        if candidate_by_id[case_id]["false_list"] and not baseline_by_id[case_id]["false_list"]
    ]
    loss_checks: dict[str, dict[str, Any]] = {}
    for role in ("positive_list", "prose_restraint"):
        for key in ("items_preserved", "scope_preserved"):
            name = f"{role}.{key.replace('_preserved', '_loss')}"
            baseline_loss = role_losses(baseline, role, key)
            candidate_loss = role_losses(candidate, role, key)
            loss_checks[name] = {
                "baseline": baseline_loss,
                "candidate": candidate_loss,
                "pass": candidate_loss <= baseline_loss,
            }

    conditions = {
        "both_arms_inference_healthy": {
            "pass": baseline["inference_failure_count"] == 0
            and candidate["inference_failure_count"] == 0,
        },
        "positive_net_gain_at_least_8": {"value": net_gain, "pass": net_gain >= 8},
        "positive_mcnemar_p_below_0_05": {
            "value": positive["exact_mcnemar_p_two_sided"],
            "pass": positive["exact_mcnemar_p_two_sided"] < 0.05,
        },
        "zero_candidate_only_restraint_false_lists": {
            "ids": candidate_only_false_lists,
            "pass": not candidate_only_false_lists,
        },
        "candidate_total_false_lists_not_above_baseline": {
            "baseline": baseline["restraint"]["false_list"]["successes"],
            "candidate": candidate["restraint"]["false_list"]["successes"],
            "pass": candidate["restraint"]["false_list"]["successes"]
            <= baseline["restraint"]["false_list"]["successes"],
        },
        "item_and_scope_loss_not_increased_per_lane": {
            "details": loss_checks,
            "pass": all(item["pass"] for item in loss_checks.values()),
        },
    }
    return {
        "mechanical_conditions": conditions,
        "mechanical_pass": all(item["pass"] for item in conditions.values()),
        "semantic_condition": "pending_arm_blind_review",
        "candidate_advances": False,
        "candidate_advances_reason": "semantic review is required after mechanical scoring",
    }


def main() -> int:
    args = parse_args()
    if args.out.exists() or args.out.is_symlink():
        raise SystemExit("--out already exists; refusing to overwrite A/B scoring evidence")
    if not args.out.parent.is_dir():
        raise SystemExit("--out parent directory must already exist")

    ab, baseline_path, candidate_path, render_path, ab_sha = load_bound_inputs(
        args.positive_corpus,
        args.restraint_corpus,
        args.ab_bundle,
        args.expected_ab_receipt_sha256,
    )
    report = deterministic.build_report(
        args.positive_corpus, args.restraint_corpus, [baseline_path, candidate_path]
    )
    if set(report["models"]) != set(EXPECTED_ARMS):
        raise RuntimeError("deterministic scorer did not preserve explicit arm identity")
    report["status"] = "connector_wire_exact_mechanical_ab_semantic_pending"
    report["ab_binding"] = {
        "receipt_path": str(args.ab_bundle / "receipt.json"),
        "receipt_sha256": ab_sha,
        "expected_receipt_sha256": args.expected_ab_receipt_sha256,
        "render_receipt_path": str(render_path),
        "baseline_prompt_sha256": ab["arms"]["baseline"]["rendered_prompts_sha256"],
        "candidate_prompt_sha256": ab["arms"]["candidate"]["rendered_prompts_sha256"],
        "arm_direction": {"left": "baseline", "right": "candidate"},
        "paste_equivalent": False,
        "decision_contract": ab["_verified_contract"],
    }
    report["advancement_gate"] = mechanical_gate(report)

    publication_sources = (
        (args.ab_bundle / "receipt.json", ab_sha, "A/B receipt"),
        (baseline_path, ab["arms"]["baseline"]["sha256"], "baseline output"),
        (candidate_path, ab["arms"]["candidate"]["sha256"], "candidate output"),
        (
            args.positive_corpus,
            report["corpora"]["positive"]["sha256"],
            "positive corpus",
        ),
        (
            args.restraint_corpus,
            report["corpora"]["restraint"]["sha256"],
            "restraint corpus",
        ),
        (
            render_path,
            ab["provenance"]["render_receipt"]["sha256"],
            "render receipt",
        ),
        (
            Path(ab["_verified_contract"]["path"]),
            ab["_verified_contract"]["sha256"],
            "decision contract",
        ),
        (SCRIPT_PATH, ab["_verified_contract"]["bindings"]["ab_scorer_sha256"], "A/B scorer"),
        (
            DETERMINISTIC_SCORER,
            ab["_verified_contract"]["bindings"]["deterministic_scorer_sha256"],
            "deterministic scorer",
        ),
        (
            CONTRACT_VERIFIER,
            ab["_verified_contract"]["bindings"]["contract_verifier_sha256"],
            "contract verifier",
        ),
    )

    def verify_before_link() -> None:
        for path, expected, label in publication_sources:
            if read_once(path, label)[1] != expected:
                raise RuntimeError(f"{label} changed during scoring")
        if (
            validate_binding_commit(
                ab["_verified_contract"]["bindings"],
                Path(ab["_verified_contract"]["path"]),
                REPO_ROOT,
            )
            != ab["_verified_contract"]["git_head"]
        ):
            raise RuntimeError("decision-contract binding commit changed during scoring")

    report_bytes = (
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    publish_exclusive(args.out, report_bytes, before_link=verify_before_link)
    print(json.dumps(report["advancement_gate"], indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
