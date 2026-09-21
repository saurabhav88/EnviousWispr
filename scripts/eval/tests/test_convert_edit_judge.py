"""Harness-contract tests for the edit-judge Core ML converter (#996 delivery).

Pure helpers (which variants a run builds, the identity each exported package
is bound under, the mask floor) plus one tiny synthetic PyTorch trace for the
retrace-through-the-wrapper property. No trained model is loaded and no Core
ML conversion is performed.
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts/eval"))

import convert_edit_judge as converter  # noqa: E402

CFG = {"precision_variant": "fp32-pytorch", "package_sha256": None, "detection_threshold": 0.62, "class_order": ["no_correction", "correction"], "decision_rule": "detection", "contract_sha256": "k" * 64}
# The run's identity carries the REAL digest of CFG, the way train_edit_judge.py
# writes it, so "the bound identity differs from the run's" is a live check.
RUN_IDENTITY = {"checkpoint_sha256": "c" * 64, "tokenizer_sha256": "t" * 64, "config_sha256": hashlib.sha256(json.dumps(CFG, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).hexdigest()}


def test_export_plan_always_starts_with_fp32_and_adds_variants_in_order():
    assert converter.export_plan(fp16=False, embedding_8bit=False) == ["coreml-fp32"]
    assert converter.export_plan(fp16=True, embedding_8bit=False) == ["coreml-fp32", "coreml-fp16"]
    assert converter.export_plan(fp16=False, embedding_8bit=True) == ["coreml-fp32", "coreml-embedding-int8"]
    assert converter.export_plan(fp16=True, embedding_8bit=True) == ["coreml-fp32", "coreml-fp16", "coreml-embedding-int8"]
    assert set(converter.export_plan(True, True)) == set(converter.VARIANT_PRECISION) == set(converter.SUMMARY_KEY)


def test_fp16_and_fp32_packages_get_distinct_identities_even_over_the_same_digest():
    digest = "d" * 64
    cfg32, id32, canon32 = converter.bind_decision_config(CFG, RUN_IDENTITY, "coreml-fp32", digest)
    cfg16, id16, canon16 = converter.bind_decision_config(CFG, RUN_IDENTITY, "coreml-fp16", digest)
    assert cfg32["precision_variant"] == "coreml-fp32" and cfg16["precision_variant"] == "coreml-fp16"
    assert cfg32["package_sha256"] == cfg16["package_sha256"] == digest
    assert id32["config_sha256"] != id16["config_sha256"]
    assert id32["config_sha256"] != RUN_IDENTITY["config_sha256"]
    # The identity keeps the run's weight and tokenizer digests: a variant is
    # the same trained judge under a different precision, never a new judge.
    for bound in (id32, id16):
        assert bound["checkpoint_sha256"] == RUN_IDENTITY["checkpoint_sha256"]
        assert bound["tokenizer_sha256"] == RUN_IDENTITY["tokenizer_sha256"]
        assert set(bound) == {"checkpoint_sha256", "tokenizer_sha256", "config_sha256"}
    # The canonical bytes ARE what the digest was taken over, and they carry
    # the variant, so a Swift re-hash of the manifest reproduces the identity.
    for canon, bound, cfg in ((canon32, id32, cfg32), (canon16, id16, cfg16)):
        assert hashlib.sha256(canon.encode("utf-8")).hexdigest() == bound["config_sha256"]
        assert json.loads(canon) == cfg
    assert '"precision_variant":"coreml-fp16"' in canon16
    # The run's own config is untouched (it is re-read for the next variant).
    assert CFG["precision_variant"] == "fp32-pytorch" and CFG["package_sha256"] is None


def test_an_unknown_variant_is_refused_before_any_identity_is_minted():
    with pytest.raises(ValueError, match="unknown precision variant"):
        converter.bind_decision_config(CFG, RUN_IDENTITY, "coreml-fp8", "d" * 64)


def test_compute_precision_names_resolve_on_the_pinned_coremltools():
    ct = pytest.importorskip("coremltools")
    for variant, name in converter.VARIANT_PRECISION.items():
        if name is None:
            assert variant == "coreml-embedding-int8"
            continue
        assert getattr(ct.precision, name).name == name


class _Backbone:
    """A ModernBERT-shaped backbone: masks come out of `_update_attention_mask`."""

    def __init__(self, torch):
        self.torch = torch

    def _update_attention_mask(self, attention_mask, output_attentions):
        neg = self.torch.finfo(self.torch.float32).min
        row = self.torch.tensor([[0.0, neg, neg, neg]])
        return row, row.clone()


def test_the_fp16_mask_floor_replaces_the_fp32_minimum_and_keeps_an_all_masked_row_finite():
    torch = pytest.importorskip("torch")
    backbone = _Backbone(torch)
    assert converter.install_fp16_mask_floor(backbone) is True
    global_mask, window_mask = backbone._update_attention_mask(None, False)
    assert float(global_mask.min()) == converter.FP16_MASK_FLOOR
    assert float(window_mask.min()) == converter.FP16_MASK_FLOOR
    assert float(global_mask[0, 0]) == 0.0
    # The failure the floor exists for: a query position whose every key is
    # masked. With the fp32 minimum the row is -inf in half precision and the
    # softmax is NaN; with the floor it is finite.
    fully_masked = torch.full((4,), torch.finfo(torch.float32).min)
    assert torch.isnan(torch.softmax(fully_masked.half(), dim=-1)).any()
    floored = fully_masked.clamp(min=converter.FP16_MASK_FLOOR)
    assert torch.isfinite(torch.softmax(floored.half(), dim=-1)).all()
    # A real score added to the floor still fits in half precision.
    assert torch.isfinite((floored + torch.tensor(-500.0)).half()).all()


def test_a_backbone_without_the_mask_hook_gets_no_fp16_package():
    assert converter.install_fp16_mask_floor(object()) is False


def test_the_fp16_retrace_sees_the_floor_through_the_judge_wrapper():
    """The converter traces `Judge`, which holds the backbone by reference, a
    second time after the floor is installed on the backbone INSTANCE. The
    instance attribute must shadow the class method inside that trace."""
    torch = pytest.importorskip("torch")

    class Backbone(torch.nn.Module):
        def _update_attention_mask(self, attention_mask, output_attentions):
            return (torch.full_like(attention_mask, torch.finfo(torch.float32).min),)

        def forward(self, attention_mask):
            return self._update_attention_mask(attention_mask, False)[0]

    class Judge(torch.nn.Module):
        def __init__(self, backbone):
            super().__init__()
            self.backbone = backbone

        def forward(self, attention_mask):
            return self.backbone(attention_mask)

    backbone = Backbone()
    judge = Judge(backbone).eval()
    example = torch.zeros(1, 4)
    fp32_trace = torch.jit.trace(judge, example, strict=False)
    assert converter.install_fp16_mask_floor(backbone)
    fp16_trace = torch.jit.trace(judge, example, strict=False)
    assert torch.isneginf(fp32_trace(example).half()).all()
    assert torch.isfinite(fp16_trace(example).half()).all()
    assert torch.equal(fp16_trace(example), torch.full_like(example, converter.FP16_MASK_FLOOR))
