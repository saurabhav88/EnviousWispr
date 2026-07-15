import copy
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock


EVAL_DIR = Path(__file__).resolve().parents[1]
if str(EVAL_DIR) not in sys.path:
    sys.path.insert(0, str(EVAL_DIR))

import build_eg1_multilingual_development_authoring as authoring
import multilingual_benchmark_v2 as v2


def valid_roster() -> dict:
    languages = list(v2.LANGUAGES)
    participants = []
    for role, prefix in (
        ("concept_author", "concept-author"),
        ("concept_reviewer", "concept-reviewer"),
    ):
        for index in range(1, 6):
            participants.append(
                {
                    "participant_id": f"custodian-{prefix}-{index:02d}",
                    "participant_type": "human",
                    "identity_reference_id": f"identity-{prefix}-{index:02d}",
                    "consent_reference_id": f"consent-{prefix}-{index:02d}",
                    "consent_status": "granted",
                    "availability_status": "confirmed",
                    "native_attestations": {},
                    "languages": [],
                    "roles": [role],
                }
            )
    for role, prefix in (("author", "author"), ("native_reviewer", "reviewer")):
        for index in range(1, 6):
            participants.append(
                {
                    "participant_id": f"native-{prefix}-{index:02d}",
                    "participant_type": "human_native",
                    "identity_reference_id": f"identity-{prefix}-{index:02d}",
                    "consent_reference_id": f"consent-{prefix}-{index:02d}",
                    "consent_status": "granted",
                    "availability_status": "confirmed",
                    "native_attestations": {
                        language: True for language in languages
                    },
                    "languages": list(languages),
                    "roles": [role],
                }
            )
    return {
        "schema_version": authoring.ROSTER_SCHEMA,
        "roster_id": "roster-dev-v1",
        "status": "approved_for_development_authoring",
        "approved_by_id": "approver-native-v1",
        "approved_at": "2026-07-15T18:00:00Z",
        "approval_reference_id": "approval-ref-v1",
        "candidate_model_output_seen": False,
        "participants": participants,
    }


def formatting_for(behavior: str) -> dict:
    contract = v2.EXPECTED_LIST_CONTRACT[behavior]
    item_count = None
    if behavior in {"explicit_two_item_list", "scoped_two_item_list"}:
        item_count = 2
    elif behavior in {
        "natural_three_to_five_item_bullet_list",
        "spoken_ordinals_numbered_list",
    }:
        item_count = 3
    return {
        "list_contract": contract,
        "expected_item_count": item_count,
        "shared_scope": "shared deadline" if contract.startswith("activate") else "",
    }


def valid_brief_concepts(allocation: list[dict]) -> list[dict]:
    concepts = []
    for index, allocated in enumerate(
        authoring.shared_brief_allocations(allocation).values(), 1
    ):
        brief = f"Private shared concept brief {index}"
        concepts.append(
            {
                **allocated,
                "brief": brief,
                "brief_sha256": authoring.sha256_bytes(brief.encode("utf-8")),
                "concept_author_id": f"identity-concept-author-{((index - 1) % 5) + 1:02d}",
                "concept_reviewer_id": f"identity-concept-reviewer-{((index - 1) % 5) + 1:02d}",
                "language_neutrality_approved": True,
                "meaning_safety_approved": True,
                "family_separation_approved": True,
                "independent_review": True,
                "candidate_model_output_seen": False,
            }
        )
    return concepts


def valid_brief_registry(allocation: list[dict]) -> dict:
    return {
        "schema_version": authoring.SHARED_BRIEF_REGISTRY_SCHEMA,
        "status": "sealed_for_development_authoring",
        "allocation_receipt_sha256": "a" * 64,
        "allocation_execution_git_head": "1" * 40,
        "producing_git_head": "2" * 40,
        "sealing_git_head": "2" * 40,
        "roster_id": "roster-dev-v1",
        "roster_sha256": "b" * 64,
        "candidate_model_output_seen": False,
        "assurance_scope": authoring.ASSURANCE_SCOPE,
        "concepts": valid_brief_concepts(allocation),
    }


def completed_rows(allocation: list[dict], assignments: list[dict], registry_sha: str | None = None) -> list[dict]:
    assignment_by_case = {row["case_id"]: row for row in assignments}
    rows = []
    for index, slot in enumerate(allocation):
        assignment = assignment_by_case[slot["case_id"]]
        provenance = {
            "source_type": slot["source_type"],
            "source_ref": assignment["assignment_id"],
            "native_author": {
                "reviewer_id": assignment["author_id"],
                "locale": f"{slot['language']}-native",
                "native_attested": True,
                "status": "complete",
                "reviewed_on": "2026-07-15",
            },
            "independent_native_validator": {
                "reviewer_id": assignment["native_reviewer_id"],
                "locale": f"{slot['language']}-native",
                "native_attested": True,
                "status": "approved",
                "reviewed_on": "2026-07-15",
                "independent_of_author": True,
            },
        }
        if registry_sha is not None:
            provenance["blocked_family_clearances"] = [
                {
                    "registry_sha256": registry_sha,
                    "candidate_semantic_family_id": slot["semantic_family_id"],
                    "reviewer_id": assignment["native_reviewer_id"],
                    "independent_of_author": True,
                    "status": "cleared",
                    "reviewed_on": "2026-07-15",
                }
            ]
        if slot["shared_concept_brief_id"] is not None:
            provenance["shared_concept_binding"] = {
                "brief_id": assignment["shared_concept_brief_id"],
                "brief_sha256": assignment["shared_concept_brief_sha256"],
                "independent_local_rewrite": True,
                "candidate_model_output_seen": False,
            }
        rows.append(
            {
                "schema_version": v2.SCHEMA_VERSION,
                **{field: slot[field] for field in authoring.IMMUTABLE_ROW_BINDINGS},
                "asr_input": f"{slot['language']} unique spoken input {index}",
                "gold_output": f"{slot['language']} unique polished output {index}",
                "requirements": {
                    "meaning": f"Preserve unique intent {index}",
                    "entities": [],
                    "numbers": [],
                    "timing": [],
                    "attribution": [],
                    "formatting": formatting_for(slot["behavior"]),
                },
                "provenance": provenance,
            }
        )
    return rows


def native_review_seal(rows: list[dict], assignments: list[dict], corpus_sha: str, allocation_sha: str, launch_sha: str) -> dict:
    assignments_by_case = {row["case_id"]: row for row in assignments}
    return {
        "schema_version": authoring.NATIVE_REVIEW_SEAL_SCHEMA,
        "status": "all_800_independent_native_reviews_approved",
        "corpus_sha256": corpus_sha,
        "benchmark_content_sha256": v2.benchmark_content_sha256(rows),
        "allocation_receipt_sha256": allocation_sha,
        "launch_receipt_sha256": launch_sha,
        "candidate_model_output_seen": False,
        "assurance_scope": authoring.ASSURANCE_SCOPE,
        "reviews": [
            {
                "case_id": row["case_id"],
                "assignment_id": assignments_by_case[row["case_id"]]["assignment_id"],
                "author_id": assignments_by_case[row["case_id"]]["author_id"],
                "reviewer_id": assignments_by_case[row["case_id"]]["native_reviewer_id"],
                "author_native_attested": True,
                "reviewer_native_attested": True,
                "independent_of_author": True,
                "status": "approved",
                "row_sha256": v2.sha256_bytes(v2.canonical_json(row).encode("utf-8")),
                "shared_concept_brief_id": assignments_by_case[row["case_id"]][
                    "shared_concept_brief_id"
                ],
                "shared_concept_brief_sha256": assignments_by_case[
                    row["case_id"]
                ]["shared_concept_brief_sha256"],
                "faithful_to_shared_brief": (
                    True
                    if assignments_by_case[row["case_id"]][
                        "shared_concept_brief_id"
                    ]
                    is not None
                    else None
                ),
            }
            for row in rows
        ],
    }


def comparability_seal(
    rows: list[dict],
    allocation: list[dict],
    assignments: list[dict],
    corpus_sha: str,
    allocation_sha: str,
    launch_sha: str,
    *,
    balanced: bool = True,
) -> dict:
    rows_by_case = {row["case_id"]: row for row in rows}
    allocation_by_case = {row["case_id"]: row for row in allocation}
    assignments_by_case = {row["case_id"]: row for row in assignments}
    groups = {}
    for slot in allocation:
        if slot["contrast_set_id"] is not None:
            groups.setdefault(slot["contrast_set_id"], []).append(slot)
    reviews = []
    reviewer_ids = [f"native-reviewer-{index:02d}" for index in range(1, 6)]
    reviewer_counts = Counter()
    for contrast_id, members in sorted(groups.items()):
        positive = next(
            row for row in members if row["behavior"] in v2.POSITIVE_LIST_BEHAVIORS
        )
        restraint = next(
            row for row in members if row["behavior"] in v2.RESTRAINT_BEHAVIORS
        )
        excluded = {
            assignments_by_case[positive["case_id"]]["author_id"],
            assignments_by_case[restraint["case_id"]]["author_id"],
            assignments_by_case[positive["case_id"]]["native_reviewer_id"],
            assignments_by_case[restraint["case_id"]]["native_reviewer_id"],
        }
        language = positive["language"]
        eligible_reviewers = [
            value for value in reviewer_ids if value not in excluded
        ]
        reviewer_id = (
            min(
                eligible_reviewers,
                key=lambda value: (reviewer_counts[(language, value)], value),
            )
            if balanced
            else eligible_reviewers[0]
        )
        reviewer_counts[(language, reviewer_id)] += 1
        reviews.append(
            {
                "contrast_set_id": contrast_id,
                "contrast_brief_id": positive["contrast_brief_id"],
                "contrast_archetype": positive["contrast_archetype"],
                "positive_case_id": positive["case_id"],
                "restraint_case_id": restraint["case_id"],
                "positive_row_sha256": v2.sha256_bytes(
                    v2.canonical_json(rows_by_case[positive["case_id"]]).encode(
                        "utf-8"
                    )
                ),
                "restraint_row_sha256": v2.sha256_bytes(
                    v2.canonical_json(rows_by_case[restraint["case_id"]]).encode(
                        "utf-8"
                    )
                ),
                "reviewer_id": reviewer_id,
                "reviewer_native_attested": True,
                "independent_of_authors_and_row_reviewers": True,
                "status": "comparable",
            }
        )
    if balanced:
        counts = Counter(
            (
                allocation_by_case[review["positive_case_id"]]["language"],
                review["reviewer_id"],
            )
            for review in reviews
        )
        for language in v2.LANGUAGES:
            while any(
                counts[(language, reviewer_id)] != 8
                for reviewer_id in reviewer_ids
            ):
                moved = False
                for review in reviews:
                    positive = allocation_by_case[review["positive_case_id"]]
                    if positive["language"] != language:
                        continue
                    current = review["reviewer_id"]
                    if counts[(language, current)] <= 8:
                        continue
                    restraint = allocation_by_case[review["restraint_case_id"]]
                    excluded = {
                        assignments_by_case[positive["case_id"]]["author_id"],
                        assignments_by_case[restraint["case_id"]]["author_id"],
                        assignments_by_case[positive["case_id"]][
                            "native_reviewer_id"
                        ],
                        assignments_by_case[restraint["case_id"]][
                            "native_reviewer_id"
                        ],
                    }
                    target = next(
                        (
                            reviewer_id
                            for reviewer_id in reviewer_ids
                            if reviewer_id not in excluded
                            and counts[(language, reviewer_id)] < 8
                        ),
                        None,
                    )
                    if target is None:
                        continue
                    review["reviewer_id"] = target
                    counts[(language, current)] -= 1
                    counts[(language, target)] += 1
                    moved = True
                    break
                if not moved:
                    raise AssertionError(
                        f"could not balance comparability fixture for {language}"
                    )
    return {
        "schema_version": authoring.CONTRAST_COMPARABILITY_SEAL_SCHEMA,
        "status": "all_200_model_blind_contrast_sets_comparable",
        "corpus_sha256": corpus_sha,
        "benchmark_content_sha256": v2.benchmark_content_sha256(rows),
        "allocation_receipt_sha256": allocation_sha,
        "launch_receipt_sha256": launch_sha,
        "candidate_model_output_seen": False,
        "assurance_scope": authoring.ASSURANCE_SCOPE,
        "reviews": reviews,
    }


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


class DevelopmentAuthoringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.contract = json.loads(authoring.CONTRACT_PATH.read_text(encoding="utf-8"))

    def setUp(self) -> None:
        self.allocation = authoring.build_allocation(self.contract)
        self.brief_concepts = valid_brief_concepts(self.allocation)
        self.participants = authoring.validate_roster(valid_roster(), self.contract)
        self.assignments, self.author_packets, self.reviewer_packets = authoring.build_assignments(
            self.allocation,
            self.participants,
            self.contract["seed"],
            self.brief_concepts,
        )

    def test_allocation_is_exact_deterministic_800_row_matrix(self) -> None:
        repeated = authoring.build_allocation(self.contract)
        self.assertEqual(self.allocation, repeated)
        self.assertEqual(len(self.allocation), 800)
        self.assertEqual(Counter(row["language"] for row in self.allocation), Counter({language: 160 for language in v2.LANGUAGES}))
        cells = Counter((row["language"], row["behavior"], row["domain"]) for row in self.allocation)
        self.assertEqual(set(cells.values()), {2})
        self.assertEqual(len(cells), 5 * 16 * 5)

    def test_allocation_is_exact_80_20_native_shared_per_language(self) -> None:
        counts = Counter((row["language"], row["source_type"]) for row in self.allocation)
        for language in v2.LANGUAGES:
            self.assertEqual(counts[(language, "native_original")], 128)
            self.assertEqual(counts[(language, "shared_concept_local_rewrite")], 32)

    def test_contrasts_are_source_matched_and_difficulty_is_cell_varying(self) -> None:
        contrasts = {}
        for row in self.allocation:
            if row["contrast_set_id"] is not None:
                contrasts.setdefault(row["contrast_set_id"], []).append(row)
        self.assertEqual(len(contrasts), 200)
        source_counts = Counter()
        for members in contrasts.values():
            self.assertEqual(len(members), 2)
            self.assertEqual(len({row["source_type"] for row in members}), 1)
            self.assertEqual(len({row["difficulty"] for row in members}), 1)
            self.assertEqual(len({row["contrast_brief_id"] for row in members}), 1)
            source_counts[members[0]["source_type"]] += 1
        self.assertEqual(
            source_counts,
            Counter(
                {"native_original": 160, "shared_concept_local_rewrite": 40}
            ),
        )
        for language in v2.LANGUAGES:
            for behavior in v2.BEHAVIORS:
                self.assertEqual(
                    {
                        row["difficulty"]
                        for row in self.allocation
                        if row["language"] == language
                        and row["behavior"] == behavior
                    },
                    {"routine", "challenging", "adversarial"},
                )
        family_counts = Counter(row["semantic_family_id"] for row in self.allocation)
        self.assertEqual(len(family_counts), 672)
        self.assertEqual(Counter(family_counts.values()), Counter({1: 640, 5: 32}))

    def test_authentication_rejects_coherently_rehashed_noncanonical_allocation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "allocation"
            authoring.allocate_bundle(
                contract=self.contract,
                output=bundle,
                execution_git_head="1" * 40,
            )
            rows = authoring.parse_rows(
                (bundle / "allocation.jsonl").read_bytes(), "allocation"
            )
            rows[0]["semantic_family_id"] = "eg1d-family-coherent-forgery"
            allocation_bytes = authoring.encode_jsonl(rows)
            (bundle / "allocation.jsonl").write_bytes(allocation_bytes)
            receipt = json.loads((bundle / "receipt.json").read_text(encoding="utf-8"))
            receipt["artifacts"]["allocation.jsonl"]["sha256"] = authoring.sha256_bytes(
                allocation_bytes
            )
            receipt["artifacts"]["allocation.jsonl"]["bytes"] = len(allocation_bytes)
            write_json(bundle / "receipt.json", receipt)
            with mock.patch.object(
                authoring, "validate_control_receipt", return_value=self.contract
            ), self.assertRaisesRegex(authoring.ValidationFailure, "deterministic"):
                authoring.authenticate_allocation(
                    bundle / "receipt.json", self.contract, "1" * 40
                )

    def test_allocation_bundle_and_receipt_bytes_are_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            left = root / "left"
            right = root / "right"
            authoring.allocate_bundle(
                contract=self.contract,
                output=left,
                execution_git_head="1" * 40,
            )
            authoring.allocate_bundle(
                contract=self.contract,
                output=right,
                execution_git_head="1" * 40,
            )
            for name in authoring.ALLOCATION_ARTIFACTS:
                self.assertEqual((left / name).read_bytes(), (right / name).read_bytes())
            receipt = json.loads((left / "receipt.json").read_text(encoding="utf-8"))
            self.assertEqual(receipt["counts"]["rows"], 800)
            self.assertFalse(receipt["gates"]["evaluation_eligible"])
            self.assertTrue(receipt["privacy"]["metadata_only"])

    def test_author_and_reviewer_packets_are_balanced_and_model_blind(self) -> None:
        for role in ("author", "native_reviewer"):
            packets = authoring.build_packets(self.allocation, role)
            self.assertEqual(len(packets), 50)
            for packet in packets:
                self.assertEqual(packet["row_count"], 16)
                self.assertEqual(set(packet["behavior_counts"].values()), {1})
                self.assertLessEqual(max(packet["domain_counts"].values()) - min(packet["domain_counts"].values()), 1)
                self.assertFalse(packet["candidate_model_output_seen"])
                self.assertFalse(packet["prose_authored"])
                self.assertNotIn("participant_id", packet)

    def test_allocation_rejects_missing_duplicate_and_mutated_cells(self) -> None:
        with self.assertRaisesRegex(authoring.ValidationFailure, "expected 800"):
            authoring.validate_allocation(self.allocation[:-1], self.contract)
        duplicate = copy.deepcopy(self.allocation)
        duplicate[-1]["case_id"] = duplicate[0]["case_id"]
        with self.assertRaisesRegex(authoring.ValidationFailure, "duplicate"):
            authoring.validate_allocation(duplicate, self.contract)
        changed = copy.deepcopy(self.allocation)
        changed[0]["domain"] = "medical"
        with self.assertRaises(authoring.ValidationFailure):
            authoring.validate_allocation(changed, self.contract)

    def test_allocation_rejects_candidate_output_and_identity_fields(self) -> None:
        exposed = copy.deepcopy(self.allocation)
        exposed[0]["candidate_model_output_seen"] = True
        with self.assertRaisesRegex(authoring.ValidationFailure, "candidate output"):
            authoring.validate_allocation(exposed, self.contract)
        identity = copy.deepcopy(self.allocation)
        identity[0]["author_id"] = "person-01"
        with self.assertRaisesRegex(authoring.ValidationFailure, "schema changed"):
            authoring.validate_allocation(identity, self.contract)

    def test_allocation_rejects_shared_family_signature_drift(self) -> None:
        changed = copy.deepcopy(self.allocation)
        shared = next(row for row in changed if row["source_type"] == "shared_concept_local_rewrite")
        sibling = next(row for row in changed if row["semantic_family_id"] == shared["semantic_family_id"] and row["case_id"] != shared["case_id"])
        sibling["difficulty"] = "adversarial" if shared["difficulty"] != "adversarial" else "routine"
        with self.assertRaisesRegex(authoring.ValidationFailure, "family changes"):
            authoring.validate_allocation(changed, self.contract)

    def test_shared_brief_registry_accepts_exact_32_by_5_allocation(self) -> None:
        registry = valid_brief_registry(self.allocation)
        with mock.patch.object(
            authoring, "require_strict_git_descendant"
        ), mock.patch.object(authoring, "require_git_ancestor"):
            concepts = authoring.validate_shared_brief_registry(
                registry,
                self.allocation,
                "a" * 64,
                "1" * 40,
                "2" * 40,
                self.participants,
                "roster-dev-v1",
                "b" * 64,
            )
        self.assertEqual(len(concepts), 32)
        self.assertEqual(len({row["brief_id"] for row in concepts}), 32)
        self.assertTrue(all(len(row["languages"]) == 5 for row in concepts))

    def test_shared_brief_registry_rejects_tamper_duplicate_and_candidate_output(self) -> None:
        attacks = {}
        changed = valid_brief_registry(self.allocation)
        changed["concepts"][0]["semantic_family_id"] = "unrelated-family"
        attacks["unrelated"] = changed
        changed = valid_brief_registry(self.allocation)
        changed["concepts"][0]["brief_sha256"] = "0" * 64
        attacks["hash"] = changed
        changed = valid_brief_registry(self.allocation)
        changed["concepts"][1]["brief"] = changed["concepts"][0]["brief"]
        changed["concepts"][1]["brief_sha256"] = changed["concepts"][0]["brief_sha256"]
        attacks["duplicate prose"] = changed
        changed = valid_brief_registry(self.allocation)
        changed["concepts"][0]["languages"].pop()
        attacks["missing language"] = changed
        changed = valid_brief_registry(self.allocation)
        changed["concepts"][0]["concept_reviewer_id"] = changed["concepts"][0]["concept_author_id"]
        attacks["identity collision"] = changed
        changed = valid_brief_registry(self.allocation)
        changed["concepts"][0]["concept_author_id"] = "arbitrary-unregistered-identity"
        attacks["unregistered concept custodian"] = changed
        changed = valid_brief_registry(self.allocation)
        changed["concepts"][0]["concept_author_id"] = "native-author-01"
        attacks["participant ID alias"] = changed
        changed = valid_brief_registry(self.allocation)
        changed["concepts"][0]["concept_author_id"] = "identity-author-01"
        attacks["wrong local role"] = changed
        changed = valid_brief_registry(self.allocation)
        for concept in changed["concepts"]:
            concept["concept_author_id"] = "identity-concept-author-01"
        attacks["one concept author"] = changed
        changed = valid_brief_registry(self.allocation)
        for concept in changed["concepts"][:9]:
            concept["concept_author_id"] = "identity-concept-author-01"
        attacks["concept author over cap"] = changed
        changed = valid_brief_registry(self.allocation)
        changed["concepts"][0]["candidate_output"] = "forbidden"
        attacks["candidate key"] = changed
        changed = valid_brief_registry(self.allocation)
        changed["concepts"][0]["candidate_model_output_seen"] = True
        attacks["candidate flag"] = changed
        with mock.patch.object(
            authoring, "require_strict_git_descendant"
        ), mock.patch.object(authoring, "require_git_ancestor"):
            for name, registry in attacks.items():
                with self.subTest(attack=name), self.assertRaises(
                    authoring.ValidationFailure
                ):
                    authoring.validate_shared_brief_registry(
                        registry,
                        self.allocation,
                        "a" * 64,
                        "1" * 40,
                        "2" * 40,
                        self.participants,
                        "roster-dev-v1",
                        "b" * 64,
                    )

    def test_shared_brief_registry_requires_strict_descendant_seal(self) -> None:
        registry = valid_brief_registry(self.allocation)
        registry["producing_git_head"] = "1" * 40
        registry["sealing_git_head"] = "1" * 40
        with self.assertRaisesRegex(authoring.ValidationFailure, "strict descendant"):
            authoring.validate_shared_brief_registry(
                registry,
                self.allocation,
                "a" * 64,
                "1" * 40,
                "1" * 40,
                self.participants,
                "roster-dev-v1",
                "b" * 64,
            )

    def test_contract_cannot_weaken_row_count_or_candidate_output_gate(self) -> None:
        weak = copy.deepcopy(self.contract)
        weak["allocation"]["total_rows"] = 799
        with self.assertRaisesRegex(authoring.ValidationFailure, "allocation contract changed"):
            authoring.validate_contract(weak)
        weak = copy.deepcopy(self.contract)
        weak["publication"]["candidate_model_output_allowed"] = True
        with self.assertRaisesRegex(authoring.ValidationFailure, "publication guardrails"):
            authoring.validate_contract(weak)

    def test_roster_requires_opaque_disjoint_native_human_lanes(self) -> None:
        participants = authoring.validate_roster(valid_roster(), self.contract)
        self.assertEqual(len(participants), 20)
        overlap = valid_roster()
        overlap["participants"][0]["roles"] = ["author", "native_reviewer"]
        with self.assertRaisesRegex(authoring.ValidationFailure, "singular and disjoint"):
            authoring.validate_roster(overlap, self.contract)
        pii = valid_roster()
        pii["participants"][0]["email"] = "person@example.test"
        with self.assertRaisesRegex(authoring.ValidationFailure, "schema changed"):
            authoring.validate_roster(pii, self.contract)

    def test_roster_rejects_duplicate_identity_and_missing_language_lane(self) -> None:
        duplicate = valid_roster()
        duplicate["participants"][1]["identity_reference_id"] = duplicate["participants"][0]["identity_reference_id"]
        with self.assertRaisesRegex(authoring.ValidationFailure, "duplicate"):
            authoring.validate_roster(duplicate, self.contract)
        cross_namespace = valid_roster()
        cross_namespace["participants"][0]["participant_id"] = (
            cross_namespace["participants"][1]["identity_reference_id"]
        )
        with self.assertRaisesRegex(authoring.ValidationFailure, "namespaces"):
            authoring.validate_roster(cross_namespace, self.contract)
        missing = valid_roster()
        local_author = next(
            participant
            for participant in missing["participants"]
            if participant["participant_id"] == "native-author-02"
        )
        local_author["languages"].remove("ru")
        del local_author["native_attestations"]["ru"]
        with self.assertRaisesRegex(authoring.ValidationFailure, "ru: at least 5"):
            authoring.validate_roster(missing, self.contract)

    def test_assignments_cover_all_rows_and_separate_identities(self) -> None:
        self.assertEqual(len(self.assignments), 800)
        self.assertEqual(len(self.author_packets), 50)
        self.assertEqual(len(self.reviewer_packets), 50)
        self.assertTrue(all(row["author_id"] != row["native_reviewer_id"] for row in self.assignments))
        self.assertTrue(all(row["candidate_model_output_seen"] is False for row in self.assignments))
        for packets in (self.author_packets, self.reviewer_packets):
            counts = Counter(
                (packet["language"], packet["participant_id"])
                for packet in packets
            )
            self.assertEqual(set(counts.values()), {2})

    def test_assignments_reject_concept_and_local_identity_collision(self) -> None:
        concepts = copy.deepcopy(self.brief_concepts)
        shared_brief_id = concepts[0]["brief_id"]
        local = next(
            row
            for row in self.assignments
            if row["shared_concept_brief_id"] == shared_brief_id
        )
        local_identity_reference = next(
            participant["identity_reference_id"]
            for participant in self.participants
            if participant["participant_id"] == local["author_id"]
        )
        self.assertNotEqual(local["author_id"], local_identity_reference)
        concepts[0]["concept_author_id"] = local_identity_reference
        with self.assertRaisesRegex(authoring.ValidationFailure, "identities must be distinct"):
            authoring.build_assignments(
                self.allocation,
                authoring.validate_roster(valid_roster(), self.contract),
                self.contract["seed"],
                concepts,
            )

    def test_roster_requires_five_people_and_per_language_attestations(self) -> None:
        missing_concept_role = valid_roster()
        missing_concept_role["participants"] = [
            participant
            for participant in missing_concept_role["participants"]
            if participant["roles"] != ["concept_author"]
        ]
        with self.assertRaisesRegex(authoring.ValidationFailure, "concept_author"):
            authoring.validate_roster(missing_concept_role, self.contract)
        too_small = valid_roster()
        too_small["participants"] = [
            participant
            for participant in too_small["participants"]
            if participant["participant_id"] != "native-author-05"
        ]
        with self.assertRaisesRegex(authoring.ValidationFailure, "at least 5"):
            authoring.validate_roster(too_small, self.contract)
        false_attestation = valid_roster()
        local_author = next(
            participant
            for participant in false_attestation["participants"]
            if participant["participant_id"] == "native-author-01"
        )
        local_author["native_attestations"]["de"] = False
        with self.assertRaisesRegex(authoring.ValidationFailure, "per-language"):
            authoring.validate_roster(false_attestation, self.contract)

    def test_final_rows_require_exact_allocation_and_launch_bindings(self) -> None:
        rows = completed_rows(self.allocation, self.assignments)
        authoring.validate_development_rows(rows, self.allocation, self.assignments)
        changed = copy.deepcopy(rows)
        changed[0]["provenance"]["native_author"]["reviewer_id"] = "substitute-author"
        with self.assertRaisesRegex(authoring.ValidationFailure, "native author differs"):
            authoring.validate_development_rows(changed, self.allocation, self.assignments)
        changed = copy.deepcopy(rows)
        changed[0]["difficulty"] = "adversarial" if changed[0]["difficulty"] != "adversarial" else "routine"
        with self.assertRaises(authoring.ValidationFailure):
            authoring.validate_development_rows(changed, self.allocation, self.assignments)

    def test_final_rows_reject_candidate_output_exposure(self) -> None:
        rows = completed_rows(self.allocation, self.assignments)
        rows[0]["requirements"]["model_output"] = "secret arm text"
        with self.assertRaises(authoring.ValidationFailure):
            authoring.validate_development_rows(rows, self.allocation, self.assignments)
        with self.assertRaisesRegex(authoring.ValidationFailure, "candidate-output field"):
            authoring.recursively_reject_candidate_output({"candidate_output": "x"})
        with self.assertRaisesRegex(authoring.ValidationFailure, "exposure is forbidden"):
            authoring.recursively_reject_candidate_output(
                {"scanner_provenance": {"candidate_model_output_seen": True}}
            )
        authoring.recursively_reject_candidate_output(
            {"scanner_provenance": {"candidate_model_output_seen": False}}
        )

    def test_shared_row_requires_brief_binding_and_native_row_forbids_it(self) -> None:
        rows = completed_rows(self.allocation, self.assignments)
        shared_index = next(
            index
            for index, row in enumerate(rows)
            if row["provenance"]["source_type"] == "shared_concept_local_rewrite"
        )
        missing = copy.deepcopy(rows)
        del missing[shared_index]["provenance"]["shared_concept_binding"]
        with self.assertRaises(authoring.ValidationFailure):
            authoring.validate_development_rows(
                missing, self.allocation, self.assignments
            )
        native_index = next(
            index
            for index, row in enumerate(rows)
            if row["provenance"]["source_type"] == "native_original"
        )
        native = copy.deepcopy(rows)
        native[native_index]["shared_concept_brief_id"] = "brief-forbidden"
        native[native_index]["provenance"]["shared_concept_binding"] = {
            "brief_id": "brief-forbidden",
            "brief_sha256": "0" * 64,
            "independent_local_rewrite": True,
            "candidate_model_output_seen": False,
        }
        with self.assertRaises(authoring.ValidationFailure):
            authoring.validate_development_rows(
                native, self.allocation, self.assignments
            )

    def test_native_review_seal_binds_every_row_assignment_and_hash(self) -> None:
        rows = completed_rows(self.allocation, self.assignments)
        corpus = authoring.encode_jsonl(rows)
        seal = native_review_seal(rows, self.assignments, authoring.sha256_bytes(corpus), "a" * 64, "b" * 64)
        authoring.validate_native_review_seal(seal, rows, self.assignments, authoring.sha256_bytes(corpus), "a" * 64, "b" * 64, self.brief_concepts, self.participants)
        stale = copy.deepcopy(seal)
        stale["reviews"][0]["row_sha256"] = "0" * 64
        with self.assertRaisesRegex(authoring.ValidationFailure, "binding is stale"):
            authoring.validate_native_review_seal(stale, rows, self.assignments, authoring.sha256_bytes(corpus), "a" * 64, "b" * 64, self.brief_concepts, self.participants)

    def test_native_review_seal_rejects_duplicate_and_identity_collision(self) -> None:
        rows = completed_rows(self.allocation, self.assignments)
        corpus_sha = authoring.sha256_bytes(authoring.encode_jsonl(rows))
        seal = native_review_seal(rows, self.assignments, corpus_sha, "a" * 64, "b" * 64)
        seal["reviews"][1]["case_id"] = seal["reviews"][0]["case_id"]
        with self.assertRaisesRegex(authoring.ValidationFailure, "duplicate"):
            authoring.validate_native_review_seal(seal, rows, self.assignments, corpus_sha, "a" * 64, "b" * 64, self.brief_concepts, self.participants)
        seal = native_review_seal(
            rows, self.assignments, corpus_sha, "a" * 64, "b" * 64
        )
        concepts = copy.deepcopy(self.brief_concepts)
        shared_assignment = next(
            assignment
            for assignment in self.assignments
            if assignment["shared_concept_brief_id"] is not None
        )
        reviewer_identity_reference = next(
            participant["identity_reference_id"]
            for participant in self.participants
            if participant["participant_id"]
            == shared_assignment["native_reviewer_id"]
        )
        concept = next(
            concept
            for concept in concepts
            if concept["brief_id"]
            == shared_assignment["shared_concept_brief_id"]
        )
        concept["concept_reviewer_id"] = reviewer_identity_reference
        with self.assertRaisesRegex(authoring.ValidationFailure, "concept custody"):
            authoring.validate_native_review_seal(
                seal,
                rows,
                self.assignments,
                corpus_sha,
                "a" * 64,
                "b" * 64,
                concepts,
                self.participants,
            )

    def test_contrast_comparability_requires_independent_full_coverage(self) -> None:
        rows = completed_rows(self.allocation, self.assignments)
        corpus_sha = authoring.sha256_bytes(authoring.encode_jsonl(rows))
        seal = comparability_seal(
            rows,
            self.allocation,
            self.assignments,
            corpus_sha,
            "a" * 64,
            "b" * 64,
        )
        authoring.validate_contrast_comparability_seal(
            seal,
            rows,
            self.allocation,
            self.assignments,
            self.participants,
            corpus_sha,
            "a" * 64,
            "b" * 64,
        )
        imbalanced = comparability_seal(
            rows,
            self.allocation,
            self.assignments,
            corpus_sha,
            "a" * 64,
            "b" * 64,
            balanced=False,
        )
        with self.assertRaisesRegex(
            authoring.ValidationFailure, "diversity or workload cap"
        ):
            authoring.validate_contrast_comparability_seal(
                imbalanced,
                rows,
                self.allocation,
                self.assignments,
                self.participants,
                corpus_sha,
                "a" * 64,
                "b" * 64,
            )
        stale = copy.deepcopy(seal)
        stale["reviews"][0]["positive_row_sha256"] = "0" * 64
        with self.assertRaisesRegex(authoring.ValidationFailure, "binding is stale"):
            authoring.validate_contrast_comparability_seal(
                stale,
                rows,
                self.allocation,
                self.assignments,
                self.participants,
                corpus_sha,
                "a" * 64,
                "b" * 64,
            )
        collided = copy.deepcopy(seal)
        case_id = collided["reviews"][0]["positive_case_id"]
        collided["reviews"][0]["reviewer_id"] = next(
            row["native_reviewer_id"]
            for row in self.assignments
            if row["case_id"] == case_id
        )
        with self.assertRaisesRegex(authoring.ValidationFailure, "not independent"):
            authoring.validate_contrast_comparability_seal(
                collided,
                rows,
                self.allocation,
                self.assignments,
                self.participants,
                corpus_sha,
                "a" * 64,
                "b" * 64,
            )
        seal = native_review_seal(rows, self.assignments, corpus_sha, "a" * 64, "b" * 64)
        seal["reviews"][0]["reviewer_id"] = seal["reviews"][0]["author_id"]
        with self.assertRaises(authoring.ValidationFailure):
            authoring.validate_native_review_seal(seal, rows, self.assignments, corpus_sha, "a" * 64, "b" * 64, self.brief_concepts, self.participants)

    def test_publish_bundle_detects_mutation_and_removes_partial_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.json"
            source.write_text("original", encoding="utf-8")
            output = root / "bundle"
            snapshots = {source: authoring.read_snapshot(source, "source")[1]}
            def mutate() -> None:
                source.write_text("changed", encoding="utf-8")
            with self.assertRaisesRegex(authoring.ValidationFailure, "changed during publication"):
                authoring.publish_bundle(output, {"data.json": b"{}\n"}, b"{}\n", snapshots, mutate)
            self.assertFalse(output.exists())
            source.write_text("stable", encoding="utf-8")
            output = root / "bundle-output-mutation"
            snapshots = {source: authoring.read_snapshot(source, "source")[1]}
            def mutate_output() -> None:
                (output / "data.json").write_bytes(b"tampered\n")
            with self.assertRaisesRegex(authoring.ValidationFailure, "artifact changed"):
                authoring.publish_bundle(output, {"data.json": b"{}\n"}, b"{}\n", snapshots, mutate_output)
            self.assertFalse(output.exists())

    def test_launch_snapshots_roster_before_validation_and_cleans_on_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            allocation_bundle = root / "allocation"
            shared_brief_bundle = root / "shared-briefs"
            allocation_bundle.mkdir()
            shared_brief_bundle.mkdir()
            allocation_blobs = {}
            for name in authoring.ALLOCATION_ARTIFACTS:
                path = allocation_bundle / name
                path.write_bytes(b"{}\n")
                allocation_blobs[name] = b"{}\n"
            shared_brief_blobs = {}
            for name in authoring.SHARED_BRIEF_ARTIFACTS:
                path = shared_brief_bundle / name
                path.write_bytes(b"{}\n")
                shared_brief_blobs[name] = b"{}\n"
            roster_path = root / "roster.json"
            write_json(roster_path, valid_roster())
            output = root / "launch"

            def mutate_roster(*_args, **_kwargs):
                roster_path.write_text('{"mutated":true}\n', encoding="utf-8")
                return self.allocation, {}, allocation_blobs, self.contract

            with mock.patch.object(
                authoring,
                "authenticate_allocation",
                side_effect=mutate_roster,
            ), mock.patch.object(
                authoring,
                "authenticate_shared_brief_bundle",
                return_value=(self.brief_concepts, {}, shared_brief_blobs),
            ), self.assertRaisesRegex(
                authoring.ValidationFailure, "sealed input changed during publication"
            ):
                authoring.launch_bundle(
                    contract=self.contract,
                    allocation_receipt_path=allocation_bundle / "receipt.json",
                    shared_brief_receipt_path=shared_brief_bundle / "receipt.json",
                    roster_path=roster_path,
                    output=output,
                    execution_git_head="1" * 40,
                )
            self.assertFalse(output.exists())

    def test_seal_briefs_snapshots_roster_and_cleans_on_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            allocation_bundle = root / "allocation"
            allocation_bundle.mkdir()
            for name in authoring.ALLOCATION_ARTIFACTS:
                (allocation_bundle / name).write_bytes(b"{}\n")
            allocation_receipt = allocation_bundle / "receipt.json"
            completion_path = root / "completion.json"
            completion = valid_brief_registry(self.allocation)
            completion["allocation_receipt_sha256"] = authoring.sha256_bytes(
                allocation_receipt.read_bytes()
            )
            write_json(completion_path, completion)
            roster_path = root / "roster.json"
            write_json(roster_path, valid_roster())
            output = root / "shared-briefs"

            def mutate_roster() -> None:
                changed = valid_roster()
                changed["approval_reference_id"] = "approval-ref-mutated"
                write_json(roster_path, changed)

            with mock.patch.object(
                authoring,
                "authenticate_allocation",
                return_value=(
                    self.allocation,
                    {"execution_git_head": "1" * 40},
                    {},
                    self.contract,
                ),
            ), mock.patch.object(
                authoring, "require_strict_git_descendant"
            ), mock.patch.object(
                authoring, "require_git_ancestor"
            ), self.assertRaisesRegex(
                authoring.ValidationFailure, "sealed input changed during publication"
            ):
                authoring.seal_shared_brief_bundle(
                    contract=self.contract,
                    allocation_receipt_path=allocation_receipt,
                    private_completion_path=completion_path,
                    roster_path=roster_path,
                    output=output,
                    execution_git_head="2" * 40,
                    pre_receipt_check=mutate_roster,
                )
            self.assertFalse(output.exists())

    def test_shared_brief_authentication_rejects_roster_swap_after_seal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            allocation_bundle = root / "allocation"
            allocation_bundle.mkdir()
            for name in authoring.ALLOCATION_ARTIFACTS:
                (allocation_bundle / name).write_bytes(b"{}\n")
            allocation_receipt = allocation_bundle / "receipt.json"
            allocation_receipt.write_text(
                json.dumps({"execution_git_head": "1" * 40}) + "\n",
                encoding="utf-8",
            )
            completion_path = root / "completion.json"
            completion = valid_brief_registry(self.allocation)
            completion["allocation_receipt_sha256"] = authoring.sha256_bytes(
                allocation_receipt.read_bytes()
            )
            write_json(completion_path, completion)
            roster_path = root / "roster.json"
            write_json(roster_path, valid_roster())
            output = root / "shared-briefs"
            with mock.patch.object(
                authoring,
                "authenticate_allocation",
                return_value=(
                    self.allocation,
                    {"execution_git_head": "1" * 40},
                    {},
                    self.contract,
                ),
            ), mock.patch.object(
                authoring, "require_strict_git_descendant"
            ), mock.patch.object(authoring, "require_git_ancestor"):
                authoring.seal_shared_brief_bundle(
                    contract=self.contract,
                    allocation_receipt_path=allocation_receipt,
                    private_completion_path=completion_path,
                    roster_path=roster_path,
                    output=output,
                    execution_git_head="2" * 40,
                )
            swapped = valid_roster()
            swapped["approval_reference_id"] = "approval-ref-swapped"
            write_json(roster_path, swapped)
            with mock.patch.object(
                authoring, "validate_control_receipt", return_value=self.contract
            ), mock.patch.object(
                authoring, "require_strict_git_descendant"
            ), mock.patch.object(
                authoring, "require_git_ancestor"
            ), self.assertRaisesRegex(
                authoring.ValidationFailure, "input binding changed"
            ):
                authoring.authenticate_shared_brief_bundle(
                    output / "receipt.json",
                    allocation_receipt,
                    self.allocation,
                    roster_path,
                    self.contract,
                    "2" * 40,
                )

    def test_nonexistent_receipt_commit_fails_closed(self) -> None:
        with self.assertRaisesRegex(authoring.ValidationFailure, "cannot authenticate"):
            authoring.validate_control_receipt({"execution_git_head": "0" * 40}, "1" * 40)

    def test_receipt_producing_commit_may_be_older_but_not_nonancestor(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            subprocess.run(["git", "init", "-q", "-b", "main"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=repo, check=True)
            subprocess.run(
                ["git", "config", "user.email", "test@example.invalid"],
                cwd=repo,
                check=True,
            )
            marker = repo / "marker"
            marker.write_text("one", encoding="utf-8")
            subprocess.run(["git", "add", "marker"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "one"], cwd=repo, check=True)
            first = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            marker.write_text("two", encoding="utf-8")
            subprocess.run(["git", "commit", "-qam", "two"], cwd=repo, check=True)
            second = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            with mock.patch.object(authoring, "REPO_ROOT", repo):
                authoring.require_git_ancestor(first, second, "receipt")
                with self.assertRaisesRegex(authoring.ValidationFailure, "not an ancestor"):
                    authoring.require_git_ancestor(second, first, "receipt")

    def test_inventory_is_bound_and_operator_scoped(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = []
            source_receipt_specs = []
            entries = []
            head = "1" * 40
            for role in v2.LEAKAGE_ROLES:
                source_path = root / f"{role}.json"
                write_json(source_path, [{"input": f"unrelated {role}"}])
                source = v2.LeakageSource(
                    role, role, source_path, v2.sha256_file(source_path)
                )
                sources.append(source)
                receipt_path = root / f"{role}-receipt.json"
                write_json(
                    receipt_path,
                    {
                        "schema_version": authoring.LEAKAGE_SOURCE_RECEIPT_SCHEMA,
                        "status": "exhaustive_source_operator_attested",
                        "role": role,
                        "name": role,
                        "source_sha256": source.sha256,
                        "record_count": 1,
                        "producing_git_head": head,
                        "producer_id": f"producer-{role.replace('_', '-')}",
                        "operator_attested_exhaustive": True,
                        "candidate_model_output_seen": False,
                        "assurance_scope": authoring.ASSURANCE_SCOPE,
                    },
                )
                source_receipt_specs.append(f"{role}:{role}={receipt_path}")
                entries.append(
                    {
                        "role": role,
                        "name": role,
                        "sha256": source.sha256,
                        "record_count": 1,
                        "producer_receipt_sha256": v2.sha256_file(receipt_path),
                    }
                )
            inventory_path = root / "inventory.json"
            write_json(
                inventory_path,
                {
                    "schema_version": authoring.LEAKAGE_INVENTORY_SCHEMA,
                    "status": "exhaustive_source_inventory_operator_attested",
                    "inventory_id": "inventory-fixture-v1",
                    "producing_git_head": head,
                    "operator_attested_exhaustive": True,
                    "candidate_model_output_seen": False,
                    "assurance_scope": authoring.ASSURANCE_SCOPE,
                    "sources": entries,
                },
            )
            with mock.patch.object(authoring, "require_git_ancestor"):
                authoring.validate_leakage_inventory(
                    inventory_path, sources, source_receipt_specs, head
                )

    def test_leakage_gate_delegates_full_recomputation_to_canonical_scanner(self) -> None:
        rows = completed_rows(self.allocation, self.assignments)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            benchmark = root / "benchmark.jsonl"
            benchmark.write_bytes(authoring.encode_jsonl(rows))
            leakage_receipt = root / "leakage.json"
            write_json(leakage_receipt, {"backend": "production"})
            inventory = root / "inventory.json"
            blocked = root / "blocked.json"
            write_json(inventory, {})
            write_json(blocked, {})
            sources = []
            source_specs = []
            source_receipts = {}
            source_receipt_specs = []
            for role in v2.REQUIRED_FROZEN_LEAKAGE_ROLES:
                source_path = root / f"{role}.jsonl"
                source_path.write_text('{"input":"unrelated"}\n', encoding="utf-8")
                source = v2.LeakageSource(
                    role, role, source_path, v2.sha256_file(source_path)
                )
                sources.append(source)
                source_specs.append(f"{role}:{role}={source_path}")
                receipt_path = root / f"{role}-receipt.json"
                write_json(receipt_path, {})
                source_receipts[(role, role)] = receipt_path
                source_receipt_specs.append(f"{role}:{role}={receipt_path}")
            model_dir = root / "model"
            model_dir.mkdir()
            with mock.patch.object(
                authoring,
                "validate_leakage_inventory",
                return_value=({}, source_receipts),
            ), mock.patch.object(
                authoring, "validate_blocked_registry_provenance"
            ), mock.patch.object(
                v2, "exact_leakage_errors", return_value=[]
            ), mock.patch.object(
                authoring.leakage_scanner,
                "verify_receipt",
                side_effect=ValueError(
                    "leakage receipt is non-certifying: calibration_required_noncertifying"
                ),
            ) as verify_receipt, self.assertRaisesRegex(
                authoring.ValidationFailure, "calibration_required_noncertifying"
            ):
                authoring.validate_leakage(
                    rows,
                    benchmark,
                    source_specs,
                    leakage_receipt,
                    blocked,
                    inventory,
                    source_receipt_specs,
                    model_dir,
                    "1" * 40,
                )
            verify_receipt.assert_called_once_with(
                leakage_receipt,
                contract_path=authoring.LEAKAGE_SCANNER_CONTRACT_PATH,
                benchmark_path=benchmark,
                sources={
                    (source.role, source.name): source.path
                    for source in v2.parse_leakage_sources(source_specs)
                },
                inventory_path=inventory,
                source_receipt_paths=source_receipts,
                blocked_registry_receipt_path=blocked,
                expected_head="1" * 40,
                model_dir=model_dir,
            )

    def test_blocked_registry_receipt_requires_ancestor_commit(self) -> None:
        receipt_head = "2" * 40
        expected_head = "3" * 40
        with mock.patch.object(
            v2,
            "validate_blocked_registry_receipt",
            return_value={"execution_git_head": receipt_head},
        ), mock.patch.object(authoring, "require_git_ancestor") as require_ancestor:
            authoring.validate_blocked_registry_provenance(
                Path("blocked-receipt.json"), [], expected_head
            )
        require_ancestor.assert_called_once_with(
            receipt_head, expected_head, "blocked-registry receipt"
        )

    def test_blocked_registry_dependency_closure_includes_artifacts_and_sources(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt_path = root / "bundle" / "receipt.json"
            receipt_path.parent.mkdir()
            head = "2" * 40
            write_json(
                receipt_path,
                {
                    "execution_git_head": head,
                    "contract": {"path": "contracts/blocked.json"},
                },
            )
            artifact_names = [
                "blocked_family_registry.jsonl",
                "blocked_text_hashes.jsonl",
                "source_coverage.jsonl",
                "provisional_decisions.jsonl",
            ]
            source_paths = [Path(f"private/source-{index}.jsonl") for index in range(4)]
            contract = {
                "expected_validator_artifacts": {
                    name: {} for name in artifact_names
                },
                "sources": [{"path": str(path)} for path in source_paths],
            }
            with mock.patch.object(
                authoring, "git_output", return_value=authoring.encode_json(contract)
            ), mock.patch.object(authoring, "REPO_ROOT", root):
                paths = authoring.blocked_registry_dependency_paths(receipt_path)
            self.assertEqual(
                set(paths),
                {
                    receipt_path,
                    *(receipt_path.parent / name for name in artifact_names),
                    *(root.resolve() / path for path in source_paths),
                },
            )

    def test_leakage_gate_requires_all_four_roles(self) -> None:
        rows = completed_rows(self.allocation, self.assignments)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "training.jsonl"
            source.write_text('{"input":"unrelated"}\n', encoding="utf-8")
            receipt = root / "leakage.json"
            write_json(receipt, {})
            with self.assertRaisesRegex(authoring.ValidationFailure, "roles differ"):
                authoring.validate_leakage(
                    rows,
                    root / "benchmark.jsonl",
                    [f"training:training={source}"],
                    receipt,
                    receipt,
                    receipt,
                    [],
                    root / "model",
                    "1" * 40,
                )

    def test_clean_archive_cli_expected_block_runs_real_precalibration_path(self) -> None:
        inside_worktree = subprocess.run(
            ["git", "rev-parse", "--is-inside-work-tree"],
            cwd=authoring.REPO_ROOT,
            capture_output=True,
            text=True,
        )
        if inside_worktree.returncode != 0:
            self.skipTest("clean-archive lifecycle requires a Git worktree")
        changed = subprocess.run(
            [
                "git",
                "diff",
                "--quiet",
                "HEAD",
                "--",
                str(authoring.SCRIPT_PATH.relative_to(authoring.REPO_ROOT)),
                str(authoring.CONTRACT_PATH.relative_to(authoring.REPO_ROOT)),
                "scripts/eval/tests/test_build_eg1_multilingual_development_authoring.py",
                ".gitignore",
            ],
            cwd=authoring.REPO_ROOT,
        )
        if changed.returncode != 0:
            self.skipTest("clean-archive lifecycle requires committed control bytes")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root / "tracked.tar"
            checkout = root / "checkout"
            checkout.mkdir()
            subprocess.run(
                [
                    "git",
                    "archive",
                    "--format=tar",
                    "-o",
                    str(archive_path),
                    "HEAD",
                ],
                cwd=authoring.REPO_ROOT,
                check=True,
            )
            with tarfile.open(archive_path) as archive:
                archive.extractall(checkout, filter="data")
            subprocess.run(["git", "init", "-q", "-b", "main"], cwd=checkout, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=checkout, check=True)
            subprocess.run(
                ["git", "config", "user.email", "test@example.invalid"],
                cwd=checkout,
                check=True,
            )
            subprocess.run(["git", "add", "-f", "-A"], cwd=checkout, check=True)
            subprocess.run(["git", "commit", "-qm", "archive"], cwd=checkout, check=True)
            head = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=checkout, text=True
            ).strip()
            artifacts = checkout / "artifacts" / "development-authoring-e2e"
            artifacts.mkdir(parents=True)
            roster_path = artifacts / "roster.json"
            write_json(roster_path, valid_roster())
            script = checkout / "scripts/eval/build_eg1_multilingual_development_authoring.py"
            environment = os.environ.copy()
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            allocation = artifacts / "allocation"
            shared_briefs = artifacts / "shared-briefs"
            launch = artifacts / "launch"
            first = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "allocate",
                    "--expected-git-head",
                    head,
                    "--out-bundle",
                    str(allocation),
                ],
                cwd=checkout,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            allocation_rows = authoring.parse_rows(
                (allocation / "allocation.jsonl").read_bytes(), "allocation"
            )
            allocation_head = head
            subprocess.run(
                ["git", "commit", "--allow-empty", "-qm", "seal shared briefs"],
                cwd=checkout,
                check=True,
            )
            head = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=checkout, text=True
            ).strip()
            brief_completion = artifacts / "shared-brief-completion.json"
            write_json(
                brief_completion,
                {
                    "schema_version": authoring.SHARED_BRIEF_REGISTRY_SCHEMA,
                    "status": "sealed_for_development_authoring",
                    "allocation_receipt_sha256": v2.sha256_file(
                        allocation / "receipt.json"
                    ),
                    "allocation_execution_git_head": allocation_head,
                    "producing_git_head": head,
                    "sealing_git_head": head,
                    "candidate_model_output_seen": False,
                    "assurance_scope": authoring.ASSURANCE_SCOPE,
                    "concepts": valid_brief_concepts(allocation_rows),
                },
            )
            sealed = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "seal-briefs",
                    "--allocation-receipt",
                    str(allocation / "receipt.json"),
                    "--private-completion",
                    str(brief_completion),
                    "--roster",
                    str(roster_path),
                    "--expected-git-head",
                    head,
                    "--out-bundle",
                    str(shared_briefs),
                ],
                cwd=checkout,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertEqual(sealed.returncode, 0, sealed.stdout + sealed.stderr)
            second = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "launch",
                    "--allocation-receipt",
                    str(allocation / "receipt.json"),
                    "--shared-brief-receipt",
                    str(shared_briefs / "receipt.json"),
                    "--roster",
                    str(roster_path),
                    "--expected-git-head",
                    head,
                    "--out-bundle",
                    str(launch),
                ],
                cwd=checkout,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            receipt = json.loads((launch / "receipt.json").read_text(encoding="utf-8"))
            self.assertEqual(receipt["counts"]["assignments"], 800)
            self.assertEqual(
                set(receipt["counts"]["author_packets_by_language_participant"]["de"].values()),
                {2},
            )
            private_root_value = os.environ.get("EG1_PRIVATE_EVAL_SOURCE_ROOT")
            model_dir_value = os.environ.get("EG1_MULTILINGUAL_SCANNER_MODEL_DIR")
            if not private_root_value or not model_dir_value:
                self.skipTest(
                    "set EG1_PRIVATE_EVAL_SOURCE_ROOT and "
                    "EG1_MULTILINGUAL_SCANNER_MODEL_DIR for the private deep lifecycle"
                )
            private_root = Path(private_root_value).expanduser().resolve()
            model_dir = Path(model_dir_value).expanduser().resolve()
            private_relatives = (
                Path("scripts/eval/corpus/type_b_approved_1890.jsonl"),
                Path("scripts/eval/corpus/type_b_overflow_900.jsonl"),
                Path("scripts/eval/corpus/type_b_all_v1.jsonl"),
                Path("scripts/eval/runs/bakeoff-1265/train_sft_v2.jsonl"),
            )
            for relative in private_relatives:
                source = private_root / relative
                self.assertTrue(source.is_file(), f"missing private fixture {source}")
                destination = checkout / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)

            def run_cli(arguments: list[str]) -> subprocess.CompletedProcess[str]:
                result = subprocess.run(
                    arguments,
                    cwd=checkout,
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                return result

            def run_cli_expected_failure(
                arguments: list[str], expected_status: str
            ) -> subprocess.CompletedProcess[str]:
                result = subprocess.run(
                    arguments,
                    cwd=checkout,
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                output = result.stdout + result.stderr
                self.assertNotEqual(result.returncode, 0, output)
                self.assertIn(expected_status, output)
                return result

            blocked_bundle = artifacts / "blocked-registry"
            run_cli(
                [
                    sys.executable,
                    str(checkout / "scripts/eval/build_eg1_type_b_v2_blocked_registry.py"),
                    "--out-bundle",
                    str(blocked_bundle),
                    "--expected-git-head",
                    head,
                ]
            )
            assignments = authoring.parse_rows(
                (launch / "assignments.jsonl").read_bytes(), "assignments"
            )
            registry_sha = v2.sha256_file(
                blocked_bundle / "blocked_family_registry.jsonl"
            )
            rows = completed_rows(allocation_rows, assignments, registry_sha)
            corpus_path = artifacts / "completed-corpus.jsonl"
            corpus_path.write_bytes(authoring.encode_jsonl(rows))
            allocation_receipt = allocation / "receipt.json"
            launch_receipt = launch / "receipt.json"
            allocation_sha = v2.sha256_file(allocation_receipt)
            launch_sha = v2.sha256_file(launch_receipt)
            native_seal_path = artifacts / "native-review-seal.json"
            write_json(
                native_seal_path,
                native_review_seal(
                    rows,
                    assignments,
                    v2.sha256_file(corpus_path),
                    allocation_sha,
                    launch_sha,
                ),
            )
            comparability_path = artifacts / "contrast-comparability-seal.json"
            write_json(
                comparability_path,
                comparability_seal(
                    rows,
                    allocation_rows,
                    assignments,
                    v2.sha256_file(corpus_path),
                    allocation_sha,
                    launch_sha,
                ),
            )
            source_paths = {
                ("training", "shipping_sft_v2"): checkout / private_relatives[3],
                ("prior_eval", "type_b_all_v1"): checkout / private_relatives[2],
                ("blocked_family_registry", "type_b_blocked_families"): (
                    blocked_bundle / "blocked_family_registry.jsonl"
                ),
                ("blocked_text_hash_registry", "type_b_blocked_text_hashes"): (
                    blocked_bundle / "blocked_text_hashes.jsonl"
                ),
            }
            source_receipt_paths = {}
            inventory_entries = []
            for (role, name), source_path in source_paths.items():
                source_receipt = artifacts / f"source-{role}.receipt.json"
                write_json(
                    source_receipt,
                    {
                        "schema_version": authoring.LEAKAGE_SOURCE_RECEIPT_SCHEMA,
                        "status": "exhaustive_source_operator_attested",
                        "role": role,
                        "name": name,
                        "source_sha256": v2.sha256_file(source_path),
                        "record_count": authoring.source_record_count(source_path),
                        "producing_git_head": head,
                        "producer_id": f"clean-archive-{role.replace('_', '-')}",
                        "operator_attested_exhaustive": True,
                        "candidate_model_output_seen": False,
                        "assurance_scope": authoring.ASSURANCE_SCOPE,
                    },
                )
                source_receipt_paths[(role, name)] = source_receipt
                inventory_entries.append(
                    {
                        "role": role,
                        "name": name,
                        "sha256": v2.sha256_file(source_path),
                        "record_count": authoring.source_record_count(source_path),
                        "producer_receipt_sha256": v2.sha256_file(source_receipt),
                    }
                )
            inventory_path = artifacts / "leakage-inventory.json"
            write_json(
                inventory_path,
                {
                    "schema_version": authoring.LEAKAGE_INVENTORY_SCHEMA,
                    "status": "exhaustive_source_inventory_operator_attested",
                    "inventory_id": "clean-archive-inventory-v1",
                    "producing_git_head": head,
                    "operator_attested_exhaustive": True,
                    "candidate_model_output_seen": False,
                    "assurance_scope": authoring.ASSURANCE_SCOPE,
                    "sources": sorted(
                        inventory_entries, key=lambda value: (value["role"], value["name"])
                    ),
                },
            )

            def scanner_command(
                *, backend: str, output: Path
            ) -> list[str]:
                command = [
                    sys.executable,
                    str(
                        checkout
                        / "scripts/eval/scan_eg1_multilingual_development_leakage.py"
                    ),
                    "--contract",
                    str(
                        checkout
                        / "scripts/eval/contracts/eg1_multilingual_development_leakage_scanner_v1.json"
                    ),
                    "--benchmark",
                    str(corpus_path),
                    "--source-inventory",
                    str(inventory_path),
                    "--blocked-registry-receipt",
                    str(blocked_bundle / "receipt.json"),
                    "--model-dir",
                    str(model_dir),
                    "--out-bundle",
                    str(output),
                    "--expected-git-head",
                    head,
                    "--backend",
                    backend,
                ]
                for (role, name), source_path in source_paths.items():
                    command.extend(
                        ["--source", f"{role}:{name}={source_path}"]
                    )
                    command.extend(
                        [
                            "--source-receipt",
                            f"{role}:{name}={source_receipt_paths[(role, name)]}",
                        ]
                    )
                return command

            def evidence_arguments(leakage_receipt: Path) -> list[str]:
                arguments = [
                    "--allocation-receipt",
                    str(allocation_receipt),
                    "--shared-brief-receipt",
                    str(shared_briefs / "receipt.json"),
                    "--launch-receipt",
                    str(launch_receipt),
                    "--roster",
                    str(roster_path),
                    "--native-review-seal",
                    str(native_seal_path),
                    "--contrast-comparability-seal",
                    str(comparability_path),
                    "--leakage-receipt",
                    str(leakage_receipt),
                    "--blocked-registry-receipt",
                    str(blocked_bundle / "receipt.json"),
                    "--leakage-inventory",
                    str(inventory_path),
                    "--scanner-model-dir",
                    str(model_dir),
                ]
                for (role, name), source_path in source_paths.items():
                    arguments.extend(
                        ["--leakage-source", f"{role}:{name}={source_path}"]
                    )
                    arguments.extend(
                        [
                            "--source-receipt",
                            f"{role}:{name}={source_receipt_paths[(role, name)]}",
                        ]
                    )
                return arguments

            production_scanner_bundle = artifacts / "leakage-scan-production"
            run_cli(
                scanner_command(
                    backend="production", output=production_scanner_bundle
                )
            )
            production_evaluation = artifacts / "evaluation-production"
            run_cli_expected_failure(
                [
                    sys.executable,
                    str(script),
                    "merge",
                    *evidence_arguments(
                        production_scanner_bundle / "receipt.json"
                    ),
                    "--completed-corpus",
                    str(corpus_path),
                    "--expected-git-head",
                    head,
                    "--out-bundle",
                    str(production_evaluation),
                ],
                "calibration_required_noncertifying",
            )
            self.assertFalse(production_evaluation.exists())

            synthetic_scanner_bundle = artifacts / "leakage-scan-synthetic"
            run_cli(
                scanner_command(
                    backend="synthetic_test_only", output=synthetic_scanner_bundle
                )
            )
            synthetic_evaluation = artifacts / "evaluation-synthetic"
            run_cli_expected_failure(
                [
                    sys.executable,
                    str(script),
                    "merge",
                    *evidence_arguments(
                        synthetic_scanner_bundle / "receipt.json"
                    ),
                    "--completed-corpus",
                    str(corpus_path),
                    "--expected-git-head",
                    head,
                    "--out-bundle",
                    str(synthetic_evaluation),
                ],
                "synthetic_not_quality_evidence",
            )
            self.assertFalse(synthetic_evaluation.exists())

    def test_merge_and_verify_eval_end_to_end_with_synthetic_private_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            allocation_bundle = root / "allocation"
            shared_brief_bundle = root / "shared-briefs"
            launch_bundle = root / "launch"
            allocation_bundle.mkdir()
            shared_brief_bundle.mkdir()
            launch_bundle.mkdir()
            for name in authoring.ALLOCATION_ARTIFACTS:
                (allocation_bundle / name).write_bytes(b"{}\n")
            for name in authoring.LAUNCH_ARTIFACTS:
                (launch_bundle / name).write_bytes(b"{}\n")
            for name in authoring.SHARED_BRIEF_ARTIFACTS:
                (shared_brief_bundle / name).write_bytes(b"{}\n")
            shared_brief_receipt = shared_brief_bundle / "receipt.json"
            brief_patch = mock.patch.object(
                authoring,
                "authenticate_shared_brief_bundle",
                return_value=(self.brief_concepts, {}, {}),
            )
            brief_patch.start()
            self.addCleanup(brief_patch.stop)
            roster_path = root / "roster.json"
            write_json(roster_path, valid_roster())
            source_paths = {}
            source_payloads = {
                "training": {"input": "unrelated training source"},
                "prior_eval": {"input": "unrelated prior evaluation"},
                "blocked_family_registry": {"family_id": "blocked-old-family"},
                "blocked_text_hash_registry": {
                    "normalized_text_sha256": hashlib.sha256(b"unrelated blocked text").hexdigest(),
                    "field_kind": "input",
                },
            }
            for role, payload in source_payloads.items():
                path = root / f"{role}.jsonl"
                path.write_text(json.dumps(payload) + "\n", encoding="utf-8")
                source_paths[role] = path
            registry_sha = v2.sha256_file(source_paths["blocked_family_registry"])
            rows = completed_rows(self.allocation, self.assignments, registry_sha)
            corpus_path = root / "completed.jsonl"
            corpus_path.write_bytes(authoring.encode_jsonl(rows))
            allocation_receipt = allocation_bundle / "receipt.json"
            launch_receipt = launch_bundle / "receipt.json"
            allocation_sha = authoring.read_snapshot(allocation_receipt, "allocation")[1]
            launch_sha = authoring.read_snapshot(launch_receipt, "launch")[1]
            seal_path = root / "native-seal.json"
            write_json(
                seal_path,
                native_review_seal(
                    rows,
                    self.assignments,
                    v2.sha256_file(corpus_path),
                    allocation_sha,
                    launch_sha,
                ),
            )
            comparability_path = root / "comparability-seal.json"
            write_json(
                comparability_path,
                comparability_seal(
                    rows,
                    self.allocation,
                    self.assignments,
                    v2.sha256_file(corpus_path),
                    allocation_sha,
                    launch_sha,
                ),
            )
            sources = [
                v2.LeakageSource(role, role, path, v2.sha256_file(path))
                for role, path in source_paths.items()
            ]
            leakage_receipt = root / "leakage.json"
            blocked_receipt = root / "blocked-receipt.json"
            blocked_sibling = root / "blocked-family-registry.jsonl"
            inventory_path = root / "inventory.json"
            write_json(blocked_receipt, {"fixture": True})
            blocked_sibling.write_text('{"family":"fixture"}\n', encoding="utf-8")
            write_json(inventory_path, {"fixture": True})
            dependency_patch = mock.patch.object(
                authoring,
                "blocked_registry_dependency_paths",
                return_value=[blocked_receipt, blocked_sibling],
            )
            dependency_patch.start()
            self.addCleanup(dependency_patch.stop)
            source_receipt_paths = {}
            for role in source_paths:
                path = root / f"{role}-source-receipt.json"
                write_json(path, {"fixture": role})
                source_receipt_paths[(role, role)] = path
            write_json(
                leakage_receipt,
                {
                    "schema_version": "eg1-multilingual-leakage-receipt-v1",
                    "benchmark_content_sha256": v2.benchmark_content_sha256(rows),
                    "screening_policy_id": "synthetic-policy-v1",
                    "sources": [
                        {
                            "role": source.role,
                            "name": source.name,
                            "sha256": source.sha256,
                            "methods": {
                                "exact_normalized": {"status": "pass", "violations": 0},
                                "token_ngram_jaccard": {"status": "pass", "violations": 0, "threshold": 0.8, "max_observed": 0.1},
                                "character_ngram_jaccard": {"status": "pass", "violations": 0, "threshold": 0.8, "max_observed": 0.1},
                                "embedding_cosine": {"status": "pass", "violations": 0, "threshold": 0.9, "max_observed": 0.2},
                            },
                        }
                        for source in sorted(sources, key=lambda item: (item.role, item.name))
                    ],
                },
            )
            output = root / "evaluation"
            source_specs = [f"{role}:{role}={path}" for role, path in source_paths.items()]
            source_receipt_specs = [
                f"{role}:{role}={path}"
                for (role, _), path in source_receipt_paths.items()
            ]
            with mock.patch.object(
                authoring,
                "authenticate_allocation",
                return_value=(self.allocation, {}, {}, self.contract),
            ), mock.patch.object(
                authoring,
                "authenticate_launch",
                return_value=(self.assignments, {}, {}),
            ), mock.patch.object(
                authoring,
                "validate_leakage",
                return_value=(sources, source_receipt_paths),
            ):
                receipt = authoring.merge_bundle(
                    contract=self.contract,
                    allocation_receipt_path=allocation_receipt,
                    shared_brief_receipt_path=shared_brief_receipt,
                    launch_receipt_path=launch_receipt,
                    roster_path=roster_path,
                    completed_corpus_path=corpus_path,
                    native_review_seal_path=seal_path,
                    contrast_comparability_seal_path=comparability_path,
                    leakage_receipt_path=leakage_receipt,
                    blocked_registry_receipt_path=blocked_receipt,
                    leakage_inventory_path=inventory_path,
                    leakage_source_specs=source_specs,
                    source_receipt_specs=source_receipt_specs,
                    scanner_model_dir=root / "model",
                    output=output,
                    execution_git_head="1" * 40,
                )
            self.assertEqual(
                receipt["status"],
                "development_evaluation_authorized_operator_attested_nonrelease",
            )
            self.assertFalse(receipt["gates"]["release_or_frozen_eligible"])
            self.assertEqual({path.name for path in output.iterdir()}, set(authoring.MERGE_ARTIFACTS))
            with mock.patch.object(
                authoring, "validate_control_receipt", return_value=self.contract
            ), mock.patch.object(
                authoring,
                "authenticate_allocation",
                return_value=(self.allocation, {}, {}, self.contract),
            ), mock.patch.object(
                authoring,
                "authenticate_launch",
                return_value=(self.assignments, {}, {}),
            ), mock.patch.object(
                authoring,
                "validate_leakage",
                return_value=(sources, source_receipt_paths),
            ):
                verified = authoring.authenticate_evaluation_bundle(
                    output,
                    "1" * 40,
                    allocation_receipt,
                    shared_brief_receipt,
                    launch_receipt,
                    roster_path,
                    seal_path,
                    comparability_path,
                    leakage_receipt,
                    blocked_receipt,
                    inventory_path,
                    source_specs,
                    source_receipt_specs,
                    root / "model",
                )
            self.assertEqual(verified["status"], receipt["status"])
            with mock.patch.object(
                authoring, "validate_control_receipt", return_value=self.contract
            ), self.assertRaisesRegex(authoring.ValidationFailure, "allocation receipt"):
                authoring.authenticate_evaluation_bundle(
                    output,
                    "1" * 40,
                    allocation_receipt,
                    shared_brief_receipt,
                    launch_receipt,
                    roster_path,
                    seal_path,
                    comparability_path,
                    leakage_receipt,
                    blocked_receipt,
                    inventory_path,
                    source_specs,
                    source_receipt_specs,
                    root / "model",
                )
            mutation_output = root / "mutation-evaluation"

            def mutate_after_validation(*_args, **_kwargs):
                source_paths["training"].write_text(
                    '{"input":"changed after validation"}\n', encoding="utf-8"
                )
                return sources, source_receipt_paths

            with mock.patch.object(
                authoring,
                "authenticate_allocation",
                return_value=(self.allocation, {}, {}, self.contract),
            ), mock.patch.object(
                authoring,
                "authenticate_launch",
                return_value=(self.assignments, {}, {}),
            ), mock.patch.object(
                authoring,
                "validate_leakage",
                side_effect=mutate_after_validation,
            ), self.assertRaisesRegex(authoring.ValidationFailure, "changed during publication"):
                authoring.merge_bundle(
                    contract=self.contract,
                    allocation_receipt_path=allocation_receipt,
                    shared_brief_receipt_path=shared_brief_receipt,
                    launch_receipt_path=launch_receipt,
                    roster_path=roster_path,
                    completed_corpus_path=corpus_path,
                    native_review_seal_path=seal_path,
                    contrast_comparability_seal_path=comparability_path,
                    leakage_receipt_path=leakage_receipt,
                    blocked_registry_receipt_path=blocked_receipt,
                    leakage_inventory_path=inventory_path,
                    leakage_source_specs=source_specs,
                    source_receipt_specs=source_receipt_specs,
                    scanner_model_dir=root / "model",
                    output=mutation_output,
                    execution_git_head="1" * 40,
                )
            self.assertFalse(mutation_output.exists())
            source_paths["training"].write_text(
                json.dumps(source_payloads["training"]) + "\n", encoding="utf-8"
            )
            blocked_mutation_output = root / "blocked-mutation-evaluation"

            def mutate_blocked_dependency(*_args, **_kwargs):
                blocked_sibling.write_text(
                    '{"family":"changed"}\n', encoding="utf-8"
                )
                return sources, source_receipt_paths

            with mock.patch.object(
                authoring,
                "authenticate_allocation",
                return_value=(self.allocation, {}, {}, self.contract),
            ), mock.patch.object(
                authoring,
                "authenticate_launch",
                return_value=(self.assignments, {}, {}),
            ), mock.patch.object(
                authoring,
                "validate_leakage",
                side_effect=mutate_blocked_dependency,
            ), self.assertRaisesRegex(
                authoring.ValidationFailure, "changed during publication"
            ):
                authoring.merge_bundle(
                    contract=self.contract,
                    allocation_receipt_path=allocation_receipt,
                    shared_brief_receipt_path=shared_brief_receipt,
                    launch_receipt_path=launch_receipt,
                    roster_path=roster_path,
                    completed_corpus_path=corpus_path,
                    native_review_seal_path=seal_path,
                    contrast_comparability_seal_path=comparability_path,
                    leakage_receipt_path=leakage_receipt,
                    blocked_registry_receipt_path=blocked_receipt,
                    leakage_inventory_path=inventory_path,
                    leakage_source_specs=source_specs,
                    source_receipt_specs=source_receipt_specs,
                    scanner_model_dir=root / "model",
                    output=blocked_mutation_output,
                    execution_git_head="1" * 40,
                )
            self.assertFalse(blocked_mutation_output.exists())
            blocked_sibling.write_text(
                '{"family":"fixture"}\n', encoding="utf-8"
            )
            with mock.patch.object(
                authoring, "validate_control_receipt", return_value=self.contract
            ), mock.patch.object(
                authoring,
                "authenticate_allocation",
                return_value=(self.allocation, {}, {}, self.contract),
            ), mock.patch.object(
                authoring,
                "authenticate_launch",
                return_value=(self.assignments, {}, {}),
            ), mock.patch.object(
                authoring,
                "validate_leakage",
                side_effect=mutate_blocked_dependency,
            ), self.assertRaisesRegex(
                authoring.ValidationFailure, "changed during verification"
            ):
                authoring.authenticate_evaluation_bundle(
                    output,
                    "1" * 40,
                    allocation_receipt,
                    shared_brief_receipt,
                    launch_receipt,
                    roster_path,
                    seal_path,
                    comparability_path,
                    leakage_receipt,
                    blocked_receipt,
                    inventory_path,
                    source_specs,
                    source_receipt_specs,
                    root / "model",
                )
            blocked_sibling.write_text(
                '{"family":"fixture"}\n', encoding="utf-8"
            )
            tampered = output / "development-corpus.jsonl"
            tampered.write_bytes(tampered.read_bytes() + b"\n")
            with mock.patch.object(
                authoring, "validate_control_receipt", return_value=self.contract
            ), self.assertRaisesRegex(authoring.ValidationFailure, "hash changed"):
                authoring.authenticate_evaluation_bundle(
                    output,
                    "1" * 40,
                    allocation_receipt,
                    shared_brief_receipt,
                    launch_receipt,
                    roster_path,
                    seal_path,
                    comparability_path,
                    leakage_receipt,
                    blocked_receipt,
                    inventory_path,
                    source_specs,
                    source_receipt_specs,
                    root / "model",
                )


if __name__ == "__main__":
    unittest.main()
