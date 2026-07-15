#!/usr/bin/env python3
"""Assemble a sealed, model-blind EG-1 list pilot as one portable bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
import time
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Callable


HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
GENERATOR_RELATIVE = Path("scripts/eval/generate_eg1_english_list_benchmark.py")
sys.path.insert(0, str(HERE))

import generate_eg1_english_list_benchmark as benchmark  # noqa: E402


OUTPUT_FIELDS = ("output", "expected_output", "gold", "reference_output", "polished")
FAMILY_FIELDS = ("family", "origin", "family_id", "semantic_family_id")
RECEIPT_NAME = "receipt.json"


@dataclass(frozen=True)
class AuditText:
    source: str
    source_id: str
    source_field: str
    source_kind: str
    role: str | None
    batch: int | None
    audit: benchmark.AuditInput


@dataclass(frozen=True)
class SelectionVerification:
    old_repo_root: Path
    positive_specs: list[benchmark.CaseSpec]
    restraint_specs: list[benchmark.CaseSpec]
    receipt: dict[str, Any]


class ComparisonStats:
    def __init__(self) -> None:
        self.comparison_count = 0
        self.candidate_text_count = 0
        self.candidate_rows: set[str] = set()
        self.candidate_fields: Counter[str] = Counter()
        self.field_pairs: Counter[str] = Counter()
        self.relations: Counter[str] = Counter()
        self.axis_maxima = {axis: 0.0 for axis in benchmark.SIMILARITY_THRESHOLDS}
        self.axis_provenance: dict[str, dict[str, Any] | None] = {
            axis: None for axis in benchmark.SIMILARITY_THRESHOLDS
        }

    def begin_candidate_text(self, candidate_id: str, candidate_field: str) -> None:
        self.candidate_text_count += 1
        self.candidate_rows.add(candidate_id)
        self.candidate_fields[candidate_field] += 1

    def observe(
        self,
        candidate_id: str,
        candidate_field: str,
        candidate_role: str,
        candidate_batch: int,
        prior: AuditText,
        axes: dict[str, float],
    ) -> None:
        self.comparison_count += 1
        self.field_pairs[f"{candidate_field}->{prior.source_field}"] += 1
        if prior.source_kind == "sealed_source":
            relation = "sealed_source"
        elif prior.role != candidate_role:
            relation = "cross_role"
        elif prior.batch != candidate_batch:
            relation = "cross_batch_same_role"
        else:
            relation = "within_batch"
        self.relations[relation] += 1
        for axis, value in axes.items():
            if value > self.axis_maxima[axis]:
                self.axis_maxima[axis] = value
                self.axis_provenance[axis] = {
                    "candidate_id": candidate_id,
                    "candidate_field": candidate_field,
                    "source": prior.source,
                    "source_id": prior.source_id,
                    "source_field": prior.source_field,
                    "relation": relation,
                    "score": round(value, 6),
                }

    def as_receipt(self) -> dict[str, Any]:
        return {
            "candidate_row_count": len(self.candidate_rows),
            "candidate_text_count": self.candidate_text_count,
            "candidate_field_counts": dict(sorted(self.candidate_fields.items())),
            "pair_comparison_count": self.comparison_count,
            "field_pair_comparison_counts": dict(sorted(self.field_pairs.items())),
            "relation_comparison_counts": dict(sorted(self.relations.items())),
            "axis_maxima": {
                axis: {
                    "score": round(self.axis_maxima[axis], 6),
                    "threshold": benchmark.SIMILARITY_THRESHOLDS[axis],
                    "provenance": self.axis_provenance[axis],
                }
                for axis in benchmark.SIMILARITY_THRESHOLDS
            },
            "cross_batch_same_role_screened": self.relations["cross_batch_same_role"] > 0,
            "cross_role_screened": self.relations["cross_role"] > 0,
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--selection-manifest", required=True)
    parser.add_argument("--expected-selection-sha256", required=True)
    parser.add_argument("--expected-definition-sha256", required=True)
    parser.add_argument("--checkpoint-dir", required=True)
    parser.add_argument("--bundle-output", required=True)
    parser.add_argument("--batch-id", default="pilot75-v1")
    parser.add_argument("--checkpoint-batch-size", type=int, default=5)
    return parser.parse_args()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def canonical_sha256(value: Any) -> str:
    encoded = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode()
    return sha256_bytes(encoded)


def repo_relative(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError as error:
        raise ValueError(f"receipt path must be inside the repository: {path}") from error


def infer_old_repo_root(sealed_generator: str) -> Path:
    generator = Path(sealed_generator)
    if not generator.is_absolute():
        raise ValueError("sealed generator path must be absolute")
    root = generator
    for _ in GENERATOR_RELATIVE.parts:
        root = root.parent
    if root / GENERATOR_RELATIVE != generator:
        raise ValueError("sealed generator path does not end in the canonical generator path")
    return root


def remap_sealed_path(sealed_path: str, old_repo_root: Path) -> Path:
    lexical = Path(sealed_path)
    if not lexical.is_absolute():
        raise ValueError(f"sealed path is not absolute: {sealed_path}")
    try:
        relative = lexical.relative_to(old_repo_root)
    except ValueError as error:
        raise ValueError(f"sealed path is outside the sealed repository: {sealed_path}") from error
    if ".." in relative.parts:
        raise ValueError(f"sealed path escapes the repository: {sealed_path}")
    return REPO_ROOT / relative


def read_once(path: Path, expected_sha256: str | None, label: str) -> tuple[bytes, str]:
    with path.open("rb") as handle:
        before = os.fstat(handle.fileno())
        value = handle.read()
        after = os.fstat(handle.fileno())
    identity_before = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    identity_after = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    if identity_before != identity_after or len(value) != after.st_size:
        raise ValueError(f"{label} changed while it was read: {path}")
    actual = sha256_bytes(value)
    if expected_sha256 is not None and actual != expected_sha256:
        raise ValueError(f"{label} SHA mismatch: expected {expected_sha256}, found {actual}")
    return value, actual


def parse_rows_bytes(value: bytes, label: str, suffix: str = ".jsonl") -> list[dict[str, Any]]:
    text = value.decode("utf-8")
    if suffix == ".jsonl":
        rows = []
        for line_number, line in enumerate(text.splitlines(), 1):
            if not line.strip():
                continue
            row = json.loads(line)
            if not isinstance(row, dict):
                raise ValueError(f"{label}:{line_number} is not an object")
            rows.append(row)
        return rows
    parsed = json.loads(text)
    if isinstance(parsed, list):
        rows = parsed
    elif isinstance(parsed, dict):
        rows = next(
            (parsed[key] for key in ("rows", "cases", "data") if isinstance(parsed.get(key), list)),
            None,
        )
    else:
        rows = None
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        raise ValueError(f"{label} contains no supported row list")
    return rows


def write_exclusive_bytes(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as handle:
        handle.write(value)
        handle.flush()
        os.fsync(handle.fileno())


def distribution(rows: list[dict[str, Any]], field: str) -> dict[str, int]:
    return dict(sorted(Counter(str(row[field]) for row in rows).items()))


def verify_sealed_selection(
    manifest: dict[str, Any], expected_definition_sha256: str
) -> SelectionVerification:
    exact_flags = {
        "status": "predeclared_candidate_pilot",
        "model_blind": True,
        "native_reviewed": False,
        "training_eligible": False,
        "frozen": False,
        "selection_rule": "first_n_checkpoint_order_without_output_inspection",
        "selection_used_model_outputs": False,
    }
    flag_matches = {key: manifest.get(key) == value for key, value in exact_flags.items()}
    if not all(flag_matches.values()):
        raise ValueError(f"sealed selection flags differ from required values: {flag_matches}")
    pilot_count = manifest.get("pilot_count_per_role")
    full_count = manifest.get("full_count_per_role")
    seed = manifest.get("seed")
    if (
        not isinstance(pilot_count, int)
        or not isinstance(full_count, int)
        or not isinstance(seed, int)
        or pilot_count <= 0
        or pilot_count > full_count
    ):
        raise ValueError("sealed pilot/full counts or seed are invalid")

    positive_full = benchmark.balanced_specs("positive_list", full_count, seed)
    restraint_full = benchmark.balanced_specs("prose_restraint", full_count, seed + 1)
    selected = {
        "positive_list": [asdict(spec) for spec in positive_full[:pilot_count]],
        "prose_restraint": [asdict(spec) for spec in restraint_full[:pilot_count]],
    }
    first_n_matches = manifest.get("selected_specs") == selected
    if not first_n_matches:
        raise ValueError("sealed selected_specs are not the regenerated first N specifications")
    excluded = {
        "positive_list": [spec.spec_id for spec in positive_full[pilot_count:]],
        "prose_restraint": [spec.spec_id for spec in restraint_full[pilot_count:]],
    }
    excluded_matches = manifest.get("excluded_from_pilot_but_reserved_for_full_run") == excluded
    if not excluded_matches:
        raise ValueError("sealed excluded specification IDs do not match regenerated suffixes")
    axes = ("domain", "case_type", "item_count", "length_bucket", "compound_required")
    recomputed_distributions = {
        role: {axis: distribution(rows, axis) for axis in axes}
        for role, rows in selected.items()
    }
    distributions_match = manifest.get("selected_distributions") == recomputed_distributions
    if not distributions_match:
        raise ValueError("sealed selected distributions do not match regenerated first N specs")
    sources = manifest.get("audit_sources")
    if not isinstance(sources, list) or not sources:
        raise ValueError("sealed manifest has no audit sources")
    definition = {
        "selection_rule": manifest["selection_rule"],
        "pilot_count_per_role": pilot_count,
        "full_count_per_role": full_count,
        "seed": seed,
        "selected_specs": selected,
        "audit_sources": sources,
    }
    recomputed_definition_sha = canonical_sha256(definition)
    definition_matches = (
        recomputed_definition_sha == manifest.get("pilot_definition_sha256")
        == expected_definition_sha256
    )
    if not definition_matches:
        raise ValueError(
            "canonical pilot definition SHA mismatch: "
            f"expected {expected_definition_sha256}, recomputed {recomputed_definition_sha}, "
            f"sealed {manifest.get('pilot_definition_sha256')}"
        )
    old_root = infer_old_repo_root(manifest.get("generator", ""))
    generator_path = remap_sealed_path(manifest["generator"], old_root)
    if generator_path != REPO_ROOT / GENERATOR_RELATIVE:
        raise ValueError("portable generator remap did not reach the canonical current path")
    _, live_generator_sha = read_once(
        generator_path, manifest.get("generator_sha256"), "sealed generator"
    )
    receipt = {
        "required_flag_matches": flag_matches,
        "regenerated_first_n_matches": first_n_matches,
        "regenerated_excluded_suffix_matches": excluded_matches,
        "regenerated_distributions_match": distributions_match,
        "recomputed_definition_sha256": recomputed_definition_sha,
        "definition_hash_matches_expected_and_sealed": definition_matches,
        "live_generator_sha256": live_generator_sha,
        "live_generator_matches_sealed": live_generator_sha == manifest.get("generator_sha256"),
        "pilot_count_per_role": pilot_count,
        "full_count_per_role": full_count,
        "seed": seed,
    }
    return SelectionVerification(
        old_repo_root=old_root,
        positive_specs=positive_full[:pilot_count],
        restraint_specs=restraint_full[:pilot_count],
        receipt=receipt,
    )


def make_audit_text(
    source: str,
    source_id: str,
    source_field: str,
    value: str,
    *,
    source_kind: str,
    role: str | None = None,
    batch: int | None = None,
) -> AuditText:
    return AuditText(
        source=source,
        source_id=source_id,
        source_field=source_field,
        source_kind=source_kind,
        role=role,
        batch=batch,
        audit=benchmark.as_audit_input(source, source_id, value),
    )


def screen_candidate_texts(
    candidate_id: str,
    candidate_role: str,
    candidate_batch: int,
    values: dict[str, str],
    blocked: list[AuditText],
    stats: ComparisonStats,
) -> None:
    for candidate_field, value in values.items():
        stats.begin_candidate_text(candidate_id, candidate_field)
        candidate = benchmark.as_audit_input("generated", candidate_id, value)
        for prior in blocked:
            provenance = f"{prior.source}:{prior.source_id}.{prior.source_field}"
            if candidate.normalized == prior.audit.normalized:
                raise ValueError(
                    f"{candidate_id}.{candidate_field}: exact overlap with {provenance}"
                )
            _, axes = benchmark.similarity(candidate, prior.audit)
            stats.observe(
                candidate_id,
                candidate_field,
                candidate_role,
                candidate_batch,
                prior,
                axes,
            )
            if benchmark.high_similarity(axes):
                triggered = {
                    axis: round(score, 6)
                    for axis, score in axes.items()
                    if score >= benchmark.SIMILARITY_THRESHOLDS[axis]
                }
                raise ValueError(
                    f"{candidate_id}.{candidate_field}: high-similarity overlap with "
                    f"{provenance} {triggered}"
                )


def snapshot_sources(
    manifest: dict[str, Any],
    verification: SelectionVerification,
    temp_dir: Path,
    final_dir: Path,
) -> tuple[list[AuditText], list[benchmark.AuditInput], set[str], list[dict[str, Any]]]:
    texts: list[AuditText] = []
    structural: list[benchmark.AuditInput] = []
    families: set[str] = set()
    inventories: list[dict[str, Any]] = []
    for index, source in enumerate(manifest["audit_sources"], 1):
        current = remap_sealed_path(source["path"], verification.old_repo_root)
        source_bytes, actual_sha = read_once(current, source.get("sha256"), "audit source")
        rows = parse_rows_bytes(source_bytes, repo_relative(current), current.suffix)
        snapshot_name = f"{index:03d}-{current.name}"
        snapshot = temp_dir / snapshot_name
        write_exclusive_bytes(snapshot, source_bytes)
        snapshot_bytes, snapshot_sha = read_once(snapshot, actual_sha, "audit source snapshot")
        snapshot_rows = parse_rows_bytes(snapshot_bytes, snapshot_name, current.suffix)
        if snapshot_rows != rows:
            raise ValueError(f"audit source snapshot reparsed differently: {snapshot_name}")
        snapshot_path = repo_relative(final_dir / snapshot_name)
        field_counts: Counter[str] = Counter()
        for row_index, row in enumerate(snapshot_rows, 1):
            source_id = str(row.get("id", row_index))
            for family_field in FAMILY_FIELDS:
                value = row.get(family_field)
                if isinstance(value, str) and value.strip():
                    families.add(benchmark.normalized(value))
            for field in (*benchmark.INPUT_FIELDS, *OUTPUT_FIELDS):
                value = row.get(field)
                if not isinstance(value, str) or not value.strip():
                    continue
                field_counts[field] += 1
                text = make_audit_text(
                    snapshot_path,
                    source_id,
                    field,
                    value,
                    source_kind="sealed_source",
                )
                texts.append(text)
                if field in benchmark.INPUT_FIELDS:
                    structural.append(text.audit)
        inventories.append(
            {
                "source_path": repo_relative(current),
                "snapshot_path": snapshot_path,
                "role": source.get("role"),
                "sha256": snapshot_sha,
                "row_count": len(snapshot_rows),
                "text_count": sum(field_counts.values()),
                "field_counts": dict(sorted(field_counts.items())),
            }
        )
    if not texts or not structural:
        raise ValueError("audit source snapshots contain no usable texts")
    return texts, structural, families, inventories


def load_role_checkpoints(
    role: str,
    specs: list[benchmark.CaseSpec],
    checkpoint_dir: Path,
    checkpoint_batch_size: int,
    batch_id: str,
    temp_dir: Path,
    final_dir: Path,
    structural: list[benchmark.AuditInput],
    leakage: list[AuditText],
    families: set[str],
    stats: ComparisonStats,
) -> tuple[
    list[dict[str, Any]],
    list[benchmark.AuditInput],
    list[AuditText],
    set[str],
    list[dict[str, Any]],
]:
    if len(specs) % checkpoint_batch_size:
        raise ValueError(f"sealed {role} count is not divisible by checkpoint batch size")
    rows: list[dict[str, Any]] = []
    checkpoints: list[dict[str, Any]] = []
    current_structural = list(structural)
    current_leakage = list(leakage)
    current_families = set(families)
    for batch_index, start in enumerate(range(0, len(specs), checkpoint_batch_size), 1):
        batch_specs = specs[start : start + checkpoint_batch_size]
        source = checkpoint_dir / f"{role}-batch-{batch_index:03d}.json"
        checkpoint_bytes, checkpoint_sha = read_once(source, None, "checkpoint")
        checkpoint = json.loads(checkpoint_bytes.decode("utf-8"))
        snapshot_name = source.name
        snapshot = temp_dir / snapshot_name
        write_exclusive_bytes(snapshot, checkpoint_bytes)
        snapshot_bytes, snapshot_sha = read_once(snapshot, checkpoint_sha, "checkpoint snapshot")
        snapshot_value = json.loads(snapshot_bytes.decode("utf-8"))
        if snapshot_value != checkpoint:
            raise ValueError(f"checkpoint snapshot reparsed differently: {snapshot_name}")
        if checkpoint.get("specs") != [asdict(spec) for spec in batch_specs]:
            raise ValueError(f"checkpoint specs differ from regenerated first N: {source.name}")
        system, user = benchmark.generation_prompt(batch_specs)
        prompt_sha = sha256_bytes((system + "\n" + user).encode())
        if checkpoint.get("prompt_sha256") != prompt_sha:
            raise ValueError(f"checkpoint prompt hash differs from sealed generator: {source.name}")
        accepted = benchmark.validate_batch(
            checkpoint.get("rows"), batch_specs, current_structural, current_families
        )
        for spec, (row, similarity_audit) in zip(batch_specs, accepted):
            enriched = benchmark.enrich(row, spec, batch_id, similarity_audit)
            screen_candidate_texts(
                enriched["id"],
                role,
                batch_index,
                {"input": row["input"], "expected_output": row["expected_output"]},
                current_leakage,
                stats,
            )
            rows.append(enriched)
            current_structural.append(
                benchmark.as_audit_input("generated", enriched["id"], row["input"])
            )
            current_leakage.extend(
                [
                    make_audit_text(
                        "generated",
                        enriched["id"],
                        "input",
                        row["input"],
                        source_kind="generated",
                        role=role,
                        batch=batch_index,
                    ),
                    make_audit_text(
                        "generated",
                        enriched["id"],
                        "expected_output",
                        row["expected_output"],
                        source_kind="generated",
                        role=role,
                        batch=batch_index,
                    ),
                ]
            )
            current_families.add(benchmark.normalized(row["family"]))
        checkpoints.append(
            {
                "path": repo_relative(final_dir / snapshot_name),
                "sha256": snapshot_sha,
                "row_count": len(accepted),
                "spec_ids": [spec.spec_id for spec in batch_specs],
                "prompt_sha256": prompt_sha,
            }
        )
    return rows, current_structural, current_leakage, current_families, checkpoints


def encode_jsonl(rows: list[dict[str, Any]]) -> bytes:
    return "".join(
        json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows
    ).encode()


def revalidate_enriched_rows(
    rows: list[dict[str, Any]],
    specs: list[benchmark.CaseSpec],
    checkpoint_batch_size: int,
    structural: list[benchmark.AuditInput],
    leakage: list[AuditText],
    families: set[str],
    stats: ComparisonStats,
) -> tuple[list[benchmark.AuditInput], list[AuditText], set[str]]:
    if len(rows) != len(specs):
        raise ValueError("written output row count differs from regenerated first N")
    current_structural = list(structural)
    current_leakage = list(leakage)
    current_families = set(families)
    for index, (row, sealed_spec) in enumerate(zip(rows, specs), 1):
        batch_index = (index - 1) // checkpoint_batch_size + 1
        for field in (
            "benchmark_role",
            "domain",
            "case_type",
            "item_count",
            "length_bucket",
            "compound_required",
        ):
            expected = getattr(sealed_spec, "role" if field == "benchmark_role" else field)
            if row.get(field) != expected:
                raise ValueError(f"written row {index} differs from sealed {field}")
        if not str(row.get("id", "")).endswith(sealed_spec.spec_id.rsplit("-", 1)[-1]):
            raise ValueError(f"written row {index} differs from sealed checkpoint order")
        structural_spec = benchmark.CaseSpec(
            spec_id=row["id"],
            role=sealed_spec.role,
            domain=sealed_spec.domain,
            case_type=sealed_spec.case_type,
            item_count=sealed_spec.item_count,
            length_bucket=sealed_spec.length_bucket,
            compound_required=sealed_spec.compound_required,
        )
        source_row = {
            field: row[field] for field in benchmark.EXPECTED_FIELDS if field != "spec_id"
        }
        source_row["spec_id"] = row["id"]
        benchmark.validate_generated_row(
            source_row, structural_spec, current_structural, current_families
        )
        screen_candidate_texts(
            row["id"],
            sealed_spec.role,
            batch_index,
            {"input": row["input"], "expected_output": row["expected_output"]},
            current_leakage,
            stats,
        )
        current_structural.append(
            benchmark.as_audit_input("generated", row["id"], row["input"])
        )
        current_leakage.extend(
            [
                make_audit_text(
                    "generated",
                    row["id"],
                    "input",
                    row["input"],
                    source_kind="generated",
                    role=sealed_spec.role,
                    batch=batch_index,
                ),
                make_audit_text(
                    "generated",
                    row["id"],
                    "expected_output",
                    row["expected_output"],
                    source_kind="generated",
                    role=sealed_spec.role,
                    batch=batch_index,
                ),
            ]
        )
        current_families.add(benchmark.normalized(row["family"]))
    return current_structural, current_leakage, current_families


def receipt_paths_are_relative(receipt: dict[str, Any]) -> bool:
    relative = True

    def check(value: Any, key: str = "") -> None:
        nonlocal relative
        if isinstance(value, dict):
            for child_key, child in value.items():
                check(child, child_key)
        elif isinstance(value, list):
            for child in value:
                check(child, key)
        elif isinstance(value, str) and key.endswith("path") and Path(value).is_absolute():
            relative = False

    check(receipt)
    return relative


def validate_receipt(receipt: dict[str, Any]) -> None:
    required = {
        "status",
        "created_at_epoch",
        "assembly_parameters",
        "selection_manifest",
        "selection_verification",
        "portable_replay",
        "generator",
        "assembler",
        "audit_sources",
        "checkpoints",
        "outputs",
        "leakage_validation",
        "publication",
    }
    missing = required - set(receipt)
    if missing:
        raise ValueError(f"receipt is missing required fields: {sorted(missing)}")
    if receipt["assembly_parameters"].get("batch_id") in (None, ""):
        raise ValueError("receipt is missing batch_id")
    for pass_name in ("assembly_pass", "written_bytes_pass"):
        validation = receipt["leakage_validation"].get(pass_name, {})
        if not {
            "pair_comparison_count",
            "field_pair_comparison_counts",
            "relation_comparison_counts",
            "axis_maxima",
        }.issubset(validation):
            raise ValueError(f"receipt leakage pass is incomplete: {pass_name}")

    if not receipt_paths_are_relative(receipt):
        raise ValueError("receipt contains an absolute path")


def copy_exclusive(source: Path, destination: Path) -> None:
    with source.open("rb") as source_handle, destination.open("xb") as destination_handle:
        shutil.copyfileobj(source_handle, destination_handle)
        destination_handle.flush()
        os.fsync(destination_handle.fileno())


def publish_bundle(
    temp_bundle: Path,
    final_bundle: Path,
    receipt_bytes: bytes,
    expected_hashes: dict[str, str],
    *,
    before_receipt: Callable[[], None] | None = None,
) -> None:
    if final_bundle.exists():
        raise FileExistsError(f"refusing to overwrite bundle: {final_bundle}")
    temp_members = {
        str(path.relative_to(temp_bundle)) for path in temp_bundle.rglob("*") if path.is_file()
    }
    if temp_members != set(expected_hashes):
        raise ValueError("published member hash map does not bind every temporary bundle file")
    final_bundle.parent.mkdir(parents=True, exist_ok=True)
    created = False
    committed = False
    try:
        os.mkdir(final_bundle)
        created = True
        for source in sorted(temp_bundle.rglob("*")):
            relative = source.relative_to(temp_bundle)
            destination = final_bundle / relative
            if source.is_dir():
                os.mkdir(destination)
            else:
                copy_exclusive(source, destination)
        for relative, expected in expected_hashes.items():
            published_bytes, actual = read_once(
                final_bundle / relative, expected, "published bundle member"
            )
            if sha256_bytes(published_bytes) != actual:
                raise ValueError(f"published bundle member rehash failed: {relative}")
        if before_receipt is not None:
            before_receipt()
        write_exclusive_bytes(final_bundle / RECEIPT_NAME, receipt_bytes)
        committed = True
    except Exception:
        if created and not committed:
            shutil.rmtree(final_bundle)
        raise


def main() -> None:
    args = parse_args()
    if args.checkpoint_batch_size <= 0:
        raise SystemExit("--checkpoint-batch-size must be positive")
    selection_path = Path(args.selection_manifest).resolve()
    checkpoint_dir = Path(args.checkpoint_dir).resolve()
    final_bundle = Path(args.bundle_output).resolve()
    repo_relative(selection_path)
    repo_relative(final_bundle)
    if final_bundle.exists():
        raise SystemExit(f"refusing to overwrite bundle: {repo_relative(final_bundle)}")

    selection_bytes, selection_sha = read_once(
        selection_path, args.expected_selection_sha256, "selection manifest"
    )
    manifest = json.loads(selection_bytes.decode("utf-8"))
    verification = verify_sealed_selection(manifest, args.expected_definition_sha256)

    final_sources = final_bundle / "sources"
    final_checkpoints = final_bundle / "checkpoints"
    final_positive = final_bundle / "positive.jsonl"
    final_restraint = final_bundle / "restraint.jsonl"
    final_receipt = final_bundle / RECEIPT_NAME
    final_bundle.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="eg1-list-bundle-", dir=final_bundle.parent) as raw_temp:
        temp_bundle = Path(raw_temp) / "bundle"
        temp_sources = temp_bundle / "sources"
        temp_checkpoints = temp_bundle / "checkpoints"
        temp_sources.mkdir(parents=True)
        temp_checkpoints.mkdir()
        leakage, structural, families, source_receipts = snapshot_sources(
            manifest, verification, temp_sources, final_sources
        )
        source_leakage = list(leakage)
        source_structural = list(structural)
        source_families = set(families)
        assembly_stats = ComparisonStats()
        positive_rows, structural, leakage, families, positive_checkpoints = load_role_checkpoints(
            "positive_list",
            verification.positive_specs,
            checkpoint_dir,
            args.checkpoint_batch_size,
            args.batch_id,
            temp_checkpoints,
            final_checkpoints,
            structural,
            leakage,
            families,
            assembly_stats,
        )
        restraint_rows, _, _, _, restraint_checkpoints = load_role_checkpoints(
            "prose_restraint",
            verification.restraint_specs,
            checkpoint_dir,
            args.checkpoint_batch_size,
            args.batch_id,
            temp_checkpoints,
            final_checkpoints,
            structural,
            leakage,
            families,
            assembly_stats,
        )
        positive_bytes = encode_jsonl(positive_rows)
        restraint_bytes = encode_jsonl(restraint_rows)
        write_exclusive_bytes(temp_bundle / "positive.jsonl", positive_bytes)
        write_exclusive_bytes(temp_bundle / "restraint.jsonl", restraint_bytes)
        written_positive_bytes, positive_sha = read_once(
            temp_bundle / "positive.jsonl", sha256_bytes(positive_bytes), "positive output snapshot"
        )
        written_restraint_bytes, restraint_sha = read_once(
            temp_bundle / "restraint.jsonl", sha256_bytes(restraint_bytes), "restraint output snapshot"
        )
        written_positive = parse_rows_bytes(written_positive_bytes, "positive output snapshot")
        written_restraint = parse_rows_bytes(written_restraint_bytes, "restraint output snapshot")
        if written_positive != positive_rows or written_restraint != restraint_rows:
            raise ValueError("output snapshots reparse differently from validated rows")

        fresh_leakage = list(source_leakage)
        fresh_structural = list(source_structural)
        fresh_families = set(source_families)
        written_stats = ComparisonStats()
        fresh_structural, fresh_leakage, fresh_families = revalidate_enriched_rows(
            written_positive,
            verification.positive_specs,
            args.checkpoint_batch_size,
            fresh_structural,
            fresh_leakage,
            fresh_families,
            written_stats,
        )
        revalidate_enriched_rows(
            written_restraint,
            verification.restraint_specs,
            args.checkpoint_batch_size,
            fresh_structural,
            fresh_leakage,
            fresh_families,
            written_stats,
        )

        output_distribution = {
            "positive_list": benchmark.distributions(positive_rows),
            "prose_restraint": benchmark.distributions(restraint_rows),
        }
        if output_distribution != manifest["selected_distributions"]:
            raise ValueError("output distributions differ from regenerated sealed selection")
        generator_path = REPO_ROOT / GENERATOR_RELATIVE
        assembler_path = Path(__file__).resolve()
        receipt = {
            "status": "portable_leakage_validation_pass_candidate_requires_independent_review",
            "created_at_epoch": time.time(),
            "assembly_parameters": {
                "operation": "assemble_existing_checkpoints_only",
                "batch_id": args.batch_id,
                "checkpoint_batch_size": args.checkpoint_batch_size,
                "positive_count": len(positive_rows),
                "restraint_count": len(restraint_rows),
                "bundle_path": repo_relative(final_bundle),
            },
            "selection_manifest": {
                "path": repo_relative(selection_path),
                "sha256": selection_sha,
                "expected_sha256": args.expected_selection_sha256,
                "pilot_definition_sha256": manifest["pilot_definition_sha256"],
                "expected_pilot_definition_sha256": args.expected_definition_sha256,
            },
            "selection_verification": verification.receipt,
            "portable_replay": {
                "sealed_paths_lexically_remapped_to_current_repo": all(
                    remap_sealed_path(source["path"], verification.old_repo_root).is_relative_to(
                        REPO_ROOT
                    )
                    for source in manifest["audit_sources"]
                ),
                "source_bytes_snapshotted_in_bundle": len(source_receipts) > 0,
            },
            "generator": {
                "path": repo_relative(generator_path),
                "sha256": verification.receipt["live_generator_sha256"],
                "matches_sealed": verification.receipt["live_generator_matches_sealed"],
                "inactive_output_writer_exception": {
                    "generation_mode_invoked": False,
                    "generator_output_writer_invoked": False,
                    "reason": (
                        "The generator remains byte-exact through this sealed assembly; "
                        "only existing checkpoints are read. Its writers will be made "
                        "exclusive after successful bundle publication under a new hash."
                    ),
                },
            },
            "assembler": {
                "path": repo_relative(assembler_path),
                "sha256": benchmark.file_sha256(assembler_path),
            },
            "audit_sources": source_receipts,
            "checkpoints": {
                "positive_list": positive_checkpoints,
                "prose_restraint": restraint_checkpoints,
            },
            "outputs": {
                "positive_list": {
                    "path": repo_relative(final_positive),
                    "sha256": positive_sha,
                    "row_count": len(positive_rows),
                    "distributions": output_distribution["positive_list"],
                },
                "prose_restraint": {
                    "path": repo_relative(final_restraint),
                    "sha256": restraint_sha,
                    "row_count": len(restraint_rows),
                    "distributions": output_distribution["prose_restraint"],
                },
            },
            "leakage_validation": {
                "thresholds": benchmark.SIMILARITY_THRESHOLDS,
                "candidate_field_counts": written_stats.as_receipt()[
                    "candidate_field_counts"
                ],
                "source_fields": sorted(
                    {field for source in source_receipts for field in source["field_counts"]}
                ),
                "family_alias_fields": list(FAMILY_FIELDS),
                "assembly_pass": assembly_stats.as_receipt(),
                "written_bytes_pass": written_stats.as_receipt(),
            },
            "publication": {
                "strategy": "exclusive_single_bundle_receipt_last",
                "refuses_existing_bundle": not final_bundle.exists(),
                "commit_marker_path": repo_relative(final_receipt),
                "pre_receipt_failure_cleanup_scope": repo_relative(final_bundle),
            },
        }
        receipt["portable_replay"]["receipt_paths_repo_relative"] = (
            receipt_paths_are_relative(receipt)
        )
        validate_receipt(receipt)
        receipt_bytes = (
            json.dumps(receipt, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        ).encode()
        expected_hashes = {
            str(Path(source["snapshot_path"]).relative_to(repo_relative(final_bundle))): source[
                "sha256"
            ]
            for source in source_receipts
        }
        expected_hashes.update(
            {
                str(Path(checkpoint["path"]).relative_to(repo_relative(final_bundle))): checkpoint[
                    "sha256"
                ]
                for checkpoint in [*positive_checkpoints, *restraint_checkpoints]
            }
        )
        expected_hashes.update({"positive.jsonl": positive_sha, "restraint.jsonl": restraint_sha})
        publish_bundle(temp_bundle, final_bundle, receipt_bytes, expected_hashes)

    print(
        json.dumps(
            {
                "bundle": repo_relative(final_bundle),
                "receipt": repo_relative(final_receipt),
                "positive_rows": len(positive_rows),
                "restraint_rows": len(restraint_rows),
                "positive_sha256": positive_sha,
                "restraint_sha256": restraint_sha,
                "receipt_sha256": benchmark.file_sha256(final_receipt),
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
