# WhisperPreviewTokenizer — provenance

The tokenizer for `openai_whisper-small_216MB`, the Live Preview universal model (#2108, epic #2077).

| | |
|---|---|
| Source | `https://huggingface.co/openai/whisper-small` |
| Pinned revision | `973afd24965f72e36ca33b3055d56a652f456b4d` |
| Declared licence | **Apache-2.0**, from the repo's own HF card metadata (`cardData.license`), read from the API on 2026-08-16 |
| Files | `tokenizer.json` (2,480,466 B), `tokenizer_config.json` (282,683 B) |
| `LICENSE` | **Not present in the source repo at that revision.** The Apache-2.0 text here is the standard licence the repo declares, copied from the sibling `WhisperTokenizer/LICENSE`. It is the licence text, not a file retrieved from that repo — recorded plainly so nobody later cites it as evidence the repo shipped one. |

## Why this exists as a separate bundled artifact

**The sibling `WhisperTokenizer/` cannot be reused, and reusing it fails silently.**

WhisperKit resolves a tokenizer through `ModelUtilities.loadTokenizer`, which searches, in order:

1. `<tokenizerFolder>/models/<tokenizerNameForVariant(variant)>/tokenizer.json`
2. `<tokenizerFolder>/tokenizer.json` — **top level, variant-agnostic**
3. additional search paths
4. otherwise **download from the Hugging Face Hub**

`WhisperTokenizer/` holds a top-level `tokenizer.json` and no hub-structured subfolder, so large-v3
resolves at step 2. Passing that same folder for the small model ALSO resolves at step 2 — and loads
the large-v3 vocabulary into a small model. Measured 2026-08-16: it loaded successfully and reported
`noSpeechToken=50363`, the large-v3 id. No error, no warning; it would have transcribed fluently and
wrongly. The two `tokenizer.json` files are genuinely different artifacts (SHA-256
`27fc476b…` here versus `6d8cbd7c…` there).

Passing `nil` instead is not a fallback: measured on the same day it also loaded, reporting
`noSpeechToken=50257`, because `WhisperKit.loadModels` calls `loadTokenizerIfNeeded()` INDEPENDENTLY
of the `download` flag — `download: false` gates the model folder, never tokenizer resolution. So
`nil` can reach the network, outside ModelDelivery's per-file SHA-256 verification.

Hence this folder, laid out at the **hub-structured path** `models/openai/whisper-small/` so that
resolution succeeds at step 1 and never reaches steps 2 through 4.

## What must stay true

- The layout is load-bearing. Flattening these files to the top level would make this folder
  behave exactly like the one it exists to avoid.
- `openai/whisper-small` is the repo id WhisperKit derives for the `.small` variant
  (`ModelUtilities.tokenizerNameForVariant`). If the preview model's variant ever changes, this path
  changes with it.
- The loaded instance's special-token identity is asserted at runtime, not assumed. Both wrong paths
  above load successfully, so "it loaded" is not evidence that it loaded the right thing.
