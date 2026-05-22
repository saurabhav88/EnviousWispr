# Council round 2 — empirical findings and concerns

## OPENAI (gpt-5.5-2026-04-23)

Your finding is real, and it changes the recommendation.

But I’d phrase the update carefully:

> Your result disproves **one-sided novel-word diffing** as a complete safety boundary.  
> It does **not fully disprove transcript-preservation validation** unless you also tested missing-input-token / order-preservation / deletion checks.

A pure “novel words in output” check is only an **insertion detector**. Transformative execution is often a **deletion + compression + reorder** problem: AFM drops the command frame — “make this warmer,” “boil this down,” “fix grammar then cut…” — and keeps/rearranges the payload words.

So I agree with your synthesized direction:

```text
primary: on-device input command-risk classifier
backstop: deterministic output validator
```

But I would upgrade the backstop from “novel-word count” to a stricter **bidirectional preservation validator**.

---

# 1. Is there any deterministic output-side signal for transformative execution?

Yes, but not “novel words.” The useful deterministic signal is:

> Did AFM delete, compress, reorder, or replace protected input tokens?

Your current measurement only asks:

```text
output words not in input?
```

You also need to ask:

```text
input words missing from output?
input token order preserved?
did output collapse a long input span into a shorter subset?
did the beginning command frame disappear?
```

For transformative execution, the command frame almost always vanishes.

Example:

```text
input:
make this sound warmer the refund will take five business days

AFM output:
The refund will take five business days.
```

Novel-word count: `0`.

But missing protected input words:

```text
make
sound
warmer
```

That is a strong reject.

So I would not use “dropped request verb” as a regexy command detector. I would generalize it into:

> reject AFM output if it drops any non-filler protected input token, especially early tokens.

That is not trying to enumerate command verbs. It is enforcing the contract that polish may not delete semantic content.

## Better output validator

Instead of:

```text
novel_content_words(output - input) > threshold
```

use something closer to:

```text
1. Normalize input and output tokens.
2. Remove only high-confidence fillers/disfluencies from the protected set.
3. Align output tokens to input tokens in order.
4. Reject if:
   - output contains unmatched protected content tokens;
   - input contains missing protected content tokens;
   - matched tokens are substantially reordered;
   - output length is much shorter than input after allowed filler deletion;
   - high-salience tokens are missing: negation, numbers, names, verbs, adjectives, app/entity names.
```

In pseudocode:

```swift
let inputTokens = normalize(input)
let outputTokens = normalize(output)

let protectedInput = inputTokens.filter { !isAllowedFiller($0) }
let protectedOutput = outputTokens.filter { !isAllowedPunctuationOrFormattingArtifact($0) }

let alignment = orderedAlignment(protectedInput, protectedOutput)

reject if alignment.missingInputProtectedTokens.count > allowedMissing
reject if alignment.novelOutputProtectedTokens.count > allowedNovel
reject if alignment.orderViolations > allowedReorders
reject if outputProtectedCount / inputProtectedCount < minCoverageRatio
reject if any missing token is highSalience
```

For safety, I would start very strict:

```text
allowedMissing = 0, except whitelisted fillers/repeats
allowedNovel = 0 or 1, except known equivalences
```

Then relax only if clean-dictation false rejection is too high.

## Do not use a generic stopword list

This matters. Generic stopword removal can hide exactly the words that change meaning.

Do not casually discard:

```text
not
no
never
without
before
after
to
from
can
can't
will
won't
should
could
this
that
```

For transcript preservation, “stopword” is the wrong abstraction. Use a tiny whitelist of genuinely droppable fillers:

```text
um
uh
erm
hmm
you know
I mean      // maybe, depending on context
like        // dangerous; can be content
sort of     // maybe
kind of     // maybe
```

Even filler deletion should be conservative.

## Length ratio is useful but incomplete

Length ratio catches summarization/compression:

```text
input:  40 tokens
output: 9 tokens
```

Reject.

But it will miss tone rewrites where length stays similar:

```text
input:
make this softer the refund will take five business days

output:
The refund should take about five business days.
```

Length ratio looks fine. Novel/missing-token diff catches more.

## Dropped request verb is useful only if generalized

A specific check like:

```text
input contains /summarize|translate|draft|rewrite/
output dropped that verb
```

is the same regex-enumeration trap if treated as the main mechanism.

But this generalized rule is worthwhile:

> If AFM output drops protected non-filler words from the input, reject.

That catches dropped command verbs without needing to know they are command verbs.

## Bottom line on output-side detection

There is no deterministic output-side way to perfectly answer:

> “Was this transformation an execution of a command?”

But there is a deterministic way to enforce:

> “AFM may only make transcript-preserving edits.”

That catches many transformative executions because execution usually requires dropping the instruction frame or compressing the payload.

So I would run one more empirical sweep:

```text
For the same 15 command cases:
- novel protected output tokens
- missing protected input tokens
- ordered LCS coverage
- length ratio
```

My guess: your six zero-novel command executions will show obvious missing protected input tokens.

---

# 2. Does the harm differ by execution type?

Yes. The harm differs, but both are product-safety relevant.

## Generative execution

Example:

```text
input:
draft a Slack to Matt saying I'll be late

output:
Hey Matt, I’m running a bit late but I’ll be there soon.
```

This is catastrophic because AFM types a new artifact the user did not dictate.

Novel-word validation catches this well if the threshold is strict enough.

But note: your threshold examples `>8` and `>10` are quality-oriented thresholds, not safety-oriented thresholds. If you want to guarantee against generative insertion, you should reject much earlier:

```text
any novel protected content word
or
novel protected content words > 1
```

The cost is more fallback to deterministic cleaner. That is acceptable if safety is the priority.

## Transformative execution

Example:

```text
input:
make this warmer the refund will take five business days

output:
The refund will take five business days.
```

This is less alien than a composed Slack message, but it is still wrong. It typed a cleaned payload instead of the user’s actual utterance.

And sometimes transformative execution can be materially harmful:

```text
make this less legally risky we admit we caused the outage
```

```text
soften this you failed to deliver what you promised
```

```text
cut this down the patient denies chest pain but reports shortness of breath
```

```text
fix the grammar I do not approve the refund
```

Small transformations can alter legal, medical, financial, or interpersonal meaning.

So I would not dismiss transformative execution as merely cosmetic.

## Is it defensible to guarantee generative execution deterministically and catch transformative execution probabilistically?

Yes, with conditions.

A defensible safety case is:

```text
Generative insertion/hallucination:
    deterministically rejected by output validator.

Transformative command execution:
    primarily prevented by input classifier.
    additionally rejected when it drops/reorders/compresses protected input tokens.

Residual risk:
    classifier false negative
    AND output validator accepts the AFM output.
```

That residual is much smaller than classifier-only.

But I would not frame it as:

```text
novel-word diff catches generative;
classifier catches transformative;
done.
```

I would frame it as:

```text
input classifier prevents command-shaped inputs from reaching AFM;
output validator rejects non-preserving AFM outputs regardless of why they happened.
```

That distinction matters because AFM can also over-transform non-command dictation.

---

# 3. De-risking NLEmbedding hard-negative collapse

The NLEmbedding risk is real, but you can probe it cleanly.

The question is not:

> Can NLEmbedding classify 315 examples?

The question is:

> Can this representation separate commands from narration/quotation/meta-discussion under phrase-family holdout, at a threshold that gives near-zero false negatives without an intolerable false-positive rate?

## Build a contrast-set evaluation

You need minimal pairs where the surface command phrase is shared.

Example command core:

```text
translate this to Spanish
```

Positive variants:

```text
translate this to Spanish
can you translate this to Spanish
please translate this to Spanish
put this in Spanish
make this Spanish
```

Hard negative variants:

```text
my colleague asked me to translate this to Spanish
the prompt says translate this to Spanish
I wrote down the phrase translate this to Spanish
I hate when apps translate this to Spanish automatically
do not translate this to Spanish
he asked whether I could translate this to Spanish
```

Do this for many command families:

```text
draft/write/compose/reply
summarize/tldr/boil down/recap
translate/put into Spanish
rewrite/rephrase/make clearer
make warmer/softer/more professional
shorten/cut/compress
fix grammar/proofread
turn into bullets
brainstorm/generate ideas
explain like I'm five
write code/function/query
```

Then add ASR-shaped noise:

```text
tldr this thread
tl dr this thread
tea elder this thread        // if observed ASR-ish corruption
make this sound warmer um the refund will take five business days
can you like make this more professional
```

## Do grouped splits, not random splits

Random splits will lie to you.

Use grouped splits by:

1. **Command family**

   Train without “translate” examples, test on translate.

2. **Negative wrapper**

   Train without “the prompt says X,” test on that wrapper.

3. **Generator prompt/source**

   If synthetic data is generated, hold out entire generation prompts or teacher models.

4. **ASR-noise recipe**

   Train on clean text, test on ASR-shaped variants.

A pass on random split is almost meaningless here.

## Compare four baselines

Do not test only NLEmbedding.

Test:

1. **word/char n-gram logistic regression**
2. **NLEmbedding pooled embedding + logistic regression**
3. **NLEmbedding + lexical features**
4. **small transformer classifier**

The combined NLEmbedding + lexical model may outperform either alone.

Lexical features matter because this boundary is partly syntactic:

```text
translate this to Spanish
```

versus:

```text
she asked me to translate this to Spanish
```

A generic sentence embedding may put those close together. Character/word n-grams can learn that wrappers like “asked me to,” “the phrase,” “the prompt says,” and “I wrote down” change the label.

## Use a recall-first threshold

Your classifier should answer:

```text
safe_for_AFM only if confidently non-command
```

So the runtime rule should be:

```text
if P(command_risk) >= threshold:
    deterministic cleaner
else:
    AFM, then output validator
```

Because false positives are tolerable, set the threshold low enough to drive command false negatives near zero.

## What is a trustworthy pass/fail?

With only 15 command positives, a pass is not trustworthy. It is only a smoke test.

For a feasibility probe, I would want at least:

```text
200–500 diverse positive command-risk examples
500–1000 clean negatives
200–500 hard negatives / minimal-pair negatives
```

A lot can be synthetic, but the locked eval should be human-reviewed.

The important thing is diversity, not raw count.

## Concrete decision rule

Ship/proceed with NLEmbedding only if:

1. **Zero false negatives** on the locked command-positive set, especially transformative commands.

2. **Zero false negatives** on command-family holdouts.

3. **No systematic failure** on ASR-shaped command variants.

4. **False-positive rate is within your quality budget.**

   Since false positives only route to deterministic cleaner, this budget can be generous. Maybe 10–30% is acceptable initially. But if you need to classify 60–80% of normal dictation as risky to catch all commands, NLEmbedding is not buying you enough.

5. **Margins are not razor-thin.**

   If all positives are barely above threshold, the model is brittle.

6. **Stable across supported macOS versions.**

   This is especially important if relying on Apple-provided embeddings that may differ by OS.

Abandon NLEmbedding and move to a MiniLM-class Core ML transformer if:

```text
- any command family has recurring false negatives;
- transformative commands are near the decision boundary;
- hard negatives collapse so badly that the FP rate becomes product-unacceptable;
- performance collapses under grouped/template/source holdout;
- Apple embedding behavior differs across OS versions;
- adding lexical features still does not stabilize it.
```

Important nuance: hard-negative collapse is not a Tier-1 safety failure if it creates false positives. If:

```text
translate this to Spanish
```

and:

```text
my colleague asked me to translate this to Spanish
```

both get routed to deterministic cleaner, that is acceptable safety-wise.

The dangerous case is when the model fails to recognize the positive command as risky.

---

# 4. Are you over-building?

No, not if AFM remains on the paste path.

Given the constraints:

```text
AFM cannot be trusted to follow instructions.
Cloud cannot be used.
Typing words the user did not say is Tier-1 harm.
False positives degrade only to deterministic cleaner.
```

Then:

```text
on-device classifier + deterministic output backstop
```

is not over-building. It is the minimum credible safety architecture.

But there are two simpler framings still worth considering.

---

## Simpler framing A: strict output validator only

Before committing fully to the classifier, test the bidirectional validator.

Not novel-word count. Full protected-token preservation.

If it catches:

```text
15/15 command executions
```

with an acceptable clean-dictation fallback rate, then you may be able to make the classifier a quality optimization rather than the primary safety mechanism.

Runtime would be:

```text
ASR
 → AFM
 → strict preservation validator
 → accept AFM only if transcript-preserving
 → else deterministic cleaner
```

This is simpler.

But it may reject too much clean AFM output, especially if AFM often “helpfully” rewrites normal dictation. If the clean reject rate is too high, keep the classifier.

---

## Simpler framing B: remove AFM from on-device polish

The most robust solution is:

```text
on-device polish = deterministic or non-generative only
cloud polish = optional for users who choose it
```

That eliminates #832 entirely.

If on-device polish is only supposed to do:

```text
punctuation
capitalization
safe filler removal
```

then a generative 3B model is architecturally mismatched.

Longer term, the cleanest replacement is a local sequence tagger:

```text
token keep/drop
token casing
boundary punctuation
```

This structurally cannot summarize, translate, or compose.

But that is a separate component. For the immediate AFM issue, classifier + validator is reasonable.

---

# Revised recommended architecture

I would now use this:

```text
ASR raw transcript
   ↓
deterministic cleaner creates safe fallback
   ↓
on-device input command-risk classifier
   ↓
if command-risk / uncertain / OOD / classifier unavailable:
      paste deterministic cleaner
else:
      call AFM polish
          ↓
      bidirectional transcript-preservation validator
          ↓
      if validator accepts:
          paste AFM output
      else:
          paste deterministic cleaner
```

The output validator should not merely count novel words. It should reject:

```text
- novel protected output words
- missing protected input words
- substantial compression
- substantial reordering
- dropped negation/numbers/entities
```

The classifier prevents most command-shaped inputs from reaching AFM.

The validator catches:

```text
- generative execution
- hallucination
- over-rewriting
- some transformative execution via dropped command-frame/payload tokens
```

Residual bad case becomes:

```text
classifier false negative
AND
AFM transforms the command
AND
the transformed output still passes strict preservation validation
```

That is the risk to measure directly. The goal is not merely “classifier accuracy.” The goal is:

```text
bad paste rate after classifier + validator = effectively zero on pressure tests.
```

Your empirical result was exactly the right test. The next one I would run is the same 315-case benchmark with a **bidirectional protected-token validator**, not just novel-word count.

## GEMINI (gemini-3.1-pro-preview)

This is excellent engineering. You tested the hypothesis, found the empirical boundary of its effectiveness (generative vs. transformative execution), and correctly synthesized a defense-in-depth architecture. 

Your synthesized position—an **on-device input classifier** as the primary router, with the **novel-word output check** retained as a deterministic backstop for generative hallucination—is fundamentally sound.

Here are the direct responses to your four concerns.

### 1. Is there ANY deterministic output-side signal for transformative execution?
**No. It is categorically the regex-enumeration trap.** 
Do not attempt a "dropped verb + length ratio" heuristic. Transformative execution is a *semantic* operation (paraphrasing, summarizing, tone-shifting). Lexical and structural heuristics cannot robustly capture semantic intent. 
*   **Length ratio fails:** "Summarize this" compresses text. "Make this more polite" often expands it. "Fix the grammar" might leave length identical. 
*   **Dropped verb fails:** If the user dictates, "We need to shorten this timeline," and AFM cleans it to "We need to shorten this timeline," the verb is preserved. If the user dictates, "Shorten this," and AFM outputs a summary, the verb is dropped. Writing a rule to distinguish these requires full dependency parsing.

Transformative execution strictly requires a semantic classifier. Your input classifier is the only viable path.

### 2. Does the harm differ by execution type, and should that change priorities?
**Yes, the harm differs, and your layered architecture perfectly reflects this.**
*   **Generative execution (10/10 harm):** AFM invents completely unprompted facts, names, or messages. If pasted into a chat, it can be professionally catastrophic. 
*   **Transformative execution (7/10 harm):** AFM rewrites what the user actually said. It is still a Tier-1 failure because the app didn't transcribe the raw dictation, but the blast radius is bounded by the user's original context. 

It is completely defensible—and standard in safety-critical ML—to have a deterministic, 100% failsafe for the catastrophic case (novel-word diff for Generative) and a 99% probabilistic ML layer for the entire class of errors (Classifier for Generative + Transformative). Keep both. The novel-word check is practically free (microseconds of CPU time), so there is no penalty for running it as a final sanity check before pasting.

### 3. De-risking the `NLEmbedding` hard-negative collapse
To trust `NLEmbedding` + Logistic Regression, you must prove `NLEmbedding` represents *syntactic relationships* (who is doing the action), not just a "bag of words." If it's a bag of words, "translate this" and "he said to translate this" will cluster on top of each other.

**The Feasibility Probe:**
1.  **Generate an Adversarial-Only Dataset:** Use GPT-4o to generate 400 highly specific *pairs* of phrases.
    *   *Positive (Command):* "translate this to Spanish", "draft a text to Mom", "make this sound less angry"
    *   *Negative (Narration):* "my boss asked me to translate this to Spanish", "I need to draft a text to Mom later", "I tried to make this sound less angry but couldn't"
2.  **Train & Holdout:** Embed all 800 strings with `NLEmbedding`. Train your Logistic Regression on 80%, test on 20%.
3.  **The Decision Rule:** Evaluate the False Positive Rate on the negative (narration) holdout. If the FPR is **> 5%**, `NLEmbedding` is suffering from semantic collapse. 
4.  **The Pivot:** If the probe fails, abandon `NLEmbedding` immediately. Do not try to prompt-engineer or feature-engineer your way out of it. Swap to a distilled Core ML transformer (like a quantized `MiniLM-L6-v2`, ~15MB) which has the deep attention heads required to resolve subject/verb dependencies.

### 4. Am I now over-building?
**No. You are building the minimum viable architecture for a weak foundation model.**
Given the hard constraints (on-device, absolute privacy, AFM ignores negative prompts, cloud is banned), you are boxed into this exact topology. 

Let's look at the actual footprint of your "over-building":
*   **Training corpus:** A one-time Python script that costs $5 in OpenAI API credits and never ships to the user.
*   **Core ML Linear Model:** A <100KB binary that executes in <2 milliseconds. 
*   **Novel-word diff:** A 10-line Swift Set operation.

This is not bloat; it is highly targeted, asymmetric engineering. You are avoiding massive technical debt (fine-tuning AFM, managing LLM weights, handling memory spikes) by relying on classical ML (logistic regression) and basic set math. 

**The final architecture is clean:**
1. Audio → ASR → Raw Text
2. Raw Text → `NLEmbedding` → CoreML Classifier
3. If `P(Command) > 0.10` → Route to deterministic punctuation cleaner → PASTE
4. If `P(Command) <= 0.10` → Route to AFM Polish
5. AFM Polish Output → Novel Word Diff vs Raw Text
6. If Novel Words > 8 → Reject AFM, run deterministic cleaner → PASTE
7. Else → PASTE AFM Output.

This guarantees the heart path never drops a dictation, deterministically blocks generative hallucinations, probabilistically catches transformative executions, and preserves total on-device privacy. Ship it.
