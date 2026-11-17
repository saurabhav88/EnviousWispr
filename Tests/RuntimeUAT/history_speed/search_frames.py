"""Turn recorded frames into G1 search results (#4586 PR 0 chunk 2). Pure: no app, no capture.

Correct pictures are established independently of timing (chunk 2 review round 7):

- A VERIFIED picture of a query is the picture held at a moment when the accessibility checker had
  confirmed the query's correct result and kept confirming it, every read, for a hold period, and
  no other picture appeared during that hold (`reference_from_frames`). Correctness comes from the
  accessibility reads, never from being whichever picture happened to be last.
- A query may have several verified pictures: control pass 6 (2026-11-15) found the unfiltered
  Dictations list drawing slightly different pixels on different visits while its rows were
  identical. Each query therefore has a SET of verified pictures: from the untimed reference
  phase before and after the counted attempts, plus, inside each attempt, the held picture at the
  end of each step's observation and of the unfiltered start.

`measure_attempt` takes exactly the records the driver collects:
- Baseline: the last complete frame at or before the first post must be a verified picture of the
  starting query. Otherwise every step is `unknown` (no baseline).
- Final picture: the last complete frame before the next post must be a verified picture of the
  step's query, or the step is `unknown`.
- `no_visible_change`: that final picture is also a verified picture of the previous query. Never a
  timing sample.
- Endpoint: the first complete frame at or after the post that is a verified picture of the query
  and not one of the previous query's. `upper_ms` = display time minus post time: an UPPER bound on
  the first correct appearance (about 11% of drawn frames are not captured on this machine).
  `gap_ms` is the time since the previous captured frame. No lower bound is claimed.
- Supersession is never assumed. A `superseded` record whose verified picture was captured before
  the replacing query was posted completed first: it is then the previous page (allowed while the
  replacement loads), reported `supersession: completed before the replacing post`. Otherwise it
  is reported `pending state unproven; no completion captured` (capture loses frames, so no
  captured completion does not prove none happened). For the replacing step, its picture before
  the replacement's endpoint is then ambiguous (`unknown`); after the endpoint it is stale.
- Stale publication (latched; never moves an established endpoint):
    a. during the step, a frame that is a verified picture of any earlier query of the attempt
       (shown superseded queries included) and not one of this query's or the previous query's
       (pictures legitimately shared by queries stay allowed);
    b. after the endpoint, a verified picture of the previous query that is not one of this
       query's (a regression to the retained page);
    c. any accessibility read classified `stale`, before or after confirmation.
- Regression after confirmation: a `wrong` or `retained` accessibility read during the observation
  after confirmation fails the step; an `unreadable` or `ambiguous` read there makes it `unknown`.
- A latched stale publication overrides every other result: the step is `failed`, keeping any
  endpoint already found.
- Brief stale frames between captured frames cannot be seen: `stale_coverage` says so.
"""

REFERENCE_HOLD_MS = 300   # untimed reference phase
STEP_HOLD_MS = 200        # inside an attempt, after each confirmation


def ms(ticks, numer, denom):
    return ticks * numer / denom / 1e6


def complete_frames(frames):
    return sorted((f for f in frames if f.get("status") == 0 and f.get("hash")), key=lambda f: f["display"])


def reference_from_frames(frames, held_until, numer, denom, hold_ms=REFERENCE_HOLD_MS):
    """The picture shown at `held_until`, if it was the only picture for the last `hold_ms`.
    The recorder delivers a frame only when the picture changes, so the last complete frame at or
    before `held_until` is the picture on screen then. Returns (hash, reason)."""
    complete = [f for f in complete_frames(frames) if f["display"] <= held_until]
    if not complete:
        return None, "no complete frame captured"
    final = complete[-1]["hash"]
    hold_ticks = hold_ms * 1e6 * denom / numer
    start = held_until - hold_ticks
    in_effect = [f for f in complete if f["display"] <= start][-1:]   # the picture showing when the hold began
    recent = in_effect + [f for f in complete if f["display"] > start]
    if not in_effect or any(f["hash"] != final for f in recent):
        return None, f"picture changed within the last {hold_ms} ms of the hold"
    return final, None


def _unknown_all(records, reason):
    return [dict(r, result="superseded" if r["kind"] == "superseded" else "unknown", reason=reason)
            for r in records]


def measure_attempt(records, frames, refs, start_query, ended, numer, denom, start_held_until=None,
                    step_hold_ms=STEP_HOLD_MS):
    """records: the driver's per-step records, in order, including `superseded` ones. refs: query ->
    set of verified picture hashes from the reference phase. Returns one result per record."""
    complete = complete_frames(frames)
    if not records:
        return []
    verified = {q: set(v) for q, v in refs.items()}

    def add_held(query, held_until):
        if held_until is None:
            return None
        picture, _ = reference_from_frames(frames, held_until, numer, denom, step_hold_ms)
        if picture is not None:
            verified.setdefault(query, set()).add(picture)
        return picture

    add_held(start_query, start_held_until)
    first_post = records[0]["posted"]
    before = [f for f in complete if f["display"] <= first_post]
    if not before or before[-1]["hash"] not in verified.get(start_query, set()):
        return _unknown_all(records, "no captured baseline that is a verified starting picture")

    measured = [i for i, r in enumerate(records) if r["kind"] != "superseded"]
    next_post = {}
    for n, i in enumerate(measured):
        next_post[i] = records[measured[n + 1]]["posted"] if n + 1 < len(measured) else ended

    results, seen, previous_query, unproven = [], [start_query], start_query, set()
    for i, r in enumerate(records):
        query = r["query"]
        if r["kind"] == "superseded":
            early = [f for f in complete if r["posted"] <= f["display"] <= r["second_posted"]
                     and f["hash"] in verified.get(query, set())]
            seen.append(query)
            if early:
                previous_query = query   # it completed before the replacement: the previous page
                results.append(dict(r, result="superseded", supersession="completed before the replacing post"))
            else:
                unproven |= verified.get(query, set())
                results.append(dict(r, result="superseded",
                                    supersession="pending state unproven; no completion captured"))
            continue
        out = dict(r, next_posted=next_post[i],
                   stale_coverage="captured frames only; brief stale frames between captures are not observable")
        out["held_picture"] = add_held(query, r.get("held_until")) is not None
        target = verified.get(query, set())
        previous = verified.get(previous_query, set()) - target
        window = [f for f in complete if r["posted"] <= f["display"] <= next_post[i]]
        superseded_pictures = unproven - target - previous
        unproven = set()   # applies to the replacing step only
        older = set().union(*(verified.get(q, set()) for q in seen)) - target - previous - superseded_pictures
        verdicts = r.get("verdicts") or {}
        post = r.get("post_verdicts") or {}
        stale = verdicts.get("stale", 0) > 0 or post.get("stale", 0) > 0
        stale = stale or any(f["hash"] in older for f in window)
        changed_to = target - verified.get(previous_query, set())   # a verified picture that is a visible change
        endpoint = next((n for n, f in enumerate(window) if f["hash"] in changed_to), None)
        if endpoint is not None:
            after = window[endpoint + 1:]
            stale = stale or any(f["hash"] in previous or f["hash"] in superseded_pictures for f in after)
        before_endpoint = window if endpoint is None else window[:endpoint]
        ambiguous = any(f["hash"] in superseded_pictures for f in before_endpoint)
        last = [f for f in complete if f["display"] <= next_post[i]]
        final = last[-1]["hash"] if last else None
        unchanged = final in verified.get(previous_query, set())
        if endpoint is not None:   # a visible change to a verified picture; kept even if later stale
            hit = window[endpoint]
            earlier = [f for f in complete if f["display"] < hit["display"]]
            out.update(upper_ms=ms(hit["display"] - r["posted"], numer, denom),
                       gap_ms=ms(hit["display"] - earlier[-1]["display"], numer, denom) if earlier else None)
        regressed = post.get("wrong", 0) + post.get("retained", 0) > 0
        unsure_after = post.get("unreadable", 0) + post.get("ambiguous", 0) + post.get("incomplete", 0) > 0
        out["stale_publication"] = stale
        if stale:
            out.update(result="failed", reason="stale publication")
        elif regressed:
            out.update(result="failed", reason="accessibility saw a wrong or retained page after confirmation")
        elif ambiguous:
            out.update(result="unknown", reason="superseded picture before the replacement's endpoint; "
                                                "pending state unproven")
        elif r.get("confirmed") is None:
            out.update(result="unknown", reason="accessibility never confirmed the correct result")
        elif r.get("field") != query:
            out.update(result="unknown", reason="the field did not carry the accepted query")
        elif unsure_after:
            out.update(result="unknown", reason="accessibility could not read the page after confirmation")
        elif final not in target:
            out.update(result="unknown", reason="the picture before the next post is not a verified picture")
        elif unchanged:
            out.update(result="no_visible_change")
        elif endpoint is None:
            out.update(result="unknown", reason="no captured frame matched a verified picture")
        else:
            out.update(result="timed")
        results.append(out)
        seen.append(query)
        previous_query = query
    return results
