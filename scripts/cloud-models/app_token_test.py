"""Tests for app_token.py (#4353 PR 5). Run through `app_token.py --self-test`.

A throwaway RSA key and a fake GitHub on 127.0.0.1 stand in for the App and the API. No network
beyond loopback, no real key, no GitHub calls.
"""

import base64
import contextlib
import io
import json
import os
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

import app_token

FAKE_TOKEN = "ghs_FAKEcanaryTOKEN0123456789"


def make_key(folder):
    path = os.path.join(folder, "key.pem")
    subprocess.run(["openssl", "genrsa", "-out", path, "2048"], check=True, capture_output=True)
    with open(path) as handle:
        return path, handle.read()


def unb64(part):
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


class FakeGitHub:
    """Answers the two App calls. `repos` is what the token reply says it covers."""

    def __init__(self, installed=True, repos=("saurabhav88/EnviousWispr",), token_status=201):
        self.calls = []
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, status, body):
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                fake.calls.append(("GET", self.path, self.headers.get("Authorization"), None))
                if self.path == "/repos/saurabhav88/EnviousWispr/installation" and installed:
                    self.reply(200, {"id": 42})
                else:
                    self.reply(404, {"message": "Not Found SECRET-BODY"})

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length) or b"null")
                fake.calls.append(("POST", self.path, self.headers.get("Authorization"), body))
                if self.path == "/app/installations/42/access_tokens" and token_status == 201:
                    self.reply(201, {"token": FAKE_TOKEN,
                                     "repositories": [{"full_name": r} for r in repos]})
                else:
                    self.reply(token_status, {"message": "SECRET-BODY"})

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.api = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()


class AppTokenTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.mkdtemp(prefix="app-token-test-")
        cls.key_path, cls.pem = make_key(cls.folder)
        pub = os.path.join(cls.folder, "pub.pem")
        subprocess.run(["openssl", "rsa", "-in", cls.key_path, "-pubout", "-out", pub],
                       check=True, capture_output=True)
        cls.pub = pub

    def env(self, **extra):
        env = {"STAGE2_APP_ID": "5620215", "STAGE2_APP_PRIVATE_KEY": self.pem, "PATH": os.environ["PATH"],
               "GITHUB_TOKEN": "inherited-token"}
        env.update(extra)
        return env

    def test_jwt_is_signed_by_the_key_and_carries_the_app_claims(self):
        jwt = app_token.app_jwt("5620215", self.pem, now=1_800_000_000)
        head, body, sig = jwt.split(".")
        self.assertEqual(json.loads(unb64(head)), {"alg": "RS256", "typ": "JWT"})
        self.assertEqual(json.loads(unb64(body)), {"iat": 1_800_000_000 - 60, "exp": 1_800_000_000 + 540,
                                                   "iss": "5620215"})
        sig_path = os.path.join(self.folder, "sig.bin")
        with open(sig_path, "wb") as handle:
            handle.write(unb64(sig))
        verify = subprocess.run(["openssl", "dgst", "-sha256", "-verify", self.pub, "-signature", sig_path],
                                input=f"{head}.{body}".encode(), capture_output=True)
        self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)

    def test_signing_leaves_no_key_file_behind(self):
        before = set(os.listdir(tempfile.gettempdir()))
        app_token.app_jwt("1", self.pem)
        leftovers = [n for n in set(os.listdir(tempfile.gettempdir())) - before if n.startswith("stage2-key-")]
        self.assertEqual(leftovers, [])

    def test_a_bad_key_is_refused_without_echoing_it(self):
        with self.assertRaises(app_token.Refused) as caught:
            app_token.app_jwt("1", "-----BEGIN PRIVATE KEY-----\nnot a key\n-----END PRIVATE KEY-----\n")
        self.assertNotIn("not a key", str(caught.exception))

    def test_exec_runs_the_command_with_a_repo_scoped_token_and_no_key(self):
        ran = {}
        with FakeGitHub() as gh:
            app_token.run_exec(["gh", "api", "user"], self.env(), api=gh.api,
                               execvpe=lambda f, a, e: ran.update(file=f, argv=a, env=e))
        self.assertEqual(ran["file"], "gh")
        self.assertEqual(ran["argv"], ["gh", "api", "user"])
        self.assertEqual(ran["env"]["GH_TOKEN"], FAKE_TOKEN)
        self.assertNotIn("STAGE2_APP_PRIVATE_KEY", ran["env"])
        self.assertNotIn("GITHUB_TOKEN", ran["env"])
        self.assertEqual([(m, p) for m, p, _, _ in gh.calls],
                         [("GET", "/repos/saurabhav88/EnviousWispr/installation"),
                          ("POST", "/app/installations/42/access_tokens")])
        self.assertEqual(gh.calls[1][3], {"repositories": ["EnviousWispr"]})
        for _, _, auth, _ in gh.calls:
            self.assertTrue(auth.startswith("Bearer ") and auth.count(".") == 2, auth)

    def test_a_token_that_covers_more_than_this_repo_is_refused(self):
        for repos in [("saurabhav88/EnviousWispr", "saurabhav88/other"), (), ("saurabhav88/other",)]:
            with self.subTest(repos=repos), FakeGitHub(repos=repos) as gh:
                with self.assertRaises(app_token.Refused):
                    app_token.run_exec(["true"], self.env(), api=gh.api, execvpe=self.fail_exec)

    def test_github_refusals_stop_before_the_command_and_hide_the_body(self):
        for fake in [dict(installed=False), dict(token_status=403), dict(token_status=500)]:
            with self.subTest(fake=fake), FakeGitHub(**fake) as gh:
                with self.assertRaises(app_token.Refused) as caught:
                    app_token.run_exec(["true"], self.env(), api=gh.api, execvpe=self.fail_exec)
                self.assertNotIn("SECRET-BODY", str(caught.exception))

    def test_unreachable_github_is_refused(self):
        with self.assertRaises(app_token.Refused):
            app_token.run_exec(["true"], self.env(), api="http://127.0.0.1:9", execvpe=self.fail_exec)

    def test_missing_or_malformed_settings_are_refused(self):
        cases = [dict(STAGE2_APP_ID=""), dict(STAGE2_APP_ID="abc"), dict(STAGE2_APP_PRIVATE_KEY=""),
                 dict(STAGE2_APP_PRIVATE_KEY="not a pem")]
        for extra in cases:
            with self.subTest(extra=extra), self.assertRaises(app_token.Refused):
                app_token.run_exec(["true"], self.env(**extra), api="http://127.0.0.1:9", execvpe=self.fail_exec)
        with self.assertRaises(app_token.Refused):
            app_token.run_exec([], self.env(), api="http://127.0.0.1:9", execvpe=self.fail_exec)

    def test_main_reports_a_refusal_as_exit_2_without_the_token_or_key(self):
        err, out = io.StringIO(), io.StringIO()
        saved = dict(os.environ)
        try:
            os.environ.update(self.env(STAGE2_APP_ID=""))
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
                code = app_token.main(["exec", "--", "true"])
        finally:
            os.environ.clear()
            os.environ.update(saved)
        self.assertEqual(code, 2)
        self.assertEqual(out.getvalue(), "")
        self.assertIn("app_token: refused:", err.getvalue())
        self.assertNotIn("PRIVATE KEY", err.getvalue())

    def test_main_without_exec_prints_usage_and_exits_1(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(app_token.main(["exec", "gh"]), 1)
        self.assertIn("app_token.py exec --", err.getvalue())

    def fail_exec(self, *args):
        self.fail("the command must not run")


def run():
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(AppTokenTests)
    result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(suite)
    ran, skipped = result.testsRun, len(result.skipped)
    failed = len(result.failures) + len(result.errors)
    print(f"AppToken: {ran} of {suite.countTestCases()} ran, {skipped} skipped, {failed} failed")
    for test, trace in result.failures + result.errors:
        print(f"FAIL {test.id()}\n{trace}")
    ok = failed == 0 and skipped == 0 and ran >= 10
    print(f"self-test: {ran} tests, {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1
