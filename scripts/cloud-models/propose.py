#!/usr/bin/env python3
"""The weekly cloud model routine's ONE owner of permitted automated list changes (#4353 PR 5,
D7 Receipt and proposal contract; founder decisions 10-13). Standard library only, offline.

  propose.py generate --base REV --receipt FILE --context FILE --freshness FILE
                      --output-root DIR --result FILE [--repo DIR]
  propose.py check    --base REV --receipt FILE --context FILE --freshness FILE
                      --result FILE --current-root DIR --target-base REV [--repo DIR]
  propose.py --self-test

`generate` and `check` call the same permission engine (`plan`). `check` is read-only: it
recomputes the result from the same evidence and requires the current list files and result
file to be exactly those bytes, so every other change is refused.

Inputs and trust (see README.md):
- `--base` is the recorded base: the commit the routine ran on. It must resolve to a commit
  whose full id equals the receipt's and the context's `sourceSHA`; its list bytes must hash
  to the receipt's recorded list hash. Git or read failures refuse; nothing defaults to empty.
- `--context` is what the AUTHENTICATED caller (the workflow or Stage 2, which obtained the
  receipt from GitHub) states about the run. This script only compares it with the receipt;
  a match here is not GitHub authentication.
- `--freshness` names, per provider, the latest authenticated successful catalog observation
  the caller knows of. A newer one supersedes this receipt's hide and un-hide actions.
- The receipt is data. No field is executed; refusal messages name fields, never values.

Exit 0: generated or checked. Exit 1: refused (one controlled reason on stderr). Exit 2: usage.
"""

import argparse
import copy
import datetime
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
PUBLIC = "website/public/cloud-models.json"
BUNDLED = "Sources/EnviousWispr/Resources/cloud-models.json"
PROVIDERS = ("openAI", "claude", "gemini")
INPUT_IDS = ("realDictations[0]", "realDictations[1]", "realDictations[2]")
RECEIPT_SCHEMA = 1
RESULT_SCHEMA = 1
FRESHNESS_SCHEMA = 1
CONTEXT_SCHEMA = 1
CONTEXT_FIELDS = ("repository", "workflow", "runID", "runAttempt", "event", "ref", "sourceSHA")
OUTCOMES = {"success", "partial", "failure", "nochange"}
PHASES = {"fallback", "screening", "confirmation"}
ERROR_CLASSES = {
    "requestRejected", "notAvailable", "keyRejected", "quotaOrRate", "transient",
    "unusableOutput", "harnessRefused", "other",
}
SEARCH_OUTCOMES = {
    "passed", "requestRejectedSearchExhausted", "noQualifyingSetting", "interrupted",
    "fallbackOutsideMenu",
}
ABSENCE_STATES = {
    "present", "missingForRoutineKey", "hide", "reappeared", "alreadyHiddenPresent",
    "alreadyHiddenMissing",
}
SHA_RE = re.compile(r"[0-9a-f]{64}")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
INSTANT_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
WEEK_RE = re.compile(r"[0-9]{4}-W[0-9]{2}")


def _load_validator():
    spec = importlib.util.spec_from_file_location("validate_list", HERE / "validate-list.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


validate_list = _load_validator()


class Refused(Exception):
    """A controlled refusal. Messages name fields and rules, never receipt or provider text."""


# MARK: - Routine marker (the one parser, shared by hiding and un-hiding)

ROUTINE_REASON_RE = re.compile(r"Not in the provider's model list since ([0-9]{4}-[0-9]{2}-[0-9]{2})")


def routine_reason(day):
    return f"Not in the provider's model list since {day}"


def routine_hidden_day(reason):
    """The UTC day when `reason` is exactly the routine's canonical text with a real date;
    otherwise None (a person's reason, a malformed one, or none)."""
    if not isinstance(reason, str):
        return None
    match = ROUTINE_REASON_RE.fullmatch(reason)
    if not match:
        return None
    try:
        validate_list.calendar_date(match.group(1), "hiddenReason")
    except validate_list.Invalid:
        return None
    return match.group(1)


# MARK: - Strict readers


def keys(obj, path, required, optional=()):
    if not isinstance(obj, dict):
        raise Refused(f"{path} is not an object")
    unknown = sorted(set(obj) - set(required) - set(optional))
    if unknown:
        raise Refused(f"{path} has unknown key {unknown[0]}")
    missing = sorted(set(required) - set(obj))
    if missing:
        raise Refused(f"{path} is missing {missing[0]}")
    return obj


def string(value, path, allowed=None):
    if not isinstance(value, str) or value == "":
        raise Refused(f"{path} is not text")
    if allowed is not None and value not in allowed:
        raise Refused(f"{path} is not an allowed value")
    return value


def integer(value, path, minimum=0, maximum=None):
    if isinstance(value, bool) or not isinstance(value, int):
        raise Refused(f"{path} is not an integer")
    if value < minimum or (maximum is not None and value > maximum):
        raise Refused(f"{path} is out of range")
    return value


def boolean(value, path):
    if not isinstance(value, bool):
        raise Refused(f"{path} is not a boolean")
    return value


def array(value, path):
    if not isinstance(value, list):
        raise Refused(f"{path} is not an array")
    return value


def sha256_hex(value, path):
    if not isinstance(value, str) or not SHA_RE.fullmatch(value):
        raise Refused(f"{path} is not a SHA-256 hex digest")
    return value


def instant(value, path):
    if not isinstance(value, str):
        raise Refused(f"{path} is not an ISO 8601 UTC instant")
    try:
        return datetime.datetime.strptime(value, INSTANT_FORMAT).replace(
            tzinfo=datetime.timezone.utc)
    except ValueError:
        raise Refused(f"{path} is not an ISO 8601 UTC instant")


def day(value, path):
    try:
        return validate_list.calendar_date(value, path)
    except validate_list.Invalid:
        raise Refused(f"{path} is not a list date")


def utc_day(moment):
    return moment.strftime("%Y-%m-%d")


def week_key(text, path):
    """(year, week) of a real ISO week such as `2026-W45`; refuses `2026-W99`."""
    if not isinstance(text, str) or not WEEK_RE.fullmatch(text):
        raise Refused(f"{path} is not an ISO week")
    year, week = int(text[:4]), int(text[6:])
    try:
        datetime.date.fromisocalendar(year, week, 1)
    except ValueError:
        raise Refused(f"{path} is not a real ISO week")
    return (year, week)


def day_week(text):
    year, week, _ = datetime.date.fromisoformat(text).isocalendar()
    return (year, week)


def iso_week(moment):
    year, week, _ = moment.isocalendar()
    return f"{year:04d}-W{week:02d}"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def load_json(data, path):
    try:
        return json.loads(data.decode("utf-8"), parse_constant=_reject_constant)
    except (UnicodeDecodeError, ValueError):
        raise Refused(f"{path} is not JSON")


def _reject_constant(_name):
    raise ValueError("not JSON")


# MARK: - Request labels (a format mapping only; no model rules)


def request_label(provider, request):
    """The routine's setting label for a list request object."""
    if provider == "openAI":
        return f"openAI:{request['openAIEffort']}/{request['temperature']}"
    if provider == "claude":
        return f"claude:{request['claudeShape']}"
    thinking = request["geminiThinking"]
    if thinking == "none":
        return "gemini:none"
    if "level" in thinking:
        return f"gemini:level:{thinking['level']}"
    return f"gemini:budget:{thinking['budget']}"


def openai_params(label):
    """The strippable OpenAI parameters a label's request sends, from the label's own fields."""
    effort, temperature = label[len("openAI:"):].split("/")
    params = []
    if effort != "omit":
        params.append("reasoning_effort")
    if temperature == "include":
        params.append("temperature")
    return sorted(params)


# MARK: - Inputs


def parse_context(data):
    context = keys(load_json(data, "context"), "context", ("schema", "receiptSHA256") + CONTEXT_FIELDS)
    if integer(context["schema"], "context.schema", 1) != CONTEXT_SCHEMA:
        raise Refused("context.schema is not supported")
    for field in CONTEXT_FIELDS:
        string(context[field], f"context.{field}")
    if not COMMIT_RE.fullmatch(context["sourceSHA"]):
        raise Refused("context.sourceSHA is not a full commit id")
    sha256_hex(context["receiptSHA256"], "context.receiptSHA256")
    return context


def parse_freshness(data):
    freshness = keys(load_json(data, "freshness"), "freshness", ("schema", "providers"))
    if integer(freshness["schema"], "freshness.schema", 1) != FRESHNESS_SCHEMA:
        raise Refused("freshness.schema is not supported")
    providers = keys(freshness["providers"], "freshness.providers", PROVIDERS)
    latest = {}
    for provider in PROVIDERS:
        value = providers[provider]
        latest[provider] = None if value is None else instant(value, f"freshness.providers.{provider}")
    return latest


def parse_call_id(value, path):
    ident = keys(value, path, ("attempt", "call"))
    integer(ident["attempt"], f"{path}.attempt", 1)
    call = keys(ident["call"], f"{path}.call", ("input", "model", "phase", "provider", "setting"))
    integer(call["input"], f"{path}.call.input", 0, 2)
    string(call["model"], f"{path}.call.model")
    string(call["phase"], f"{path}.call.phase", PHASES)
    string(call["provider"], f"{path}.call.provider", PROVIDERS)
    setting = keys(call["setting"], f"{path}.call.setting", ("label", "provider"))
    string(setting["label"], f"{path}.call.setting.label")
    if setting["provider"] != call["provider"]:
        raise Refused(f"{path}.call.setting is for another provider")
    return (call["provider"], call["model"], setting["label"], call["phase"], call["input"]), ident["attempt"]


def parse_phase(value, path, phase):
    result = keys(
        value, path, ("setting", "phase", "inputs", "perInputMs", "memoAdapted", "physicalAttempts"),
        ("errorClass", "requestsMatchedSetting"))
    string(result["setting"], f"{path}.setting")
    if result["phase"] != phase:
        raise Refused(f"{path}.phase is not {phase}")
    for index, item in enumerate(array(result["inputs"], f"{path}.inputs")):
        integer(item, f"{path}.inputs[{index}]", 0, 2)
    for index, item in enumerate(array(result["perInputMs"], f"{path}.perInputMs")):
        integer(item, f"{path}.perInputMs[{index}]")
    if len(result["perInputMs"]) > len(result["inputs"]):
        raise Refused(f"{path} has more timings than inputs")
    if "errorClass" in result:
        string(result["errorClass"], f"{path}.errorClass", ERROR_CLASSES)
    boolean(result["memoAdapted"], f"{path}.memoAdapted")
    if phase == "fallback":
        if "requestsMatchedSetting" in result:
            raise Refused(f"{path}.requestsMatchedSetting is set on a fallback phase")
    else:
        boolean(result.get("requestsMatchedSetting"), f"{path}.requestsMatchedSetting")
    integer(result["physicalAttempts"], f"{path}.physicalAttempts")
    completed = "errorClass" not in result and len(result["perInputMs"]) == len(result["inputs"])
    if not completed and "errorClass" not in result:
        raise Refused(f"{path} stopped early without a failure class")
    return result, completed


def parse_receipt(data):
    receipt = keys(load_json(data, "receipt"), "receipt", (
        "schema", "provenance", "observedAt", "list", "inputs", "outcome", "providers", "calls",
        "physicalRequests", "logicalCalls", "physicalExchanges", "unrecordedExchanges", "refusals",
        "history", "publicationReady"))
    if integer(receipt["schema"], "receipt.schema", 1) != RECEIPT_SCHEMA:
        raise Refused("receipt.schema is not supported")
    provenance = keys(receipt["provenance"], "receipt.provenance", (), CONTEXT_FIELDS)
    for field in CONTEXT_FIELDS:
        if field not in provenance:
            raise Refused(f"receipt.provenance.{field} is missing")
        string(provenance[field], f"receipt.provenance.{field}")
    observed = instant(receipt["observedAt"], "receipt.observedAt")
    listed = keys(receipt["list"], "receipt.list", ("updated", "revision", "sha256"))
    day(listed["updated"], "receipt.list.updated")
    string(listed["revision"], "receipt.list.revision")
    sha256_hex(listed["sha256"], "receipt.list.sha256")
    inputs = array(receipt["inputs"], "receipt.inputs")
    if [keys(item, f"receipt.inputs[{index}]", ("id", "sha256")).get("id")
            for index, item in enumerate(inputs)] != list(INPUT_IDS):
        raise Refused("receipt.inputs are not the three fixed dictations")
    for index, item in enumerate(inputs):
        sha256_hex(item["sha256"], f"receipt.inputs[{index}].sha256")
    string(receipt["outcome"], "receipt.outcome", OUTCOMES)
    if boolean(receipt["publicationReady"], "receipt.publicationReady"):
        raise Refused("receipt.publicationReady is set; the instrument never claims readiness")
    for field in ("logicalCalls", "physicalExchanges", "unrecordedExchanges", "refusals"):
        integer(receipt[field], f"receipt.{field}")

    calls = {}
    for index, record in enumerate(array(receipt["calls"], "receipt.calls")):
        path = f"receipt.calls[{index}]"
        keys(record, path, ("id", "outcome"), ("usage",))
        call, attempt = parse_call_id(record["id"], f"{path}.id")
        outcome = record["outcome"]
        if outcome == {"noReply": {}}:
            status = None
        else:
            replied = keys(outcome, f"{path}.outcome", ("replied",))["replied"]
            status = integer(keys(replied, f"{path}.outcome.replied", ("status",))["status"],
                             f"{path}.outcome.replied.status", 0, 999)
        if (call, attempt) in calls:
            raise Refused(f"{path} repeats an exchange")
        calls[(call, attempt)] = status
    physical = {}
    for index, item in enumerate(array(receipt["physicalRequests"], "receipt.physicalRequests")):
        path = f"receipt.physicalRequests[{index}]"
        keys(item, path, ("id", "sentOpenAIParams"))
        call, attempt = parse_call_id(item["id"], f"{path}.id")
        params = array(item["sentOpenAIParams"], f"{path}.sentOpenAIParams")
        for p_index, param in enumerate(params):
            string(param, f"{path}.sentOpenAIParams[{p_index}]", {"temperature", "reasoning_effort"})
        if (call, attempt) in physical:
            raise Refused(f"{path} repeats an exchange")
        physical[(call, attempt)] = sorted(params)
    if receipt["physicalExchanges"] != len(physical):
        raise Refused("receipt.physicalExchanges does not match physicalRequests")
    if len(physical) != len(calls) + receipt["unrecordedExchanges"] or not set(calls) <= set(physical):
        raise Refused("receipt.calls and physicalRequests do not reconcile")
    if receipt["logicalCalls"] < len({call for call, _ in physical}):
        raise Refused("receipt.logicalCalls is below the calls that sent requests")

    history = keys(receipt["history"], "receipt.history", ("version", "latestObservedAt", "entries"))
    if integer(history["version"], "receipt.history.version", 1) != 1:
        raise Refused("receipt.history.version is not supported")
    latest_raw = keys(history["latestObservedAt"], "receipt.history.latestObservedAt", (), PROVIDERS)
    latest = {provider: instant(value, f"receipt.history.latestObservedAt.{provider}")
              for provider, value in latest_raw.items()}
    entries = {}
    for index, entry in enumerate(array(history["entries"], "receipt.history.entries")):
        path = f"receipt.history.entries[{index}]"
        keys(entry, path, ("provider", "id", "firstMissingDay", "weeks"))
        provider = string(entry["provider"], f"{path}.provider", PROVIDERS)
        string(entry["id"], f"{path}.id")
        first = day(entry["firstMissingDay"], f"{path}.firstMissingDay")
        weeks = [week_key(w, f"{path}.weeks[{i}]")
                 for i, w in enumerate(array(entry["weeks"], f"{path}.weeks"))]
        if not weeks or weeks != sorted(set(weeks)):
            raise Refused(f"{path}.weeks are not distinct ascending ISO weeks")
        if day_week(first) != weeks[0]:
            raise Refused(f"{path}.firstMissingDay is not in its first missing week")
        if provider not in latest:
            raise Refused(f"{path} has no latest observation for its provider")
        if weeks[-1] > day_week(utc_day(latest[provider])) or first > utc_day(latest[provider]):
            raise Refused(f"{path} is later than its provider's latest observation")
        if (provider, entry["id"]) in entries:
            raise Refused(f"{path} repeats a provider and id")
        entries[(provider, entry["id"])] = entry

    providers = array(receipt["providers"], "receipt.providers")
    if [item.get("provider") if isinstance(item, dict) else None for item in providers] != list(PROVIDERS):
        raise Refused("receipt.providers are not openAI, claude, gemini in order")
    parsed = {}
    for item in providers:
        provider = item["provider"]
        path = f"receipt.providers.{provider}"
        keys(item, path, ("provider", "catalog", "identityCount", "excludedModels", "excluded",
                          "dispositions", "candidates", "absence", "stale"), ("catalogFailure",))
        complete = string(item["catalog"], f"{path}.catalog", {"complete", "failed"}) == "complete"
        stale = boolean(item["stale"], f"{path}.stale")
        integer(item["identityCount"], f"{path}.identityCount")
        if complete == ("catalogFailure" in item):
            raise Refused(f"{path}.catalogFailure does not match the catalog state")
        if not complete:
            string(item["catalogFailure"], f"{path}.catalogFailure", ERROR_CLASSES)
            if item["candidates"] or item["absence"] or stale:
                raise Refused(f"{path} has evidence from a failed catalog")
        absence = keys(item["absence"], f"{path}.absence", (), item["absence"].keys()
                       if isinstance(item["absence"], dict) else ())
        if stale and absence:
            raise Refused(f"{path} has absence evidence from a stale observation")
        for model_id, evidence in absence.items():
            parse_absence(evidence, f"{path}.absence[{model_id}]")
        candidates = [parse_candidate(c, f"{path}.candidates[{i}]", provider)
                      for i, c in enumerate(array(item["candidates"], f"{path}.candidates"))]
        if len({c["id"] for c in candidates}) != len(candidates):
            raise Refused(f"{path}.candidates repeat an id")
        parsed[provider] = {"complete": complete, "stale": stale, "absence": absence,
                            "candidates": candidates}

    for provider, evidence in parsed.items():
        if not evidence["complete"]:
            continue
        path = f"receipt.providers.{provider}"
        seen = latest.get(provider)
        if seen is None or (seen > observed) != evidence["stale"] or seen < observed:
            raise Refused(f"{path} does not agree with the history's latest observation")
        if evidence["stale"]:
            continue
        pending = {model_id for (p, model_id) in entries if p == provider}
        absent = {model_id for model_id, a in evidence["absence"].items()
                  if a["state"] in ("missingForRoutineKey", "hide")}
        if pending != absent:
            raise Refused(f"{path} absence does not agree with the history entries")
        this_week = day_week(utc_day(observed))
        for model_id in absent:
            entry, absence = entries[(provider, model_id)], evidence["absence"][model_id]
            weeks = [week_key(w, "weeks") for w in entry["weeks"]]
            if weeks[-1] != this_week:
                raise Refused(f"{path}.absence[{model_id}] history does not include this week")
            if absence["state"] == "missingForRoutineKey" and (
                    len(weeks) != 1 or entry["firstMissingDay"] != absence["firstMissingDay"]):
                raise Refused(f"{path}.absence[{model_id}] does not match its history entry")
            if absence["state"] == "hide" and len(weeks) < 2:
                raise Refused(f"{path}.absence[{model_id}] hides without two weekly absences")

    failed = any(not p["complete"] for p in parsed.values()) or receipt["refusals"] > 0
    unfinished = any(c["outcome"] not in ("pass", "passViaSearch")
                     for p in parsed.values() for c in p["candidates"])
    proposes = any("row" in c for p in parsed.values() for c in p["candidates"]) or any(
        e["state"] == "hide" for p in parsed.values() for e in p["absence"].values())
    expected = ("failure" if failed else "partial" if unfinished
                else "success" if proposes else "nochange")
    if receipt["outcome"] != expected:
        raise Refused("receipt.outcome contradicts its own evidence")
    return {"raw": receipt, "observed": observed, "providers": parsed, "calls": calls,
            "physical": physical, "entries": entries}


def parse_absence(evidence, path):
    keys(evidence, path, ("state",), ("firstMissingDay", "weeks", "hiddenReason"))
    state = string(evidence["state"], f"{path}.state", ABSENCE_STATES)
    extras = set(evidence) - {"state"}
    if state == "missingForRoutineKey":
        if extras != {"firstMissingDay", "weeks"}:
            raise Refused(f"{path} is not a complete missing record")
        day(evidence["firstMissingDay"], f"{path}.firstMissingDay")
        if integer(evidence["weeks"], f"{path}.weeks", 1) != 1:
            raise Refused(f"{path}.weeks is not 1 for a row that is not yet hidden")
    elif state == "hide":
        if extras != {"hiddenReason"} or routine_hidden_day(evidence["hiddenReason"]) is None:
            raise Refused(f"{path} does not carry the routine's own hidden reason")
    elif extras:
        raise Refused(f"{path} has fields its state does not carry")


def parse_candidate(value, path, provider):
    candidate = keys(value, path, ("id", "outcome", "passViaAdaptation", "perInputMs"), (
        "setting", "errorClass", "medianMs", "sourceDate", "resolvesTheSame", "row", "fallback",
        "search", "resolution"))
    string(candidate["id"], f"{path}.id")
    outcome = string(candidate["outcome"], f"{path}.outcome",
                     {"pass", "passViaSearch", "fail", "notTried"})
    boolean(candidate["passViaAdaptation"], f"{path}.passViaAdaptation")
    if "errorClass" in candidate:
        string(candidate["errorClass"], f"{path}.errorClass", ERROR_CLASSES)
    if outcome in ("fail", "notTried") and "row" in candidate:
        raise Refused(f"{path} carries a row without a pass")
    if outcome in ("pass", "passViaSearch") and "row" not in candidate:
        raise Refused(f"{path} passed without a row")
    return candidate


# MARK: - Evidence for one addition


def last_reply(receipt, call):
    """The status of the last recorded exchange of a logical call, or None."""
    attempts = sorted(a for (c, a) in receipt["calls"] if c == call)
    return receipt["calls"][(call, attempts[-1])] if attempts else None


# The classes after which the Swift search tries the next alternative (`searchContinues`).
CONTINUE_CLASSES = {"requestRejected", "unusableOutput"}


def middle(values):
    """The Swift median (`LiveSweepSupport.medianMs`): the middle of the sorted values."""
    return sorted(values)[len(values) // 2] if values else None


def phase_keys(receipt, provider, model):
    """Every (setting, phase) this model sent requests for."""
    return {(c[2], c[3]) for (c, _) in receipt["physical"] if c[:2] == (provider, model)}


def verify_phase(receipt, provider, model, phase, completed):
    """Bind one phase record to the exchanges the ledger recorded for it: which inputs sent
    requests, how each ended, how many physical requests there were and what they carried."""
    label, name = phase["setting"], phase["phase"]
    where = f"{provider}/{model} {name} {label}"
    done = len(phase["perInputMs"])
    tried = phase["inputs"] if completed else phase["inputs"][:done + 1]
    error = phase.get("errorClass")
    recorded = sorted({c[4] for (c, _) in receipt["physical"]
                       if c[:4] == (provider, model, label, name)})
    # A returned-but-unusable output already contributed its timing (Swift times a reply
    # before judging it, CloudModelRoutineSearch.swift `runPhase`); a connector-thrown
    # unusable output did not.
    if not completed and error == "unusableOutput" and done > 0 \
            and recorded == sorted(phase["inputs"][:done]):
        tried = phase["inputs"][:done]
    allowed = [sorted(tried)]
    if error == "harnessRefused":
        # A refusal can stop an input before its first request is sent.
        allowed.append(sorted(tried[:-1]))
    if recorded not in allowed:
        raise Refused(f"{where} exchanges do not match the inputs it tried")
    for index in tried[:done]:
        status = last_reply(receipt, (provider, model, label, name, index))
        if status is None or not 200 <= status <= 299:
            raise Refused(f"{where} input {index} has no successful reply")
    if not completed and error in CONTINUE_CLASSES:
        status = last_reply(receipt, (provider, model, label, name, tried[-1]))
        if status is None:
            raise Refused(f"{where} failure has no reply")
        if (error == "unusableOutput") != (200 <= status <= 299):
            raise Refused(f"{where} failure class does not match its reply")
    sent = [params for (c, _), params in receipt["physical"].items()
            if c[:4] == (provider, model, label, name)]
    if len(sent) != phase["physicalAttempts"]:
        raise Refused(f"{where} physical attempts do not reconcile")
    if provider == "openAI":
        mismatched = any(p != openai_params(label) for p in sent)
        if phase["memoAdapted"] and not mismatched:
            raise Refused(f"{where} claims a parameter strip its requests do not show")
        if name == "fallback":
            if mismatched and not phase["memoAdapted"]:
                raise Refused(f"{where} sent a request outside its setting")
        elif phase["requestsMatchedSetting"] == mismatched:
            raise Refused(f"{where} request match flag contradicts its requests")
    elif phase["memoAdapted"] or (name != "fallback" and phase["requestsMatchedSetting"] is not True):
        raise Refused(f"{where} reports an adaptation this provider cannot make")


def proves(phase, completed):
    return completed and not phase["memoAdapted"] and phase.get("requestsMatchedSetting") is True


def check_median(where, row, timings):
    expected = middle(timings)
    in_range = expected is not None and \
        validate_list.MEDIAN_POLISH_MS[0] <= expected <= validate_list.MEDIAN_POLISH_MS[1]
    if row.get("medianPolishMs") != (expected if in_range else None):
        raise Refused(f"{where} median is not its measured median")


def addition_row(provider, candidate, receipt, base_ids):
    model = candidate["id"]
    where = f"{provider}/{model}"
    if (provider, model) in base_ids:
        raise Refused(f"{where} is already in the recorded base list")
    row = candidate["row"]
    try:
        validate_list.validate_row(row, where)
    except validate_list.Invalid as error:
        raise Refused(f"{where} row is invalid: {error}")
    if row["provider"] != provider or row["id"] != model:
        raise Refused(f"{where} row names another model")
    if row["recommended"] or row["hidden"] or "hiddenReason" in row or "displayName" in row:
        raise Refused(f"{where} row is not a plain new row")
    if "released" in row:
        if "sourceDate" not in candidate or \
                utc_day(instant(candidate["sourceDate"], f"{where}.sourceDate")) != row["released"]:
            raise Refused(f"{where} released day is not the provider's own date")
    if candidate.get("resolvesTheSame") is not True:
        raise Refused(f"{where} has no resolution check")
    fallback_label = string(candidate.get("setting"), f"{where}.setting")
    if "fallback" not in candidate:
        raise Refused(f"{where} has no fallback phase")
    fallback, fallback_done = parse_phase(candidate["fallback"], f"{where}.fallback", "fallback")
    if fallback["setting"] != fallback_label or fallback["inputs"] != [0, 1, 2]:
        raise Refused(f"{where} fallback phase is not the three fixed dictations")

    resolution = array(candidate.get("resolution"), f"{where}.resolution")
    if len(resolution) != 3:
        raise Refused(f"{where}.resolution does not cover the id and its dated spellings")
    spellings = []
    for index, item in enumerate(resolution):
        path = f"{where}.resolution[{index}]"
        keys(item, path, ("id", "before", "after"))
        spellings.append(string(item["id"], f"{path}.id"))
        for side in ("before", "after"):
            keys(item[side], f"{path}.{side}", ("supportsChatCompletions", "allowsFileBatch"),
                 ("setting",))
            boolean(item[side]["supportsChatCompletions"], f"{path}.{side}.supportsChatCompletions")
            boolean(item[side]["allowsFileBatch"], f"{path}.{side}.allowsFileBatch")
        if item["before"]["supportsChatCompletions"] != item["after"]["supportsChatCompletions"] \
                or item["before"]["allowsFileBatch"] != item["after"]["allowsFileBatch"]:
            raise Refused(f"{path} changes chat eligibility or file batching")
    if spellings[0] != model or len(set(spellings)) != 3 or \
            not all(s.startswith(model + "-") for s in spellings[1:]):
        raise Refused(f"{where}.resolution does not cover the id and its dated spellings")
    base = resolution[0]["before"]
    if row["supportsChatCompletions"] != base["supportsChatCompletions"] or \
            row["allowsFileBatch"] != base["allowsFileBatch"]:
        raise Refused(f"{where} row changes the fallback's chat eligibility or file batching")
    if base.get("setting") != fallback_label:
        raise Refused(f"{where} fallback setting is not what the captured list resolves")
    label = request_label(provider, row["request"])

    if candidate["outcome"] == "pass":
        if "errorClass" in candidate or "search" in candidate or not fallback_done:
            raise Refused(f"{where} pass without three fallback successes")
        if candidate["perInputMs"] != fallback["perInputMs"] or \
                candidate["passViaAdaptation"] != fallback["memoAdapted"]:
            raise Refused(f"{where} summary disagrees with its fallback phase")
        if label != fallback_label or any(
                r["before"].get("setting") != fallback_label or r["after"].get("setting") != fallback_label
                for r in resolution):
            raise Refused(f"{where} fallback row does not resolve the unchanged fallback")
        verify_phase(receipt, provider, model, fallback, fallback_done)
        if phase_keys(receipt, provider, model) != {(fallback_label, "fallback")}:
            raise Refused(f"{where} sent requests its phases do not describe")
        check_median(where, row, fallback["perInputMs"])
        return row, {"op": "add", "provider": provider, "id": model, "setting": label,
                     "via": "fallbackAdapted" if fallback["memoAdapted"] else "fallback"}

    # passViaSearch
    if candidate.get("errorClass") != "requestRejected" or fallback.get("errorClass") != "requestRejected" \
            or fallback_done or candidate["perInputMs"] != fallback["perInputMs"]:
        raise Refused(f"{where} search without a rejected fallback")
    verify_phase(receipt, provider, model, fallback, fallback_done)
    described = {(fallback_label, "fallback")}
    search = keys(candidate.get("search"), f"{where}.search", (
        "trigger", "fallbackSetting", "alternatives", "attempts", "outcome"),
        ("interruption", "chosenSetting", "issueIntent"))
    if search["trigger"] != "requestRejected" or search["fallbackSetting"] != fallback_label or \
            search["outcome"] != "passed" or "interruption" in search or "issueIntent" in search:
        raise Refused(f"{where} search did not pass")
    alternatives = array(search["alternatives"], f"{where}.search.alternatives")
    if not alternatives or len(set(alternatives)) != len(alternatives) or fallback_label in alternatives \
            or not all(isinstance(a, str) and a.startswith(provider + ":") for a in alternatives):
        raise Refused(f"{where} search alternatives are not a valid menu")
    attempts = array(search["attempts"], f"{where}.search.attempts")
    if not attempts or [a.get("setting") if isinstance(a, dict) else None for a in attempts] \
            != alternatives[:len(attempts)]:
        raise Refused(f"{where} search did not follow its menu order")
    chosen = string(search.get("chosenSetting"), f"{where}.search.chosenSetting")
    for index, attempt in enumerate(attempts):
        path = f"{where}.search.attempts[{index}]"
        keys(attempt, path, ("setting", "request", "screening", "qualified"), ("confirmation",))
        try:
            validate_list.validate_request(attempt["request"], provider, f"{path}.request")
        except validate_list.Invalid:
            raise Refused(f"{path}.request is invalid")
        if request_label(provider, attempt["request"]) != attempt["setting"]:
            raise Refused(f"{path}.request is not its setting")
        last = index == len(attempts) - 1
        if boolean(attempt["qualified"], f"{path}.qualified") != last:
            raise Refused(f"{where} search qualified a setting that is not the last tried")
        described.add((attempt["setting"], "screening"))
        if "confirmation" in attempt:
            described.add((attempt["setting"], "confirmation"))
        if last:
            continue
        # An earlier attempt must have failed in a way the search continues after.
        screening, screened = parse_phase(attempt["screening"], f"{path}.screening", "screening")
        if screening["setting"] != attempt["setting"] or screening["inputs"] != [0]:
            raise Refused(f"{path}.screening is not one screening of its setting")
        verify_phase(receipt, provider, model, screening, screened)
        ended = screening
        if proves(screening, screened):
            if "confirmation" not in attempt:
                raise Refused(f"{path} passed screening but was not confirmed")
            confirmation, confirmed = parse_phase(
                attempt["confirmation"], f"{path}.confirmation", "confirmation")
            if confirmation["setting"] != attempt["setting"] or confirmation["inputs"] != [0, 1, 2]:
                raise Refused(f"{path}.confirmation is not three confirmations of its setting")
            verify_phase(receipt, provider, model, confirmation, confirmed)
            if proves(confirmation, confirmed):
                raise Refused(f"{where} search continued after a setting that qualified")
            ended, screened = confirmation, confirmed
        elif "confirmation" in attempt:
            raise Refused(f"{path} was confirmed without passing screening")
        if not screened and ended.get("errorClass") not in CONTINUE_CLASSES:
            raise Refused(f"{where} search continued after a failure that stops it")
    winner = attempts[-1]
    if winner["setting"] != chosen or label != chosen:
        raise Refused(f"{where} row is not the chosen setting")
    screening, screened = parse_phase(winner["screening"], f"{where}.screening", "screening")
    if "confirmation" not in winner:
        raise Refused(f"{where} chosen setting has no confirmation")
    confirmation, confirmed = parse_phase(winner["confirmation"], f"{where}.confirmation", "confirmation")
    for phase, done, inputs in ((screening, screened, [0]), (confirmation, confirmed, [0, 1, 2])):
        if not done or phase["inputs"] != inputs or phase["setting"] != chosen or \
                phase["memoAdapted"] or phase["requestsMatchedSetting"] is not True:
            raise Refused(f"{where} chosen setting did not prove itself without adaptation")
    verify_phase(receipt, provider, model, screening, screened)
    verify_phase(receipt, provider, model, confirmation, confirmed)
    if phase_keys(receipt, provider, model) != described:
        raise Refused(f"{where} sent requests its phases do not describe")
    check_median(where, row, confirmation["perInputMs"])
    if any(r["after"].get("setting") != chosen for r in resolution):
        raise Refused(f"{where} proposed list does not resolve the chosen setting")
    return row, {"op": "add", "provider": provider, "id": model, "setting": chosen, "via": "search"}


ROW_ORDER = ("provider", "id", "released", "recommended", "hidden", "hiddenReason", "displayName",
             "request", "supportsChatCompletions", "allowsFileBatch", "medianPolishMs")


def canonical_row(row):
    return {key: row[key] for key in ROW_ORDER if key in row}


# MARK: - The permission engine


def encode_list(document):
    return (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def plan(base_bytes, receipt, context, freshness, receipt_sha):
    """Everything this evidence permits against the recorded base. Pure: no reads, no writes.
    Returns (list bytes, result object)."""
    raw = receipt["raw"]
    provenance = raw["provenance"]
    for field in CONTEXT_FIELDS:
        if provenance[field] != context[field]:
            raise Refused(f"receipt.provenance.{field} does not match the caller's context")
    if context["receiptSHA256"] != receipt_sha:
        raise Refused("receipt bytes do not match the caller's receipt hash")
    if sha256(base_bytes) != raw["list"]["sha256"]:
        raise Refused("the recorded base list is not the list the run measured")
    try:
        validate_list.validate_bytes(base_bytes)
    except validate_list.Invalid as error:
        raise Refused(f"the recorded base list is invalid: {error}")
    base = json.loads(base_bytes.decode("utf-8"))
    if encode_list(base) != base_bytes:
        raise Refused("the recorded base list is not in the canonical two-space form")
    if base["updated"] != raw["list"]["updated"]:
        raise Refused("the recorded base list date does not match the receipt")

    observed = receipt["observed"]
    rows = {(r["provider"], r["id"]): index for index, r in enumerate(base["models"])}
    operations, notes, additions = [], [], []
    instrument = raw["outcome"]

    for provider in PROVIDERS:
        evidence = receipt["providers"][provider]
        latest = freshness[provider]
        current = evidence["complete"] and not evidence["stale"]
        if current and (latest is None or latest < observed):
            raise Refused(f"freshness for {provider} is older than this receipt's own observation")
        if current:
            listed = {model_id for (p, model_id) in rows if p == provider}
            if set(evidence["absence"]) != listed:
                raise Refused(f"receipt.providers.{provider}.absence does not cover the base rows")
        superseded = current and latest > observed
        for model_id, absence in sorted(evidence["absence"].items()):
            index = rows[(provider, model_id)]
            row = base["models"][index]
            state = absence["state"]
            if state in ("missingForRoutineKey", "hide", "reappeared", "present") and row["hidden"]:
                raise Refused(f"{provider}/{model_id} absence state contradicts the base row")
            if state == "missingForRoutineKey":
                notes.append({"note": "missingForRoutineKey", "provider": provider, "id": model_id,
                              "firstMissingDay": absence["firstMissingDay"]})
            elif state in ("hide", "alreadyHiddenPresent") and superseded:
                notes.append({"note": "supersededByNewerObservation", "provider": provider,
                              "id": model_id, "state": state})
            elif state == "hide":
                entry = receipt["entries"].get((provider, model_id))
                marker_day = routine_hidden_day(absence["hiddenReason"])
                if entry is None or len(entry["weeks"]) < 2 or iso_week(observed) not in entry["weeks"] \
                        or entry["firstMissingDay"] != marker_day:
                    raise Refused(f"{provider}/{model_id} hide lacks two weekly absences")
                operations.append(("hide", index, absence["hiddenReason"]))
            elif state == "alreadyHiddenPresent":
                if not row["hidden"]:
                    raise Refused(f"{provider}/{model_id} hidden-present evidence for a visible row")
                if routine_hidden_day(row.get("hiddenReason")) is None:
                    notes.append({"note": "personHiddenPresent", "provider": provider, "id": model_id})
                else:
                    operations.append(("restore", index, None))
            elif state == "alreadyHiddenMissing" and not row["hidden"]:
                raise Refused(f"{provider}/{model_id} absence state contradicts the base row")
        for candidate in evidence["candidates"]:
            if candidate["outcome"] in ("pass", "passViaSearch"):
                additions.append(addition_row(provider, candidate, receipt, rows))

    if instrument == "failure":
        result_ops, document = [], base
    else:
        document = copy.deepcopy(base)
        result_ops = []
        for kind, index, reason in operations:
            row = document["models"][index]
            summary = {"op": kind, "provider": row["provider"], "id": row["id"]}
            if kind == "hide":
                rebuilt = {}
                for key, value in row.items():
                    # Any earlier reason is replaced, so the routine owns this hide.
                    if key == "hiddenReason":
                        continue
                    rebuilt[key] = True if key == "hidden" else value
                    if key == "hidden":
                        rebuilt["hiddenReason"] = reason
                document["models"][index] = rebuilt
            else:
                row["hidden"] = False
                del row["hiddenReason"]
            result_ops.append(summary)
        for row, summary in additions:
            document["models"].append(canonical_row(row))
            result_ops.append(summary)
        if result_ops:
            document["updated"] = max(base["updated"], utc_day(observed))

    output = encode_list(document) if result_ops else base_bytes
    try:
        validate_list.validate_bytes(output)
    except validate_list.Invalid as error:
        raise Refused(f"the proposed list is invalid: {error}")
    final = instrument if instrument in ("failure", "partial") else (
        "success" if result_ops else "nochange")
    result = {
        "schema": RESULT_SCHEMA,
        "receiptSHA256": receipt_sha,
        "context": {field: context[field] for field in CONTEXT_FIELDS},
        "recordedBase": {"commit": context["sourceSHA"], "listSHA256": sha256(base_bytes)},
        "instrumentOutcome": instrument,
        "outcome": final,
        "proposal": bool(result_ops),
        # A proposal is only ever proposed here; merge and publication are recorded later.
        "proposalStatus": "proposed" if result_ops else "none",
        "updated": document["updated"] if result_ops else None,
        "listSHA256": sha256(output),
        "operations": result_ops,
        "observations": notes,
    }
    return output, result


def encode_result(result):
    return (json.dumps(result, indent=2, sort_keys=True) + "\n").encode("utf-8")


# MARK: - Git and files


def git_commit(repo, revision):
    done = subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "--quiet",
                           f"{revision}^{{commit}}"], capture_output=True)
    commit = done.stdout.decode().strip()
    if done.returncode != 0 or not COMMIT_RE.fullmatch(commit):
        raise Refused(f"revision {revision!r} is not a commit in this repository")
    return commit


def git_file(repo, commit, path):
    done = subprocess.run(["git", "-C", str(repo), "show", f"{commit}:{path}"], capture_output=True)
    if done.returncode != 0:
        raise Refused(f"{path} cannot be read at {commit[:12]}")
    return done.stdout


def read_file(path, label):
    try:
        return Path(path).read_bytes()
    except OSError:
        raise Refused(f"{label} cannot be read")


def list_pair(repo, commit):
    public, bundled = git_file(repo, commit, PUBLIC), git_file(repo, commit, BUNDLED)
    if public != bundled:
        raise Refused(f"the two list copies differ at {commit[:12]}")
    return public


def evaluate(args):
    receipt_bytes = read_file(args.receipt, "receipt")
    context = parse_context(read_file(args.context, "context"))
    freshness = parse_freshness(read_file(args.freshness, "freshness"))
    receipt = parse_receipt(receipt_bytes)
    commit = git_commit(args.repo, args.base)
    if commit != context["sourceSHA"]:
        raise Refused("--base is not the commit the run measured")
    base_bytes = list_pair(args.repo, commit)
    return plan(base_bytes, receipt, context, freshness, sha256(receipt_bytes))


def write_atomically(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    staging = path.with_name(f".{path.name}.staging")
    staging.write_bytes(data)
    os.replace(staging, path)
    if path.read_bytes() != data:
        raise Refused(f"{path.name} did not read back as written")


def generate(args):
    output, result = evaluate(args)
    if result["proposal"]:
        root = Path(args.output_root)
        for relative in (PUBLIC, BUNDLED):
            write_atomically(root / relative, output)
    # The result is written last: it exists only once both list copies are in place.
    write_atomically(Path(args.result), encode_result(result))
    print(f"{result['outcome']}: {len(result['operations'])} change(s); proposal "
          f"{'written' if result['proposal'] else 'none'}")
    return 0


def describe(expected, current):
    """The first unpermitted difference between the expected and current lists, in words."""
    try:
        expected_doc, current_doc = json.loads(expected), json.loads(current)
    except ValueError:
        return "the current list is not JSON"
    if not isinstance(current_doc, dict) or not isinstance(current_doc.get("models"), list):
        return "the current list is not a list document"
    want = [(r.get("provider"), r.get("id")) for r in expected_doc["models"]]
    have = [(r.get("provider"), r.get("id")) for r in current_doc["models"] if isinstance(r, dict)]
    if set(want) - set(have):
        return "a row the evidence keeps was deleted"
    if set(have) - set(want):
        return "a row was added that the evidence does not permit"
    if want != have:
        return "rows were reordered"
    for row_want, row_have in zip(expected_doc["models"], current_doc["models"]):
        if row_want != row_have:
            return f"row {row_want['provider']}/{row_want['id']} differs from what the evidence permits"
    if expected_doc.get("updated") != current_doc.get("updated"):
        return "the list date differs from the proposal's"
    return "the list bytes differ from the proposal's canonical form"


def check(args):
    output, result = evaluate(args)
    target = git_commit(args.repo, args.target_base)
    if list_pair(args.repo, target) != list_pair(args.repo, git_commit(args.repo, args.base)):
        raise Refused("the list on the target base changed since the run; run the routine again "
                      "or reconcile by hand")
    root = Path(args.current_root)
    public = read_file(root / PUBLIC, "the current public list")
    bundled = read_file(root / BUNDLED, "the current bundled list")
    if public != bundled:
        raise Refused("the current public and bundled lists are not byte-identical")
    if public != output:
        raise Refused(f"current list refused: {describe(output, public)}")
    if read_file(args.result, "the result") != encode_result(result):
        raise Refused("the result file is not what this evidence produces")
    print(f"ok: {result['outcome']}; {len(result['operations'])} permitted change(s)")
    return 0


def main(argv):
    if argv == ["--self-test"]:
        sys.path.insert(0, str(HERE))
        import propose_test
        return propose_test.run()
    parser = argparse.ArgumentParser(prog="propose.py")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("generate", "check"):
        command = commands.add_parser(name)
        command.add_argument("--repo", default=str(REPO_ROOT))
        for flag in ("--base", "--receipt", "--context", "--freshness", "--result"):
            command.add_argument(flag, required=True)
        if name == "generate":
            command.add_argument("--output-root", required=True)
        else:
            command.add_argument("--current-root", required=True)
            command.add_argument("--target-base", required=True)
    try:
        args = parser.parse_args(argv)
    except SystemExit as exit_:
        return 2 if exit_.code else 0
    try:
        return generate(args) if args.command == "generate" else check(args)
    except Refused as error:
        print(f"refused: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
