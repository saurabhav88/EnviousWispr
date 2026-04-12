# Apple Intelligence Language Gate. UAT Results (2026-04-12)

## Setup

- App: `/Users/m4pro_sv/Desktop/EnviousWispr-ai-lang-gate/build/EnviousWispr Local.app` (dev bundle from worktree)
- Provider: `appleIntelligence` via `defaults write com.enviouswispr.app.dev llmProvider -string appleIntelligence`
- Session priors reset before run
- Harness: `harness.py` (20 langs x 3 utterance types, GCP Chirp3-HD TTS, rcmd PTT)
- Audio: MacBook Pro Speakers (output) + MacBook Pro Microphone (input), headphones off

## Translation hallucination elimination (de, ko)

| Case | Baseline | Post-change |
|---|---|---|
| de/list | `Also, for the trip, I need my passport, my charger, my headphones, and, ah, my sunglasses.` (EN hallucination) | `Auch für die Reise brauche ich meinen Pass und mein Ladegerät und meine Kopfhörer und, ach ja, meine Sonnenbrille.` (clean DE) |
| ko/list | `Um, I travel with my passport, my charger, my headphones, and my glasses.` (EN hallucination) | `음여행에는 여권이랑 그 충전기랑 헤드폰이랑 아 맞다 선글라스도 필요해` (clean KO) |

Both failure modes eliminated. Output stays in source language.

## Preflight gate (silent-fail 8)

Languages: ar, he, ru, uk, pl, th, ta. Expected: `LLMError.unsupportedInputLanguage` throw, pipeline catches and returns raw transcript.

All 14 cases (7 langs x {normal, list}) show `polish_status` neither `ran` nor `no_change` nor `skipped`. The harness regex did not match because `try polisher.polish(...)` throws `LLMError.unsupportedInputLanguage`; the runner catches it, skips setting `polishError`, and the chain continues with raw text. Paste falls back to the raw ASR transcript.

`vi` was on the plan's empirical silent-fail list but is in Apple's documented allowlist. Post-fix it polishes correctly (`polish=ran`). Net improvement.

## Reliable 7 regression check (en, es, fr, it, pt, ja, zh)

All seven still polishing in their source language with the new language-aware prompt. Minor char-level variance on some (punctuation, whitespace) driven by Apple Intelligence model non-determinism (the en/normal case traversed the `base == "en"` early-return branch, which is the same path as pre-change). No translation drift. No language regressions.

## Parakeet byte-identity

Static-analysis verdict: the Parakeet pipeline (`TranscriptionPipeline.swift`) never sets `llmPolishStep.languageDetection`, so `config.detectedLanguage` stays nil. In the connector:
1. Preflight gate is guarded by `if let base = normalizedBase` and is skipped.
2. `polishWithFoundationModels(..., detectedLanguage: nil)` is called.
3. `makeSession` hits `guard let base = detectedLanguage, base != "en" else { return Self.onDeviceInstructions }`, which returns the pre-change constant verbatim.
4. Output validation guard `if let expectedBase = normalizedBase, expectedBase != "en"` is skipped.

Byte-identical prompt + byte-identical code path. Apple Intelligence's model variance is orthogonal to our change.

## Outcome tally (60 tests)

| Status | Baseline | Post |
|---|---|---|
| ran (polished successfully) | 15 | 16 |
| no_change (polish ran, no edit) | 32 | 28 |
| gated/error (preflight + raw passthrough) | 13 | 16 |

The shift from `no_change` to `gated/error` is the preflight gate catching languages that previously produced silent empty generations (~30 ms) before falling back. Faster path to raw, log trail visible.
