"""Tests for propose.py (#4353 PR 5). Run through `propose.py --self-test`.

Every case runs the real generator or the real `check` command against a throwaway git
repository. Expected rows and changes are literals written from the plan, not computed by
propose.py. Receipts follow the Swift encoding (`CloudModelRoutineReceipt`); the Swift
integration test `CloudModelRoutineProposalTests` proves that shape against the real harness.
"""

import copy
import hashlib
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import propose

OBSERVED = "2026-11-04T00:00:00Z"


def row(provider, model, request, hidden=False, reason=None, recommended=False, chat=False, batch=True):
    item = {"provider": provider, "id": model, "recommended": recommended, "hidden": hidden}
    if reason is not None:
        item["hiddenReason"] = reason
    item.update({"request": request, "supportsChatCompletions": chat, "allowsFileBatch": batch})
    return item


OPENAI_FALLBACK = {"openAIEffort": "omit", "temperature": "include"}
BASE_MODELS = [
    row("openAI", "gpt-a", OPENAI_FALLBACK, chat=True),
    row("openAI", "gpt-p", OPENAI_FALLBACK, hidden=True, reason="Retired on purpose", chat=True),
    row("claude", "claude-a", {"claudeShape": "thinkingDisabled"}),
    row("gemini", "gemini-a", {"geminiThinking": "none"}),
]


def list_bytes(models=None, updated="2026-11-01"):
    return propose.encode_list({"schema": 1, "updated": updated, "models": models or BASE_MODELS})


def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)


def commit_list(repo, data, message="list"):
    for relative in (propose.PUBLIC, propose.BUNDLED):
        path = repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", message)
    return subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], check=True,
                          capture_output=True).stdout.decode().strip()


# MARK: - Receipt builder (Swift field names and encoding)


def call_id(provider, model, label, phase, index, attempt=1):
    return {"attempt": attempt, "call": {"input": index, "model": model, "phase": phase,
                                         "provider": provider,
                                         "setting": {"label": label, "provider": provider}}}


class Receipt:
    def __init__(self, commit, base, outcome=None):
        self.commit, self.base, self.outcome = commit, base, outcome
        self.calls, self.physical, self.logical = [], [], set()
        self.candidates = {p: [] for p in propose.PROVIDERS}
        self.failed = set()

    def send(self, provider, model, label, phase, index, status=200, params=None, attempts=1):
        for attempt in range(1, attempts + 1):
            ident = call_id(provider, model, label, phase, index, attempt)
            self.calls.append({"id": ident, "outcome": {"replied": {"status": status}},
                               "usage": {"absent": {}}})
            sent = params if params is not None else (
                propose.openai_params(label) if provider == "openAI" else [])
            self.physical.append({"id": ident, "sentOpenAIParams": sent})
        self.logical.add((provider, model, label, phase, index))

    def fallback_pass(self, model="gpt-new", provider="openAI", label="openAI:omit/include",
                      request=None, adapted=False, chat=True):
        request = request or OPENAI_FALLBACK
        for index in range(3):
            self.send(provider, model, label, "fallback", index,
                      params=[] if adapted else None, attempts=2 if adapted and index == 0 else 1)
        new = row(provider, model, request, chat=chat)
        new["released"] = "2026-10-01"
        new["medianPolishMs"] = 6
        self.candidates[provider].append({
            "id": model, "outcome": "pass", "passViaAdaptation": adapted, "perInputMs": [5, 6, 7],
            "medianMs": 6, "setting": label, "sourceDate": "2026-10-01T00:00:00Z",
            "resolvesTheSame": True, "row": new,
            "fallback": {"setting": label, "phase": "fallback", "inputs": [0, 1, 2],
                         "perInputMs": [5, 6, 7], "memoAdapted": adapted,
                         "physicalAttempts": 4 if adapted else 3},
            "resolution": resolution(model, label, label, chat),
        })
        return new

    def search_pass(self, model="gpt-new", chosen="openAI:none/omit",
                    request=None, rejected=("openAI:omit/omit", "openAI:none/include"),
                    adapted_first=False):
        fallback = "openAI:omit/include"
        request = request or {"openAIEffort": "none", "temperature": "omit"}
        self.send("openAI", model, fallback, "fallback", 0, status=400)
        attempts = []
        for number, label in enumerate(rejected):
            if adapted_first and number == 0:
                # A success that needed a strip: two requests, the second without a parameter.
                self.send("openAI", model, label, "screening", 0, params=openai_params_of(label))
                self.physical[-1]["sentOpenAIParams"] = ["reasoning_effort", "temperature"]
                ident = call_id("openAI", model, label, "screening", 0, 2)
                self.calls.append({"id": ident, "outcome": {"replied": {"status": 200}}})
                self.physical.append({"id": ident, "sentOpenAIParams": ["reasoning_effort"]})
                self.calls[-2]["outcome"] = {"replied": {"status": 400}}
                attempts.append({"setting": label, "request": label_request(label), "qualified": False,
                                 "screening": {"setting": label, "phase": "screening", "inputs": [0],
                                               "perInputMs": [3], "memoAdapted": True,
                                               "requestsMatchedSetting": False,
                                               "physicalAttempts": 2}})
                continue
            self.send("openAI", model, label, "screening", 0, status=400)
            attempts.append({"setting": label, "request": label_request(label), "qualified": False,
                             "screening": {"setting": label, "phase": "screening", "inputs": [0],
                                           "perInputMs": [], "errorClass": "requestRejected",
                                           "memoAdapted": False, "requestsMatchedSetting": True,
                                           "physicalAttempts": 1}})
        self.send("openAI", model, chosen, "screening", 0)
        for index in range(3):
            self.send("openAI", model, chosen, "confirmation", index)
        attempts.append({
            "setting": chosen, "request": request, "qualified": True,
            "screening": {"setting": chosen, "phase": "screening", "inputs": [0], "perInputMs": [4],
                          "memoAdapted": False, "requestsMatchedSetting": True, "physicalAttempts": 1},
            "confirmation": {"setting": chosen, "phase": "confirmation", "inputs": [0, 1, 2],
                             "perInputMs": [4, 5, 6], "memoAdapted": False,
                             "requestsMatchedSetting": True, "physicalAttempts": 3}})
        new = row("openAI", model, request, chat=True)
        new["medianPolishMs"] = 5
        self.candidates["openAI"].append({
            "id": model, "outcome": "passViaSearch", "passViaAdaptation": False, "perInputMs": [],
            "setting": fallback, "errorClass": "requestRejected", "resolvesTheSame": True,
            "row": new,
            "fallback": {"setting": fallback, "phase": "fallback", "inputs": [0, 1, 2],
                         "perInputMs": [], "errorClass": "requestRejected", "memoAdapted": False,
                         "physicalAttempts": 1},
            "search": {"trigger": "requestRejected", "fallbackSetting": fallback,
                       "alternatives": OPENAI_ALTERNATIVES, "attempts": attempts,
                       "outcome": "passed", "chosenSetting": chosen},
            "resolution": resolution(model, fallback, chosen, True),
        })
        return new

    def failed_candidate(self, model="gpt-bad"):
        self.send("openAI", model, "openAI:omit/include", "fallback", 0, status=401)
        self.candidates["openAI"].append({
            "id": model, "outcome": "fail", "passViaAdaptation": False, "perInputMs": [],
            "setting": "openAI:omit/include", "errorClass": "keyRejected"})

    def build(self):
        providers = []
        for provider in propose.PROVIDERS:
            item = {"provider": provider, "catalog": "complete", "identityCount": 9,
                    "excludedModels": [], "excluded": {}, "dispositions": {},
                    "candidates": self.candidates[provider]}
            if provider in self.failed:
                item.update(catalog="failed", catalogFailure="transient", candidates=[],
                            identityCount=0)
            providers.append(item)
        failed = bool(self.failed)
        unfinished = any(c["outcome"] not in ("pass", "passViaSearch")
                         for items in self.candidates.values() for c in items)
        proposes = any("row" in c for items in self.candidates.values() for c in items)
        outcome = self.outcome or ("failure" if failed else "partial" if unfinished
                                   else "success" if proposes else "nochange")
        return {
            "schema": 1,
            "provenance": {"repository": "example/repo", "workflow": "cloud-models-sweep",
                           "runID": "101", "runAttempt": "1", "event": "schedule",
                           "ref": "refs/heads/main", "sourceSHA": self.commit},
            "observedAt": OBSERVED,
            "list": {"updated": json.loads(self.base)["updated"],
                     "revision": "r", "sha256": hashlib.sha256(self.base).hexdigest()},
            "inputs": [{"id": f"realDictations[{i}]", "sha256": "a" * 64} for i in range(3)],
            "outcome": outcome,
            "providers": providers,
            "calls": self.calls,
            "physicalRequests": self.physical,
            "logicalCalls": len(self.logical),
            "physicalExchanges": len(self.physical),
            "unrecordedExchanges": 0,
            "refusals": 0,
            "publicationReady": False,
        }


OPENAI_ALTERNATIVES = [
    "openAI:omit/omit", "openAI:none/include", "openAI:none/omit", "openAI:minimal/include",
    "openAI:minimal/omit", "openAI:low/include", "openAI:low/omit",
]


def openai_params_of(label):
    return propose.openai_params(label)


def label_request(label):
    effort, temperature = label[len("openAI:"):].split("/")
    return {"openAIEffort": effort, "temperature": temperature}


def resolution(model, before, after, chat):
    return [{"id": spelling,
             "before": {"setting": before, "supportsChatCompletions": chat, "allowsFileBatch": True},
             "after": {"setting": after, "supportsChatCompletions": chat, "allowsFileBatch": True}}
            for spelling in (model, f"{model}-2030-01-01", f"{model}-20300101")]


# MARK: - Harness


class Case(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="propose-test-")
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "test@example.invalid")
        git(self.repo, "config", "user.name", "test")
        self.base = list_bytes()
        self.commit = commit_list(self.repo, self.base)

    def tearDown(self):
        self.temp.cleanup()

    def receipt(self, outcome=None):
        return Receipt(self.commit, self.base, outcome)

    def inputs(self, receipt, context_edit=None, receipt_bytes=None):
        data = receipt_bytes if receipt_bytes is not None else json.dumps(
            receipt if isinstance(receipt, dict) else receipt.build(), sort_keys=True).encode()
        (self.root / "receipt.json").write_bytes(data)
        context = {"schema": 1, "receiptSHA256": hashlib.sha256(data).hexdigest(),
                   "repository": "example/repo", "workflow": "cloud-models-sweep", "runID": "101",
                   "runAttempt": "1", "event": "schedule", "ref": "refs/heads/main",
                   "sourceSHA": self.commit}
        if context_edit:
            context_edit(context)
        (self.root / "context.json").write_text(json.dumps(context))
    def common(self, base=None):
        return ["--repo", str(self.repo), "--base", base or self.commit,
                "--receipt", str(self.root / "receipt.json"),
                "--context", str(self.root / "context.json"),
                "--result", str(self.root / "result.json")]

    def cli(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            status = propose.main(argv)
        return status, out.getvalue() + err.getvalue()

    def generate(self, base=None):
        output = self.root / "out"
        status, text = self.cli(["generate", *self.common(base), "--output-root", str(output)])
        return status, text, output

    def generated_list(self):
        return json.loads((self.root / "out" / propose.PUBLIC).read_bytes())

    def result(self):
        return json.loads((self.root / "result.json").read_bytes())

    def check(self, root=None, target=None):
        return self.cli(["check", *self.common(), "--current-root", str(root or self.root / "out"),
                         "--target-base", target or self.commit])

    def refused(self, receipt=None, needle="", **inputs):
        if receipt is not None:
            self.inputs(receipt, **inputs)
        status, text, output = self.generate()
        self.assertEqual(status, 1, text)
        self.assertIn("refused:", text)
        self.assertIn(needle, text)
        self.assertFalse((output / propose.PUBLIC).exists())
        self.assertFalse((self.root / "result.json").exists())
        return text


# MARK: - Inputs and trust


class InputsAndTrust(Case):
    def test_valid_run_is_accepted(self):
        receipt = self.receipt()
        receipt.fallback_pass()
        self.inputs(receipt)
        self.assertEqual(self.generate()[0], 0)

    def test_missing_revision(self):
        receipt = self.receipt()
        self.inputs(receipt)
        status, text, _ = self.generate(base="0" * 40)
        self.assertEqual(status, 1)
        self.assertIn("is not a commit", text)

    def test_base_is_not_the_measured_commit(self):
        other = commit_list(self.repo, list_bytes(updated="2026-11-02"), "moved")
        receipt = self.receipt()
        self.inputs(receipt)
        status, text, _ = self.generate(base=other)
        self.assertEqual(status, 1)
        self.assertIn("not the commit the run measured", text)

    def test_missing_list_file_at_base(self):
        git(self.repo, "rm", "-q", propose.BUNDLED)
        git(self.repo, "commit", "-q", "-m", "drop")
        self.commit = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"],
                                     capture_output=True, check=True).stdout.decode().strip()
        self.refused(self.receipt(), "cannot be read")

    def test_wrong_list_hash(self):
        receipt = self.receipt().build()
        receipt["list"]["sha256"] = "b" * 64
        self.refused(receipt, "not the list the run measured")

    def test_each_context_field_must_match(self):
        for field in propose.CONTEXT_FIELDS:
            with self.subTest(field=field):
                value = "f" * 40 if field == "sourceSHA" else "other"
                # A different sourceSHA is caught first, by the base-commit comparison.
                needle = "not the commit the run measured" if field == "sourceSHA" else "does not match"
                self.refused(self.receipt(), needle,
                             context_edit=lambda c, f=field, v=value: c.__setitem__(f, v))

    def test_receipt_hash_must_match(self):
        self.refused(self.receipt(), "receipt hash",
                     context_edit=lambda c: c.__setitem__("receiptSHA256", "c" * 64))

    def test_missing_provenance_field(self):
        receipt = self.receipt().build()
        del receipt["provenance"]["ref"]
        self.refused(receipt, "provenance.ref is missing")

    def test_publication_ready_is_not_trusted(self):
        receipt = self.receipt().build()
        receipt["publicationReady"] = True
        self.refused(receipt, "publicationReady")

    def test_contradictory_counts(self):
        receipt = self.receipt()
        receipt.fallback_pass()
        built = receipt.build()
        built["physicalExchanges"] += 1
        self.refused(built, "physicalExchanges")
        built = receipt.build()
        built["calls"].pop()
        self.refused(built, "do not reconcile")

    def test_outcome_must_match_evidence(self):
        receipt = self.receipt("nochange")
        receipt.fallback_pass()
        self.refused(receipt, "contradicts its own evidence")

    def test_not_json(self):
        self.refused(self.receipt(), "is not JSON", receipt_bytes=b"{not json")

    def test_hiding_evidence_is_not_accepted(self):
        # The routine never hides (founder decision 14): a receipt carrying absence or history
        # fields is not this receipt.
        built = self.receipt().build()
        built["history"] = {"version": 1, "entries": [], "latestObservedAt": {}}
        self.refused(built, "unknown key history")
        built = self.receipt().build()
        built["providers"][2]["absence"] = {"claude-a": {"state": "hide"}}
        self.refused(built, "unknown key absence")

    def test_messages_never_echo_values(self):
        receipt = self.receipt().build()
        receipt["provenance"]["workflow"] = "secret-looking-value"
        text = self.refused(receipt, "does not match")
        self.assertNotIn("secret-looking-value", text)


# MARK: - Additions


class Additions(Case):
    def test_fallback_addition_is_appended_exactly(self):
        receipt = self.receipt()
        receipt.fallback_pass()
        self.inputs(receipt)
        self.assertEqual(self.generate()[0], 0)
        document = self.generated_list()
        self.assertEqual(document["models"][:4], BASE_MODELS)
        self.assertEqual(document["models"][4], {
            "provider": "openAI", "id": "gpt-new", "released": "2026-10-01", "recommended": False,
            "hidden": False, "request": {"openAIEffort": "omit", "temperature": "include"},
            "supportsChatCompletions": True, "allowsFileBatch": True, "medianPolishMs": 6})
        self.assertEqual(document["updated"], "2026-11-04")
        self.assertEqual(self.result()["operations"], [
            {"op": "add", "provider": "openAI", "id": "gpt-new", "setting": "openAI:omit/include",
             "via": "fallback"}])

    def test_adapted_fallback_keeps_the_unchanged_row(self):
        receipt = self.receipt()
        receipt.fallback_pass(adapted=True)
        self.inputs(receipt)
        self.assertEqual(self.generate()[0], 0)
        self.assertEqual(self.generated_list()["models"][4]["request"], OPENAI_FALLBACK)
        self.assertEqual(self.result()["operations"][0]["via"], "fallbackAdapted")

    def test_searched_addition(self):
        receipt = self.receipt()
        receipt.search_pass()
        self.inputs(receipt)
        self.assertEqual(self.generate()[0], 0)
        self.assertEqual(self.generated_list()["models"][4], {
            "provider": "openAI", "id": "gpt-new", "recommended": False, "hidden": False,
            "request": {"openAIEffort": "none", "temperature": "omit"},
            "supportsChatCompletions": True, "allowsFileBatch": True, "medianPolishMs": 5})
        self.assertEqual(self.result()["operations"][0]["via"], "search")

    def mutate_search(self, change, needle):
        receipt = self.receipt()
        receipt.search_pass()
        built = receipt.build()
        change(built["providers"][0]["candidates"][0])
        self.refused(built, needle)

    def test_incomplete_confirmation(self):
        def change(c):
            c["search"]["attempts"][-1]["confirmation"]["perInputMs"] = [4, 5]
        self.mutate_search(change, "stopped early")

    def test_adapted_confirmation_does_not_qualify(self):
        def change(c):
            c["search"]["attempts"][-1]["confirmation"]["memoAdapted"] = True
        self.mutate_search(change, "without adaptation")

    def test_qualified_flag_alone_is_not_enough(self):
        def change(c):
            c["search"]["attempts"][0]["qualified"] = True
        self.mutate_search(change, "not the last tried")

    def test_menu_order(self):
        def change(c):
            c["search"]["alternatives"] = list(reversed(OPENAI_ALTERNATIVES))
        self.mutate_search(change, "menu order")

    def test_row_must_be_the_chosen_setting(self):
        def change(c):
            c["row"]["request"] = {"openAIEffort": "low", "temperature": "omit"}
        self.mutate_search(change, "not the chosen setting")

    def test_search_needs_a_rejected_fallback(self):
        def change(c):
            c["fallback"].pop("errorClass")
            c["fallback"]["perInputMs"] = [1, 2, 3]
        self.mutate_search(change, "rejected fallback")

    def test_search_without_fallback_exchanges(self):
        receipt = self.receipt()
        receipt.search_pass()
        built = receipt.build()
        keep = lambda item: item["id"]["call"]["phase"] != "fallback"
        built["calls"] = [c for c in built["calls"] if keep(c)]
        built["physicalRequests"] = [c for c in built["physicalRequests"] if keep(c)]
        built["logicalCalls"] -= 1
        built["physicalExchanges"] -= 1
        self.refused(built, "exchanges do not match the inputs it tried")

    def test_search_after_a_stopping_failure(self):
        receipt = self.receipt()
        receipt.search_pass()
        built = receipt.build()
        built["providers"][0]["candidates"][0]["search"]["attempts"][0]["screening"][
            "errorClass"] = "keyRejected"
        self.refused(built, "failure that stops it")

    def test_search_after_an_earlier_qualifying_setting(self):
        receipt = self.receipt()
        receipt.search_pass(rejected=("openAI:omit/omit",), chosen="openAI:none/include",
                            request={"openAIEffort": "none", "temperature": "include"})
        built = receipt.build()
        attempt = built["providers"][0]["candidates"][0]["search"]["attempts"][0]
        attempt["screening"].update(perInputMs=[3])
        attempt["screening"].pop("errorClass")
        for record in built["calls"]:
            if record["id"]["call"]["setting"]["label"] == "openAI:omit/omit":
                record["outcome"] = {"replied": {"status": 200}}
        self.refused(built, "passed screening but was not confirmed")

    def test_an_adapted_earlier_attempt_is_a_valid_control(self):
        receipt = self.receipt()
        receipt.search_pass(rejected=("openAI:omit/omit", "openAI:none/include"), adapted_first=True)
        built = receipt.build()
        self.inputs(built)
        status, text, _ = self.generate()
        self.assertEqual(status, 0, text)
        self.assertEqual(self.result()["operations"][0]["setting"], "openAI:none/omit")

    def unusable_confirmation(self, timed, extra_send=False, drop_send=False):
        """omit/omit passes screening, then confirmation input 1 is unusable; none/include wins.
        `timed`: the reply came back and was judged unusable (its timing is recorded), versus
        the connector throwing on an empty reply (no timing)."""
        receipt = self.receipt()
        model, first, winner = "gpt-new", "openAI:omit/omit", "openAI:none/include"
        receipt.send("openAI", model, "openAI:omit/include", "fallback", 0, status=400)
        receipt.send("openAI", model, first, "screening", 0)
        for index in (0, 1):
            receipt.send("openAI", model, first, "confirmation", index)
        if extra_send:
            receipt.send("openAI", model, first, "confirmation", 2)
        if drop_send:
            receipt.calls.pop()
            receipt.physical.pop()
        receipt.send("openAI", model, winner, "screening", 0)
        for index in range(3):
            receipt.send("openAI", model, winner, "confirmation", index)
        sends = 3 if extra_send else 1 if drop_send else 2
        request = {"openAIEffort": "none", "temperature": "include"}
        phase = lambda label, name, inputs, ms, attempts, error=None: dict(
            {"setting": label, "phase": name, "inputs": inputs, "perInputMs": ms,
             "memoAdapted": False, "requestsMatchedSetting": True, "physicalAttempts": attempts},
            **({"errorClass": error} if error else {}))
        new = row("openAI", model, request, chat=True)
        new["medianPolishMs"] = 5
        receipt.candidates["openAI"].append({
            "id": model, "outcome": "passViaSearch", "passViaAdaptation": False, "perInputMs": [],
            "setting": "openAI:omit/include", "errorClass": "requestRejected",
            "resolvesTheSame": True, "row": new,
            "fallback": {"setting": "openAI:omit/include", "phase": "fallback", "inputs": [0, 1, 2],
                         "perInputMs": [], "errorClass": "requestRejected", "memoAdapted": False,
                         "physicalAttempts": 1},
            "search": {"trigger": "requestRejected", "fallbackSetting": "openAI:omit/include",
                       "alternatives": OPENAI_ALTERNATIVES, "outcome": "passed",
                       "chosenSetting": winner, "attempts": [
                           {"setting": first, "request": label_request(first), "qualified": False,
                            "screening": phase(first, "screening", [0], [3], 1),
                            "confirmation": phase(first, "confirmation", [0, 1, 2],
                                                  [3, 4] if timed else [3], sends, "unusableOutput")},
                           {"setting": winner, "request": request, "qualified": True,
                            "screening": phase(winner, "screening", [0], [4], 1),
                            "confirmation": phase(winner, "confirmation", [0, 1, 2], [4, 5, 6], 3)},
                       ]},
            "resolution": resolution(model, "openAI:omit/include", winner, True),
        })
        return receipt

    def test_unusable_output_in_both_timing_forms(self):
        for timed in (True, False):
            with self.subTest(timed=timed):
                self.inputs(self.unusable_confirmation(timed))
                (self.root / "result.json").unlink(missing_ok=True)
                status, text, _ = self.generate()
                self.assertEqual(status, 0, text)
                self.assertEqual(self.result()["operations"][0]["setting"], "openAI:none/include")

    def test_unusable_output_with_missing_or_extra_exchanges(self):
        # Timed: inputs 0 and 1 must both have sent. Untimed: exactly inputs 0 and 1 sent.
        # (Timed with three sends is not refused: it reads as the untimed form failing at input 2.)
        for timed, extra, drop in ((True, False, True), (False, True, False)):
            with self.subTest(timed=timed, extra=extra, drop=drop):
                shutil.rmtree(self.root / "out", ignore_errors=True)
                (self.root / "result.json").unlink(missing_ok=True)
                self.refused(self.unusable_confirmation(timed, extra, drop), "exchanges do not match")

    def test_unexplained_requests_are_refused(self):
        receipt = self.receipt()
        receipt.fallback_pass()
        receipt.send("openAI", "gpt-new", "openAI:low/omit", "screening", 0)
        self.refused(receipt, "phases do not describe")

    def test_median_must_be_the_measured_one(self):
        receipt = self.receipt()
        receipt.fallback_pass()
        built = receipt.build()
        built["providers"][0]["candidates"][0]["row"]["medianPolishMs"] = 60000
        self.refused(built, "measured median")
        built["providers"][0]["candidates"][0]["row"].pop("medianPolishMs")
        self.refused(built, "measured median")

    def test_request_outside_the_setting(self):
        receipt = self.receipt()
        receipt.search_pass()
        built = receipt.build()
        built["physicalRequests"][-1]["sentOpenAIParams"] = ["temperature"]
        self.refused(built, "request match flag contradicts its requests")

    def test_flags_must_stay_the_fallbacks(self):
        receipt = self.receipt()
        receipt.fallback_pass()
        built = receipt.build()
        candidate = built["providers"][0]["candidates"][0]
        candidate["row"]["allowsFileBatch"] = False
        self.refused(built, "chat eligibility or file batching")
        candidate["row"]["allowsFileBatch"] = True
        candidate["resolution"][1]["after"]["supportsChatCompletions"] = False
        self.refused(built, "changes chat eligibility")

    def test_existing_row_cannot_be_added(self):
        receipt = self.receipt()
        receipt.fallback_pass(model="gpt-a")
        self.refused(receipt, "already in the recorded base")

    def test_released_must_be_the_providers_date(self):
        receipt = self.receipt()
        receipt.fallback_pass()
        built = receipt.build()
        built["providers"][0]["candidates"][0]["row"]["released"] = "2026-11-04"
        self.refused(built, "provider's own date")

    def test_failed_candidate_adds_nothing_and_stays_partial(self):
        receipt = self.receipt()
        receipt.fallback_pass()
        receipt.failed_candidate()
        self.inputs(receipt)
        self.assertEqual(self.generate()[0], 0)
        result = self.result()
        self.assertEqual(result["outcome"], "partial")
        self.assertTrue(result["proposal"])
        self.assertEqual([op["id"] for op in result["operations"]], ["gpt-new"])


# MARK: - Hiding and restoration


class OutcomesAndCheck(Case):
    def test_true_nochange_writes_no_list(self):
        self.inputs(self.receipt())
        status, _, output = self.generate()
        self.assertEqual(status, 0)
        self.assertFalse((output / propose.PUBLIC).exists())
        result = self.result()
        self.assertEqual((result["outcome"], result["proposal"], result["proposalStatus"],
                          result["updated"]), ("nochange", False, "none", None))
        self.assertEqual(result["listSHA256"], hashlib.sha256(self.base).hexdigest())

    def test_failure_is_preserved_and_proposes_nothing(self):
        receipt = self.receipt()
        receipt.failed.add("gemini")
        receipt.fallback_pass()
        self.inputs(receipt)
        status, _, output = self.generate()
        self.assertEqual(status, 0)
        self.assertFalse((output / propose.PUBLIC).exists())
        self.assertEqual((self.result()["outcome"], self.result()["proposal"]), ("failure", False))

    def test_identical_inputs_give_identical_bytes(self):
        receipt = self.receipt()
        receipt.fallback_pass()
        self.inputs(receipt)
        self.generate()
        first = ((self.root / "out" / propose.PUBLIC).read_bytes(),
                 (self.root / "result.json").read_bytes())
        self.generate()
        second = ((self.root / "out" / propose.PUBLIC).read_bytes(),
                  (self.root / "result.json").read_bytes())
        self.assertEqual(first, second)
        self.assertEqual((self.root / "out" / propose.PUBLIC).read_bytes(),
                         (self.root / "out" / propose.BUNDLED).read_bytes())
        self.assertEqual(self.result()["listSHA256"], hashlib.sha256(first[0]).hexdigest())
        self.assertEqual(self.result()["receiptSHA256"],
                         hashlib.sha256((self.root / "receipt.json").read_bytes()).hexdigest())

    def test_updated_never_moves_back(self):
        self.base = list_bytes(updated="2026-11-10")
        self.commit = commit_list(self.repo, self.base, "later date")
        receipt = self.receipt()
        receipt.fallback_pass()
        self.inputs(receipt)
        self.generate()
        self.assertEqual(self.generated_list()["updated"], "2026-11-10")

    def proposed(self):
        receipt = self.receipt()
        receipt.fallback_pass()
        self.inputs(receipt)
        self.assertEqual(self.generate()[0], 0)

    def test_check_accepts_the_generated_proposal_read_only(self):
        self.proposed()
        files = [self.root / "out" / propose.PUBLIC, self.root / "out" / propose.BUNDLED,
                 self.root / "result.json"]
        before = [(f.read_bytes(), f.stat().st_mtime_ns) for f in files]
        status, text = self.check()
        self.assertEqual(status, 0, text)
        self.assertEqual(before, [(f.read_bytes(), f.stat().st_mtime_ns) for f in files])

    def tamper(self, change, needle):
        self.proposed()
        document = self.generated_list()
        change(document)
        data = propose.encode_list(document)
        for relative in (propose.PUBLIC, propose.BUNDLED):
            (self.root / "out" / relative).write_bytes(data)
        status, text = self.check()
        self.assertEqual(status, 1, text)
        self.assertIn(needle, text)

    def test_check_refuses_an_existing_request_edit(self):
        self.tamper(lambda d: d["models"][0]["request"].update(temperature="omit"),
                    "row openAI/gpt-a differs")

    def test_check_refuses_a_recommendation_change(self):
        self.tamper(lambda d: d["models"][0].update(recommended=True), "row openAI/gpt-a differs")

    def test_check_refuses_deletion_and_reordering(self):
        self.tamper(lambda d: d["models"].pop(0), "was deleted")
        self.tamper(lambda d: d["models"].reverse(), "reordered")

    def test_check_refuses_an_unsupported_addition(self):
        self.tamper(lambda d: d["models"].append(row("gemini", "gemini-x", {"geminiThinking": "none"})),
                    "does not permit")

    def test_check_refuses_metadata_changes(self):
        self.tamper(lambda d: d.update(updated="2026-12-01"), "list date")

    def test_check_refuses_mismatched_copies_and_results(self):
        self.proposed()
        (self.root / "out" / propose.BUNDLED).write_bytes(list_bytes())
        status, text = self.check()
        self.assertEqual(status, 1)
        self.assertIn("not byte-identical", text)
        self.proposed()
        result = self.result()
        result["outcome"] = "nochange"
        (self.root / "result.json").write_text(json.dumps(result))
        status, text = self.check()
        self.assertEqual(status, 1)
        self.assertIn("result file", text)

    def test_moved_base_with_the_same_list_is_compatible(self):
        self.proposed()
        (self.repo / "README.md").write_text("unrelated")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "unrelated")
        moved = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"],
                               capture_output=True, check=True).stdout.decode().strip()
        self.assertEqual(self.check(target=moved)[0], 0)

    def test_intervening_manual_list_change_is_refused(self):
        self.proposed()
        manual = copy.deepcopy(BASE_MODELS)
        manual[0]["recommended"] = True
        moved = commit_list(self.repo, list_bytes(manual), "manual edit")
        status, text = self.check(target=moved)
        self.assertEqual(status, 1)
        self.assertIn("changed since the run", text)

    def test_checker_refuses_contradictory_evidence_too(self):
        self.proposed()
        receipt = self.receipt()
        receipt.fallback_pass()
        built = receipt.build()
        built["providers"][0]["candidates"][0]["row"]["medianPolishMs"] = 60000
        self.inputs(built)
        status, text = self.check()
        self.assertEqual(status, 1)
        self.assertIn("measured median", text)
        receipt.send("openAI", "gpt-new", "openAI:low/omit", "screening", 0)
        self.inputs(receipt)
        status, text = self.check()
        self.assertEqual(status, 1)
        self.assertIn("phases do not describe", text)

    def test_usage_errors_exit_two(self):
        self.assertEqual(self.cli(["generate"])[0], 2)
        self.assertEqual(self.cli(["nonsense"])[0], 2)


CATEGORIES = (InputsAndTrust, Additions, OutcomesAndCheck)


def run():
    loader = unittest.TestLoader()
    failures = 0
    for category in CATEGORIES:
        suite = loader.loadTestsFromTestCase(category)
        count = suite.countTestCases()
        stream = io.StringIO()
        outcome = unittest.TextTestRunner(stream=stream, verbosity=0).run(suite)
        bad = len(outcome.failures) + len(outcome.errors)
        if count == 0 or outcome.testsRun != count or outcome.skipped:
            bad += 1
        print(f"{category.__name__}: {outcome.testsRun} of {count} ran, {bad} failed")
        if bad:
            print(stream.getvalue(), file=sys.stderr)
        failures += bad
    print("self-test:", "PASS" if failures == 0 else f"FAIL ({failures})")
    return 1 if failures else 0
