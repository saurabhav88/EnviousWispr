---
name: swift-format-check
description: Check Swift formatting across the project without modifying files. Reports files that would change.
disable-model-invocation: true
---

# Swift Format Check

Run `swift-format lint` across all Swift source files to identify formatting violations without modifying any files.

## Steps

1. Find the `swift-format` binary (check `~/bin/swift-format`, `/usr/local/bin/swift-format`, or the project-local build at `/tmp/swift-format-build/.build/release/swift-format`).
2. If not found, tell the user swift-format is not installed and suggest building it:
   ```
   git clone --depth 1 https://github.com/swiftlang/swift-format.git /tmp/swift-format-build
   cd /tmp/swift-format-build && swift build -c release
   cp .build/release/swift-format ~/bin/
   ```
3. Run: `find Sources/ -name '*.swift' | xargs <swift-format> lint 2>&1`
4. Summarize the results:
   - If clean: report "All Swift files pass formatting checks."
   - If violations found: list each file with its violation count and the most common violation types.
5. Optionally, if the user asks, run `swift-format format --in-place` to auto-fix.
