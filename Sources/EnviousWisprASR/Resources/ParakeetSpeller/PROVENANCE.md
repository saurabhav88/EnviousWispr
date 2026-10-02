# ParakeetSpeller — provenance

`parakeet-v3-speller.json` is the BPE vocabulary, merges (file order) and added tokens of NVIDIA's
Parakeet TDT 0.6B v3 tokenizer, used by `ParakeetPhraseSpeller` (#3338) to spell a word into the
model's token ids. No normalizer table is included: the speller applies NFC and refuses inputs that
NFKC would change (#2610 §3.2).

| | |
|---|---|
| Source | `https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/blob/541d1f99c6b0c3cd0b11a95167540bb8edefd82b/tokenizer.json` |
| Pinned revision | `541d1f99c6b0c3cd0b11a95167540bb8edefd82b` |
| Source SHA-256 | `bd321b096832a3f270bd3b2a88823957920f1a5c5ada71114a26ea729d0cbe91` |
| Generated SHA-256 | `ebe7f485eb5e187449df47fb35ab47d4cf7e2810bd5b6efbd6bb968a872d6973` (also `ParakeetPhraseSpeller.resourceSHA256`) |
| Licence | CC-BY-4.0, from the NVIDIA model card. Attribution: "Parakeet TDT 0.6B v3" by NVIDIA, https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3, licensed CC-BY-4.0 (https://creativecommons.org/licenses/by/4.0/). Changes: the tokenizer's vocabulary, merges and added tokens re-serialized as JSON. |

Regenerate (byte-identical on rerun):

```
python3 scripts/parakeet-speller-data.py resource <tokenizer.json at the pinned revision> \
  Sources/EnviousWisprASR/Resources/ParakeetSpeller/parakeet-v3-speller.json
```

The resource is not yet in the app bundle: no production code calls the speller. The PR that adds the
first caller adds the bundle entry (`Project.swift`) and the THIRD-PARTY-NOTICES entry.
