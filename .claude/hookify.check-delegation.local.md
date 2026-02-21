---
name: check-delegation
enabled: true
event: stop
pattern: .*
---

**Before stopping, verify delegation discipline:**

- Did you delegate implementation to agents (Rules 2-3)?
- Did you read `.claude/knowledge/` files before acting (Rule 6)?
- Did you use skills where they existed (superpowers workflow)?
- If 2+ agents were needed, did you use TeamCreate (Rule 7)?

You are a **coordinator only** — if you wrote application source code directly, that's a violation.
