---
name: block-xcodebuild
enabled: true
event: bash
conditions:
  - field: command
    operator: regex_match
    pattern: (^|\s|&&|\|)\s*(xcodebuild|xctest)
action: block
---

**This project uses Command Line Tools only — no Xcode.**

- Use `swift build`, never `xcodebuild`
- No XCTest framework
- See CLAUDE.md Environment section and `.claude/knowledge/gotchas.md`
