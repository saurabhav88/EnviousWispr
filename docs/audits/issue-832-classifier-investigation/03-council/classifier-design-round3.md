# Council round 3 — bidirectional probe results, architecture finalization

## OPENAI (gpt-5.5-2026-04-23)

Your synthesis is now mostly right.

The corrected version of my earlier recommendation is:

> **Output validation is useful only for bounded classes of AFM misbehavior. It is not a complete safety boundary once “legitimate polish” includes token-changing normalization.**  
> Therefore the **input classifier becomes the primary #832 defense**, and the output check becomes a **narrow hallucination / high-novelty backstop**.

I would ship toward:

```text
ASR raw transcript
   ↓
safe deterministic fallback prepared
   ↓
on-device input command-risk classifier
   ↓
if command-risk / uncertain / OOD / classifier failure:
      use deterministic fallback
else:
      AFM polish
         ↓
      novel-protected-word output backstop
         ↓
      if high novelty: use deterministic fallback
      else: paste AFM output
```

Now to your questions.

---

# 1. Does 24% false-fire kill bidirectional validation as always-on?

Yes.

A 24% false-fire rate, concentrated in:

- dates/times,
- number formatting,
- emails/URLs/phones,
- homophones,
- revision handling,
- emoji conversion,

kills the bidirectional validator as an always-on accept/reject gate **for your current product contract**.

If AFM’s value includes turning:

```text
five pm
```

into:

```text
5 PM
```

or:

```text
support at gmail dot com
```

into:

```text
support@gmail.com
```

then missing-token validation is rejecting exactly the transformations users want.

So the bidirectional validator is not a safety backstop anymore; it is a second polish policy that says:

> “AFM may not perform many of the useful normalizations we use AFM for.”

That is too expensive.

## Novel-words-only is the right always-on backstop form

But I would name it precisely:

> **high-novelty insertion guard**, not transcript-preservation validation.

It catches:

- composed artifacts,
- translated output,
- code generation,
- brainstorming,
- hallucinated additions,
- long invented messages.

It does **not** catch:

- same-vocabulary summarization,
- command-frame deletion,
- tone rewrites using existing words,
- “reply yes that works” → “Yes, that works.”

So yes: keep novel-word-only as the deterministic output backstop, but do not describe it internally as covering transformative execution.

Also, do not overclaim “generative execution is guaranteed caught.” It is guaranteed caught only when it exceeds your novelty threshold. Some composed outputs can be low-novelty.

Example:

```text
input:
reply yes that works

AFM output:
Yes, that works.
```

Novel words: zero.

That is still command execution.

So the backstop catches **high-insertion generative execution**, not all generative execution.

---

# 2. Can missing-token validation be salvaged by excluding known normalizations?

Partially, but I would not make it the main path.

There are two categories.

## Worth doing: closed-class canonicalization

Some false-fires come from finite, grammar-like transformations. These are reasonable to canonicalize before diffing.

Examples:

```text
five pm       ↔ 5 PM        → TIME(17:00)
a hundred     ↔ 100         → NUM(100)
support at gmail dot com ↔ support@gmail.com → EMAIL(...)
slash dot colon at         → URL/EMAIL symbols
smiley face emoji          → 🙂
ten am scratch that eleven am → revised TIME(11:00)
```

This is not the same as the regex-enumeration trap, because these are bounded normalizer domains.

If you already have or want a deterministic cleaner, these canonicalizers are useful anyway.

I would consider canonicalizing:

- numbers,
- dates,
- times,
- phone numbers,
- emails,
- URLs,
- spoken punctuation/symbols,
- common emoji phrases,
- casing,
- contractions,
- maybe explicit self-correction markers: “scratch that,” “no wait,” “rather,” etc.

Then rerun the bidirectional validator.

## Not worth broadening: open-ended semantic equivalence

I would not chase broad exceptions for:

- homophone repair,
- grammar repair,
- paraphrase,
- tone changes,
- language preservation,
- arbitrary ASR corrections.

That becomes the inverse regex trap.

For example:

```text
aloud → allowed
there → their
to → too
your → you're
```

Some are legitimate ASR fixes; some are meaning-changing; the set is open-ended.

Once your validator starts saying:

> “Missing token is fine if AFM probably replaced it with a semantically/phonologically equivalent word,”

you are rebuilding an unreliable semantic judge.

## Practical recommendation

Do a short salvage probe only if cheap:

```text
Implement canonical equivalence for numbers/dates/times/email/URL/phone/spoken symbols/emoji.
Rerun the 315-case benchmark.
Keep missing-token validation only if false-fire drops dramatically.
```

My decision rule would be:

- If bidirectional false-fire remains above ~5–8% on clean cases, drop it as always-on.
- If it catches only cases the input classifier already catches, drop it.
- If it materially catches additional residual bad pastes at low false-fire, keep it as a secondary conditional guard.

But I would not let this delay the classifier. The classifier is still necessary.

---

# 3. Is residual transformative-command risk acceptable, and how should it be bounded?

The residual risk is:

```text
input classifier says safe
AND input is actually a command
AND AFM executes transformatively
AND novel-word backstop does not fire
```

That is the exact failure mode to measure.

Is it acceptable? Technically, yes, **if** you bound it aggressively and fail closed. There is no deterministic complete fix for this class unless you either:

1. remove AFM from the on-device polish path, or
2. accept a strict output validator that rejects many useful normalizations.

So if AFM remains, the safety case has to be probabilistic around the input classifier.

## Measure end-to-end, not just classifier accuracy

Do not only report:

```text
classifier false negatives
```

Also report:

```text
end-to-end bad paste rate
```

For each command case:

```text
if classifier routes to deterministic fallback:
    safe
else:
    run AFM
    run novel-word backstop
    human/judge checks whether final pasted output executed the command
```

Your key metric is:

```text
bad_paste_rate_on_command_inputs
```

Then break it down:

```text
bad_paste_rate_on_transformative_commands
bad_paste_rate_on_generative_commands
classifier_false_negative_rate
backstop_catch_rate_given_classifier_FN
```

## Build a specific transformative-command eval set

Your current 15 command cases are useful but far too small.

Create a locked eval with hundreds to thousands of command positives, especially:

```text
make this warmer ...
make this softer ...
make this more professional ...
rewrite this ...
rephrase this ...
shorten this ...
cut this down ...
boil this down ...
tldr this ...
summarize this ...
fix grammar then ...
turn this into bullets ...
explain this simply ...
make this sound less harsh ...
make this legally safer ...
```

Include ASR-shaped forms:

```text
make this sound warmer um the refund will take five business days
can you just soften this a little i need the report today
tldr this thread basically the launch slipped again
```

Also include hard negatives:

```text
my manager asked me to make this warmer but I disagree
the prompt says make this more professional
I wrote down the phrase summarize this thread
she told me to translate this to Spanish
do not rewrite this
I hate when apps make this sound warmer without asking
```

## Use grouped holdouts

Random splits are not enough.

Hold out by:

- command family,
- wrapper phrase,
- generation prompt,
- ASR-noise recipe,
- teacher model,
- domain.

You need to know whether the model learned the underlying distinction or memorized command families.

## Use rule-of-three bounds carefully

If you get:

```text
0 residual bad pastes in 1,000 independent command-positive cases
```

then the rough 95% upper bound is:

```text
~0.3%
```

If:

```text
0 / 3,000
```

then:

```text
~0.1%
```

But synthetic examples are correlated, so treat those as directional, not absolute.

## Threshold for asymmetric harm

Set the classifier threshold so that only confidently safe dictation reaches AFM.

Runtime policy should be:

```text
if P(command_risk) >= low_threshold:
    deterministic fallback

if classifier confidence poor:
    deterministic fallback

if OOD:
    deterministic fallback

if language unsupported:
    deterministic fallback

if input too long/weird for reliable classification:
    deterministic fallback
```

Do not optimize F1. Optimize command recall and end-to-end bad-paste avoidance.

A high false-positive rate is acceptable if the UX remains tolerable.

## Is NLEmbedding enough?

Maybe, but the pass/fail should be strict.

Proceed with `NLEmbedding + logistic regression` only if it gets:

- zero command false negatives on the locked transformative-command set,
- zero systematic misses by command family,
- stable behavior under ASR noise,
- acceptable false positives on clean dictation,
- stable behavior across target macOS versions.

If it misses a command family like:

```text
make this warmer ...
boil this down ...
fix grammar then ...
```

move to a small Core ML transformer classifier.

---

# 4. Is the architecture final, or is there still a gap?

The architecture is final enough for implementation exploration:

```text
input command-risk classifier = primary safety mechanism
novel-word output guard = high-novelty hallucination backstop
deterministic fallback = safe degradation path
```

But there are still gaps:

1. **Classifier validation gap:** you still need a locked, ASR-shaped, family-held-out eval set focused on transformative commands before trusting the classifier.

2. **Threshold gap:** you need an explicit recall-first threshold and abstention policy where uncertainty routes to deterministic fallback.

3. **Backstop-definition gap:** the novel-word guard must be documented as a high-novelty hallucination detector, not a complete command-execution detector.

4. **OOD gap:** unsupported language, very long input, classifier load failure, tokenizer failure, and embedding/model drift must all fail closed to deterministic fallback.

5. **Model-choice gap:** if `NLEmbedding + linear head` has any systematic command-family false negatives, you should abandon it for a bundled MiniLM-class Core ML classifier.

6. **Long-term architecture gap:** the only deterministic way to eliminate #832 while preserving rich local polish is to replace AFM with a non-generative local polish model, such as a punctuation/casing/normalization sequence tagger.

So: no, you are not over-building. Given the empirical results, the current best architecture is exactly:

> **on-device input classifier as primary + narrow novel-word output guard as backstop + deterministic fallback for all uncertainty.**

## GEMINI (gemini-3.1-pro-preview)

This is exceptional engineering. You took a theoretical mechanism, stress-tested it against real distributions, identified the semantic overlap (formatting/self-correction vs. transformative execution), and correctly killed the bad idea. 

Your synthesis is airtight. Here are the direct answers to round 3.

### 1. Do you agree 24% false-fire kills the bidirectional validator, and novel-only is the right backstop?
**I agree completely.** A 24% false-fire rate is a product-killer, especially because it systematically degrades the exact features users value most (number formatting, email formatting, homophone correction). You proved that at the token-set level, legitimate normalization and transformative execution are indistinguishable. The bidirectional check must die. The novel-words-only check survives because it perfectly targets the catastrophic failure mode (inventing unprompted data) with near-zero false positives.

### 2. Can we salvage missing-tokens by ignoring normalizable words, or is that a regex trap?
**It is the ultimate inverse regex trap.** Do not build it. 
To make it work, you would have to maintain exhaustive whitelists of spoken-to-written symbol mappings ("dollar" -> "$", "at" -> "@"), every homophone pair in the English language, and every colloquial self-correction phrase ("scratch that", "no I meant", "go back"). It is an unmaintainable nightmare for a founder/AI team. More importantly, it still wouldn't catch the hardest cases where the transformation drops contextually specific nouns. Trust the input classifier for this; it handles it zero-shot.

### 3. Residual risk: Classifier FN on a transformative command. Acceptable? How to bound?
**It is highly acceptable.** 
*   **The harm profile:** A false-negative generative execution (typing a fake message) is a 10/10 harm; your novel-word backstop mathematically prevents this. A false-negative transformative execution (e.g., summarizing what they just dictated) is a 4/10 harm. The text is wrong, but the blast radius is contained entirely to the user's own semantic context. It is annoying, not dangerous.
*   **How to bound/measure:** Implement a strict, privacy-safe telemetry counter: the **Length Deviation Metric**. If `Output Length < 0.6 * Input Length` (heavy summary) or `Output Length > 1.4 * Input Length` (expansion), and the novel-word check *didn't* trip, increment a silent anomaly counter. If this counter spikes globally, your classifier's recall on transformative commands is degrading, and you need to update the Core ML model's training corpus.

### 4. Is the architecture now final, or is there still a gap?
The architecture is final, but there are two execution gaps you must mind:

*   **Gap 1 (Latency constraint):** Running the input classifier sequentially *before* calling AFM will add latency to the heart path; you should start the opaque AFM generation immediately and run the classifier concurrently, aborting the AFM call mid-flight if the classifier flags it.
*   **Gap 2 (Telemetry blindness):** Because you cannot see the real text due to privacy constraints, you have no way to know if your `P > 0.10` classifier threshold is catching 99% of commands or false-firing on 20% of dictations unless you instrument an aggregate metric counting how often the deterministic fallback is triggered.
