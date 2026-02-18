---
name: check-dependency-versions
description: Use when asked to check whether WhisperKit or FluidAudio have new releases available, or before planning a dependency update to confirm the latest stable version numbers.
---

# Check Dependency Versions

## Dependency Registry

| Package | URL | Package.swift identifier |
|---|---|---|
| WhisperKit | https://github.com/argmaxinc/WhisperKit.git | `whisperkit` |
| FluidAudio | https://github.com/FluidInference/FluidAudio.git | `fluidaudio` |

## Step 1 — Read Current Pinned Versions

```bash
cat /Users/m4pro_sv/Desktop/EnviousWispr/Package.swift
```

Note the `.upToNextMajor(from:)` or `.exact()` version string for each dependency.

Also check the resolved file for the actual pinned commit/version:
```bash
cat /Users/m4pro_sv/Desktop/EnviousWispr/Package.resolved
```

## Step 2 — Query Latest GitHub Releases

Use the GitHub API (no auth required for public repos):

```bash
curl -s https://api.github.com/repos/argmaxinc/WhisperKit/releases/latest \
  | grep '"tag_name"'

curl -s https://api.github.com/repos/FluidInference/FluidAudio/releases/latest \
  | grep '"tag_name"'
```

If `releases/latest` returns 404, fall back to listing tags:
```bash
curl -s https://api.github.com/repos/argmaxinc/WhisperKit/tags?per_page=5 \
  | grep '"name"'
```

## Step 3 — Compare and Report

For each dependency produce a one-line summary:

```
WhisperKit : current=0.12.0  latest=0.13.1  → UPDATE AVAILABLE
FluidAudio : current=0.1.0   latest=0.1.0   → up to date
```

## Step 4 — Assess Risk Before Recommending Update

- Minor/patch bump (0.x.Y → 0.x.Z or X.Y.0 → X.Y.1): low risk, recommend.
- Minor bump across 0.x boundary: check changelog for API changes before recommending.
- Major bump: invoke `handle-breaking-changes` skill after updating.

## Step 5 — Update Package.swift (if approved)

Edit the relevant `.package(url:from:)` line in Package.swift with the new version,
then run `swift package update` to pull and re-resolve:

```bash
swift package update
cat /Users/m4pro_sv/Desktop/EnviousWispr/Package.resolved
```

Confirm the resolved version matches the intended target.
