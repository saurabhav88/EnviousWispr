#!/usr/bin/env python3
"""Tests for the pack-mode section envelope (#2851 phase 2) and the runner's pack plumbing.

`section_envelope.py` is the Python mirror of the Swift `SectionEnvelope` the phase-2 plan
names (`docs/feature-requests/issue-2851-2026-09-13-cloud-packing.md` §3 A, C, D). When the
Swift lands, its tests and these rows must agree row for row: add a row THERE, add it HERE
(the same discipline as `test_preamble_mirror.py`).

Run from repo root:
  python3 scripts/eval/tests/test_section_envelope.py
"""
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from section_envelope import (  # noqa: E402
    accept_section, looks_like_question, pack_addendum, unwrap_sections, wrap_sections,
)
import run_cloud_type_b as runner  # noqa: E402

EXPECTED_TESTS = 12
_failures = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global _failures
    if not cond:
        _failures += 1
        print(f"FAIL: {name} {detail}")


def test_wrap_shape() -> None:
    w = wrap_sections(["Yeah.", "So we went there."])
    check("wrap shape", w == "<s1>Yeah.</s1>\n<s2>So we went there.</s2>", repr(w))
    try:
        wrap_sections([])
        check("empty pack refused", False)
    except ValueError:
        pass


def test_round_trip_and_escaping() -> None:
    sections = ["plain words", "a literal <s2> and </s7> inside", "tail"]
    w = wrap_sections(sections)
    check("literal tag escaped on the way in", "<\\s2>" in w and "</\\s7>" in w, repr(w))
    check("round trip restores the words", unwrap_sections(w, 3) == sections)
    # A speaker's words that already carry a backslash-escaped tag survive too.
    nested = ["already <\\s2> escaped"]
    check("an already-escaped literal round-trips unchanged",
          unwrap_sections(wrap_sections(nested), 1) == nested, repr(wrap_sections(nested)))


def test_unwrap_refusals() -> None:
    rows = [
        ("missing closing tag", "<s1>a</s1>\n<s2>b", 2),
        ("N-1 tags", "<s1>a</s1>", 2),
        ("N+1 tags", "<s1>a</s1>\n<s2>b</s2>\n<s3>c</s3>", 2),
        ("swapped order", "<s2>b</s2>\n<s1>a</s1>", 2),
        ("text outside the tags", "Here you go:\n<s1>a</s1>\n<s2>b</s2>", 2),
        ("duplicated tag", "<s1>a</s1>\n<s1>b</s1>", 2),
        ("a stray open tag between sections", "<s1>a</s1><s3>\n<s2>b</s2>", 2),
        ("a tag nested inside a section", "<s1>a<s2>b</s1><s2>c</s2>", 2),
        ("zero-padded numbering", "<s01>a</s01>", 1),
        ("expected zero", "<s1>a</s1>", 0),
    ]
    for label, text, n in rows:
        check(f"unwrap refuses: {label}", unwrap_sections(text, n) is None)
    check("whitespace outside the tags is fine",
          unwrap_sections("  <s1>a</s1>\n\n<s2>b</s2>\n", 2) == ["a", "b"])
    check("multi-line section content survives",
          unwrap_sections("<s1>line one\nline two</s1>", 1) == ["line one\nline two"])


def test_addendum_names_the_count() -> None:
    a = pack_addendum(29)
    check("addendum count", "29 sections" in a and "from 1 to 29" in a, a)
    check("addendum starts on its own paragraph", a.startswith("\n\n"))


def test_accept_mirrors_the_validator() -> None:
    original = "so um I think we should go to the store and buy some milk today okay"
    check("clean edit accepted",
          accept_section(original, "I think we should go to the store and buy some milk today.").status
          == "accepted")
    check("empty is empty", accept_section(original, "   ").status == "empty")
    check("expansion over 3x (min 200) rejected",
          accept_section(original, "x " * 200).status == "rejectedExpansion")
    # 14 words -> ceil(14*2/5) = 6; five words is a content drop.
    check("content drop under ceil(2/5) rejected",
          accept_section(original, "we should go buy milk").status == "rejectedContentDrop")
    # Under ten words the drop guard does not apply (the Swift guard is `>= 10`).
    check("short originals skip the drop guard",
          accept_section("one two three four five six", "one").status == "accepted")
    check("question to answer rejected",
          accept_section("should we ship it today", "We ship it today.").status
          == "rejectedQuestionAnswer")
    # Precomposed and decomposed forms count the same after NFC.
    # 101 precomposed = 101 code points (accepted under the 200 floor); 101 decomposed would be
    # 202 code points and rejected WITHOUT the NFC step, so this row fails before the fix.
    check("NFC before counting",
          accept_section("x", "\u00e9" * 101).status
          == accept_section("x", "e\u0301" * 101).status
          == "accepted")


def test_looks_like_question_rows() -> None:
    rows = [
        ("is it done?", True),
        ("um, should we go", True),
        ("um\u2014 should we go", True),  # an em dash after the filler is punctuation too
        ("how do we handle this", True),
        ("how we handle this is simple", False),
        ("how many are there", True),
        ("i was wondering if you saw it", True),
        ("we went home", False),
        ("", False),
    ]
    for text, expected in rows:
        check(f"looks_like_question {text!r}", looks_like_question(text) == expected)


def test_build_pack_request_shapes() -> None:
    sections = ["Yeah.", "So we went there and it was fine."]
    for provider in ("openai", "gemini", "claude"):
        system, user, body = runner.build_pack_request(provider, "model-x", sections)
        check(f"{provider}: user carries the wrapped pack",
              user.startswith("Transcript to clean:\n\n<s1>Yeah.</s1>\n<s2>"), user[:60])
        check(f"{provider}: system ends with the addendum",
              system.rstrip().endswith("Never merge, drop, reorder or add a section."))
        check(f"{provider}: v7 body is inside the system prompt unchanged",
              runner.build_cloud_fixed_system(9) in system)
        key = {"openai": "messages", "gemini": "contents", "claude": "messages"}[provider]
        check(f"{provider}: body carries the provider's message field", isinstance(body, dict) and key in body)


def test_polish_pack_outcomes() -> None:
    """Drive `polish_pack` with a fake `call_once` so no provider is touched: a good pack,
    a miscount, a truncation, and a per-section rejection inside a good pack."""
    texts = {"a": "so um we went to the store and bought some milk today okay", "b": "Yeah.",
             "c": "should we ship it today"}
    pack = {"file": "t", "pack_index": 0, "section_ids": ["a", "b", "c"]}
    original = runner.call_once
    try:
        runner.call_once = lambda *a, **k: (
            "Here is the cleaned transcript:\n"
            "<s1>We went to the store and bought some milk today.</s1>\n<s2>Yeah.</s2>\n"
            "<s3>We ship it today.</s3>", {"outTok": 12})
        summary, rows = runner.polish_pack("openai", "m", "k", pack, texts)
        check("good pack ok", summary["outcome"] == "ok", str(summary))
        check("one row per section in order", [r["id"] for r in rows] == ["a", "b", "c"])
        check("accepted section carries its candidate",
              rows[0]["section_status"] == "accepted" and rows[0]["candidate"].startswith("We went"))
        check("a rejected section carries its ORIGINAL words (production's fallback), never empty",
              rows[2]["section_status"] == "rejectedQuestionAnswer" and rows[2]["candidate"] == texts["c"])
        check("statuses counted", summary["section_statuses"].get("accepted") == 2)

        runner.call_once = lambda *a, **k: ("<s1>x</s1>\n<s2>y</s2>", {})
        summary, rows = runner.polish_pack("openai", "m", "k", pack, texts)
        check("miscount recorded", summary["outcome"] == "miscount")
        check("miscount: every section keeps its original words with the reason",
              all(r["section_status"] == "miscount" and r["candidate"] == texts[r["id"]] for r in rows))

        def truncated(*a, **k):
            raise RuntimeError("truncated response rejected (finish_reason=length)")
        runner.call_once = truncated
        summary, rows = runner.polish_pack("openai", "m", "k", pack, texts)
        check("truncation recorded", summary["outcome"] == "truncated", str(summary))
        check("truncation never retried", summary["attempts"] == 1)
        check("truncated sections keep their original words",
              all(r["candidate"] == texts[r["id"]] for r in rows))

        def gemini_max_tokens(*a, **k):
            raise RuntimeError("non-STOP finishReason=MAX_TOKENS")
        runner.call_once = gemini_max_tokens
        summary, rows = runner.polish_pack("gemini", "m", "k", pack, texts)
        check("Gemini MAX_TOKENS counts as truncation, not error", summary["outcome"] == "truncated")
    finally:
        runner.call_once = original


def test_bare_prompt_and_bedrock_payload() -> None:
    sections = ["one two three"]
    system, _, _ = runner.build_pack_request("openai", "m", sections, prompt_mode="bare")
    check("bare mode sends the v7 file alone plus the addendum",
          system.startswith(runner.BARE_PROMPT) and "Never merge" in system
          and "preferred spellings" not in system)
    system, _, _ = runner.build_pack_request("openai", "m", sections)
    check("production mode composes the full system prompt", "preferred spellings" in system)
    _, user, body = runner.build_pack_request("bedrock", "anthropic.claude", sections)
    check("the live bedrock call and the dry run share one builder",
          body == runner.bedrock_body("anthropic.claude", body["system"][0]["text"], user))
    check("bedrock dry-run body is the converse payload",
          body.get("modelId") == "anthropic.claude"
          and isinstance(body.get("system"), list)
          and body["system"][0]["text"].endswith("add a section.")
          and body["messages"][0]["content"][0]["text"] == user
          and body["inferenceConfig"] == {"maxTokens": runner.CLAUDE_MAX_OUTPUT_TOKENS}
          and body["additionalModelRequestFields"] == {"thinking": {"type": "disabled"}},
          str(body)[:200])


def test_thinking_off_refusal() -> None:
    check("no thinking field: nothing to refuse", runner.thinking_off_refusal(None, 50) is None)
    off = ("thinkingBudget", 0)
    check("off and zero reasoning: fine", runner.thinking_off_refusal(off, 0) is None)
    msg = runner.thinking_off_refusal(off, 12)
    check("off and reasoning tokens: refused", msg is not None and msg.startswith("FAIL: 12 reasoning tokens"))
    on = ("thinkingBudget", 1024)
    check("on with reasoning: not this guard's business", runner.thinking_off_refusal(on, 12) is None)


def test_incomplete_pack_run_exits_nonzero() -> None:
    """The isolated path returns 1 when any case errored; a pack run reports the same
    (originals are still graded, the exit status says INCOMPLETE)."""
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / "s.jsonl").write_text(json.dumps({"id": "f:1", "asr_input": "one two three"}) + "\n")
        (d / "p.jsonl").write_text(
            json.dumps({"file": "f", "pack_index": 0, "section_ids": ["f:1"], "words": 3}) + "\n")
        original = runner.call_once

        def truncated(*a, **k):
            raise RuntimeError("non-STOP finishReason=MAX_TOKENS")
        runner.call_once = truncated
        try:
            class Args:
                provider, model = "gemini", "g"
                corpus, pack, out = d / "s.jsonl", d / "p.jsonl", d / "o.jsonl"
                dry_run, limit, workers, system_prompt = None, 0, 1, "production"
            rc = runner.run_pack_mode(Args, api_key="k", azure_endpoint="", prompt_body=None, thinking=None)
            check("truncated pack run exits 1", rc == 1)
            row = json.loads((d / "o.jsonl").read_text().splitlines()[0])
            check("the section still carries its original words",
                  row["candidate"] == "one two three" and row["section_status"] == "truncated")
        finally:
            runner.call_once = original


def test_dry_run_writes_bodies_and_calls_nobody() -> None:
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / "sections.jsonl").write_text(
            json.dumps({"id": "f:1", "asr_input": "one two three"}) + "\n"
            + json.dumps({"id": "f:2", "asr_input": "four five"}) + "\n")
        (d / "packs.jsonl").write_text(
            json.dumps({"file": "f", "pack_index": 0, "section_ids": ["f:1", "f:2"], "words": 5}) + "\n")
        original = runner.call_once

        def boom(*a, **k):
            raise AssertionError("dry-run must not call a provider")
        runner.call_once = boom
        try:
            class Args:
                provider, model = "gemini", "gemini-x"
                corpus, pack, out = d / "sections.jsonl", d / "packs.jsonl", d / "nested" / "out.jsonl"
                dry_run, limit, workers = d / "dry.jsonl", 0, 1
                system_prompt = "production"
            rc = runner.run_pack_mode(Args, api_key="", azure_endpoint="", prompt_body=None, thinking=None)
            check("dry-run exits 0", rc == 0)
            lines = (d / "dry.jsonl").read_text().splitlines()
            check("one body per pack", len(lines) == 1)
            body = json.loads(lines[0])
            check("body carries the section ids", body["section_ids"] == ["f:1", "f:2"])
            check("gemini body shape", "contents" in body["body"] and "systemInstruction" in body["body"])
            check("no output rows written on a dry run", not (d / "out.jsonl").exists())
            check("no output directory created on a dry run", not (d / "nested").exists())
        finally:
            runner.call_once = original


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    assert len(tests) == EXPECTED_TESTS, f"expected {EXPECTED_TESTS} tests, found {len(tests)}"
    for t in tests:
        t()
    print(f"{len(tests)} tests, {_failures} failed")
    return 1 if _failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
