# Council round 1 — classifier design approach

## OPENAI (gpt-5.5-2026-04-23)

## Up to 2 missing premises

1. **What exact edits is “AI Polish” allowed to make?**  
   If the contract is truly “same words, better punctuation/capitalization, maybe filler removal,” then you can enforce that contract deterministically and may not need command detection as the safety boundary. If AFM is also allowed to rewrite grammar, fix ASR word errors, paraphrase, or shorten, then a validator becomes harder and the classifier matters more.

2. **What is the on-device deployment envelope?**  
   Specifically: max acceptable added latency before paste, acceptable app/model bundle size, supported macOS/hardware/languages, and whether using Apple `NaturalLanguage` embeddings is acceptable despite OS/model-version drift. This determines whether `NLEmbedding + logistic regression` is enough or whether you should bundle a small Core ML transformer.

---

# Short recommendation

Do **not** try to make AFM classify its own failure mode. Do **not** rely on prompt tuning or few-shot AFM. Do **not** bet first on AFM LoRA/adapters unless Apple gives you a stable, supported, low-latency classification path.

The best classifier approach is:

> **Distill frontier-model labels into a dedicated on-device discriminative classifier, tuned for very high command recall, with deterministic fallback.**

But I would not make that classifier the only safety layer.

The more robust framing is:

> **AFM output should be accepted only if it is transcript-preserving.**  
> If AFM adds/drops/reorders non-filler content words, reject it and use the deterministic cleaner/raw transcript.

That deterministic transcript-preservation gate is the obvious alternative to revisit. It is not the same as the failed output-side artifact heuristic. It directly enforces the invariant: “the app must not type words the user did not say.”

My preferred production design:

```text
ASR raw transcript
   ↓
deterministic normalizer / cleaner candidate
   ↓
on-device command-risk classifier
   ↓
if command-risk high or classifier unavailable/uncertain:
      use deterministic cleaner
else:
      call AFM polish
         ↓
      deterministic transcript-preservation validator
         ↓
      if valid: paste AFM output
      else: paste deterministic cleaner/raw
```

So the classifier improves routing and quality, but the validator is the hard safety stop.

---

# 1. Best build approach for an accurate on-device classifier

## Use a dedicated distilled classifier

The decision boundary appears learnable by a capable model, and the runtime constraint rules out cloud. That points to a small local discriminative model trained from frontier-labeled data.

I would evaluate two variants in this order:

### First baseline: local embeddings + lightweight head

Use:

- Apple `NaturalLanguage` sentence embeddings, if available and stable enough for your target OSes.
- Plus simple lexical features:
  - word/char n-grams,
  - first-token / first-clause features,
  - length,
  - imperative marker features,
  - quoted/narration marker features.
- Train logistic regression, linear SVM, or a tiny MLP.
- Calibrate probability with Platt scaling or isotonic regression.
- Export to Core ML or implement the head directly.

Advantages:

- Tiny.
- Fast.
- Easy to debug.
- Easy to threshold conservatively.
- Easy to fail closed to deterministic cleaner.
- No generative behavior.

Risks:

- Apple embeddings may be opaque and version-dependent.
- Sentence embeddings can blur distinctions like:

  ```text
  translate this to Spanish
  ```

  versus:

  ```text
  my colleague asked me to translate this to Spanish but I refused
  ```

- Generic embeddings may not encode the exact syntactic/narrative distinction you need.
- If the embedding model changes across OS releases, calibration may drift.

This is worth prototyping because it is cheap and may be enough. But I would not assume it will be sufficient until it beats a non-random, adversarial holdout.

### Preferred shipping candidate if feasible: small fine-tuned transformer classifier

If latency and bundle size allow it, my default shipping choice would be a small encoder classifier converted to Core ML:

- MiniLM / DistilBERT / DeBERTa-small-class model class.
- Max sequence length 64–128 tokens initially.
- Quantized or float16.
- Binary output: `command_risk` vs `safe_for_AFM`.
- Core ML inference on CPU/ANE where available.

Why I prefer this over generic embeddings:

- The hard negatives are compositional and syntactic, not just semantic.
- You care about distinctions like:
  - “translate this to French”
  - “he asked me to translate this to French”
  - “the prompt says translate this to French”
  - “can you draft a message saying I’ll be late”
  - “I wrote down: can you draft a message saying I’ll be late”
- A fine-tuned encoder can learn these boundaries better than a frozen embedding plus linear head.
- You own the model version, so calibration is reproducible.

Risks:

- Core ML conversion friction.
- Tokenizer implementation complexity.
- Bundle size.
- Cold-start latency.
- CPU fallback on unsupported hardware.
- Long transcript handling.
- Multilingual behavior.
- Quantization may move borderline cases.

Still, this is a much better tool than AFM for this binary task.

---

## Data strategy

You have 315 hand-labeled cases. That is enough for initial benchmarking, not enough for safety confidence.

I would build a larger corpus with four buckets.

### 1. True command-risk positives

Examples:

```text
draft a Slack to Matt saying I'll be late
write an email to Sarah asking for the report
tldr this thread
summarize this conversation
translate this to Spanish
make this shorter
turn this into bullet points
reply saying yes that works
compose a message to my manager that I am sick
create a Jira ticket for the login bug
```

Include colloquial forms:

```text
can you make this sound better
help me write a note to my landlord
let's send Bob a quick message that I'm running late
I need a summary of this
could you put this in Spanish
```

### 2. Hard negatives containing command words

These are essential:

```text
my colleague asked me to translate this into French but I don't speak French
the button says summarize this thread
I wrote the phrase draft a Slack to Matt in my notes
she told me to write an email to Sarah
the prompt was translate this to Spanish
I hate when apps summarize things without asking
the article says create a Jira ticket for every bug
```

### 3. Normal dictation with imperative language

These may be false positives, but you need to know how often they happen:

```text
please send me the file by Friday
call me when you get home
don't forget to bring your passport
let me know what you think
make sure the door is locked
```

Some of these are legitimate text the user may want typed. Routing them to the deterministic cleaner is acceptable, but you should quantify the quality cost.

### 4. Real ASR-shaped inputs

Train and test on transcripts shaped like your ASR output:

- no punctuation,
- odd casing,
- homophone errors,
- partial utterances,
- restarts,
- filler words,
- repeated words,
- names misrecognized,
- app names misrecognized,
- code-switching,
- very short commands.

Do not train only on clean typed sentences.

Example ASR-like variants:

```text
draft a slack to matt saying ill be late
can you make this sound better um just a little more professional
tldr this thread
my coworker asked me to translate this to french but i said no
```

---

## Splitting and evaluation

Avoid random train/test splits over generated data. They will overstate performance.

Use splits by:

- generation template,
- source prompt,
- teacher model,
- phrase family,
- command type,
- negative type.

Keep a human-curated holdout that is never used for prompt iteration or model selection.

Also keep a “pressure test” set specifically designed to break the classifier.

Metrics should prioritize:

- command recall,
- false-negative rate,
- negative predictive value for “safe for AFM,”
- false-positive rate only as a quality metric.

Do not optimize primarily for accuracy or AUC.

---

## Why not AFM LoRA/adapters?

I would not choose AFM fine-tuning/adapters as the primary path.

Reasons:

1. **Support risk.**  
   Unless Apple provides a stable, documented, app-shippable adapter path for AFM classification, this is operationally fragile.

2. **Wrong model shape.**  
   You need a small discriminative binary classifier, not a 3B generative model.

3. **Latency.**  
   Running AFM just to decide whether to run AFM is unattractive.

4. **Calibration.**  
   You need tunable probabilities and conservative thresholds. Generative label outputs are harder to calibrate reliably.

5. **Same family of failure.**  
   AFM already failed at instruction-following and zero-shot classification. Fine-tuning might help, but it is not the cleanest safety boundary.

If Apple eventually supports reliable local adapters and you can benchmark them, fine. But I would treat that as secondary.

---

## Why not few-shot or structured prompting of AFM?

No.

You already have evidence that AFM ignores the relevant instruction boundary. Few-shot prompting may improve a benchmark, but it is brittle and hard to trust as a Tier-1 safety mechanism.

Structured output helps only with label formatting. It does not make the reasoning reliable.

For example, forcing:

```json
{ "label": "COMMAND" }
```

does not solve whether AFM understands the distinction.

---

## Best hybrid

Use:

1. **Dedicated classifier** for pre-routing.
2. **Deterministic cleaner** as safe fallback.
3. **Transcript-preservation validator** after AFM.
4. **Conservative thresholding** so uncertain cases do not reach AFM.

Rules can still be useful, but I would use them as:

- features,
- test generators,
- fallback guards,

not as the core detector.

---

# 2. Are you missing an obvious alternative?

Yes: **enforce transcript preservation directly.**

The failed output-side detector looked for artifacts like salutations, sign-offs, placeholders, or dropped request verbs. That is heuristic and overfit-prone.

A stronger approach is not “does this look like an executed command?” but:

> “Could this output have been produced from the input using only allowed transcript-preserving edits?”

If not, reject AFM output.

## Deterministic transcript-preservation validator

Given input:

```text
draft a Slack to Matt saying I'll be late
```

AFM executed output:

```text
Hey Matt, I'll be late.
```

The validator rejects because:

- `Hey` was added.
- `draft`, `Slack`, `to`, `saying` disappeared.
- The output is not a punctuation/capitalization/filler-only edit.

Given input:

```text
translate this to Spanish
```

AFM executed output:

```text
Traduce esto al español.
```

Reject:

- New language.
- Content words not present in input.
- Original content words absent.

Given input:

```text
um I think we should go tomorrow
```

AFM output:

```text
I think we should go tomorrow.
```

Accept, if `um` is on the filler whitelist.

---

## What the validator should allow

Allowed:

- punctuation insertion,
- capitalization changes,
- apostrophe/contraction normalization,
- whitespace normalization,
- deletion of whitelisted fillers/disfluencies,
- maybe repeated-word collapse,
- maybe very small whitelisted ASR normalizations.

Example accepted edits:

```text
input:  i dont think um we should go
output: I don't think we should go.
```

```text
input:  so so i think this is fine
output: So I think this is fine.
```

---

## What the validator should reject

Reject:

- new non-input content words,
- deletion of non-filler content words,
- significant reordering,
- translation,
- summarization,
- shortening,
- salutation/sign-off insertion,
- message composition,
- replacement with an artifact.

Examples rejected:

```text
input:  draft an email to jane saying i need the report
output: Hi Jane, I need the report.
```

```text
input:  tldr this thread
output: The main point is that the deadline moved to Friday.
```

```text
input:  make this sound more professional
output: I would appreciate your assistance with this matter.
```

---

## Why this may be better than classification

A classifier asks:

> “Is this input command-shaped?”

A validator asks:

> “Did the model output only words the user said, modulo safe edits?”

The second directly protects the product invariant.

It also catches non-command hallucinations. For example, if AFM rewrites a normal dictation too aggressively, the classifier may never be involved. The validator still catches it.

This is the closest thing here to a deterministic safety guarantee.

---

## Could constrained decoding solve it?

Maybe in theory, but likely not with AFM as exposed today.

If you could force AFM to emit only:

- original tokens,
- punctuation,
- capitalization operations,
- filler deletion operations,

then yes, that would be ideal.

But typical “structured output” or schema guidance only ensures the shape of the response, not that the string content is transcript-preserving.

For example:

```json
{
  "cleanedTranscript": "Hey Matt, I'll be late."
}
```

is valid JSON but still unsafe.

So unless AFM supports a dynamic grammar constrained to the input token set/edit operations, post-validation is more practical.

---

## Another alternative: replace AFM polish with a non-generative polish model

If AI Polish is intended to do only punctuation, capitalization, and filler removal, a generative LLM is not the natural tool.

A safer long-term architecture is a local sequence tagger:

```text
token → keep/drop
token → casing
token boundary → punctuation
```

This model structurally cannot summarize, translate, or compose an email.

That could be:

- a small Core ML transformer,
- a BiLSTM/CRF-style tagger,
- a distilled punctuation restoration model,
- or a deterministic/ML hybrid.

This reframes the whole problem so command detection is unnecessary.

Tradeoff: more engineering and training data for the polish model. But architecturally, it matches the desired behavior better than AFM.

---

# 3. Asymmetric-error design

You have the right asymmetry:

- **False positive:** normal dictation uses deterministic cleaner. Mild quality loss.
- **False negative:** AFM may type words the user never said. Tier-1 harm.

Therefore the classifier should be designed as a **high-recall command-risk detector**, not a balanced classifier.

## Label the positive class broadly

Do not label only obvious commands as positive. Label as positive anything that a local generative model might plausibly treat as an instruction to execute.

Positive examples should include:

```text
draft a Slack to Matt saying I'll be late
write a note that says thank you
summarize this
make this shorter
turn this into bullets
translate this into German
can you reply to her saying yes
```

Borderline? Route safe.

If uncertain, label positive or use deterministic fallback.

---

## Threshold rule

If the model outputs `P(command_risk)`, use:

```text
if P(command_risk) >= threshold:
    deterministic cleaner
else:
    AFM polish, then validator
```

Set the threshold to minimize false negatives, not to maximize F1.

In practice, the threshold may be surprisingly low. That is acceptable because false positives are tolerable.

Even better:

```text
if classifier unavailable:
    deterministic cleaner

if language unsupported:
    deterministic cleaner

if input too long for reliable classification:
    deterministic cleaner or chunked classification

if confidence low / OOD:
    deterministic cleaner

if P(command_risk) above conservative threshold:
    deterministic cleaner

else:
    AFM polish with transcript-preservation validation
```

AFM should receive only cases that are confidently safe.

---

## Evaluation target

Do not report only aggregate accuracy. Require something like:

- zero false negatives on the command pressure set,
- zero or near-zero false negatives on fresh phrase-family holdouts,
- high recall on ASR-noised command variants,
- measured false-positive rate separately as quality degradation.

Use the “rule of three” for zero-failure tests:

- 0 misses in 300 independent positive cases gives an approximate 95% upper bound of 1% miss rate.
- 0 misses in 3,000 gives roughly 0.1%.

Synthetic data helps, but the confidence only means much if the cases are diverse and not template-leaked.

---

## Training loss

Use class weighting or focal loss if needed, but thresholding matters more than loss function.

For a transformer classifier:

- train normally with binary cross-entropy,
- oversample hard positives and hard negatives,
- calibrate after training,
- select threshold based on command recall.

For logistic regression / linear model:

- use class weights,
- tune regularization,
- calibrate,
- threshold conservatively.

---

## OOD handling

Because false negatives are costly, out-of-distribution should mean “do not use AFM.”

Route to deterministic cleaner when:

- language is unknown,
- transcript is mostly non-English if unsupported,
- transcript exceeds model max length and cannot be reliably chunked,
- tokenizer fails,
- classifier fails to load,
- score is near threshold,
- embedding distance / representation confidence indicates OOD,
- input is extremely short and command-like:

  ```text
  summarize
  translate
  rewrite this
  ```

---

# 4. Highest risk I would worry about

The highest risk is **treating input classification as the safety boundary**.

Even a strong classifier is probabilistic. If the only protection is:

```text
classifier says safe → AFM output is pasted
```

then one false negative can still produce the exact Tier-1 harm.

Also, the safety property you actually care about is not “was the input a command?” It is:

> “Did the app paste only the user’s dictated words, except for allowed cleaning?”

Those are related but not identical.

AFM could hallucinate or rewrite non-command dictation too. A command classifier would not catch that.

## De-risk early

Build the deterministic transcript-preservation validator first, or at least in parallel.

Then test it against:

- all known AFM execution outputs,
- synthetic executed-command outputs,
- normal polished outputs,
- ASR-noisy transcripts,
- filler-heavy transcripts,
- contractions,
- names,
- numbers,
- code-ish text,
- multilingual text if supported.

The validator should become a product invariant:

```text
AFM output is never pasted unless it passes transcript-preservation validation.
```

Then the classifier becomes a quality/latency optimization instead of the only thing preventing harm.

If you do that, the residual risk drops dramatically.

---

# Concrete final design

## Runtime pipeline

```text
1. ASR produces raw transcript.

2. Deterministic cleaner creates safe fallback:
   - punctuation/caps if available,
   - filler removal only by safe whitelist,
   - never adds semantic content.

3. Command-risk classifier runs locally.

4. If classifier says command-risk, uncertain, OOD, unavailable, unsupported language, or over length:
      paste deterministic cleaner.

5. Else run AFM polish.

6. Validate AFM output with transcript-preservation gate.

7. If valid:
      paste AFM output.
   Else:
      paste deterministic cleaner.
```

## Classifier choice

Recommended:

1. Prototype `NLEmbedding + logistic regression/linear SVM + lexical features`.
2. In parallel or next, fine-tune a tiny transformer classifier.
3. Ship the simpler model only if it clears adversarial, non-random, ASR-shaped holdouts at the desired recall.
4. Otherwise ship the transformer.

Do not use AFM prompting or AFM self-classification.

## Safety posture

- Default safe.
- AFM only on confidently safe dictation.
- AFM output accepted only if structurally transcript-preserving.
- Any failure degrades to deterministic cleaner/raw transcript, never to no text and never to unvalidated generated text.

That design matches the heart-path rule: the user still gets their dictated text, and the optional polish limb can degrade without causing semantic harm.

## GEMINI (gemini-3.1-pro-preview)

Here is a rigorous, design-exploration review of your approach to issue #832. 

Before answering the core questions, I need to identify two missing premises that dictate the technical boundaries of this solution:

### 5. Missing Premises
1. **Execution Environment & Interceptability:** Are you running AFM via Apple’s opaque system APIs (e.g., macOS 15.1+ `Intelligence` frameworks) or via a local framework like MLX? If MLX, you have access to the logits and token generation stream. If Apple APIs, you treat AFM as an opaque black box where you only control the prompt and receive the final string.
2. **The "Deterministic Cleaner" Fallback:** Does this component actually exist and produce acceptable quality? The plan assumes that routing a false positive to this non-LLM cleaner is a "tolerable" degradation. If this cleaner relies on rigid regexes and frequently mangles standard dictation, the cost of a false positive is much higher than stated.

---

### 2. Are you missing an obvious alternative? (Yes.)
A machine-learned input classifier is **not** the best tool for this problem. You are attempting to solve a *semantic hallucination* problem via *intent classification*. There is a much simpler, robust, and deterministic alternative that perfectly captures your asymmetry constraint.

**Alternative A: Output-Input Lexical Diffing (The "Novel Word" Threshold)**
You previously tried an *Output-side rule detector* (looking for shapes like salutations). That failed because execution shapes are open-ended. Instead, measure the exact harm: **execution introduces novel words.**
1. Run the dictation through AFM.
2. Strip punctuation and lowercase both the input (raw dictation) and the output (AFM polish).
3. Calculate the set of novel words generated by AFM that were *not* in the input. 
4. If `Count(Novel Words) > 3` (or `> 10%` of input length), AFM has hallucinated a command. Reject the AFM output, and fallback to the deterministic cleaner.

*Why this wins:* A "polish" operation, by definition, only deletes words (fillers) or mutates casing/punctuation. It rarely invents new words. An "execution" operation (translating, summarizing, drafting) generates completely new vocabulary. This requires zero Core ML conversion, zero training data, zero dataset maintenance, and perfectly targets the actual bug.

**Alternative B: Constrained Decoding (If using MLX)**
If you are running AFM via MLX, you can use a custom Logits Processor. Build a Trie of the words present in the raw dictation (plus punctuation tokens). At every generation step, force AFM's logits to *only* allow tokens that exist in that Trie. It becomes physically impossible for AFM to draft a Slack message because the vocabulary required to do so has its probabilities masked to `-inf`. 

---

### 1. Best build approach for the on-device classifier
*If you reject the alternatives and strictly want the classifier, here is the optimal build.*

**The Pick: Option A (Distilled frontier labels → `NLEmbedding` + Core ML Logistic Regression).**
Do not fine-tune AFM (too slow, high memory, brittle). Do not use an on-device distilled transformer immediately (overkill, heavier maintenance). 

**The Pipeline:**
1. Generate ~20k synthetically labeled examples using GPT-4o (10k Commands, 10k Dictation, heavily over-indexing on hard negatives like "He told me to draft an email").
2. Run this corpus through macOS's native `NLEmbedding` (Apple’s built-in Natural Language framework sentence embeddings).
3. Train a standard Logistic Regression model in Python (scikit-learn).
4. Use `coremltools` to export the logistic regression to a `.mlmodel`.
5. **Runtime:** Text → `NLEmbedding` → Core ML Linear Model → Probability Score.

**Why:** `NLEmbedding` is already loaded in macOS memory—zero RAM overhead, practically zero latency. A Core ML linear model is <100KB. It physically cannot crash the heart path if you wrap the Core ML call in a basic `do/catch` block with a 50ms timeout.

**Failure Mode:** `NLEmbedding` might suffer from semantic collapse on "hard negatives" (e.g., it might embed "translate this to Spanish" and "he asked me to translate this to Spanish" too closely, causing the linear boundary to fail). If you hit this ceiling, Option D (distilling a 15MB MiniLM-L6-v2 to Core ML) is your fallback.

---

### 3. Asymmetric-error design
You established that False Positives (FP = rougher text) are acceptable, but False Negatives (FN = executing commands) are Tier-1 unacceptable. 

This means your classifier should act as an **Anomaly Detector optimized for Recall**.
*   **Design implication:** Do not use a binary `.predict()` output. The model must output a probability distribution: `P(Command)`.
*   **Thresholding:** Instead of the default `0.5`, you shift the threshold drastically. If `P(Command) > 0.10`, route to the deterministic cleaner. You intentionally catch 99.9% of commands at the cost of sweeping up 5-10% of standard dictation into the rougher fallback.
*   **Build implication:** Logistic regression naturally produces well-calibrated probabilities, making it vastly superior to SVMs or heavily quantized adapters for this specific need. 

---

### 4. Highest unstated risk
**The risk:** Classifier maintenance as phrasing evolves (The Long Tail of Idioms).

Right now, GPT-4o gives you 100% precision/recall on a 300-case holdout. But in production, users invent highly idiosyncratic verbs for commands ("zap this to Matt," "tldr me," "make this sound less angry"). Over time, a static Core ML classifier trained on a one-time synthetic snapshot will experience a slow degradation in recall (more FNs creeping in) as user phrasing drifts. 

**How to de-risk early:** 
Instrument a silent, privacy-safe telemetry flag. You cannot send dictation text to the cloud, but you *can* send metadata. Log the ratio of `Input Length` vs `Output Length` of AFM's polish step. 

If a user says "tldr me" (2 words), and AFM outputs a 50-word summary, the length ratio is `25x`. Whenever the ratio exceeds `1.5x`, it means your classifier failed (a False Negative occurred) and AFM hallucinated. Tracking this anonymous integer ratio lets Claude Code and the founder monitor the actual #832 regression rate in production without violating privacy. If the anomaly rate spikes, it's time to regenerate the synthetic dataset with new frontier-model seeds and push a new Core ML file.
