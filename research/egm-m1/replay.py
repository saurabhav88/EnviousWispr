"""EG-M step 1 (#4443), research only: start the repo's llama-server on a GitHub-hosted macOS M1 runner
(7 GB), replay recorded shipping-summary requests, and record completion, latency and memory.
The requests were recorded on an M5 Max from SummaryBench (shipping MeetingSummary.write, prompt v5) for
AMI IS1001a (15 min) and the joined 131-min TS3006b+c+d meeting. Not part of the app.

Memory is sampled from server launch through startup, replay and shutdown. A measurement that could not be
read is null, never 0. Swap is system-wide: baseline at launch and peak increase. result.json is rewritten
after every call and every 10 s. Exit 1 if the server never became healthy, any call failed, or the overall
deadline passed (a watchdog stops the server at the deadline, even mid-call); a call cut at its token limit is reported as finish=length (not a failure of the run).
Usage: replay.py <server binary> <model.gguf> <requests.jsonl> <out.json> [deadline seconds]"""
import json, subprocess, sys, threading, time, urllib.request

SERVER, MODEL, REQ, OUT = sys.argv[1:5]
DEADLINE = time.time() + (int(sys.argv[5]) if len(sys.argv) > 5 else 4200)
PORT = 18440
state = {'status': 'starting', 'calls': [], 'health_seconds': None,
         'peak': {'footprint_mb': None, 'rss_mb': None, 'swap_used_mb_baseline': None, 'swap_used_mb_peak_increase': None},
         'samples': 0, 'sample_errors': 0, 'last_sample_error': None}
lock = threading.Lock()


def save():
    with lock:
        state['total_seconds'] = round(sum(c['seconds'] for c in state['calls']), 1)
        with open(OUT, 'w') as f: json.dump(state, f, indent=1)


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    if r.returncode != 0: raise RuntimeError(f'{cmd[0]} exit {r.returncode}: {r.stderr[:120]}')
    return r.stdout


def to_mb(value, unit):
    return float(value) * {'K': 1 / 1024, 'KB': 1 / 1024, 'M': 1, 'MB': 1, 'G': 1024, 'GB': 1024}[unit]


def swap_used():
    used = run(['sysctl', '-n', 'vm.swapusage']).split('used = ')[1].split()[0]
    return to_mb(used[:-1], used[-1])


def bump(key, value):
    if value is not None and (state['peak'][key] is None or value > state['peak'][key]): state['peak'][key] = value


def sample(proc, stop):
    last_save = 0
    while not stop.is_set() and proc.poll() is None:
        ok = True
        try:
            line = next(l for l in run(['footprint', '-p', str(proc.pid)]).splitlines() if 'phys_footprint:' in l)
            v, u = line.split('phys_footprint:')[1].split()[:2]
            fp = to_mb(v, u)
        except Exception as e:
            fp, ok = None, False; state['last_sample_error'] = repr(e)[:200]
        try: rss = int(run(['ps', '-o', 'rss=', '-p', str(proc.pid)]).strip()) / 1024
        except Exception as e: rss, ok = None, False; state['last_sample_error'] = repr(e)[:200]
        try:
            base = state['peak']['swap_used_mb_baseline']
            inc = swap_used() - base if base is not None else None
        except Exception as e: inc, ok = None, False; state['last_sample_error'] = repr(e)[:200]
        with lock:
            bump('footprint_mb', fp); bump('rss_mb', rss); bump('swap_used_mb_peak_increase', inc)
            state['samples'] += 1; state['sample_errors'] += 0 if ok else 1
        if time.time() - last_save > 10: save(); last_save = time.time()
        time.sleep(1)


def stop_server(proc):
    """Bounded shutdown: terminate, wait 20 s, then kill and wait again."""
    if proc is None or proc.poll() is not None: return
    proc.terminate()
    try: proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill()
        try: proc.wait(timeout=20)
        except subprocess.TimeoutExpired: pass


proc, sampler, failed = None, None, False
stop, deadline_hit = threading.Event(), threading.Event()


def watchdog():
    # The overall deadline is enforced even inside a running call: bounded shutdown ends the call.
    while proc.poll() is None:
        if time.time() > DEADLINE:
            deadline_hit.set(); stop_server(proc); return
        time.sleep(1)


try:
    save()  # initial state on disk before anything can fail
    try:
        state['peak']['swap_used_mb_baseline'] = swap_used(); state['peak']['swap_used_mb_peak_increase'] = 0.0
    except Exception as e:
        state['sample_errors'] += 1; state['last_sample_error'] = repr(e)[:200]
    requests = [json.loads(line) for line in open(REQ) if line.strip()]  # parse up front: bad input fails before launch
    proc = subprocess.Popen([SERVER, '-m', MODEL, '-c', '16384', '-fa', 'on', '--cache-type-k', 'q8_0', '--cache-type-v', 'q8_0',
                             '--jinja', '-np', '1', '--host', '127.0.0.1', '--port', str(PORT)],
                            stdout=open('server.log', 'w'), stderr=subprocess.STDOUT)
    sampler = threading.Thread(target=sample, args=(proc, stop), daemon=True)
    sampler.start()
    threading.Thread(target=watchdog, daemon=True).start()
    t0 = time.time()
    while time.time() - t0 < 240 and proc.poll() is None:
        try:
            urllib.request.urlopen(f'http://127.0.0.1:{PORT}/health', timeout=5).read(); state['health_seconds'] = round(time.time() - t0, 1); break
        except Exception: time.sleep(2)
    if state['health_seconds'] is None:
        state['status'] = f'server never healthy (exit code {proc.poll()})'; failed = True
    else:
        state['status'] = 'replaying'
        for i, body in enumerate(requests):
            if time.time() > DEADLINE:
                state['status'] = f'deadline passed before call {i + 1}'; failed = True; break
            t = time.time()
            try:
                req = urllib.request.Request(f'http://127.0.0.1:{PORT}/v1/chat/completions', json.dumps(body).encode(),
                                             {'Content-Type': 'application/json'})
                with urllib.request.urlopen(req, timeout=max(1, DEADLINE - time.time())) as r: j = json.loads(r.read())
                ch = j['choices'][0]
                call = {'seconds': round(time.time() - t, 1), 'finish': ch.get('finish_reason'), 'usage': j.get('usage'),
                        'answer_chars': len(ch['message']['content'] or '')}
            except Exception as e:
                call = {'seconds': round(time.time() - t, 1), 'error': repr(e)[:300]}; failed = True
            with lock: state['calls'].append(call)
            save(); print(call, flush=True)
        else:
            state['status'] = 'finished'
except Exception as e:
    state['status'] = f'unexpected error: {e!r}'[:300]; failed = True
finally:
    if deadline_hit.is_set() or time.time() > DEADLINE:
        state['status'] = 'deadline passed'; failed = True
    stop_server(proc)
    stop.set()
    if sampler is not None: sampler.join(timeout=40)
    save()
    print(json.dumps({k: state.get(k) for k in ('status', 'health_seconds', 'peak', 'samples', 'sample_errors', 'total_seconds')}))
sys.exit(1 if failed else 0)
