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
import http.client, json, urllib.request, urllib.error, time, os, argparse
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlsplit

from eg1_shipped_request import build_request_body, parse_success

ap = argparse.ArgumentParser()
ap.add_argument("--prompts", required=True)
ap.add_argument("--provider", required=True, choices=["openai", "gemini", "ollama"])
ap.add_argument("--model", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--workers", type=int, default=8)
# #1271: point the openai provider at an OpenAI-compatible LOCAL server
# (the native EG-1 llama-server) — the shipped (artifact x engine x flags)
# combination is the unit of QA. Localhost endpoints take a dummy key.
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
ap.add_argument(
    "--lora-json",
    default="",
    help=(
        "Optional llama.cpp per-request LoRA list, for example "
        "'[{\"id\":0,\"scale\":1.0}]'. Local OpenAI-compatible endpoints only."
    ),
)
args = ap.parse_args()

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
                response = json.load(
                    urllib.request.urlopen(req, timeout=min(20, remaining))
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

with open(args.out, "w") as f:
    for p in prompts:
        f.write(json.dumps(results[p["id"]]) + "\n")
errs = [r for r in results.values() if r.get("error")]
lats = sorted(r["latencyMs"] for r in results.values() if r.get("latencyMs"))
print(f"DONE {len(results)}/{len(prompts)} in {int(time.time()-t0)}s | errors={len(errs)}")
if lats:
    print(f"latency ms: median={lats[len(lats)//2]} p90={lats[len(lats)*9//10]} max={lats[-1]}")
if errs:
    print("first errors:", [e["error"] for e in errs[:5]])
