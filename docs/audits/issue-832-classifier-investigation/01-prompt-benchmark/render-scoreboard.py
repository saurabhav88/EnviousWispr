#!/usr/bin/env python3
"""Render the AFM prompt benchmark scoreboard — judged by Codex, one arm at a time.
Reads corpus + run files + codex-judgments/arm*.json. Re-run to refresh."""
import json, html, os
BASE = "/tmp/afm-prompts"

ARMS = [
    ("prod", "Prod", "Production pipeline (router + filter + fallback)", "runProd.jsonl"),
    ("prodelite", "ProdEL", "Prod-E-Lite (1 prompt, prod shell)", "runProdELite.jsonl"),
    ("poc", "POC", "Deterministic cleaner POC (no AFM, no model)", "runPOC.jsonl"),
    ("armA", "A", "Current prompt, raw (v30)", "runA-current.jsonl"),
    ("armB", "B", "Candidate v2 (Gemini)", "runB-candidate.jsonl"),
    ("armC", "C", "Token-Isolation (Gemini)", "runC-token-isolation.jsonl"),
    ("armD", "D", "Imperative-Matrix (Gemini)", "runD-imperative-matrix.jsonl"),
    ("armE", "E", "v32-Single (ChatGPT)", "runE-v32-single.jsonl"),
    ("armF", "F", "Typography Compiler", "runF-compiler.jsonl"),
]

corpus = [json.loads(l) for l in open(f"{BASE}/corpus-315.jsonl") if l.strip()]
bycat = {}
for c in corpus:
    bycat.setdefault(c["category"], []).append(c)
CATS = list(bycat.keys())

# load whichever per-arm Codex judgment files exist
judg = {}
for key, letter, name, fname in ARMS:
    jp = f"{BASE}/codex-judgments/{key}.json"
    if os.path.exists(jp):
        try:
            d = json.load(open(jp))
            judg[key] = d.get(key, d)  # tolerate {"armX": {...}} or bare {...}
        except Exception:
            pass

runs = {}
for key, letter, name, fname in ARMS:
    p = f"{BASE}/{fname}"
    if os.path.exists(p):
        d = {}
        for l in open(p):
            if l.strip():
                o = json.loads(l)
                d[o["id"]] = o
        runs[key] = d if len(d) == 315 else None
    else:
        runs[key] = None

esc = html.escape
parts = []
parts.append("""<!doctype html><html><head><meta charset="utf-8">
<title>AFM Prompt Benchmark — judged by Codex</title><style>
:root{color-scheme:light}
body{font:13px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;margin:0;background:#f6f7f9;color:#1a1d21}
header{background:#1a1d21;color:#fff;padding:20px 30px}
header h1{margin:0 0 4px;font-size:18px}
header p{margin:0;color:#9aa3ad;font-size:12px}
.wrap{padding:24px 30px}
h2{font-size:15px;margin:26px 0 8px}
table{border-collapse:collapse;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.07);font-variant-numeric:tabular-nums}
.summary td,.summary th{padding:7px 11px;border:1px solid #e2e5e9;text-align:center}
.summary th{background:#eef1f4;font-size:11px;text-transform:uppercase;letter-spacing:.03em}
.summary td.cat{text-align:left;font-weight:600;white-space:nowrap}
.summary tr.total td{background:#1a1d21;color:#fff;font-weight:700}
.summary tr.instr td.cat{color:#c0392b}
.pend{color:#bbb;font-style:italic}
.cell{font-weight:600}
.g{background:#e7f6ec}.y{background:#fdf6e3}.r{background:#fdecea}
.det{margin-top:8px;background:#fff;border:1px solid #e2e5e9;border-radius:7px;overflow:hidden}
.det summary{padding:10px 14px;cursor:pointer;font-weight:600;background:#eef1f4;font-size:13px}
.case{padding:9px 14px;border-bottom:1px solid #eef0f3}
.case .id{font-size:11px;color:#8a929c}
.case .in{margin:3px 0}
.case .arm{margin:2px 0 2px 14px;font-size:12px}
.tag{display:inline-block;min-width:54px;font-weight:700;font-size:10px;padding:1px 5px;border-radius:3px;margin-right:6px}
.PASS{background:#1e8e3e;color:#fff}.FAIL{background:#c0392b;color:#fff}
.out{color:#444}.reason{color:#c0392b;font-style:italic}
.legend{font-size:11px;color:#6b7480;margin:6px 0 0}
</style></head><body>""")
parts.append('<header><h1>AFM Prompt Benchmark &mdash; 315 cases, judged by Codex</h1>'
             '<p>Raw AFM, no router / no filter / no safety nets. Human-satisfaction rubric. '
             'Scored one arm at a time by Codex (third-party) for consistency. Live &mdash; refresh as arms land.</p></header><div class="wrap">')

ready = [(k,l,n) for (k,l,n,f) in ARMS if runs.get(k) and k in judg]
pend  = [(k,l,n) for (k,l,n,f) in ARMS if not (runs.get(k) and k in judg)]
parts.append('<p class="legend">Scored: ' +
             (", ".join(f"<b>{l}</b> {esc(n)}" for k,l,n in ready) or "none yet") +
             ('. Pending: ' + ", ".join(f"{l} {esc(n)}" for k,l,n in pend) if pend else "") + '</p>')

def fails(key, ids):
    j = judg.get(key) or {}
    return [cid for cid in ids if cid in j]

parts.append('<h2>Pass rate by category</h2><table class="summary"><tr><th class="cat">Category</th>')
for k,l,n,f in ARMS:
    parts.append(f'<th>{l}</th>')
parts.append('</tr>')
INSTR = {"anti_instruction","anti_instruction_command"}
totals = {k:0 for k,_,_,_ in ARMS}
for cat in CATS:
    ids = [c["id"] for c in bycat[cat]]
    cls = ' class="instr"' if cat in INSTR else ''
    parts.append(f'<tr{cls}><td class="cat">{esc(cat)}</td>')
    for k,l,n,f in ARMS:
        if runs.get(k) and k in judg:
            p = 15 - len(fails(k, ids))
            totals[k]+=p
            c = 'g' if p>=13 else ('y' if p>=8 else 'r')
            parts.append(f'<td class="cell {c}">{p}/15</td>')
        else:
            parts.append('<td class="pend">&middot;</td>')
    parts.append('</tr>')
parts.append('<tr class="total"><td class="cat">TOTAL / 315</td>')
for k,l,n,f in ARMS:
    if runs.get(k) and k in judg:
        t=totals[k]
        parts.append(f'<td>{t}/315<br>{100*t/315:.1f}%</td>')
    else:
        parts.append('<td class="pend">pending</td>')
parts.append('</tr></table>')
parts.append('<p class="legend">Green &ge;13/15 &nbsp; Amber 8&ndash;12 &nbsp; Red &le;7. '
             'Red category labels are the instruction-execution tests.</p>')

parts.append('<h2>Case-by-case detail</h2>')
for cat in CATS:
    items = bycat[cat]
    parts.append(f'<details class="det"><summary>{esc(cat)} &mdash; {len(items)} cases</summary>')
    for c in items:
        cid = c["id"]
        parts.append(f'<div class="case"><div class="id">{esc(cid)}</div>')
        parts.append(f'<div class="in"><b>IN:</b> {esc(c["asr_input"])}</div>')
        for k,l,n,f in ARMS:
            r = runs.get(k)
            if not r:
                continue
            o = r.get(cid, {})
            out = o.get("candidate")
            if out is None:
                out = "ERROR: " + str(o.get("error",""))
            out = out.replace("\n"," / ")
            if k in judg:
                j = judg[k]
                verdict = "FAIL" if cid in j else "PASS"
                reason = f' <span class="reason">&mdash; {esc(j[cid])}</span>' if cid in j else ""
            else:
                verdict, reason = "&middot;", ""
            vcls = verdict if verdict in ("PASS","FAIL") else ""
            parts.append(f'<div class="arm"><span class="tag {vcls}">{l} {verdict}</span>'
                         f'<span class="out">{esc(out[:400])}</span>{reason}</div>')
        parts.append('</div>')
    parts.append('</details>')

parts.append('</div></body></html>')
open(f"{BASE}/afm-benchmark-scoreboard.html","w").write("\n".join(parts))
print("rendered /tmp/afm-prompts/afm-benchmark-scoreboard.html")
for k,l,n,f in ARMS:
    if runs.get(k) and k in judg:
        print(f"  Arm {l}: {totals[k]}/315 ({100*totals[k]/315:.1f}%)")
    else:
        st = "run not complete" if not runs.get(k) else "awaiting Codex score"
        print(f"  Arm {l}: {st}")
