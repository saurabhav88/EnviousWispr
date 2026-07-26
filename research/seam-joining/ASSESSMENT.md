# Where this actually stands — 2026-07-25

Written after a day of measurement, at the founder's direction to stop and define
the target. Everything here is measured unless marked otherwise.

## Solved, and not worth revisiting

**How to perform the edit.** Joining requires deleting a full stop that is
already in the user's document. Tested three mechanisms in four apps that behave
four different ways (native, Chromium, Electron, Microsoft). Only a synthesised
backspace works everywhere; it is undoable, costs nothing, and reuses the
mechanism the paste path already uses. The two "faster" alternatives are silent
no-ops in most apps, which their success codes do not reveal.

**How many characters to remove.** Never a constant. Some apps keep the trailing
space we append, some strip it. Count from what the caret read actually returns.

**Delivery.** Bundled or fetched at install alongside the speech model, on by
default, opt-out, never setup-blocking. 279 MB, 2.7 ms, macOS 14 compatible.

## The problem, stated plainly

**The model works on invented data and fails on real speech.**

| | invented test data | the founder's real recordings |
|---|---|---|
| accuracy | 99.5% | 82-88% |
| wrongly joins separate sentences | ~0 of 149 | **30-58 of 431 (7-13%)** |
| misses joins it should make | ~0 | **24-29 of 49 (>50%)** |

Both directions are bad, and the gap between the two columns is the finding of
the day. Six models, three seeds each, two independent labelling passes. It is
not a labelling artifact: correcting 35 labels moved wrong merges from 8-15% to
7-13%.

**Most likely cause, not yet proven:** training data is polished written prose
chopped into halves. Real dictation is instructions, half-thoughts, test
phrases, topic jumps. The model learned a tidy version of a messy problem.

## The gaps

1. **No trustworthy labelled real data.** This is the bottleneck, not compute.
   The first grader called 29 of 43 real sentence boundaries a join. The
   corrected one still needs its flags read by hand.
2. **Capitalisation is entirely unmeasured.** The plan says the model should
   decide it. Nothing has been built, trained or tested. We have zero numbers.
3. **"Train on real data" is an untested hypothesis**, not a plan step.
4. **No definition of good enough** — until now.

## The bar

The feature fires when the model says join. Getting it wrong damages text the
user wrote; getting it right fixes text the transcriber broke. Those are not
equally weighted, so the bar is asymmetric.

Measured base rate: **about 10% of consecutive recordings are genuinely one
thought split by a pause.** The other 90% are separate and must be left alone.

**Ship criteria, fixed now, before any more results are seen:**

| | target | today |
|---|---|---|
| wrongly joins a separate pair | **under 1%** | 7-13% |
| catches a real join | **over 50%** | under 50% |
| capitalisation correct, given a correct join | **over 95%** | unmeasured |

At those numbers the feature fixes roughly 5% of pauses and damages under 1%, a
better than five-to-one ratio of help to harm. Today it is roughly one to one,
which is not worth shipping.

**Wrong merges are capped in absolute terms too:** on a 500-pair real test set,
no more than 5. A rate can hide a small denominator.

## The plan to get there, and where it stops

1. **Label real data properly.** 640 pairs now via parallel agents, capturing
   BOTH the join decision and the capitalisation decision in one pass, so
   nothing needs relabelling. A slower 4,000-pair pass runs unattended in the
   background. Both graders see identical rows, which gives a free agreement
   check on how much any of these labels can be trusted.
2. **Retrain on real recordings** instead of chopped prose. Hold out a real test
   set that no training touches.
3. **Measure against the bar above.**
4. **Stop if it misses.** If real training does not reach the bar, the answer is
   not to grind: it is to ship the deterministic rules alone, which reach about
   a quarter of seams with no model, or to ship nothing and keep the mechanism
   work for later. That is a founder decision, brought with numbers.

## What would make this fail, and be worth knowing early

- Joinable seams are only ~10% of pauses, so the ceiling on user-visible benefit
  is modest even at perfect accuracy. Worth remembering before spending weeks.
- One person's voice is the entire validation set. Stated plainly rather than
  implied away.
- The labels are model-generated. Two independent passes disagreeing would be
  the signal that this whole measurement rests on sand.
