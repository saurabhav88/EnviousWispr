#!/usr/bin/env python3
"""Send a rendered prompts file (id, system, user) through a cloud provider and
capture candidates. THINKING/REASONING OFF (founder constraint 2026-07-01):
gpt-4o is non-reasoning (temp 0); gemini uses thinkingConfig.thinkingBudget=0.

Usage (keys bridged via get-key launch):
  get-key launch openai-api-key OPENAI_API_KEY -- \
    python3 subset_polish_runner.py --prompts <f> --provider openai --model gpt-4o --out <c>
  get-key launch gemini-api-key GEMINI_API_KEY -- \
    python3 subset_polish_runner.py --prompts <f> --provider gemini --model gemini-2.5-flash --out <c>
"""
import http.client, json, urllib.request, urllib.error, time, os, argparse, hashlib
from concurrent.futures import ThreadPoolExecutor
import importlib.util
from pathlib import Path
from urllib.parse import urlsplit


_SHIPPED_REQUEST_PATH = Path(__file__).resolve().with_name("eg1_shipped_request.py")
if not _SHIPPED_REQUEST_PATH.is_file() or _SHIPPED_REQUEST_PATH.is_symlink():
    raise SystemExit("exact shipped-request sibling is unavailable")
_SHIPPED_SPEC = importlib.util.spec_from_file_location(
    "_subset_polish_runner_shipped_request", _SHIPPED_REQUEST_PATH
)
if _SHIPPED_SPEC is None or _SHIPPED_SPEC.loader is None:
    raise SystemExit("cannot load exact shipped-request sibling")
_SHIPPED_MODULE = importlib.util.module_from_spec(_SHIPPED_SPEC)
_SHIPPED_SPEC.loader.exec_module(_SHIPPED_MODULE)
build_request_body = _SHIPPED_MODULE.build_request_body
parse_success = _SHIPPED_MODULE.parse_success

ap = argparse.ArgumentParser()
ap.add_argument("--prompts", required=True)
ap.add_argument("--provider", required=True, choices=["openai", "gemini", "ollama"])
ap.add_argument("--model", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--workers", type=int, default=8)
# #1271: point the openai provider at an OpenAI-compatible LOCAL server
# (the native EG-1 llama-server) — the shipped (artifact x engine x flags)
# combination is the unit of QA. Standalone localhost servers may take a dummy
# key; the shipped app uses a per-launch credential. Use eg1_local_app_eval.py
# for app-owned servers so that credential never appears in shell history.
ap.add_argument("--endpoint", default="https://api.openai.com/v1/chat/completions")
# gpt-5.1+ reasoning models reject a non-default temperature but accept
# reasoning_effort ("none" = thinking off, verified against developers.openai.com
# 2026-05-19 per run_provider_bench.py). Non-reasoning models (gpt-4o*) leave
# this unset and keep the existing temperature=0 determinism pin.
ap.add_argument("--reasoning-effort", default=None)
ap.add_argument(
    "--eg1-shipped-request",
    action="store_true",
    help=(
        "Mirror EGOneConnector request, timeout, transport retry, truncation, and "
        "output-cleanup rules. Restricted to the local OpenAI-compatible endpoint."
    ),
)
ap.add_argument("--eg1-swift-launcher")
ap.add_argument("--eg1-swift-launcher-path-sha256")
ap.add_argument("--eg1-swift-executable")
ap.add_argument("--eg1-swift-executable-path-sha256")
ap.add_argument("--eg1-swift-executable-sha256")
ap.add_argument("--eg1-swift-developer-dir")
ap.add_argument("--eg1-swift-environment-sha256")
ap.add_argument(
    "--lora-json",
    default="",
    help=(
        "Optional llama.cpp per-request LoRA list, for example "
        "'[{\"id\":0,\"scale\":1.0}]'. Local OpenAI-compatible endpoints only."
    ),
)
args = ap.parse_args()


def configure_exact_swift_runtime():
    values = (
        args.eg1_swift_launcher,
        args.eg1_swift_launcher_path_sha256,
        args.eg1_swift_executable,
        args.eg1_swift_executable_path_sha256,
        args.eg1_swift_executable_sha256,
        args.eg1_swift_developer_dir,
        args.eg1_swift_environment_sha256,
    )
    if not args.eg1_shipped_request:
        if any(value is not None for value in values):
            raise SystemExit("EG-1 Swift runtime arguments require exact shipped mode")
        return
    if any(not value for value in values):
        raise SystemExit("exact shipped mode requires a pinned Swift runtime contract")

    swift_environment = {
        "HOME": "/tmp",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": "/tmp",
    }
    developer_dir = args.eg1_swift_developer_dir
    if developer_dir != "none":
        try:
            developer_path = Path(developer_dir).resolve(strict=True)
        except OSError as error:
            raise SystemExit("pinned Swift DEVELOPER_DIR is unavailable") from error
        if str(developer_path) != developer_dir or not developer_path.is_dir():
            raise SystemExit("pinned Swift DEVELOPER_DIR is invalid")
        swift_environment["DEVELOPER_DIR"] = developer_dir

    observed_environment = {
        key: os.environ.get(key) for key in swift_environment
    }
    if observed_environment != swift_environment or (
        developer_dir == "none" and "DEVELOPER_DIR" in os.environ
    ):
        raise SystemExit("exact shipped mode Swift environment differs from the pin")
    environment_sha = hashlib.sha256(
        json.dumps(
            swift_environment,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    if environment_sha != args.eg1_swift_environment_sha256:
        raise SystemExit("exact shipped mode Swift environment hash differs from the pin")
    try:
        swift_launcher = Path(args.eg1_swift_launcher)
        swift_executable = Path(args.eg1_swift_executable).resolve(strict=True)
        if (
            not swift_launcher.is_absolute()
            or str(swift_launcher) != args.eg1_swift_launcher
            or str(swift_executable) != args.eg1_swift_executable
            or hashlib.sha256(str(swift_launcher).encode("utf-8")).hexdigest()
            != args.eg1_swift_launcher_path_sha256
            or hashlib.sha256(str(swift_executable).encode("utf-8")).hexdigest()
            != args.eg1_swift_executable_path_sha256
        ):
            raise ValueError("pinned Swift runtime path identity differs")
        _SHIPPED_MODULE.configure_swift_count_executable(
            swift_launcher,
            swift_executable,
            args.eg1_swift_executable_sha256,
            swift_environment,
        )
    except (OSError, ValueError) as error:
        raise SystemExit("exact shipped mode Swift runtime differs from the pin") from error


configure_exact_swift_runtime()

endpoint_parts = urlsplit(args.endpoint)
is_local_openai_endpoint = (
    args.provider == "openai"
    and endpoint_parts.scheme == "http"
    and endpoint_parts.hostname == "127.0.0.1"
    and endpoint_parts.username is None
    and endpoint_parts.password is None
)

if args.eg1_shipped_request:
    if not is_local_openai_endpoint:
        raise SystemExit("--eg1-shipped-request requires a local OpenAI-compatible endpoint")
    if args.reasoning_effort is not None or args.lora_json:
        raise SystemExit("--eg1-shipped-request cannot be combined with reasoning or LoRA overrides")

lora_config = None
if args.lora_json:
    if not is_local_openai_endpoint:
        raise SystemExit("--lora-json is restricted to a local OpenAI-compatible endpoint")
    lora_config = json.loads(args.lora_json)
    if not isinstance(lora_config, list) or any(
        not isinstance(item, dict)
        or not isinstance(item.get("id"), int)
        or not isinstance(item.get("scale"), (int, float))
        for item in lora_config
    ):
        raise SystemExit('--lora-json must be a list of {"id": int, "scale": number}')

if is_local_openai_endpoint:
    # Local single-user latency must be measured single-stream, same rule
    # as the ollama branch below.
    args.workers = 1

if args.provider == "ollama":
    # Local single-user latency must be measured single-stream
    # (ollama-operations.md RULE: benchmark-ollama-must-match-production).
    args.workers = 1

prompts = [json.loads(l) for l in open(args.prompts) if l.strip()]
prompt_ids = [prompt.get("id") if isinstance(prompt, dict) else None for prompt in prompts]
if any(not isinstance(prompt_id, str) or not prompt_id for prompt_id in prompt_ids):
    raise SystemExit("every prompt must have a nonempty string id")
if len(prompt_ids) != len(set(prompt_ids)):
    raise SystemExit("duplicate prompt id; refusing to dispatch corrupted evidence")
exact_local_opener = (
    urllib.request.build_opener(urllib.request.ProxyHandler({}))
    if args.eg1_shipped_request
    else None
)

def retryable_eg1_transport_error(error):
    reason = error.reason if isinstance(error, urllib.error.URLError) else error
    return isinstance(
        reason,
        (
            ConnectionRefusedError,
            ConnectionResetError,
            ConnectionAbortedError,
            BrokenPipeError,
            http.client.IncompleteRead,
            http.client.RemoteDisconnected,
        ),
    )

def call_openai(system, user, max_tokens=None):
    key = os.environ.get("OPENAI_API_KEY", "local")
    if args.eg1_shipped_request:
        payload = build_request_body(
            model=args.model, system=system, user=user, max_tokens=max_tokens
        )
    else:
        payload = {
            "model": args.model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        }
        if args.reasoning_effort is None:
            payload["temperature"] = 0  # non-reasoning model; thinking N/A
        else:
            payload["reasoning_effort"] = args.reasoning_effort  # reasoning model, temperature omitted (default-only)
        if lora_config is not None:
            payload["lora"] = lora_config
    body = json.dumps(payload).encode()
    req = urllib.request.Request(args.endpoint, data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    if args.eg1_shipped_request:
        logical_deadline = time.monotonic() + 15
        last_transport_error = None
        for transport_attempt in range(2):
            if transport_attempt:
                if logical_deadline - time.monotonic() <= 0.75:
                    raise TimeoutError("eg1_pipeline_timeout")
                time.sleep(0.75)
            remaining = logical_deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("eg1_pipeline_timeout")
            try:
                if exact_local_opener is None:
                    raise RuntimeError("missing proxy-disabled EG-1 opener")
                response = json.load(
                    exact_local_opener.open(req, timeout=min(20, remaining))
                )
                content, finish_reason = parse_success(response)
                if time.monotonic() > logical_deadline:
                    raise TimeoutError("eg1_pipeline_timeout")
                return content, transport_attempt + 1, finish_reason
            except urllib.error.HTTPError:
                raise
            except (urllib.error.URLError, ConnectionError, http.client.IncompleteRead) as error:
                if not retryable_eg1_transport_error(error):
                    raise
                last_transport_error = error
        raise last_transport_error or RuntimeError("eg1_transport_failed")
    response = json.load(urllib.request.urlopen(req, timeout=120))
    choice = response["choices"][0]
    return choice["message"]["content"].strip(), 1, choice.get("finish_reason")

def call_gemini(system, user, max_tokens=None):
    _ = max_tokens
    key = os.environ["GEMINI_API_KEY"]
    body = json.dumps({
        "systemInstruction": {"parts": [{"text": system}]},
        "contents": [{"role": "user", "parts": [{"text": user}]}],
        "generationConfig": {"temperature": 0, "thinkingConfig": {"thinkingBudget": 0}},  # THINKING OFF
    }).encode()
    url = (f"https://generativelanguage.googleapis.com/v1beta/models/{args.model}:generateContent?key={key}")
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=120))
    parts = r["candidates"][0]["content"]["parts"]
    return "".join(p.get("text", "") for p in parts).strip(), 1, None

def call_ollama(system, user, max_tokens=None):
    _ = max_tokens
    # #1265 vanilla-baseline config. DELIBERATE deviation from the shipped
    # connector (which OMITS `think`, letting gemma4 reason for ~6-8s): we send
    # think:false because the artifact this bake-off scopes is a NON-thinking
    # tuned model, and the vanilla ceiling must be measured in that regime.
    # Worked cleanly on Ollama 0.30.x (2026-06-23 teardown bench); every run
    # spot-checks the first outputs for leaked reasoning before trusting scores.
    # num_predict 2048 = the thinking-capable floor (#272) so a stray reasoning
    # burst can't starve the answer; temperature 0 mirrors the cloud cells.
    body = json.dumps({
        "model": args.model,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "stream": False,
        "think": False,
        "keep_alive": "60m",
        "options": {"temperature": 0, "num_predict": 2048},
    }).encode()
    req = urllib.request.Request("http://localhost:11434/api/chat", data=body,
        headers={"Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=180))
    msg = r.get("message", {})
    thinking = msg.get("thinking") or ""
    content = (msg.get("content") or "").strip()
    if not content:
        raise RuntimeError(f"empty content (done_reason={r.get('done_reason')}, thinking_chars={len(thinking)})")
    return content, 1, r.get("done_reason")

call = {"openai": call_openai, "gemini": call_gemini, "ollama": call_ollama}[args.provider]

if args.provider == "ollama":
    # Warm the model so case 1's latency is not a cold load.
    try:
        call("You are a helpful assistant.", "ok", None)
        print(f"warmed {args.model}", flush=True)
    except Exception as e:
        print(f"WARM-UP FAILED for {args.model}: {e}", flush=True)
        raise SystemExit(2)

def ask(p):
    # Generic-mode latencyMs preserves the historical successful-attempt-only
    # metric. Exact EG-1 mode instead measures the complete connector call,
    # including its one possible failure and 750 ms retry wait, so it reflects
    # user-visible wall time inside the 15-second logical budget.
    if args.eg1_shipped_request:
        try:
            t0 = time.time()
            cand, attempts, finish_reason = call(
                p["system"], p["user"], p.get("max_tokens")
            )
            result = {
                "id": p["id"],
                "candidate": cand,
                "latencyMs": int((time.time() - t0) * 1000),
                "attempts": attempts,
            }
            if finish_reason is not None:
                result["finishReason"] = finish_reason
            return result
        except Exception as e:
            return {
                "id": p["id"],
                "candidate": "",
                "latencyMs": 0,
                "error": str(e)[:150],
            }

    last = "unknown"
    for attempt in range(6):
        try:
            t0 = time.time()
            cand, _, finish_reason = call(p["system"], p["user"], p.get("max_tokens"))
            result = {"id": p["id"], "candidate": cand, "latencyMs": int((time.time() - t0) * 1000),
                    "attempts": attempt + 1}
            return result
        except urllib.error.HTTPError as e:
            last = f"HTTP{e.code}:{e.read().decode()[:120]}"
            if e.code == 429 or e.code >= 500:
                time.sleep(min(2 ** attempt, 20)); continue
            time.sleep(2)
        except Exception as e:
            last = str(e)[:150]; time.sleep(2)
    return {"id": p["id"], "candidate": "", "latencyMs": 0, "error": last}

t0 = time.time(); results = {}; done = 0
with ThreadPoolExecutor(max_workers=args.workers) as ex:
    for res in ex.map(ask, prompts):
        results[res["id"]] = res; done += 1
        if done % 100 == 0:
            print(f"  {done}/{len(prompts)} ({int(time.time()-t0)}s)", flush=True)

with open(args.out, "x") as f:
    for p in prompts:
        f.write(json.dumps(results[p["id"]]) + "\n")
errs = [r for r in results.values() if r.get("error")]
lats = sorted(r["latencyMs"] for r in results.values() if r.get("latencyMs"))
print(f"DONE {len(results)}/{len(prompts)} in {int(time.time()-t0)}s | errors={len(errs)}")
if lats:
    print(f"latency ms: median={lats[len(lats)//2]} p90={lats[len(lats)*9//10]} max={lats[-1]}")
if errs:
    print("first errors:", [e["error"] for e in errs[:5]])
    raise SystemExit(2)
