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

EXPECTED_TESTS = 16
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
        check("good pack unwrapped", summary["outcome"] == "unwrapped", str(summary))
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


def test_isolated_arm_validate_flag() -> None:
    """`--validate` gives the isolated arm the packed arm's fallback treatment; without it
    the historical behaviour (raw answer, no status) is byte-identical."""
    original = runner.call_once
    case = {"id": "q", "text": "should we ship it today"}
    try:
        runner.call_once = lambda *a, **k: ("We ship it today.", {})
        plain = runner.polish_case("openai", "m", "k", case)
        check("without --validate the raw answer is kept and no status is written",
              plain["candidate"] == "We ship it today." and "section_status" not in plain)
        validated = runner.polish_case("openai", "m", "k", case, validate=True)
        check("with --validate a rejected answer becomes the original with its reason",
              validated["candidate"] == case["text"]
              and validated["section_status"] == "rejectedQuestionAnswer")
        runner.call_once = lambda *a, **k: ("Should we ship it today?", {})
        accepted = runner.polish_case("openai", "m", "k", case, validate=True)
        check("with --validate an accepted answer is kept and marked accepted",
              accepted["candidate"] == "Should we ship it today?" and accepted["section_status"] == "accepted")

        def boom(*a, **k):
            raise RuntimeError("provider down")
        runner.call_once = boom
        failed_plain = runner.polish_case("openai", "m", "k", case)
        check("without --validate a failed call is an empty candidate with an error and no status",
              failed_plain["candidate"] == "" and failed_plain["error"] == "provider down"
              and "section_status" not in failed_plain)
        failed = runner.polish_case("openai", "m", "k", case, validate=True)
        check("with --validate a failed call keeps the original words with status error, like a failed pack",
              failed["candidate"] == case["text"] and failed["section_status"] == "error"
              and failed["fallback_error"] == "provider down" and "error" not in failed, str(failed))
        from behavior_judge import partition_candidates
        judged, skipped = partition_candidates({"q": {}}, {"q": failed})
        check("the judge grades the validated fallback row instead of skipping it",
              judged == ["q"] and not skipped, f"{judged} {skipped}")
        judged, skipped = partition_candidates({"q": {}}, {"q": failed_plain})
        check("the judge still skips the plain failed row", judged == [] and len(skipped) == 1, f"{judged} {skipped}")
    finally:
        runner.call_once = original


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


def test_packing_report_refuses_only_mechanical_mismatches() -> None:
    """`compare_arms_paired.py --packing-report` lives beside the runner. It refuses a row
    without `section_status`, a graded row whose text is not the supplied candidate, and a
    duplicate id. It does NOT refuse arms whose receipts differ: it prints both receipts
    and leaves that reading to the operator."""
    import subprocess
    report = Path(__file__).resolve().parents[1] / "compare_arms_paired.py"
    check("compare_arms_paired.py is beside the runner", report.exists())
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        graded = json.dumps({"id": "x", "verdict": "pass", "candidate_output": "t"}) + "\n"
        (d / "a.jsonl").write_text(graded)
        (d / "b.jsonl").write_text(graded)
        receipt = {"provider": "openai", "model": "m", "prompt_mode": "production", "prompt_sha256": "a" * 64,
                   "thinking": None, "validated": True, "mode": "isolated", "pack_file": None}
        other_model = {**receipt, "model": "other", "mode": "packed", "pack_file": "packs-1500.jsonl"}
        good = json.dumps({"id": "x", "candidate": "t", "section_status": "accepted", "run": receipt}) + "\n"
        (d / "plain.jsonl").write_text(json.dumps({"id": "x", "candidate": "t", "run": receipt}) + "\n")
        (d / "good.jsonl").write_text(good)
        (d / "dup.jsonl").write_text(good + good)
        (d / "othermodel.jsonl").write_text(json.dumps({"id": "x", "candidate": "t", "section_status": "rejectedExpansion", "run": other_model}) + "\n")
        (d / "foreign.jsonl").write_text(json.dumps({"id": "x", "candidate": "OTHER", "section_status": "accepted", "run": receipt}) + "\n")

        def run(a_cand, b_cand):
            r = subprocess.run(
                [sys.executable, str(report), "--a", str(d / "a.jsonl"), "--b", str(d / "b.jsonl"),
                 "--packing-report", "--a-candidates", str(d / a_cand),
                 "--b-candidates", str(d / b_cand)], capture_output=True, text=True)
            return r.returncode, r.stdout + r.stderr
        rc, out = run("plain.jsonl", "good.jsonl")
        check("a plain isolated arm is refused", rc != 0 and "section_status missing" in out, out[-300:])
        rc, out = run("foreign.jsonl", "good.jsonl")
        check("a candidate file the scores did not come from is refused",
              rc != 0 and "not the supplied candidate" in out, out[-300:])
        rc, out = run("dup.jsonl", "good.jsonl")
        check("a duplicate id in a candidate file is refused", rc != 0 and "duplicate id x" in out, out[-300:])
        (d / "a-dup.jsonl").write_text(graded + graded)
        r = subprocess.run([sys.executable, str(report), "--a", str(d / "a-dup.jsonl"), "--b", str(d / "b.jsonl")],
                           capture_output=True, text=True)
        check("a duplicate id in a score file is refused, packing report or not",
              r.returncode != 0 and "duplicate id x" in r.stdout + r.stderr, (r.stdout + r.stderr)[-300:])
        rc, out = run("good.jsonl", "othermodel.jsonl")
        check("arms with different receipts are NOT refused; both receipts are printed",
              rc == 0 and '"model": "other"' in out and '"model": "m"' in out
              and "does not certify" in out and "not in the receipt" in out
              and "#2904" in out, out[-600:])
        check("the fallback count names the rejected row",
              "B: 1 fallback rows of 1" in out and "rejectedExpansion" in out, out[-500:])


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
                dry_run, limit, workers = d / "dry-dir" / "dry.jsonl", 0, 1
                system_prompt = "production"
            rc = runner.run_pack_mode(Args, api_key="", azure_endpoint="", prompt_body=None, thinking=None)
            check("dry-run exits 0", rc == 0)
            (d / "packs-dup.jsonl").write_text(
                json.dumps({"section_ids": ["f:1", "f:2"]}) + "\n" + json.dumps({"section_ids": ["f:2"]}) + "\n")

            class DupArgs(Args):
                pack = d / "packs-dup.jsonl"
                dry_run = d / "dry-dup.jsonl"
            rc = runner.run_pack_mode(DupArgs, api_key="", azure_endpoint="", prompt_body=None, thinking=None)
            check("a section id in two packs is refused before anything is written",
                  rc == 2 and not (d / "dry-dup.jsonl").exists())
            lines = (d / "dry-dir" / "dry.jsonl").read_text().splitlines()
            check("one body per pack, in a directory the dry run created for its own file", len(lines) == 1)
            body = json.loads(lines[0])
            check("body carries the section ids", body["section_ids"] == ["f:1", "f:2"])
            check("gemini body shape", "contents" in body["body"] and "systemInstruction" in body["body"])
            check("no output rows written on a dry run", not (d / "out.jsonl").exists())
            check("no output directory created on a dry run", not (d / "nested").exists())
        finally:
            runner.call_once = original


def test_pack_limit_bounds_sections_not_packs() -> None:
    """`--limit N` is a SECTION bound in pack mode too (#2909): the leading whole packs while
    their sections total at most N, never a cut pack, and a refusal (not a skip to a later,
    smaller pack) when the first pack alone exceeds N. The receipt records `packs_total`."""
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        ids = [f"f:{i}" for i in range(1, 8)]
        (d / "sections.jsonl").write_text(
            "".join(json.dumps({"id": i, "asr_input": f"words for {i}"}) + "\n" for i in ids))

        def packs_file(name: str, sizes: list[int]) -> Path:
            rows, cursor = [], 0
            for n, size in enumerate(sizes):
                rows.append({"file": "f", "pack_index": n, "section_ids": ids[cursor:cursor + size],
                             "words": size * 3})
                cursor += size
            (d / name).write_text("".join(json.dumps(r) + "\n" for r in rows))
            return d / name

        original = runner.call_once

        def boom(*a, **k):
            raise AssertionError("dry-run must not call a provider")
        runner.call_once = boom
        try:
            class Args:
                provider, model = "openai", "m"
                corpus, pack, out = d / "sections.jsonl", packs_file("p232.jsonl", [2, 3, 2]), d / "out.jsonl"
                dry_run, limit, workers = d / "dry5.jsonl", 5, 1
                system_prompt = "production"
            rc = runner.run_pack_mode(Args, api_key="", azure_endpoint="", prompt_body=None, thinking=None)
            kept = [json.loads(l)["section_ids"] for l in (d / "dry5.jsonl").read_text().splitlines()]
            check("limit 5 over packs [2, 3, 2] keeps the leading two whole packs (5 sections), exit 0",
                  rc == 0 and kept == [ids[0:2], ids[2:5]], f"rc={rc} kept={kept}")

            class Limit4(Args):
                limit, dry_run = 4, d / "dry4.jsonl"
            rc = runner.run_pack_mode(Limit4, api_key="", azure_endpoint="", prompt_body=None, thinking=None)
            kept = [json.loads(l)["section_ids"] for l in (d / "dry4.jsonl").read_text().splitlines()]
            check("limit 4 stops at the first pack that does not fit; the second pack is never cut",
                  rc == 0 and kept == [ids[0:2]], f"rc={rc} kept={kept}")

            class NoLimit(Args):
                limit, dry_run = 0, d / "dry0.jsonl"
            rc = runner.run_pack_mode(NoLimit, api_key="", azure_endpoint="", prompt_body=None, thinking=None)
            check("limit 0 (the default, no limit) keeps every pack",
                  rc == 0 and len((d / "dry0.jsonl").read_text().splitlines()) == 3)

            class Exact(Args):
                limit, dry_run = 2, d / "dry2.jsonl"
            rc = runner.run_pack_mode(Exact, api_key="", azure_endpoint="", prompt_body=None, thinking=None)
            kept = [json.loads(l)["section_ids"] for l in (d / "dry2.jsonl").read_text().splitlines()]
            check("a limit equal to the first pack's size admits exactly that pack",
                  rc == 0 and kept == [ids[0:2]], f"rc={rc} kept={kept}")
            try:
                runner.nonnegative_int("-1")
                check("a negative --limit is rejected at parse time", False)
            except Exception as e:  # argparse.ArgumentTypeError
                check("a negative --limit is rejected at parse time", "0 or more" in str(e), str(e))
            check("--limit 0 parses as the no-limit default", runner.nonnegative_int("0") == 0)

            import io
            from contextlib import redirect_stderr

            class Refused(Args):
                pack, limit, dry_run = packs_file("p52.jsonl", [5, 2]), 2, d / "dry-refused.jsonl"
            err = io.StringIO()
            with redirect_stderr(err):
                rc = runner.run_pack_mode(Refused, api_key="", azure_endpoint="", prompt_body=None, thinking=None)
            check("limit 2 over packs [5, 2] refuses rather than skipping to the smaller second pack",
                  rc == 2 and not (d / "dry-refused.jsonl").exists() and not (d / "out.jsonl").exists(),
                  f"rc={rc}")
            check("the refusal names the FIRST pack and recommends its size",
                  "f:0 has 5 sections" in err.getvalue() and "--limit 5 or more" in err.getvalue(),
                  err.getvalue()[-300:])
        finally:
            runner.call_once = original

        # Live path with a fake provider: the receipt on every written row carries packs_total,
        # the count BEFORE the limit, so a limited run is distinguishable from a full one.
        runner.call_once = lambda *a, **k: ("<s1>x</s1>\n<s2>y</s2>", {"outTok": 2})
        try:
            class Live(Args):
                limit, dry_run, out = 2, None, d / "live" / "out.jsonl"
            rc = runner.run_pack_mode(Live, api_key="k", azure_endpoint="", prompt_body=None, thinking=None)
            rows = [json.loads(l) for l in (d / "live" / "out.jsonl").read_text().splitlines()]
            check("live limited run wrote the first pack's two rows only",
                  rc == 0 and [r["id"] for r in rows] == ids[0:2], f"rc={rc} ids={[r.get('id') for r in rows]}")
            check("every row's receipt records packs_total = 3 (packs available before --limit)",
                  all(r["run"].get("packs_total") == 3 for r in rows), str(rows[:1])[:300])
        finally:
            runner.call_once = original


def test_json_out_creates_parent() -> None:
    """`compare_arms_paired.py --json-out` into a directory that does not exist yet writes the
    report instead of raising after the comparison already ran (#2911)."""
    import subprocess
    report = Path(__file__).resolve().parents[1] / "compare_arms_paired.py"
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        graded = json.dumps({"id": "x", "verdict": "pass", "candidate_output": "t"}) + "\n"
        (d / "a.jsonl").write_text(graded)
        (d / "b.jsonl").write_text(graded)
        target = d / "new" / "dir" / "report.json"
        r = subprocess.run([sys.executable, str(report), "--a", str(d / "a.jsonl"), "--b", str(d / "b.jsonl"),
                            "--json-out", str(target)], capture_output=True, text=True)
        check("comparison exits 0 with --json-out in a new directory", r.returncode == 0, (r.stdout + r.stderr)[-300:])
        check("the report exists and parses, with the shared count",
              target.exists() and json.loads(target.read_text()).get("n_shared") == 1)


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    assert len(tests) == EXPECTED_TESTS, f"expected {EXPECTED_TESTS} tests, found {len(tests)}"
    for t in tests:
        t()
    print(f"{len(tests)} tests, {_failures} failed")
    return 1 if _failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
