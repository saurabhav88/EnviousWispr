#!/usr/bin/env python3
"""Run one command as the Stage 2 writer App (#4353 PR 5, workers/cloud-models-routine/README.md).

    python3 -I scripts/cloud-models/app_token.py exec -- gh api repos/saurabhav88/EnviousWispr/...
    python3 -I scripts/cloud-models/app_token.py --self-test

`exec` mints a short-lived installation token for this repository only and runs the command
with it in GH_TOKEN. The token is never printed and never written to disk. It needs:
- STAGE2_APP_ID: the Stage 2 App's numeric ID
- STAGE2_APP_PRIVATE_KEY: that App's PEM private key (the text, not a path)
- `openssl` on PATH (it signs the App's JWT; Python has no RSA signer in its standard library)

Every failure exits 2 with a one-line reason and no response body, so nothing GitHub returns
reaches the transcript.
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

API = "https://api.github.com"
OWNER = "saurabhav88"
NAME = "EnviousWispr"


class Refused(Exception):
    pass


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def app_jwt(app_id, pem, now=None):
    """RS256 JWT for the App, valid for 9 minutes (GitHub allows at most 10), backdated 60 s."""
    now = int(time.time()) if now is None else now
    head = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    body = b64url(json.dumps({"iat": now - 60, "exp": now + 540, "iss": str(app_id)}).encode())
    signing = f"{head}.{body}".encode()
    fd, path = tempfile.mkstemp(prefix="stage2-key-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(pem)
        result = subprocess.run(["openssl", "dgst", "-sha256", "-sign", path], input=signing,
                                capture_output=True)
    finally:
        os.unlink(path)
    if result.returncode != 0 or not result.stdout:
        raise Refused("openssl could not sign with STAGE2_APP_PRIVATE_KEY")
    return f"{head}.{body}.{b64url(result.stdout)}"


def request(api, method, path, bearer, body=None):
    req = urllib.request.Request(api + path, method=method,
                                 data=None if body is None else json.dumps(body).encode())
    req.add_header("Authorization", f"Bearer {bearer}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "EnviousWispr-cloud-model-stage2")
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            return res.status, json.loads(res.read() or b"null")
    except urllib.error.HTTPError as error:
        return error.code, None
    except (urllib.error.URLError, TimeoutError, ValueError):
        return None, None


def installation_token(app_id, pem, api=API):
    jwt = app_jwt(app_id, pem)
    status, inst = request(api, "GET", f"/repos/{OWNER}/{NAME}/installation", jwt)
    if status != 200 or not isinstance(inst, dict) or not isinstance(inst.get("id"), int):
        raise Refused(f"the App is not installed on {OWNER}/{NAME} (HTTP {status})")
    status, tok = request(api, "POST", f"/app/installations/{inst['id']}/access_tokens", jwt,
                          {"repositories": [NAME]})
    if status != 201 or not isinstance(tok, dict) or not isinstance(tok.get("token"), str):
        raise Refused(f"GitHub refused the installation token (HTTP {status})")
    repos = [r.get("full_name") for r in tok.get("repositories") or []]
    if repos != [f"{OWNER}/{NAME}"]:
        raise Refused("the installation token is not scoped to this repository alone")
    return tok["token"]


def run_exec(argv, environ, api=API, execvpe=os.execvpe):
    if not argv:
        raise Refused("exec needs a command after --")
    app_id = environ.get("STAGE2_APP_ID", "")
    pem = environ.get("STAGE2_APP_PRIVATE_KEY", "")
    if not app_id.isdigit():
        raise Refused("STAGE2_APP_ID is not set to a numeric App ID")
    if "PRIVATE KEY-----" not in pem:
        raise Refused("STAGE2_APP_PRIVATE_KEY is not set to a PEM private key")
    token = installation_token(app_id, pem, api)
    env = {k: v for k, v in environ.items() if k != "STAGE2_APP_PRIVATE_KEY"}
    env["GH_TOKEN"] = token
    env.pop("GITHUB_TOKEN", None)
    execvpe(argv[0], argv, env)


def main(argv):
    if argv == ["--self-test"]:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import app_token_test
        return app_token_test.run()
    if argv[:2] != ["exec", "--"]:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 1
    try:
        run_exec(argv[2:], dict(os.environ))
    except Refused as reason:
        print(f"app_token: refused: {reason}", file=sys.stderr)
        return 2
    except OSError as error:
        print(f"app_token: could not run the command ({error.strerror})", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
