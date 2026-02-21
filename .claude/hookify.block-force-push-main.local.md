---
name: block-force-push-main
enabled: true
event: bash
pattern: git\s+push\s+.*--force|git\s+push\s+.*-f(\s|$)
action: block
---

**Force push blocked.**

This is a public repository (github.com/saurabhav88/EnviousWispr).
Force pushing can destroy commit history and break collaborator state.

If you truly need to force push to a non-main branch, ask the user first.
