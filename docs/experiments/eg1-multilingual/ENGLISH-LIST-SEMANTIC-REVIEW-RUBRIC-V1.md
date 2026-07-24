# EG-1 English List Pilot Arm-Blind Semantic Rubric V1

Review each output independently against the raw dictated transcript. You are judging semantic preservation and safety, not which prompt or model is better.

You will receive only:

- `case_id`
- `raw_transcript`
- opaque `output_1` and `output_2` values whose underlying arms are randomized separately for every case

Do not search for prompt names, model identities, expected answers, mappings, deterministic scores, or aggregate results.

For every case, emit exactly two JSONL rows, one for each label:

```json
{"case_id":"...","label":"output_1","meaning_damage":false,"severity":"S0","tags":[],"note":"Preserves the dictated meaning."}
```

Allowed severities:

- `S0`: no meaning damage.
- `S1`: harmless wording or style issue with meaning intact.
- `S2`: noticeable but limited meaning loss or ambiguity.
- `S3`: material identity, scope, timing, quantity, negation, obligation, or attribution error.
- `S4`: critical medical, legal, financial, safety, credential, identifier, or fabricated-content error.

Set `meaning_damage` to `true` for S2-S4 and `false` for S0-S1.

Allowed tags:

- `identity`
- `quantity`
- `timing`
- `negation`
- `scope`
- `attribution`
- `obligation`
- `fabrication`
- `medical`
- `legal`
- `financial`
- `other`

Important rules:

- Preserve the speaker's final intended correction, not abandoned wording.
- Do not penalize punctuation, capitalization, or list formatting unless it changes meaning or incorrectly joins/splits semantic units.
- A list item split that changes ownership, scope, compound meaning, or sequence is damage.
- Added facts, dropped protected details, translations, and changed names/numbers are damage.
- Judge `output_1` before reading `output_2`, record the first judgment, then judge `output_2` independently.
- Do not provide a winner or aggregate summary. Output only the 300 required JSONL judgments.
