# Ollama library routine (#2778)

A weekly Claude Code routine (Sonnet 5.5) that proposes additions to
`website/public/ollama-library.json`. That file is served at
`https://enviouswispr.com/ollama-library.json` and read by the app (`OllamaLibraryFeedClient`).
This is not a Worker: nothing here is deployed with `wrangler`.

| Piece | Where |
|---|---|
| Routine prompt (reference copy) | `routine-prompt.md` |
| Candidate scan (deterministic) | `scripts/ollama-library/scan.py` |
| Feed validator (offline in CI, registry at routine time) | `scripts/ollama-library/validate-feed.py` |
| Shared helpers and name fixtures | `scripts/ollama-library/library.py`, `name-fixtures.json` |
| App parser (runtime authority) | `Sources/EnviousWisprLLM/OllamaLibraryFeedClient.swift` |
| Committed-file test | `Tests/EnviousWisprTests/LLM/OllamaLibraryFeedTests.swift` |

## Status: DISABLED until activated

The routine does not exist yet. Create it only after both gates below.

### Activation gates

1. **Capability probe** in the chosen routine environment. Prove, and record the actor and the evidence on
   #2778: it can reach `ollama.com` and `registry.ollama.ai`; it can authenticate and push a branch; it can
   open a pull request; CI triggers on that pull request; review handling works; which merge operations it
   is permitted. The existing Sentry triage routines are forbidden to push, so push permission is NOT
   inherited from them, and there is no fallback to their environment. Least privilege: only the connectors and credentials this
   needs. No Discord.
2. **Founder decision on weekly review.** Feed-only pull requests follow the normal review gates
   (independent review before anything user-facing ships, and one cloud review round per pull request). Either an engineering session on the
   Mac reviews and merges each weekly pull request, or the founder grants a written exemption for
   feed-only pull requests gated by the deterministic checks. Record the decision on #2778.

### Creating it

Create the routine at `claude.ai/code/routines/new` with the prompt in `routine-prompt.md` (strip the
leading comment block), cron `30 13 * * 1`, model Sonnet 5.5. To change the prompt later, edit the
routine's Instructions box and compare the saved text with `routine-prompt.md`. Record the trigger ID
on issue #2778.

## What cannot go wrong silently

- A bad file cannot merge: `pr-check.yml` runs `validate-feed.py --offline` against the PR base, and the
  Swift lane (forced for this path by `scripts/ci/classify-changes.sh`) parses the committed file with the
  production parser and fails if any row would be dropped.
- A made-up model name cannot be added: `validate-feed.py --registry` (routine time) requires the registry
  manifest to answer 200 and its layer sizes to equal `sizeBytes`.
- A hostile feed cannot widen what the app trusts: the app re-validates every row, a row cannot carry a
  verdict, and every row reads "Not tested by us".

## Recovery

Disabling the routine stops new proposals but does not clear published rows. The add-only validator rejects
clearing a populated feed, so clearing needs a separately reviewed engineering pull request that explicitly
revises the publication policy for that reset and publishes an empty feed. The routine cannot do it. Once an
empty feed is deployed, apps clear their retained rows on the next successful refresh.

## If Ollama changes its library page

`scan.py` exits non-zero with `layout changed` when it parses fewer than 100 cards. The routine files an
issue; a person fixes `library.py` (`_CardParser`) in a normal reviewed pull request.
