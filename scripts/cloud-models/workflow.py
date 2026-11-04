#!/usr/bin/env python3
"""Stage 1 orchestration for the weekly cloud model routine (#4353 PR 5, D7: Runner, Secret
scoping, PR authentication, Stage 1 execution, Failure handling; founder decisions 12 and 14).
Standard library only.

  workflow.py authorize                     the run may use provider keys (event, repo, ref, SHA)
  workflow.py finish-sweep --log L --receipt R --out DIR
                                            in the sweep step: prove the named test ran, scan
                                            for the injected keys, stage the evidence files
  workflow.py publish --evidence DIR --checkout DIR
                                            publication job: re-derive and publish one PR
  workflow.py check-pr --event FILE --trusted DIR --pr DIR --work DIR
                                            PR check: a routine App PR must be exactly what its
                                            authenticated run's evidence permits
  workflow.py report-failure                failure job: one deduplicated, sanitized report
  workflow.py --self-test

`propose.py` stays the only owner of permitted list changes; this file never decides what a
row may be. Every GitHub call goes through `GitHub` (tests inject a fake). Output is built
from allowlisted facts and closed stage names, never from logs, provider text or errors.
"""

import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
PROPOSE = HERE / "propose.py"
VALIDATE = HERE / "validate-list.py"
PUBLIC = "website/public/cloud-models.json"
BUNDLED = "Sources/EnviousWispr/Resources/cloud-models.json"

REPOSITORY = "saurabhav88/EnviousWispr"
WORKFLOW_PATH = ".github/workflows/cloud-models-sweep.yml"
MAIN_REF = "refs/heads/main"
EVENTS = {"schedule", "workflow_dispatch"}
SWEEP_JOB = "sweep"
SWEEP_TEST_NAME = "weeklySweep()"
ARTIFACT_PREFIX = "cloud-model-routine-evidence"
BRANCH_PREFIX = "cloud-model-routine/run-"
BRANCH_RE = re.compile(r"cloud-model-routine/run-([1-9][0-9]{0,19})-([1-9][0-9]{0,3})")
KEY_VARIABLES = ("TEST_RUNNER_EW_ROUTINE_OPENAI_KEY", "TEST_RUNNER_EW_ROUTINE_CLAUDE_KEY",
                 "TEST_RUNNER_EW_ROUTINE_GEMINI_KEY")
CONTEXT_FIELDS = ("repository", "workflow", "runID", "runAttempt", "event", "ref", "sourceSHA")
# Every file that may pass between jobs, with its size limit. Nothing else is accepted.
EVIDENCE_LIMITS = {
    "receipt.json": 4_000_000, "context.json": 16_384, "result.json": 262_144,
    "cloud-models.json": 262_144, "pr-body.md": 65_536, "manifest.json": 16_384,
}
REQUIRED_EVIDENCE = {"receipt.json", "context.json", "result.json", "pr-body.md", "manifest.json"}
# Closed failure stages: `sweep` covers the test run and the in-step scan and staging.
FAILURE_STAGES = ("authorize", "sweep", "receipt", "publication", "outcome", "cancelled")
FAILURE_ISSUE = "Cloud model routine: run failed"
CALL_RECIPE_ISSUE = "Cloud model routine: call recipe"
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
MAX_ZIP_BYTES = 8_000_000


class Refused(Exception):
    """A controlled refusal; the message names a rule, never a secret or provider text."""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def artifact_name(run_id, attempt):
    return f"{ARTIFACT_PREFIX}-{run_id}-{attempt}"


def branch_name(run_id, attempt):
    return f"{BRANCH_PREFIX}{run_id}-{attempt}"


# MARK: - Who may run with provider keys


def authorize(env):
    """The facts of a run that may use provider keys, or Refused."""
    facts = {
        "repository": env.get("GITHUB_REPOSITORY", ""), "workflow": env.get("GITHUB_WORKFLOW", ""),
        "runID": env.get("GITHUB_RUN_ID", ""), "runAttempt": env.get("GITHUB_RUN_ATTEMPT", ""),
        "event": env.get("GITHUB_EVENT_NAME", ""), "ref": env.get("GITHUB_REF", ""),
        "sourceSHA": env.get("GITHUB_SHA", ""),
    }
    if facts["repository"] != REPOSITORY:
        raise Refused("this repository may not run the routine")
    if facts["event"] not in EVENTS:
        raise Refused("only a schedule or manual run may use the routine keys")
    if facts["ref"] != MAIN_REF:
        raise Refused("only main may use the routine keys")
    if not COMMIT_RE.fullmatch(facts["sourceSHA"]):
        raise Refused("the source commit is not a full commit id")
    if not facts["runID"].isdigit() or not facts["runAttempt"].isdigit() or not facts["workflow"]:
        raise Refused("the run identity is incomplete")
    if env.get("GITHUB_WORKFLOW_REF", "").split("@")[0] != f"{REPOSITORY}/{WORKFLOW_PATH}":
        raise Refused("only the routine workflow file may use the routine keys")
    return facts


# MARK: - Sweep step: prove the run, scan, stage


SWIFT_PASS_RE = re.compile(r"Test " + re.escape(SWEEP_TEST_NAME) + r" passed after")
EXECUTED_RE = re.compile(r"==> [A-Za-z]+ lane executed ([0-9]+) tests?")


def verify_sweep_log(text):
    """The named sweep test executed and passed in a lane whose verdict is PASS."""
    executed = [int(n) for n in EXECUTED_RE.findall(text)]
    if not executed or min(executed) < 1:
        raise Refused("the sweep test did not execute")
    if not SWIFT_PASS_RE.search(text):
        raise Refused("the named sweep test did not pass")
    if "verdict: PASS" not in text or re.search(r"verdict: (FAIL|SKIP)", text):
        raise Refused("the sweep lane verdict is not PASS")
    if re.search(r"Test " + re.escape(SWEEP_TEST_NAME) + r" skipped", text):
        raise Refused("the named sweep test was skipped")


def secrets_from(env):
    values = [env.get(name, "") for name in KEY_VARIABLES]
    if any(not value for value in values):
        raise Refused("a routine key is missing at the scan")
    return values


def scan(named_bytes, secrets):
    for name, data in named_bytes.items():
        text = data.decode("utf-8", errors="replace")
        if any(secret in text for secret in secrets):
            raise Refused(f"{name} contains a routine key")


def context_for(facts, receipt_bytes):
    return dict({"schema": 1, "receiptSHA256": sha256(receipt_bytes)},
                **{field: facts[field] for field in CONTEXT_FIELDS})


def run_propose(args):
    done = subprocess.run([sys.executable, "-I", str(PROPOSE), *args], capture_output=True)
    if done.returncode != 0:
        # propose.py prints one controlled line naming a rule; pass it on.
        reason = done.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or ["refused"]
        raise Refused(f"proposal refused: {reason[0][:200]}")


def generate(repo, base, receipt_path, context_path, work):
    """Run the one permission engine; return (result object, list bytes or None)."""
    output = work / "proposal"
    result_path = work / "result.json"
    run_propose(["generate", "--repo", str(repo), "--base", base, "--receipt", str(receipt_path),
                 "--context", str(context_path), "--output-root", str(output),
                 "--result", str(result_path)])
    result = json.loads(result_path.read_bytes())
    listed = (output / PUBLIC).read_bytes() if result["proposal"] else None
    return result, result_path.read_bytes(), listed


def pr_body(result, facts):
    lines = [
        f"Weekly cloud model routine, run {facts['runID']} attempt {facts['runAttempt']}.",
        "",
        "New models that passed three real dictations through the shipped connectors:",
        "",
    ]
    for op in result["operations"]:
        lines.append(f"- `{op['provider']}/{op['id']}`: `{op['setting']}` ({op['via']})")
    lines += [
        "",
        f"Outcome: {result['outcome']}. Source commit: `{facts['sourceSHA']}`.",
        f"Receipt SHA-256: `{result['receiptSHA256']}`. List SHA-256: `{result['listSHA256']}`.",
        f"Run: https://github.com/{facts['repository']}/actions/runs/{facts['runID']}",
        "",
        "The PR check verifies this against the run's own evidence; the text above is not trusted.",
        "",
        f"<!-- cloud-model-routine run={facts['runID']} attempt={facts['runAttempt']} -->",
    ]
    return ("\n".join(lines) + "\n").encode("utf-8")


def finish_sweep(env, log_text, receipt_path, out, repo=REPO_ROOT):
    facts = authorize(env)
    verify_sweep_log(log_text)
    try:
        receipt_bytes = Path(receipt_path).read_bytes()
    except OSError:
        raise Refused("the sweep wrote no receipt")
    if not receipt_bytes or len(receipt_bytes) > EVIDENCE_LIMITS["receipt.json"]:
        raise Refused("the receipt is empty or too large")
    secrets = secrets_from(env)
    scan({"receipt.json": receipt_bytes}, secrets)
    out = Path(out)
    out.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="routine-stage-") as scratch:
        work = Path(scratch)
        (work / "receipt.json").write_bytes(receipt_bytes)
        context = (json.dumps(context_for(facts, receipt_bytes), indent=2, sort_keys=True) + "\n").encode()
        (work / "context.json").write_bytes(context)
        result, result_bytes, listed = generate(repo, facts["sourceSHA"], work / "receipt.json",
                                                work / "context.json", work)
        files = {"receipt.json": receipt_bytes, "context.json": context, "result.json": result_bytes,
                 "pr-body.md": pr_body(result, facts)}
        if listed is not None:
            files["cloud-models.json"] = listed
        scan(files, secrets)
    write_evidence(out, files)
    return result


def write_evidence(out, files):
    manifest = {"schema": 1, "files": {name: sha256(data) for name, data in sorted(files.items())}}
    for name, data in files.items():
        (out / name).write_bytes(data)
    (out / "manifest.json").write_bytes((json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode())


# MARK: - Evidence between jobs


def read_evidence(folder):
    """Exactly the allowlisted files, each within its limit and matching the manifest."""
    folder = Path(folder)
    found = {}
    for entry in folder.iterdir():
        if entry.is_symlink() or not entry.is_file() or entry.name not in EVIDENCE_LIMITS:
            raise Refused("the evidence holds an unexpected entry")
        data = entry.read_bytes()
        if len(data) > EVIDENCE_LIMITS[entry.name]:
            raise Refused(f"evidence file {entry.name} is too large")
        found[entry.name] = data
    if not REQUIRED_EVIDENCE <= set(found):
        raise Refused("the evidence is missing a required file")
    try:
        manifest = json.loads(found["manifest.json"])
        listed = manifest["files"]
    except (ValueError, KeyError, TypeError):
        raise Refused("the evidence manifest is unreadable")
    if not isinstance(listed, dict) or set(listed) != set(found) - {"manifest.json"} or \
            any(sha256(found[name]) != digest for name, digest in listed.items()):
        raise Refused("the evidence does not match its manifest")
    try:
        result = json.loads(found["result.json"])
        proposal = result["proposal"]
    except (ValueError, KeyError, TypeError):
        raise Refused("the evidence result is unreadable")
    if not isinstance(proposal, bool):
        raise Refused("the evidence result is unreadable")
    if proposal != ("cloud-models.json" in found):
        raise Refused("the evidence list file does not match the result")
    return found


def extract_zip(data, folder):
    """A downloaded artifact, unpacked only if every entry is an allowlisted flat file."""
    if len(data) > MAX_ZIP_BYTES:
        raise Refused("the evidence archive is too large")
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=False)
    try:
        archive = zipfile.ZipFile(io_bytes(data))
    except zipfile.BadZipFile:
        raise Refused("the evidence archive is not a zip file")
    with archive:
        entries = archive.infolist()
        if len(entries) > len(EVIDENCE_LIMITS):
            raise Refused("the evidence archive has too many entries")
        for info in entries:
            if info.filename not in EVIDENCE_LIMITS or info.is_dir() or \
                    info.file_size > EVIDENCE_LIMITS[info.filename]:
                raise Refused("the evidence archive holds an unexpected entry")
            (folder / info.filename).write_bytes(archive.read(info))
    return read_evidence(folder)


def io_bytes(data):
    return io.BytesIO(data)


# MARK: - GitHub


class GitHub:
    """The REST API with one token. Tests replace it with a fake that has the same methods."""

    def __init__(self, token, repository=REPOSITORY, api="https://api.github.com", opener=None):
        self.token, self.repository, self.api = token, repository, api
        self.opener = opener or urllib.request.build_opener()

    def call(self, method, path, body=None, raw=False):
        url = path if path.startswith("https://") else f"{self.api}{path}"
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cloud-model-routine"})
        # Unredirected: the artifact endpoint redirects to a signed storage URL, and the token
        # must not travel there.
        request.add_unredirected_header("Authorization", f"Bearer {self.token}")
        try:
            with self.opener.open(request, timeout=60) as response:
                payload = response.read()
                return response.status, payload if raw else (json.loads(payload) if payload else None)
        except urllib.error.HTTPError as error:
            return error.code, None
        except (urllib.error.URLError, TimeoutError, ValueError):
            raise Refused(f"GitHub {method} failed without a reply")


def gh_ok(status, what):
    if status is None or not 200 <= status <= 299:
        raise Refused(f"GitHub refused {what}")


PAGE_SIZE = 100
MAX_PAGES = 50


def every_page(github, path, what):
    """Every item of a list endpoint, page by page until a short page. Any failed or malformed
    page refuses, so a partial list never stands for absence."""
    items = []
    separator = "&" if "?" in path else "?"
    for page in range(1, MAX_PAGES + 1):
        status, chunk = github.call("GET", f"{path}{separator}per_page={PAGE_SIZE}&page={page}")
        gh_ok(status, what)
        if not isinstance(chunk, list):
            raise Refused(f"GitHub returned an unreadable {what}")
        items.extend(chunk)
        if len(chunk) < PAGE_SIZE:
            return items
    raise Refused(f"the {what} is longer than this reporter reads")


def by(item, author):
    return isinstance(item, dict) and (item.get("user") or {}).get("login") == author


def find_issue(github, title, author):
    for issue in every_page(github, f"/repos/{github.repository}/issues?state=open", "issue list"):
        if by(issue, author) and issue.get("title") == title and "pull_request" not in issue:
            return issue
    return None


def report_once(github, title, author, marker, body):
    """One open issue per title and author, and one report per marker: reruns add nothing.
    Only the reporting author's own issue body and comments count as an earlier report."""
    issue = find_issue(github, title, author)
    if issue is None:
        status, created = github.call("POST", f"/repos/{github.repository}/issues",
                                      {"title": title, "body": body + "\n" + marker + "\n"})
        gh_ok(status, "the new issue")
        return "created"
    number = issue["number"]
    comments = every_page(github, f"/repos/{github.repository}/issues/{number}/comments",
                          "issue comments")
    texts = [c.get("body") or "" for c in comments if by(c, author)] + [issue.get("body") or ""]
    if any(marker in text for text in texts):
        return "already reported"
    status, _ = github.call("POST", f"/repos/{github.repository}/issues/{number}/comments",
                            {"body": body + "\n" + marker + "\n"})
    gh_ok(status, "the issue comment")
    return "commented"


# MARK: - Publication


def git(args, cwd, env=None):
    done = subprocess.run(["git", *args], cwd=cwd, capture_output=True, env=env)
    return done.returncode, done.stdout.decode().strip()


def publish(env, evidence_dir, checkout, github, remote, bot):
    """Re-derive the proposal from this run's evidence and publish it as one routine PR."""
    facts = authorize(env)
    found = read_evidence(evidence_dir)
    receipt = found["receipt.json"]
    expected_context = context_for(facts, receipt)
    if json.loads(found["context.json"]) != expected_context:
        raise Refused("the evidence context is not this run's")
    with tempfile.TemporaryDirectory(prefix="routine-publish-") as scratch:
        work = Path(scratch)
        (work / "receipt.json").write_bytes(receipt)
        (work / "context.json").write_bytes(found["context.json"])
        result, result_bytes, listed = generate(checkout, facts["sourceSHA"], work / "receipt.json",
                                                work / "context.json", work)
    if result_bytes != found["result.json"] or listed != found.get("cloud-models.json"):
        raise Refused("the evidence is not what this run's receipt produces")
    if pr_body(result, facts) != found["pr-body.md"]:
        raise Refused("the PR body is not this run's")
    summary = {"outcome": result["outcome"], "proposal": result["proposal"], "pr": None}
    file_candidate_issues(github, json.loads(receipt), facts, bot)
    if not result["proposal"]:
        return summary
    branch = branch_name(facts["runID"], facts["runAttempt"])
    summary["pr"] = open_pr(github, checkout, remote, branch, facts, listed, found["pr-body.md"],
                            result, bot)
    return summary


def open_pr(github, checkout, remote, branch, facts, listed, body, result, bot):
    rc, _ = git(["checkout", "-q", "--detach", facts["sourceSHA"]], checkout)
    if rc != 0:
        raise Refused("the source commit is not in the checkout")
    for relative in (PUBLIC, BUNDLED):
        (Path(checkout) / relative).write_bytes(listed)
    count = len(result["operations"])
    message = f"chore(cloud-models): add {count} model(s) from routine run {facts['runID']}\n\nPart of #4353.\n"
    identity = ["-c", f"user.name={bot}", "-c", f"user.email={bot}@users.noreply.github.com"]
    for args in (["add", PUBLIC, BUNDLED], [*identity, "commit", "-q", "-m", message]):
        rc, _ = git(args, checkout)
        if rc != 0:
            raise Refused("the proposal commit could not be made")
    _, tree = git(["rev-parse", "HEAD^{tree}"], checkout)
    rc, remote_head = git(["ls-remote", remote, f"refs/heads/{branch}"], checkout)
    if rc != 0:
        raise Refused("the remote could not be read")
    if remote_head:
        rc, _ = git(["fetch", "-q", remote, f"refs/heads/{branch}"], checkout)
        _, remote_tree = git(["rev-parse", "FETCH_HEAD^{tree}"], checkout)
        _, remote_author = git(["log", "-1", "--format=%an", "FETCH_HEAD"], checkout)
        if rc != 0 or remote_tree != tree or remote_author != bot:
            raise Refused("the routine branch already holds something else")
    else:
        rc, _ = git(["push", "-q", remote, f"HEAD:refs/heads/{branch}"], checkout)
        if rc != 0:
            raise Refused("the routine branch could not be pushed")
    owner = github.repository.split("/")[0]
    status, pulls = github.call("GET", f"/repos/{github.repository}/pulls?state=all&head={owner}:{branch}")
    gh_ok(status, "the PR list")
    for pull in pulls or []:
        if (pull.get("user") or {}).get("login") != bot:
            raise Refused("a PR for the routine branch has another author")
        if pull.get("state") != "open":
            raise Refused("the routine PR for this run is already closed")
        return pull["number"]
    title = f"Cloud model list: add {len(result['operations'])} model(s) (routine run {facts['runID']})"
    status, created = github.call("POST", f"/repos/{github.repository}/pulls", {
        "title": title, "head": branch, "base": "main", "body": body.decode("utf-8"),
        "maintainer_can_modify": False})
    gh_ok(status, "the new PR")
    return created["number"]


def file_candidate_issues(github, receipt, facts, bot):
    """One deduplicated issue per failed candidate, and the call-recipe issue on exhaustion.
    Bodies hold only provider, id, closed classes and the run link."""
    run = f"https://github.com/{facts['repository']}/actions/runs/{facts['runID']}"
    marker = f"<!-- cloud-model-routine run={facts['runID']} attempt={facts['runAttempt']} -->"
    for provider in receipt.get("providers", []):
        for candidate in provider.get("candidates", []):
            if candidate.get("outcome") in ("pass", "passViaSearch"):
                continue
            ident = f"{provider.get('provider')}/{candidate.get('id')}"
            if not re.fullmatch(r"[A-Za-z]+/[a-z0-9][a-z0-9._-]{0,99}", ident):
                raise Refused("a candidate identity is not a plain model id")
            error = candidate.get("errorClass") or candidate.get("outcome")
            search = (candidate.get("search") or {}).get("outcome")
            body = f"`{ident}` did not pass: `{error}`" + (f", search `{search}`" if search else "") + \
                f". Run: {run}"
            report_once(github, f"Cloud model routine: {ident} failed", bot, marker, body)
            if search == "requestRejectedSearchExhausted":
                report_once(github, CALL_RECIPE_ISSUE, bot, marker,
                            f"Every approved setting was rejected for `{ident}`. Run: {run}")


# MARK: - PR check


def identify(event, bot):
    """The (run id, attempt) of a routine App PR, None for any other PR, or Refused for an App
    PR that does not carry a routine branch from this repository."""
    pull = event.get("pull_request") or {}
    user = pull.get("user") or {}
    if not bot or user.get("login") != bot or user.get("type") != "Bot":
        return None
    head = pull.get("head") or {}
    if (head.get("repo") or {}).get("full_name") != REPOSITORY or \
            ((pull.get("base") or {}).get("repo") or {}).get("full_name") != REPOSITORY:
        raise Refused("a routine PR must come from this repository")
    match = BRANCH_RE.fullmatch(head.get("ref") or "")
    if not match:
        raise Refused("a routine PR has no routine branch")
    return match.group(1), match.group(2)


def authenticated_run(github, run_id, attempt):
    """The run's own GitHub facts, refused unless it is this workflow on main by an allowed
    event with its sweep job succeeded."""
    status, run = github.call("GET", f"/repos/{REPOSITORY}/actions/runs/{run_id}/attempts/{attempt}")
    gh_ok(status, "the source run")
    if (run.get("repository") or {}).get("full_name") != REPOSITORY or run.get("path") != WORKFLOW_PATH \
            or run.get("event") not in EVENTS or run.get("head_branch") != "main" \
            or str(run.get("id")) != run_id or str(run.get("run_attempt")) != attempt \
            or not COMMIT_RE.fullmatch(run.get("head_sha") or ""):
        raise Refused("the source run is not a routine run on main")
    status, jobs = github.call(
        "GET", f"/repos/{REPOSITORY}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")
    gh_ok(status, "the source run jobs")
    sweeps = [job for job in (jobs or {}).get("jobs", []) if job.get("name") == SWEEP_JOB]
    if len(sweeps) != 1 or sweeps[0].get("conclusion") != "success":
        raise Refused("the source run's sweep did not succeed")
    return {"repository": REPOSITORY, "workflow": run.get("name"), "runID": run_id,
            "runAttempt": attempt, "event": run.get("event"), "ref": MAIN_REF,
            "sourceSHA": run["head_sha"]}


def download_evidence(github, run_id, attempt, folder):
    name = artifact_name(run_id, attempt)
    status, listing = github.call("GET", f"/repos/{REPOSITORY}/actions/runs/{run_id}/artifacts?name={name}")
    gh_ok(status, "the run's artifacts")
    matches = [a for a in (listing or {}).get("artifacts", []) if a.get("name") == name]
    if len(matches) != 1 or matches[0].get("expired"):
        raise Refused("the run has no single current evidence artifact")
    status, data = github.call(
        "GET", f"/repos/{REPOSITORY}/actions/artifacts/{matches[0]['id']}/zip", raw=True)
    gh_ok(status, "the evidence archive")
    return extract_zip(data, folder)


def check_pr(event, github, bot, trusted, pr_checkout, work):
    """Exit status for the PR check: 0 for a non-routine PR or a valid routine PR."""
    identity = identify(event, bot)
    if identity is None:
        return "not a routine PR"
    run_id, attempt = identity
    facts = authenticated_run(github, run_id, attempt)
    work = Path(work)
    found = download_evidence(github, run_id, attempt, work / "evidence")
    context = context_for(facts, found["receipt.json"])
    if json.loads(found["context.json"]) != context:
        raise Refused("the evidence context is not its run's")
    (work / "context.json").write_text(json.dumps(context, indent=2, sort_keys=True) + "\n")
    pull = event["pull_request"]
    base_sha, head_sha = pull["base"]["sha"], pull["head"]["sha"]
    # Three dots: what the PR head changed since it left the base, as GitHub shows a PR. The
    # base list itself is compared to the recorded base by `propose.py check --target-base`.
    rc, changed = git(["diff", "--name-only", f"{base_sha}...{head_sha}"], pr_checkout)
    if rc != 0:
        raise Refused("the PR diff could not be read")
    if set(changed.splitlines()) - {PUBLIC, BUNDLED}:
        raise Refused("a routine PR changes files other than the two list copies")
    rc, current = git(["rev-parse", "HEAD"], pr_checkout)
    if rc != 0 or current != head_sha:
        raise Refused("the checked-out PR is not the current head")
    run_propose(["check", "--repo", str(trusted), "--base", facts["sourceSHA"],
                 "--receipt", str(work / "evidence" / "receipt.json"),
                 "--context", str(work / "context.json"),
                 "--result", str(work / "evidence" / "result.json"),
                 "--current-root", str(pr_checkout), "--target-base", base_sha])
    return f"routine PR for run {run_id} attempt {attempt} matches its evidence"


# MARK: - Failure report


def failure_stage(sweep_result, sweep_stage, publish_result, publish_outcome):
    """The closed stage a failed run stopped at, from job results only; None when the run
    did not fail."""
    if "cancelled" in (sweep_result, publish_result):
        return "cancelled"
    if sweep_result == "skipped":
        return "authorize"
    if sweep_result != "success":
        return sweep_stage if sweep_stage in FAILURE_STAGES[:3] else "sweep"
    if publish_result != "success":
        return "publication"
    if publish_outcome == "failure":
        return "outcome"
    return None


def report_failure(env, github, bot):
    # Only the routine's own main runs may write a report (no writes for any other run).
    authorize(env)
    stage = failure_stage(env.get("SWEEP_RESULT", ""), env.get("SWEEP_STAGE", ""),
                          env.get("PUBLISH_RESULT", ""), env.get("PUBLISH_OUTCOME", ""))
    if stage is None:
        return "no failure", "nothing to report"
    run_id, attempt = env.get("GITHUB_RUN_ID", ""), env.get("GITHUB_RUN_ATTEMPT", "")
    if not run_id.isdigit() or not attempt.isdigit():
        raise Refused("the run identity is incomplete")
    run = f"https://github.com/{REPOSITORY}/actions/runs/{run_id}"
    marker = f"<!-- cloud-routine-failure run={run_id} attempt={attempt} -->"
    body = f"cloud-routine-failure run={run_id} attempt={attempt} stage={stage} Run: {run}"
    return body, report_once(github, FAILURE_ISSUE, bot, marker, body)


# MARK: - Command line


def main(argv):
    if argv == ["--self-test"]:
        sys.path.insert(0, str(HERE))
        import workflow_test
        return workflow_test.run()
    import argparse
    parser = argparse.ArgumentParser(prog="workflow.py")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("authorize")
    sweep = commands.add_parser("finish-sweep")
    for flag in ("--log", "--receipt", "--out"):
        sweep.add_argument(flag, required=True)
    publication = commands.add_parser("publish")
    publication.add_argument("--evidence", required=True)
    publication.add_argument("--checkout", required=True)
    pr = commands.add_parser("check-pr")
    for flag in ("--event", "--trusted", "--pr", "--work"):
        pr.add_argument(flag, required=True)
    commands.add_parser("report-failure")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exit_:
        return 2 if exit_.code else 0
    env = dict(os.environ)
    try:
        if args.command == "authorize":
            authorize(env)
            print("authorized")
        elif args.command == "finish-sweep":
            try:
                log = Path(args.log).read_text(errors="replace")
            except OSError:
                raise Refused("the sweep log is missing")
            result = finish_sweep(env, log, args.receipt, args.out)
            print(f"staged: outcome {result['outcome']}, proposal {result['proposal']}")
        elif args.command == "publish":
            token = env.get("ROUTINE_APP_TOKEN", "")
            bot = env.get("ROUTINE_APP_BOT", "")
            if not token or not bot:
                raise Refused("the publication App is not configured")
            remote = f"https://x-access-token:{token}@github.com/{REPOSITORY}.git"
            summary = publish(env, args.evidence, args.checkout, GitHub(token), remote, bot)
            print(f"published: outcome {summary['outcome']}, PR {summary['pr']}")
            write_output(env, "outcome", summary["outcome"])
        elif args.command == "check-pr":
            event = json.loads(Path(args.event).read_text())
            message = check_pr(event, GitHub(env.get("GH_TOKEN", "")), env.get("ROUTINE_APP_BOT", ""),
                               args.trusted, args.pr, args.work)
            print(message)
        else:
            body, outcome = report_failure(env, GitHub(env.get("GH_TOKEN", "")),
                                           "github-actions[bot]")
            print(f"{outcome}: {body}")
    except Refused as error:
        print(f"refused: {error}", file=sys.stderr)
        return 1
    return 0


def write_output(env, name, value):
    path = env.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as handle:
            handle.write(f"{name}={value}\n")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
