---
name: warn-fluidaudio-qualifier
enabled: true
event: file
conditions:
  - field: new_text
    operator: regex_match
    pattern: FluidAudio\.\w+
---

**FluidAudio naming collision detected!**

The FluidAudio module exports a struct `FluidAudio` that shadows the module name.
`FluidAudio.AsrManager`, `FluidAudio.VadManager`, etc. will NOT compile.

**Fix:** Use unqualified names — `AsrManager`, `VadManager`, `AsrModels` — and rely on type inference.

See `.claude/knowledge/gotchas.md` and skill `wispr-resolve-naming-collisions`.
