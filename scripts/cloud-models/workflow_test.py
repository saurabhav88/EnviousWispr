"""Tests for workflow.py and the two workflow files (#4353 PR 5). Run through
`workflow.py --self-test`.

Every case runs the real helper path the workflow calls, against throwaway git repositories
and a fake GitHub that records every call. No network, no GitHub writes, no provider keys:
the keys below are fakes used as canaries. Receipts come from propose_test's builder, which
follows the Swift encoding that CloudModelRoutineProposalTests proves against the harness.
"""

import copy
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

import propose
import propose_test
import workflow

try:
    import yaml
except ImportError:  # The structural group needs PyYAML; build-check provisions it.
    yaml = None

ROOT = Path(__file__).resolve().parents[2]
SWEEP_YAML = ROOT / ".github/workflows/cloud-models-sweep.yml"
PR_YAML = ROOT / ".github/workflows/pr-check.yml"
BOT = "envious-cloud-models[bot]"
KEYS = {"TEST_RUNNER_EW_ROUTINE_OPENAI_KEY": "fake-openai-key-41f0",
        "TEST_RUNNER_EW_ROUTINE_CLAUDE_KEY": "fake-claude-key-82aa",
        "TEST_RUNNER_EW_ROUTINE_GEMINI_KEY": "fake-gemini-key-c3d9"}
PASSING_LOG = ("◇ Test weeklySweep() started.\n✔ Test weeklySweep() passed after 41.2 seconds.\n"
               "==> Debug lane executed 1 test\n==> Debug lane result bundle: 1 test case, all accepted\n"
               "==> Debug lane verdict: PASS\n==> Debug lane ran all 1 selection(s)\n")


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True
                          ).stdout.decode().strip()


class FakeGitHub:
    """Routes (method, path) to (status, payload); unknown calls answer 404. Records calls."""

    def __init__(self, routes=None):
        self.repository = workflow.REPOSITORY
        self.routes = dict(routes or {})
        self.calls = []
        self.issues = []

    failing_page = None

    @staticmethod
    def page(path, items):
        query = dict(part.split("=", 1) for part in path.split("?", 1)[1].split("&"))
        size, number = int(query.get("per_page", "30")), int(query.get("page", "1"))
        return items[(number - 1) * size: number * size], number

    def call(self, method, path, body=None, raw=False):
        self.calls.append((method, path, body))
        if (method, path) in self.routes:
            answer = self.routes[(method, path)]
            return answer(body) if callable(answer) else answer
        base = f"/repos/{self.repository}"
        if method == "GET" and path.startswith(f"{base}/issues?state=open"):
            items, number = self.page(path, self.issues)
            if number == self.failing_page:
                return 502, None
            return 200, [{k: v for k, v in i.items() if k != "comments"} for i in items]
        if method == "POST" and path == f"{base}/issues":
            number = 1000 + len(self.issues)
            self.issues.append({"number": number, "title": body["title"], "body": body["body"],
                                "user": {"login": self.author}, "comments": []})
            return 201, {"number": number}
        for issue in self.issues:
            if path == f"{base}/issues/{issue['number']}":
                return 200, {k: v for k, v in issue.items() if k != "comments"}
            if path.startswith(f"{base}/issues/{issue['number']}/comments"):
                if method == "POST":
                    issue["comments"].append({"body": body["body"], "user": {"login": self.author}})
                    return 201, {}
                items, number = self.page(path, issue["comments"])
                if number == self.failing_page:
                    return 502, None
                return 200, items
        return 404, None

    author = BOT

    def writes(self):
        return [c for c in self.calls if c[0] != "GET"]


class Case(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="workflow-test-")
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "config", "user.email", "test@example.invalid")
        git(self.repo, "config", "user.name", "test")
        self.base = propose_test.list_bytes()
        self.commit = propose_test.commit_list(self.repo, self.base)
        self.remote = self.root / "remote.git"
        subprocess.run(["git", "clone", "-q", "--bare", str(self.repo), str(self.remote)], check=True)

    def tearDown(self):
        self.temp.cleanup()

    def env(self, **changes):
        env = {"GITHUB_REPOSITORY": workflow.REPOSITORY, "GITHUB_WORKFLOW": "Cloud model routine sweep",
               "GITHUB_RUN_ID": "101", "GITHUB_RUN_ATTEMPT": "1", "GITHUB_EVENT_NAME": "schedule",
               "GITHUB_REF": workflow.MAIN_REF, "GITHUB_SHA": self.commit,
               "GITHUB_WORKFLOW_REF": f"{workflow.REPOSITORY}/{workflow.WORKFLOW_PATH}@refs/heads/main"}
        env.update(KEYS)
        env.update(changes)
        return env

    def receipt(self, build=None, outcome=None):
        receipt = propose_test.Receipt(self.commit, self.base, outcome)
        (build or (lambda r: r.fallback_pass()))(receipt)
        built = receipt.build()
        built["provenance"].update(repository=workflow.REPOSITORY, workflow="Cloud model routine sweep")
        return built

    def write_receipt(self, built):
        path = self.root / "receipt.json"
        path.write_bytes(json.dumps(built, sort_keys=True).encode())
        return path

    def stage(self, built=None, log=PASSING_LOG, **env):
        path = self.write_receipt(built if built is not None else self.receipt())
        out = self.root / "evidence"
        shutil.rmtree(out, ignore_errors=True)
        return workflow.finish_sweep(self.env(**env), log, path, out, repo=self.repo), out

    def checkout(self):
        path = self.root / "checkout"
        shutil.rmtree(path, ignore_errors=True)
        subprocess.run(["git", "clone", "-q", str(self.repo), str(path)], check=True)
        return path

    def publish(self, github=None, **env):
        github = github or FakeGitHub(self.pull_routes())
        summary = workflow.publish(self.env(**env), self.root / "evidence", self.checkout(), github,
                                   str(self.remote), BOT)
        return summary, github

    def pull_routes(self, existing=None):
        branch = workflow.branch_name("101", "1")
        path = f"/repos/{workflow.REPOSITORY}/pulls?state=all&head=saurabhav88:{branch}"
        return {("GET", path): (200, existing or []),
                ("POST", f"/repos/{workflow.REPOSITORY}/pulls"): (201, {"number": 7})}

    def run_routes(self, run=None, jobs=None, artifacts=None, archive=None):
        base = f"/repos/{workflow.REPOSITORY}/actions"
        run = run or {"id": 101, "run_attempt": 1, "path": workflow.WORKFLOW_PATH, "event": "schedule",
                      "head_branch": "main", "head_sha": self.commit, "name": "Cloud model routine sweep",
                      "repository": {"full_name": workflow.REPOSITORY}, "status": "completed",
                      "conclusion": "success", "created_at": "2026-11-09T06:17:03Z"}
        name = workflow.artifact_name("101", "1")
        jobs = jobs or {"jobs": [{"name": "sweep", "conclusion": "success"},
                                 {"name": "publish", "conclusion": "success"}]}
        jobs.setdefault("total_count", len(jobs["jobs"]))
        for job in jobs["jobs"]:
            # GitHub reports every job's status; fixtures that only name a conclusion are done.
            if isinstance(job, dict) and "conclusion" in job and not isinstance(job.get("name"), int):
                job.setdefault("status", "completed")
        artifacts = artifacts or {"artifacts": [{"id": 9, "name": name, "expired": False}]}
        artifacts.setdefault("total_count", len(artifacts["artifacts"]))
        return {
            ("GET", f"{base}/runs/101/attempts/1"): (200, run),
            ("GET", f"{base}/runs/101/attempts/1/jobs?per_page=100&page=1"): (200, jobs),
            ("GET", f"{base}/runs/101/artifacts?name={name}&per_page=100&page=1"): (200, artifacts),
            ("GET", f"{base}/artifacts/9/zip"): (200, archive),
        }

    def refused(self, call, needle):
        with self.assertRaises(workflow.Refused) as caught:
            call()
        self.assertIn(needle, str(caught.exception))
        return str(caught.exception)


# MARK: - Groups


class Events(Case):
    def test_schedule_and_manual_runs_on_main_are_allowed(self):
        for event in ("schedule", "workflow_dispatch"):
            self.assertEqual(workflow.authorize(self.env(GITHUB_EVENT_NAME=event))["event"], event)

    def test_everything_else_is_refused(self):
        cases = [({"GITHUB_EVENT_NAME": "pull_request"}, "schedule or manual"),
                 ({"GITHUB_EVENT_NAME": "pull_request_target"}, "schedule or manual"),
                 ({"GITHUB_REPOSITORY": "someone/fork"}, "repository"),
                 ({"GITHUB_REF": "refs/heads/feature"}, "only main"),
                 ({"GITHUB_REF": "refs/tags/v1"}, "only main"),
                 ({"GITHUB_SHA": "abc123"}, "full commit"),
                 ({"GITHUB_RUN_ID": ""}, "incomplete"),
                 ({"GITHUB_WORKFLOW_REF": f"{workflow.REPOSITORY}/.github/workflows/other.yml@refs/heads/main"},
                  "routine workflow file")]
        for change, needle in cases:
            with self.subTest(change=change):
                self.refused(lambda c=change: workflow.authorize(self.env(**c)), needle)


@unittest.skipIf(yaml is None, "PyYAML is required")
class Scoping(Case):
    def sweep(self):
        return yaml.safe_load(SWEEP_YAML.read_text())

    def test_provider_keys_only_in_the_sweep_step(self):
        document = self.sweep()
        text = SWEEP_YAML.read_text()
        self.assertEqual(text.count("secrets.EW_ROUTINE_"), 3)
        for name, job in document["jobs"].items():
            for step in job["steps"]:
                carries = "secrets.EW_ROUTINE_" in json.dumps(step)
                self.assertEqual(carries, name == "sweep" and step.get("id") == "sweep",
                                 f"{name}/{step.get('name')}")
        self.assertEqual(document["permissions"], {})
        self.assertEqual(document["jobs"]["sweep"]["permissions"], {"contents": "read"})
        self.assertEqual(document["jobs"]["sweep"]["environment"], "cloud-model-routine")
        self.assertEqual(document["concurrency"]["cancel-in-progress"], False)
        self.assertEqual(set(document[True]) if True in document else set(document["on"]),
                         {"schedule", "workflow_dispatch"})

    def test_app_credentials_only_in_publish_and_no_merge(self):
        document = self.sweep()
        for name, job in document["jobs"].items():
            dumped = json.dumps(job)
            self.assertEqual("CLOUD_MODEL_ROUTINE_APP_PRIVATE_KEY" in dumped, name == "publish", name)
            runs = " ".join(step.get("run", "") for step in job["steps"])
            self.assertNotIn("merge", runs)
            for step in job["steps"]:
                if "actions/checkout@" in step.get("uses", ""):
                    self.assertEqual(step["with"].get("persist-credentials"), False, name)
                    self.assertEqual(step["with"].get("ref"), "${{ github.sha }}", name)
        self.assertEqual(document["jobs"]["publish"]["environment"], "cloud-model-routine-publish")
        self.assertEqual(document["jobs"]["report-failure"]["permissions"],
                         {"contents": "read", "issues": "write"})
        self.assertNotIn("pull_request_target", SWEEP_YAML.read_text() + PR_YAML.read_text())

    def test_artifact_is_an_explicit_allowlist(self):
        upload = next(s for s in self.sweep()["jobs"]["sweep"]["steps"] if s.get("id") == "upload")
        paths = [line.strip() for line in upload["with"]["path"].splitlines() if line.strip()]
        self.assertEqual({p.rsplit("/", 1)[-1] for p in paths}, set(workflow.EVIDENCE_LIMITS))
        self.assertTrue(all(p.startswith("${{ runner.temp }}/evidence/") for p in paths))
        self.assertEqual(upload["with"]["name"],
                         "cloud-model-routine-evidence-${{ github.run_id }}-${{ github.run_attempt }}")

    def test_routine_check_feeds_build_check(self):
        jobs = yaml.safe_load(PR_YAML.read_text())["jobs"]
        self.assertIn("routine-pr-check", jobs["build-check"]["needs"])
        require = next(s for s in jobs["build-check"]["steps"] if s.get("name") == "Require every lane")
        self.assertIn("routine-pr-check=$ROUTINE", require["run"])
        self.assertEqual(jobs["routine-pr-check"]["permissions"], {"contents": "read", "actions": "read"})
        dumped = json.dumps(jobs["routine-pr-check"])
        self.assertNotIn("secrets.", dumped)
        self.assertIn("trusted/scripts/cloud-models/workflow.py check-pr", dumped)


class SweepRun(Case):
    def test_named_test_executed_and_receipt_staged(self):
        result, out = self.stage()
        self.assertTrue(result["proposal"])
        self.assertEqual({p.name for p in out.iterdir()}, set(workflow.EVIDENCE_LIMITS))

    def test_skipped_zero_or_failed_runs_and_bad_receipts_are_refused(self):
        logs = {"no test ran": PASSING_LOG.replace("executed 1 test", "executed 0 tests"),
                "skipped": "✘ Test weeklySweep() skipped\n==> Debug lane executed 1 test\n==> Debug lane verdict: PASS\n",
                "no pass line": PASSING_LOG.replace("✔ Test weeklySweep() passed", "◇ Test other()"),
                "failed lane": PASSING_LOG.replace("verdict: PASS", "verdict: FAIL"),
                "empty": ""}
        for name, log in logs.items():
            with self.subTest(log=name):
                self.refused(lambda l=log: workflow.verify_sweep_log(l), "sweep")
        self.refused(lambda: workflow.finish_sweep(self.env(), PASSING_LOG, self.root / "none.json",
                                                   self.root / "out"), "no receipt")
        path = self.root / "bad.json"
        path.write_text("{not json")
        self.refused(lambda: workflow.finish_sweep(self.env(), PASSING_LOG, path, self.root / "out2",
                                                   repo=self.repo), "proposal refused")


class Binding(Case):
    def test_run_metadata_must_be_the_routine_run(self):
        good = self.run_routes()[("GET", f"/repos/{workflow.REPOSITORY}/actions/runs/101/attempts/1")][1]
        changes = [{"path": ".github/workflows/other.yml"}, {"event": "push"}, {"head_branch": "dev"},
                   {"run_attempt": 2}, {"repository": {"full_name": "someone/fork"}}]
        for change in changes:
            with self.subTest(change=change):
                github = FakeGitHub(self.run_routes(run=dict(good, **change)))
                self.refused(lambda g=github: workflow.authenticated_run(g, "101", "1"), "routine run")
        github = FakeGitHub(self.run_routes(jobs={"jobs": [{"name": "sweep", "conclusion": "failure"}]}))
        self.refused(lambda: workflow.authenticated_run(github, "101", "1"), "sweep did not succeed")
        facts = workflow.authenticated_run(FakeGitHub(self.run_routes()), "101", "1")
        self.assertEqual(facts["sourceSHA"], self.commit)

    def test_artifact_is_bound_to_the_run_and_attempt(self):
        listing = {"artifacts": [{"id": 9, "name": workflow.artifact_name("101", "2"), "expired": False}]}
        github = FakeGitHub(self.run_routes(artifacts=listing))
        self.refused(lambda: workflow.download_evidence(github, "101", "1", self.root / "e"),
                     "artifact is missing")
        expired = {"artifacts": [{"id": 9, "name": workflow.artifact_name("101", "1"), "expired": True}]}
        github = FakeGitHub(self.run_routes(artifacts=expired))
        self.refused(lambda: workflow.download_evidence(github, "101", "1", self.root / "f"),
                     "artifact is expired")


def zip_of(files):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, data in files.items():
            archive.writestr(name, data)
    return buffer.getvalue()


class Artifacts(Case):
    def test_unexpected_entries_are_refused(self):
        _, out = self.stage()
        files = {p.name: p.read_bytes() for p in out.iterdir()}
        bad = {"extra file": dict(files, **{"run.sh": b"echo"}),
               "path escape": dict(files, **{"../receipt.json": b"{}"}),
               "nested": dict(files, **{"dir/receipt.json": b"{}"}),
               "oversized": dict(files, **{"pr-body.md": b"x" * 70_000})}
        for index, (name, entries) in enumerate(bad.items()):
            with self.subTest(case=name):
                self.refused(lambda e=entries, i=index: workflow.extract_zip(zip_of(e), self.root / f"z{i}"),
                             "evidence")

    def test_manifest_and_folder_checks(self):
        _, out = self.stage()
        (out / "pr-body.md").write_bytes(b"edited\n")
        self.refused(lambda: workflow.read_evidence(out), "does not match its manifest")
        _, out = self.stage()
        (out / "notes.txt").write_text("x")
        self.refused(lambda: workflow.read_evidence(out), "unexpected entry")
        _, out = self.stage()
        os.unlink(out / "cloud-models.json")
        self.refused(lambda: workflow.read_evidence(out), "manifest")
        _, out = self.stage()
        extracted = workflow.extract_zip(zip_of({p.name: p.read_bytes() for p in out.iterdir()}),
                                         self.root / "ok")
        self.assertEqual(set(extracted), set(workflow.EVIDENCE_LIMITS))


class Publication(Case):
    def test_addition_opens_one_pr_on_the_routine_branch(self):
        self.stage()
        summary, github = self.publish()
        self.assertEqual((summary["outcome"], summary["pr"]), ("success", 7))
        branch = workflow.branch_name("101", "1")
        listed = git(self.remote, "show", f"refs/heads/{branch}:{propose.PUBLIC}")
        self.assertEqual(json.loads(listed)["models"][-1]["id"], "gpt-new")
        self.assertEqual(git(self.remote, "show", f"refs/heads/{branch}:{propose.BUNDLED}"), listed)
        self.assertEqual(git(self.remote, "log", "-1", "--format=%an", f"refs/heads/{branch}"), BOT)
        posts = [c for c in github.writes() if c[1].endswith("/pulls")]
        self.assertEqual(len(posts), 1)
        self.assertEqual((posts[0][2]["head"], posts[0][2]["base"]), (branch, "main"))
        self.assertNotIn("merge", json.dumps(github.calls).lower())

    def test_true_nochange_writes_nothing(self):
        self.stage(self.receipt(build=lambda r: None))
        summary, github = self.publish()
        self.assertEqual((summary["outcome"], summary["proposal"], summary["pr"]), ("nochange", False, None))
        self.assertEqual(github.writes(), [])
        self.assertEqual(git(self.remote, "branch", "--list", "cloud-model-routine/*"), "")

    def test_tampered_evidence_is_refused_before_any_write(self):
        _, out = self.stage()
        result = json.loads((out / "result.json").read_bytes())
        result["operations"] = []
        data = (json.dumps(result) + "\n").encode()
        (out / "result.json").write_bytes(data)
        manifest = json.loads((out / "manifest.json").read_bytes())
        manifest["files"]["result.json"] = workflow.sha256(data)
        (out / "manifest.json").write_text(json.dumps(manifest))
        github = FakeGitHub(self.pull_routes())
        self.refused(lambda: self.publish(github), "not what this run's receipt produces")
        self.assertEqual(github.writes(), [])


class Outcomes(Case):
    def test_partial_is_preserved_and_failed_models_get_one_issue(self):
        self.stage(self.receipt(build=lambda r: (r.fallback_pass(), r.failed_candidate())))
        summary, github = self.publish()
        self.assertEqual((summary["outcome"], summary["pr"]), ("partial", 7))
        titles = [i["title"] for i in github.issues]
        self.assertEqual(titles, ["Cloud model routine: openAI/gpt-bad failed"])
        self.publish(github)
        self.assertEqual(len(github.issues), 1)
        self.assertEqual(github.issues[0]["comments"], [])

    def test_failure_proposes_nothing(self):
        def build(receipt):
            receipt.failed.add("gemini")
            receipt.fallback_pass()
        self.stage(self.receipt(build=build))
        summary, github = self.publish()
        self.assertEqual((summary["outcome"], summary["pr"]), ("failure", None))
        self.assertFalse([c for c in github.writes() if "/pulls" in c[1]])


def pr_event(commit, head, **changes):
    event = {"pull_request": {
        "user": {"login": BOT, "type": "Bot"},
        "head": {"ref": workflow.branch_name("101", "1"), "sha": head,
                 "repo": {"full_name": workflow.REPOSITORY}},
        "base": {"sha": commit, "repo": {"full_name": workflow.REPOSITORY}}}}
    for path, value in changes.items():
        target = event["pull_request"]
        *parents, last = path.split(".")
        for part in parents:
            target = target[part]
        target[last] = value
    return event


class Identity(Case):
    def test_only_the_app_bot_is_a_routine_pr(self):
        self.assertIsNone(workflow.identify(pr_event(self.commit, "h", **{"user.login": "a-person"}), BOT))
        self.assertIsNone(workflow.identify(pr_event(self.commit, "h", **{"user.type": "User"}), BOT))
        self.assertIsNone(workflow.identify(pr_event(self.commit, "h"), ""))
        # A person's PR with the routine's branch, title or body is ordinary.
        spoof = pr_event(self.commit, "h", **{"user.login": "a-person", "title": "Cloud model list: add"})
        self.assertIsNone(workflow.identify(spoof, BOT))
        self.assertEqual(workflow.identify(pr_event(self.commit, "h"), BOT), ("101", "1"))

    def test_app_pr_without_provenance_fails_closed(self):
        self.refused(lambda: workflow.identify(
            pr_event(self.commit, "h", **{"head.repo": {"full_name": "someone/fork"}}), BOT), "this repository")
        self.refused(lambda: workflow.identify(pr_event(self.commit, "h", **{"head.ref": "feature"}), BOT),
                     "routine branch")
        github = FakeGitHub()
        self.refused(lambda: workflow.check_pr(pr_event(self.commit, "h"), github, BOT, self.repo,
                                               self.repo, self.root / "w"), "source run")


class HeadAndBase(Case):
    def routine_pr(self):
        """Stage, publish to the bare remote, and return (event, github, pr checkout)."""
        _, out = self.stage()
        self.publish()
        branch = workflow.branch_name("101", "1")
        pr = self.root / "pr"
        shutil.rmtree(pr, ignore_errors=True)
        subprocess.run(["git", "clone", "-q", "-b", branch, str(self.remote), str(pr)], check=True)
        head = git(pr, "rev-parse", "HEAD")
        archive = zip_of({p.name: p.read_bytes() for p in out.iterdir()})
        return pr_event(self.commit, head), FakeGitHub(self.run_routes(archive=archive)), pr

    def test_exact_head_passes_and_a_moved_base_with_the_same_list_passes(self):
        event, github, pr = self.routine_pr()
        message = workflow.check_pr(event, github, BOT, self.repo, pr, self.root / "w1")
        self.assertIn("matches its evidence", message)
        (self.repo / "README.md").write_text("unrelated")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "unrelated")
        moved = git(self.repo, "rev-parse", "HEAD")
        git(pr, "fetch", "-q", str(self.repo), "main")
        event["pull_request"]["base"]["sha"] = moved
        self.assertIn("matches", workflow.check_pr(event, github, BOT, self.repo, pr, self.root / "w2"))
        # A moved base whose LIST changed is refused by the checker.
        manual = copy.deepcopy(propose_test.BASE_MODELS)
        manual[0]["recommended"] = True
        changed = propose_test.commit_list(self.repo, propose_test.list_bytes(manual), "manual edit")
        git(pr, "fetch", "-q", str(self.repo), "main")
        event["pull_request"]["base"]["sha"] = changed
        self.refused(lambda: workflow.check_pr(event, github, BOT, self.repo, pr, self.root / "w3"),
                     "changed since the run")

    def test_changed_head_extra_files_and_edited_lists_are_refused(self):
        event, github, pr = self.routine_pr()
        stale = dict(event)
        stale["pull_request"] = copy.deepcopy(event["pull_request"])
        stale["pull_request"]["head"]["sha"] = self.commit
        self.refused(lambda: workflow.check_pr(stale, github, BOT, self.repo, pr, self.root / "w1"),
                     "current head")
        listed = json.loads((pr / propose.PUBLIC).read_text())
        listed["models"][0]["recommended"] = True
        for relative in (propose.PUBLIC, propose.BUNDLED):
            (pr / relative).write_bytes(propose.encode_list(listed))
        git(pr, "-c", "user.name=x", "-c", "user.email=x@x", "commit", "-qam", "edit")
        event["pull_request"]["head"]["sha"] = git(pr, "rev-parse", "HEAD")
        self.refused(lambda: workflow.check_pr(event, github, BOT, self.repo, pr, self.root / "w2"),
                     "proposal refused")
        (pr / "run.sh").write_text("echo")
        git(pr, "add", "run.sh")
        git(pr, "-c", "user.name=x", "-c", "user.email=x@x", "commit", "-qm", "extra")
        event["pull_request"]["head"]["sha"] = git(pr, "rev-parse", "HEAD")
        self.refused(lambda: workflow.check_pr(event, github, BOT, self.repo, pr, self.root / "w3"),
                     "other than the two list copies")


class Ownership(Case):
    def test_rerun_reuses_the_same_branch_and_pr(self):
        self.stage()
        self.publish()
        existing = [{"number": 7, "state": "open", "user": {"login": BOT}}]
        summary, github = self.publish(FakeGitHub(self.pull_routes(existing)))
        self.assertEqual(summary["pr"], 7)
        self.assertFalse([c for c in github.writes() if c[1].endswith("/pulls")])

    def test_foreign_branch_or_pr_is_refused(self):
        self.stage()
        self.publish()
        other = [{"number": 8, "state": "open", "user": {"login": "a-person"}}]
        self.refused(lambda: self.publish(FakeGitHub(self.pull_routes(other))), "another author")
        closed = [{"number": 7, "state": "closed", "user": {"login": BOT}}]
        self.refused(lambda: self.publish(FakeGitHub(self.pull_routes(closed))), "already closed")
        # Someone else's content on the routine branch.
        work = self.checkout()
        git(work, "checkout", "-q", "-b", "x")
        (work / "README.md").write_text("other")
        git(work, "add", "-A")
        git(work, "-c", "user.name=x", "-c", "user.email=x@x", "commit", "-qm", "other")
        git(work, "push", "-q", "-f", str(self.remote), f"HEAD:refs/heads/{workflow.branch_name('101', '1')}")
        self.refused(lambda: self.publish(), "already holds something else")


class FailureReports(Case):
    def test_stage_comes_from_job_results(self):
        table = [(("skipped", "", "skipped", ""), "authorize"),
                 (("failure", "authorize", "skipped", ""), "authorize"),
                 (("failure", "", "skipped", ""), "sweep"),
                 (("failure", "receipt", "skipped", ""), "receipt"),
                 (("failure", "anything; rm -rf", "skipped", ""), "sweep"),
                 (("cancelled", "", "skipped", ""), "cancelled"),
                 (("success", "", "failure", ""), "publication"),
                 (("success", "", "success", "failure"), "outcome"),
                 (("success", "", "success", "partial"), None)]
        for args, stage in table:
            with self.subTest(args=args):
                self.assertEqual(workflow.failure_stage(*args), stage)

    def test_one_issue_and_one_comment_per_run_even_before_a_receipt(self):
        github = FakeGitHub()
        github.author = "github-actions[bot]"
        env = self.env(SWEEP_RESULT="failure", SWEEP_STAGE="sweep", PUBLISH_RESULT="skipped")
        body, outcome = workflow.report_failure(env, github, "github-actions[bot]")
        self.assertEqual(outcome, "created")
        self.assertIn("stage=sweep", body)
        self.assertNotIn("fake-", body)
        self.assertEqual(workflow.report_failure(env, github, "github-actions[bot]")[1], "already reported")
        later = dict(env, GITHUB_RUN_ID="102")
        self.assertEqual(workflow.report_failure(later, github, "github-actions[bot]")[1], "commented")
        self.assertEqual(len(github.issues), 1)
        self.assertEqual(len(github.issues[0]["comments"]), 1)


class Pagination(Case):
    def filler(self, github, count):
        github.issues.extend({"number": n, "title": f"Other issue {n}", "body": "", "comments": [],
                              "user": {"login": "a-person"}} for n in range(1, count + 1))

    def test_issue_beyond_the_first_page_is_reused(self):
        github = FakeGitHub()
        github.author = "github-actions[bot]"
        self.filler(github, 150)
        env = self.env(SWEEP_RESULT="failure", PUBLISH_RESULT="skipped")
        self.assertEqual(workflow.report_failure(env, github, "github-actions[bot]")[1], "created")
        self.assertEqual(workflow.report_failure(dict(env, GITHUB_RUN_ID="102"), github,
                                                 "github-actions[bot]")[1], "commented")
        self.assertEqual([i["title"] for i in github.issues].count(workflow.FAILURE_ISSUE), 1)

    def test_marker_beyond_the_first_comment_page_prevents_a_duplicate(self):
        github = FakeGitHub()
        github.author = "github-actions[bot]"
        env = self.env(SWEEP_RESULT="failure", PUBLISH_RESULT="skipped")
        workflow.report_failure(env, github, "github-actions[bot]")
        issue = github.issues[0]
        issue["comments"] = [{"body": f"note {n}", "user": {"login": "a-person"}} for n in range(120)]
        later = dict(env, GITHUB_RUN_ID="102")
        self.assertEqual(workflow.report_failure(later, github, "github-actions[bot]")[1], "commented")
        self.assertEqual(workflow.report_failure(later, github, "github-actions[bot]")[1],
                         "already reported")
        self.assertEqual(len(issue["comments"]), 121)

    def test_another_authors_marker_does_not_suppress_the_report(self):
        github = FakeGitHub()
        github.author = "github-actions[bot]"
        env = self.env(SWEEP_RESULT="failure", PUBLISH_RESULT="skipped")
        workflow.report_failure(env, github, "github-actions[bot]")
        later = dict(env, GITHUB_RUN_ID="102")
        marker = "<!-- cloud-routine-failure run=102 attempt=1 -->"
        github.issues[0]["comments"].append({"body": marker, "user": {"login": "a-person"}})
        self.assertEqual(workflow.report_failure(later, github, "github-actions[bot]")[1], "commented")

    def test_a_failed_later_page_writes_nothing(self):
        for failing in ("issues", "comments"):
            with self.subTest(page=failing):
                github = FakeGitHub()
                github.author = "github-actions[bot]"
                env = self.env(SWEEP_RESULT="failure", PUBLISH_RESULT="skipped")
                if failing == "issues":
                    self.filler(github, 150)
                else:
                    workflow.report_failure(env, github, "github-actions[bot]")
                    github.issues[0]["comments"] = [
                        {"body": "x", "user": {"login": "a-person"}} for _ in range(120)]
                github.failing_page = 2
                before = len(github.writes())
                self.refused(lambda: workflow.report_failure(
                    dict(env, GITHUB_RUN_ID="103"), github, "github-actions[bot]"), "GitHub refused")
                self.assertEqual(len(github.writes()), before)


class Unauthorized(Case):
    def test_failure_job_is_limited_to_main_schedule_or_manual(self):
        if yaml is None:
            self.fail("PyYAML is required")
        condition = yaml.safe_load(SWEEP_YAML.read_text())["jobs"]["report-failure"]["if"]
        for fragment in ("github.repository == 'saurabhav88/EnviousWispr'",
                         "github.ref == 'refs/heads/main'",
                         "github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'"):
            self.assertIn(fragment, condition)

    def test_unauthorized_facts_report_nothing(self):
        for change in ({"GITHUB_REF": "refs/heads/feature"}, {"GITHUB_REF": "refs/tags/v9"},
                       {"GITHUB_EVENT_NAME": "push"}):
            with self.subTest(change=change):
                github = FakeGitHub()
                env = self.env(SWEEP_RESULT="skipped", PUBLISH_RESULT="skipped", **change)
                self.refused(lambda e=env, g=github: workflow.report_failure(e, g, "github-actions[bot]"),
                             "")
                self.assertEqual(github.calls, [])


class Redirects(Case):
    def test_the_token_is_not_forwarded_across_an_artifact_redirect(self):
        import email.message
        import urllib.request
        import urllib.response
        _, out = self.stage()
        archive = zip_of({p.name: p.read_bytes() for p in out.iterdir()})
        seen = []

        class FakeHTTPS(urllib.request.BaseHandler):
            handler_order = 100

            def https_open(self, request):
                seen.append((request.full_url, request.get_header("Authorization")))
                headers = email.message.Message()
                if request.full_url.startswith("https://api.github.com/"):
                    headers["Location"] = "https://blob.example.invalid/signed?sig=1"
                    response = urllib.response.addinfourl(io.BytesIO(b""), headers, request.full_url, 302)
                else:
                    response = urllib.response.addinfourl(io.BytesIO(archive), headers, request.full_url, 200)
                response.msg = "OK"
                return response

        github = workflow.GitHub("fake-gh-token-77", opener=urllib.request.build_opener(FakeHTTPS))
        status, data = github.call("GET", f"/repos/{workflow.REPOSITORY}/actions/artifacts/9/zip", raw=True)
        self.assertEqual(status, 200)
        self.assertEqual(seen[0], (f"https://api.github.com/repos/{workflow.REPOSITORY}/actions/artifacts/9/zip",
                                   "Bearer fake-gh-token-77"))
        self.assertEqual(seen[1], ("https://blob.example.invalid/signed?sig=1", None))
        extracted = workflow.extract_zip(data, self.root / "downloaded")
        self.assertEqual(set(extracted), set(workflow.EVIDENCE_LIMITS))


class VerifyRun(Case):
    """`verify-run`: one closed classification of a completed run, from GitHub facts and
    the run's own evidence."""

    BASE = f"/repos/{workflow.REPOSITORY}/actions"

    def evidence_routes(self, built=None, **changes):
        _, out = self.stage(built)
        archive = zip_of({p.name: p.read_bytes() for p in out.iterdir()})
        return self.run_routes(archive=archive, **changes), out

    def verify(self, routes, run="101", attempt="1"):
        github = FakeGitHub(routes)
        result = workflow.verify_run(github, run, attempt, self.repo, self.root / f"v-{len(os.listdir(self.root))}")
        self.assertEqual(github.writes(), [])
        return result

    def test_verified_proposal_and_searched_addition(self):
        for build, setting in ((lambda r: r.fallback_pass(), "fallback"),
                               (lambda r: r.search_pass(), "search")):
            with self.subTest(via=setting):
                routes, _ = self.evidence_routes(self.receipt(build=build))
                result = self.verify(routes)
                self.assertEqual((result["status"], result["reason"], result["measured"]),
                                 ("verified", "evidence-verified", True))
                self.assertEqual(result["receipt"], {"providers": 3, "candidates": 1, "added": 1,
                                                     "failed": 0, "outcome": "success"})
                self.assertTrue(result["evidence"]["proposal"])
                self.assertEqual(result["run"]["createdAt"], "2026-11-09T06:17:03Z")
                self.assertEqual((result["run"]["sweep"], result["run"]["publish"]), ("success", "success"))

    def test_verified_no_change(self):
        routes, _ = self.evidence_routes(self.receipt(build=lambda r: None))
        result = self.verify(routes)
        self.assertEqual(result["status"], "verified")
        self.assertEqual(result["receipt"], {"providers": 3, "candidates": 0, "added": 0, "failed": 0,
                                             "outcome": "nochange"})
        self.assertFalse(result["evidence"]["proposal"])

    def test_partial_and_failure_evidence_keep_their_outcomes(self):
        routes, _ = self.evidence_routes(self.receipt(build=lambda r: (r.fallback_pass(), r.failed_candidate())))
        self.assertEqual(self.verify(routes)["receipt"], {"providers": 3, "candidates": 2, "added": 1,
                                                          "failed": 1, "outcome": "partial"})

        def failed(receipt):
            receipt.failed.add("gemini")
            receipt.fallback_pass()
        routes, _ = self.evidence_routes(self.receipt(build=failed))
        result = self.verify(routes)
        self.assertEqual((result["status"], result["measured"]), ("verified", True))
        self.assertEqual(result["receipt"], {"providers": 3, "candidates": 1, "added": 0, "failed": 0,
                                             "outcome": "failure"})

    def test_failed_sweep_without_evidence(self):
        for conclusion in ("failure", "cancelled", "timed_out", "skipped"):
            with self.subTest(conclusion=conclusion):
                routes = self.run_routes(jobs={"jobs": [{"name": "sweep", "conclusion": conclusion}]})
                github = FakeGitHub(routes)
                result = workflow.verify_run(github, "101", "1", self.repo, self.root / f"f-{conclusion}")
                self.assertEqual((result["status"], result["reason"], result["measured"]),
                                 ("failure", f"sweep-{conclusion}", False))
                self.assertEqual(result["receipt"], {"providers": 3, "candidates": 0, "added": 0,
                                                     "failed": 0, "outcome": "failure"})
                self.assertFalse([c for c in github.calls if "artifacts" in c[1]])

    def test_publication_failure_is_surfaced(self):
        jobs = {"jobs": [{"name": "sweep", "conclusion": "success"}, {"name": "publish", "conclusion": "failure"}]}
        routes, _ = self.evidence_routes(jobs=jobs)
        result = self.verify(routes)
        self.assertEqual((result["status"], result["run"]["publish"]), ("verified", "failure"))

    def test_wrong_identity_is_refused(self):
        good = self.run_routes()[("GET", f"{self.BASE}/runs/101/attempts/1")][1]
        for change in ({"repository": {"full_name": "someone/fork"}}, {"path": ".github/workflows/x.yml"},
                       {"head_branch": "dev"}, {"event": "push"}, {"head_sha": "abc"}, {"run_attempt": 2},
                       {"id": 102}):
            with self.subTest(change=change):
                result = self.verify(self.run_routes(run=dict(good, **change)))
                self.assertEqual((result["status"], result["reason"]), ("refused", "not-a-routine-run"))
                self.assertIsNone(result["receipt"])
        for run, attempt in (("1/../x", "1"), ("101", "0"), ("", "1"), ("101", "a")):
            with self.subTest(run=run, attempt=attempt):
                github = FakeGitHub()
                result = workflow.verify_run(github, run, attempt, self.repo, self.root / "bad")
                self.assertEqual((result["status"], result["reason"]), ("refused", "bad-arguments"))
                self.assertEqual(github.calls, [])

    def test_incomplete_run_is_temporary(self):
        good = self.run_routes()[("GET", f"{self.BASE}/runs/101/attempts/1")][1]
        result = self.verify(self.run_routes(run=dict(good, status="in_progress", conclusion=None)))
        self.assertEqual((result["status"], result["reason"]), ("temporary", "run-incomplete"))
        self.assertIsNone(result["receipt"])

    def test_missing_and_expired_artifacts_are_confirmed_failures(self):
        routes = self.run_routes(artifacts={"artifacts": []})
        self.assertEqual(self.verify(routes)["reason"], "artifact-missing")
        name = workflow.artifact_name("101", "1")
        routes = self.run_routes(artifacts={"artifacts": [{"id": 9, "name": name, "expired": True}]})
        result = self.verify(routes)
        self.assertEqual((result["status"], result["reason"], result["measured"]),
                         ("failure", "artifact-expired", False))

    def test_uncertain_answers_are_temporary(self):
        name = workflow.artifact_name("101", "1")
        endpoints = [f"{self.BASE}/runs/101/attempts/1", f"{self.BASE}/runs/101/attempts/1/jobs?per_page=100&page=1",
                     f"{self.BASE}/runs/101/artifacts?name={name}&per_page=100&page=1", f"{self.BASE}/artifacts/9/zip"]

        def no_reply(_body):
            raise workflow.NoReply("no reply")
        for endpoint in endpoints:
            for answer in ((429, None), (500, None), (502, None), (403, None), (404, None), no_reply):
                with self.subTest(endpoint=endpoint.rsplit("/", 1)[-1], answer=getattr(answer, "__name__", answer)):
                    routes, _ = self.evidence_routes()
                    routes[("GET", endpoint)] = answer
                    result = self.verify(routes)
                    self.assertEqual((result["status"], result["reason"]), ("temporary", "github-unavailable"))
                    self.assertIsNone(result["receipt"])

    def test_incomplete_enumeration_is_temporary(self):
        jobs = {"jobs": [{"name": "sweep", "conclusion": "success"}], "total_count": 3}
        self.assertEqual(self.verify(self.run_routes(jobs=jobs))["status"], "temporary")
        name = workflow.artifact_name("101", "1")
        listing = {"artifacts": [{"id": 9, "name": name, "expired": False}], "total_count": 2}
        routes, _ = self.evidence_routes(artifacts=listing)
        self.assertEqual(self.verify(routes)["status"], "temporary")

    def test_tampered_evidence_is_refused(self):
        def rezip(out, change):
            files = {p.name: p.read_bytes() for p in out.iterdir()}
            change(files)
            return zip_of(files)

        def edit_result(files):
            result = json.loads(files["result.json"])
            result["operations"] = []
            files["result.json"] = (json.dumps(result) + "\n").encode()
            manifest = json.loads(files["manifest.json"])
            manifest["files"]["result.json"] = workflow.sha256(files["result.json"])
            files["manifest.json"] = json.dumps(manifest).encode()

        def edit_list(files):
            listed = json.loads(files["cloud-models.json"])
            listed["models"][0]["recommended"] = True
            files["cloud-models.json"] = propose.encode_list(listed)
            manifest = json.loads(files["manifest.json"])
            manifest["files"]["cloud-models.json"] = workflow.sha256(files["cloud-models.json"])
            files["manifest.json"] = json.dumps(manifest).encode()

        def edit_context(files):
            context = json.loads(files["context.json"])
            context["workflow"] = "Other workflow"
            files["context.json"] = json.dumps(context).encode()
            manifest = json.loads(files["manifest.json"])
            manifest["files"]["context.json"] = workflow.sha256(files["context.json"])
            files["manifest.json"] = json.dumps(manifest).encode()

        def edit_without_manifest(files):
            files["pr-body.md"] = b"edited\n"

        cases = [(edit_result, "evidence-mismatch"), (edit_list, "evidence-mismatch"),
                 (edit_context, "evidence-mismatch"), (edit_without_manifest, "evidence-invalid")]
        for change, reason in cases:
            with self.subTest(change=change.__name__):
                _, out = self.stage()
                routes = self.run_routes(archive=rezip(out, change))
                result = self.verify(routes)
                self.assertEqual((result["status"], result["reason"]), ("refused", reason))
                self.assertIsNone(result["receipt"])

    def test_historical_source_stays_valid_after_main_moves(self):
        routes, _ = self.evidence_routes()
        manual = copy.deepcopy(propose_test.BASE_MODELS)
        manual[0]["recommended"] = True
        propose_test.commit_list(self.repo, propose_test.list_bytes(manual), "later list change")
        head_before = git(self.repo, "rev-parse", "HEAD")
        result = self.verify(routes)
        self.assertEqual(result["status"], "verified")
        self.assertEqual(git(self.repo, "rev-parse", "HEAD"), head_before)
        self.assertEqual(git(self.repo, "status", "--porcelain"), "")

    def test_cli_json_and_exit_contract(self):
        routes, _ = self.evidence_routes()
        good = routes[("GET", f"{self.BASE}/runs/101/attempts/1")][1]
        cases = [(routes, 0, "verified"),
                 ({**routes, ("GET", f"{self.BASE}/runs/101/attempts/1"): (503, {"message": "canary-err-55"})},
                  75, "temporary"),
                 (self.run_routes(run=dict(good, event="push")), 1, "refused"),
                 (self.run_routes(jobs={"jobs": [{"name": "sweep", "conclusion": "failure"}]}), 10, "failure")]
        original = workflow.GitHub
        try:
            for number, (answers, code, status) in enumerate(cases):
                with self.subTest(status=status):
                    workflow.GitHub = lambda token, answers=answers: FakeGitHub(answers)
                    work = self.root / f"cli-{number}"
                    out = io.StringIO()
                    with __import__("contextlib").redirect_stdout(out):
                        exit_code = workflow.main(["verify-run", "--run", "101", "--attempt", "1",
                                                   "--trusted", str(self.repo), "--work", str(work)])
                    self.assertEqual(exit_code, code)
                    printed = json.loads(out.getvalue())
                    self.assertEqual(printed["status"], status)
                    self.assertEqual(printed["schema"], 1)
                    self.assertEqual(json.loads((work / "verify-run.json").read_text()), printed)
                    for canary in ("canary-err-55", "fake-gh-token", *KEYS.values()):
                        self.assertNotIn(canary, out.getvalue())
        finally:
            workflow.GitHub = original

    def jobs(self, publish="success", sweep="success", completed=("2026-11-09T07:40:00Z", "2026-11-09T07:44:10Z")):
        return {"jobs": [{"name": "sweep", "status": "completed", "conclusion": sweep, "completed_at": completed[0]},
                         {"name": "publish", "status": "completed", "conclusion": publish,
                          "completed_at": completed[1]}]}

    def test_publication_failure_with_no_change_keeps_both_outcomes(self):
        routes, _ = self.evidence_routes(self.receipt(build=lambda r: None), jobs=self.jobs(publish="failure"))
        result = self.verify(routes)
        self.assertEqual((result["status"], result["runOutcome"]), ("verified", "failure"))
        self.assertEqual(result["receipt"]["outcome"], "nochange")
        self.assertEqual(result["run"]["publish"], "failure")

    def test_publication_failure_with_a_proposal_is_a_run_failure(self):
        routes, _ = self.evidence_routes(jobs=self.jobs(publish="cancelled"))
        result = self.verify(routes)
        self.assertEqual((result["status"], result["runOutcome"], result["evidence"]["proposal"]),
                         ("verified", "failure", True))
        self.assertEqual(result["receipt"]["outcome"], "success")

    def test_run_conclusion_failure_with_measured_evidence(self):
        routes, _ = self.evidence_routes(jobs=self.jobs())
        run = routes[("GET", f"{self.BASE}/runs/101/attempts/1")][1]
        routes[("GET", f"{self.BASE}/runs/101/attempts/1")] = (200, dict(run, conclusion="failure"))
        result = self.verify(routes)
        self.assertEqual((result["status"], result["runOutcome"], result["measured"]), ("verified", "failure", True))
        healthy, _ = self.evidence_routes(jobs=self.jobs())
        self.assertEqual(self.verify(healthy)["runOutcome"], "success")

    def test_malformed_replies_are_temporary_never_absence(self):
        name = workflow.artifact_name("101", "1")
        good_run = self.run_routes()[("GET", f"{self.BASE}/runs/101/attempts/1")][1]
        cases = {
            "null job": {"jobs": {"jobs": [None], "total_count": 1}},
            "job name not text": {"jobs": {"jobs": [{"name": 5, "conclusion": "success", "status": "completed"}],
                                           "total_count": 1}},
            "conclusion not text": {"jobs": {"jobs": [{"name": "sweep", "conclusion": 1, "status": "completed"}],
                                             "total_count": 1}},
            "count is a boolean": {"jobs": {"jobs": [], "total_count": True}},
            "null artifact": {"artifacts": {"artifacts": [None], "total_count": 1}},
            "artifact id a boolean": {"artifacts": {"artifacts": [{"id": True, "name": name, "expired": False}],
                                                    "total_count": 1}},
            "expired not a boolean": {"artifacts": {"artifacts": [{"id": 9, "name": name, "expired": "no"}],
                                                    "total_count": 1}},
            "artifact name missing": {"artifacts": {"artifacts": [{"id": 9, "expired": False}], "total_count": 1}},
            "run status missing": {"run": {k: v for k, v in good_run.items() if k != "status"}},
            "created_at not text": {"run": dict(good_run, created_at=17)},
        }
        for label, change in cases.items():
            with self.subTest(case=label):
                routes, _ = self.evidence_routes(**change)
                result = self.verify(routes)
                self.assertEqual((result["status"], result["reason"]), ("temporary", "github-malformed"), label)
                self.assertIsNone(result["receipt"])

    def test_completion_time_is_the_attempts_own(self):
        good_run = self.run_routes()[("GET", f"{self.BASE}/runs/101/attempts/1")][1]
        routes, _ = self.evidence_routes(
            jobs=self.jobs(completed=("2026-11-12T10:00:00Z", "2026-11-12T10:05:30Z")),
            run=dict(good_run, created_at="2026-11-09T06:17:03Z"))
        result = self.verify(routes)
        self.assertEqual(result["run"]["createdAt"], "2026-11-09T06:17:03Z")
        self.assertEqual(result["run"]["completedAt"], "2026-11-12T10:05:30Z")

    def test_unknown_completion_time_is_null_not_guessed(self):
        jobs = self.jobs()
        del jobs["jobs"][1]["completed_at"]
        routes, _ = self.evidence_routes(jobs=jobs)
        result = self.verify(routes)
        self.assertEqual(result["status"], "verified")
        self.assertIsNone(result["run"]["completedAt"])
        self.assertNotEqual(result["run"]["completedAt"], result["run"]["createdAt"])

    def test_cli_contract_for_publication_failure_and_malformed_replies(self):
        publication, _ = self.evidence_routes(jobs=self.jobs(publish="failure"))
        malformed = self.run_routes(jobs={"jobs": [None], "total_count": 1})
        original = workflow.GitHub
        try:
            for number, (answers, code, status) in enumerate(((publication, 0, "verified"),
                                                             (malformed, 75, "temporary"))):
                with self.subTest(status=status):
                    fake = FakeGitHub(answers)
                    workflow.GitHub = lambda token, fake=fake: fake
                    out = io.StringIO()
                    with __import__("contextlib").redirect_stdout(out):
                        code_seen = workflow.main(["verify-run", "--run", "101", "--attempt", "1", "--trusted",
                                                   str(self.repo), "--work", str(self.root / f"cli2-{number}")])
                    self.assertEqual(code_seen, code)
                    self.assertEqual(json.loads(out.getvalue())["status"], status)
                    self.assertEqual(fake.writes(), [])
                    for canary in (*KEYS.values(), "fake-gh-token"):
                        self.assertNotIn(canary, out.getvalue())
        finally:
            workflow.GitHub = original

    def test_malformed_identity_fields_and_impossible_times(self):
        good = self.run_routes()[("GET", f"{self.BASE}/runs/101/attempts/1")][1]
        run_cases = {
            "repository is text": {"repository": "bad"}, "repository without name": {"repository": {}},
            "repository name not text": {"repository": {"full_name": 7}}, "event a list": {"event": []},
            "head_sha a number": {"head_sha": 17}, "id as text": {"id": "101"},
            "attempt a boolean": {"run_attempt": True}, "path missing": {"path": None},
            "branch a number": {"head_branch": 5}, "name missing": {"name": None},
            "impossible created_at": {"created_at": "2026-99-99T99:99:99Z"},
            "created_at not canonical": {"created_at": "2026-11-09 06:17:03"},
            "conclusion a number": {"conclusion": 0},
        }
        for label, change in run_cases.items():
            with self.subTest(case=label):
                result = self.verify(self.run_routes(run=dict(good, **change)))
                self.assertEqual((result["status"], result["reason"]), ("temporary", "github-malformed"), label)
        jobs = self.jobs()
        jobs["jobs"][0]["completed_at"] = "2026-02-30T10:00:00Z"
        with self.subTest(case="impossible job completion"):
            self.assertEqual(self.verify(self.run_routes(jobs=jobs))["reason"], "github-malformed")
        # Valid controls: right types with wrong values are refused, right values verify.
        for change in ({"event": "push"}, {"repository": {"full_name": "someone/fork"}}, {"head_sha": "abc"}):
            with self.subTest(control=change):
                self.assertEqual(self.verify(self.run_routes(run=dict(good, **change)))["reason"],
                                 "not-a-routine-run")
        routes, _ = self.evidence_routes(jobs=self.jobs())
        self.assertEqual(self.verify(routes)["status"], "verified")

    def test_cli_contract_for_malformed_identity(self):
        good = self.run_routes()[("GET", f"{self.BASE}/runs/101/attempts/1")][1]
        original = workflow.GitHub
        try:
            for number, change in enumerate(({"repository": "bad"}, {"event": []}, {"head_sha": 17},
                                              {"created_at": "2026-99-99T99:99:99Z"})):
                with self.subTest(change=change):
                    fake = FakeGitHub(self.run_routes(run=dict(good, **change)))
                    workflow.GitHub = lambda token, fake=fake: fake
                    out = io.StringIO()
                    with __import__("contextlib").redirect_stdout(out):
                        code = workflow.main(["verify-run", "--run", "101", "--attempt", "1", "--trusted",
                                              str(self.repo), "--work", str(self.root / f"cli3-{number}")])
                    self.assertEqual(code, 75)
                    printed = json.loads(out.getvalue())
                    self.assertEqual((printed["status"], printed["reason"]), ("temporary", "github-malformed"))
                    self.assertEqual(fake.writes(), [])
                    self.assertNotIn("fake-gh-token", out.getvalue())
        finally:
            workflow.GitHub = original

    def test_pr_check_still_requires_a_successful_sweep(self):
        github = FakeGitHub(self.run_routes(jobs={"jobs": [{"name": "sweep", "conclusion": "failure"}]}))
        self.refused(lambda: workflow.authenticated_run(github, "101", "1"), "sweep did not succeed")


class Canaries(Case):
    def test_a_key_in_the_receipt_is_refused_before_staging(self):
        built = self.receipt()
        built["providers"][0]["candidates"][0]["sourceDate"] = KEYS["TEST_RUNNER_EW_ROUTINE_OPENAI_KEY"]
        path = self.write_receipt(built)
        self.refused(lambda: workflow.finish_sweep(self.env(), PASSING_LOG, path, self.root / "out",
                                                   repo=self.repo), "contains a routine key")
        self.assertFalse((self.root / "out").exists())

    def test_staged_files_carry_no_key_and_a_missing_key_refuses(self):
        _, out = self.stage()
        for path in out.iterdir():
            for key in KEYS.values():
                self.assertNotIn(key.encode(), path.read_bytes(), path.name)
        self.refused(lambda: workflow.secrets_from(dict(KEYS, TEST_RUNNER_EW_ROUTINE_GEMINI_KEY="")),
                     "missing")
        self.refused(lambda: workflow.scan({"pr-body.md": b"x fake-claude-key-82aa"}, list(KEYS.values())),
                     "pr-body.md contains a routine key")


GROUPS = (Events, Scoping, SweepRun, Binding, Artifacts, Publication, Outcomes, Identity,
          HeadAndBase, Ownership, FailureReports, Pagination, Unauthorized, Redirects, VerifyRun,
          Canaries)


def run():
    loader = unittest.TestLoader()
    failures, total = 0, 0
    for group in GROUPS:
        suite = loader.loadTestsFromTestCase(group)
        count = suite.countTestCases()
        stream = io.StringIO()
        outcome = unittest.TextTestRunner(stream=stream, verbosity=0).run(suite)
        bad = len(outcome.failures) + len(outcome.errors)
        if count == 0 or outcome.testsRun != count or outcome.skipped:
            bad += 1
        total += outcome.testsRun
        print(f"{group.__name__}: {outcome.testsRun} of {count} ran, "
              f"{len(outcome.skipped)} skipped, {bad} failed")
        if bad:
            print(stream.getvalue(), file=sys.stderr)
        failures += bad
    if total < 57:
        failures += 1
        print(f"only {total} tests ran; at least 57 are required", file=sys.stderr)
    print(f"self-test: {total} tests,", "PASS" if failures == 0 else f"FAIL ({failures})")
    return 1 if failures else 0
