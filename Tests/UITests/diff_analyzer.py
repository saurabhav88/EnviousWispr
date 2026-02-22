#!/usr/bin/env python3
"""Analyze git diff to determine what changed and which domains are affected.

Produces structured output for the test generator agent:
- changed_files: list of {path, status, diff_excerpt}
- domains: inferred from file paths
- intent: from optional agent-provided context
- diff_summary: truncated diff content per file
"""

import os
import subprocess
import sys
from typing import Optional


# Domain inference from file paths.
# The LLM decides what to test — this just labels files for structured input.
DOMAIN_RULES = [
    ("Services/HotkeyService", "hotkeys"),
    ("Views/Components/HotkeyRecorderView", "hotkeys"),
    ("Services/PasteService", "clipboard"),
    ("PostProcessing/", "clipboard"),
    ("Audio/", "audio-pipeline"),
    ("ASR/", "audio-pipeline"),
    ("Pipeline/", "audio-pipeline"),
    ("Services/Audio", "audio-pipeline"),
    ("Views/Settings/", "settings-ui"),
    ("Views/Main/", "main-window"),
    ("Views/Overlay/", "overlay"),
    ("Views/Onboarding/", "onboarding"),
    ("LLM/", "llm-polish"),
    ("Models/", "data-models"),
    ("Storage/", "storage"),
    ("Services/PermissionsService", "permissions"),
    ("Utilities/", "utilities"),
    ("App/", "app-lifecycle"),
    ("Resources/", "resources"),
]

MAX_DIFF_PER_FILE = 2000  # chars of diff content per file


def infer_domains(file_path: str) -> list[str]:
    """Infer domains from a file path."""
    domains = []
    for pattern, domain in DOMAIN_RULES:
        if pattern in file_path:
            domains.append(domain)
    return domains if domains else ["unknown"]


def get_git_diff(staged_only: bool = False) -> str:
    """Get git diff output."""
    cmd = ["git", "diff"]
    if staged_only:
        cmd.append("--cached")
    cmd.append("--no-color")
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return result.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""


def get_changed_files() -> list[dict]:
    """Get list of changed files with status."""
    files = []

    # Unstaged changes
    try:
        result = subprocess.run(
            ["git", "diff", "--name-status", "--no-color"],
            capture_output=True, text=True, timeout=10,
        )
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split("\t", 1)
            if len(parts) == 2:
                status_code, path = parts
                status = {"M": "modified", "A": "added", "D": "deleted"}.get(
                    status_code[0], "unknown"
                )
                files.append({"path": path, "status": status, "source": "unstaged"})
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # Staged changes
    try:
        result = subprocess.run(
            ["git", "diff", "--cached", "--name-status", "--no-color"],
            capture_output=True, text=True, timeout=10,
        )
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split("\t", 1)
            if len(parts) == 2:
                status_code, path = parts
                status = {"M": "modified", "A": "added", "D": "deleted"}.get(
                    status_code[0], "unknown"
                )
                # Avoid duplicates
                existing_paths = {f["path"] for f in files}
                if path not in existing_paths:
                    files.append({"path": path, "status": status, "source": "staged"})
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # If no staged/unstaged changes, check last commit
    if not files:
        try:
            result = subprocess.run(
                ["git", "diff", "--name-status", "--no-color", "HEAD~1", "HEAD"],
                capture_output=True, text=True, timeout=10,
            )
            for line in result.stdout.strip().split("\n"):
                if not line.strip():
                    continue
                parts = line.split("\t", 1)
                if len(parts) == 2:
                    status_code, path = parts
                    status = {"M": "modified", "A": "added", "D": "deleted"}.get(
                        status_code[0], "unknown"
                    )
                    files.append({"path": path, "status": status, "source": "last_commit"})
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

    return files


def get_file_diff(file_path: str) -> str:
    """Get truncated diff content for a single file."""
    # Try unstaged first
    try:
        result = subprocess.run(
            ["git", "diff", "--no-color", "--", file_path],
            capture_output=True, text=True, timeout=10,
        )
        if result.stdout.strip():
            return result.stdout[:MAX_DIFF_PER_FILE]
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # Try staged
    try:
        result = subprocess.run(
            ["git", "diff", "--cached", "--no-color", "--", file_path],
            capture_output=True, text=True, timeout=10,
        )
        if result.stdout.strip():
            return result.stdout[:MAX_DIFF_PER_FILE]
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # Try last commit
    try:
        result = subprocess.run(
            ["git", "diff", "--no-color", "HEAD~1", "HEAD", "--", file_path],
            capture_output=True, text=True, timeout=10,
        )
        if result.stdout.strip():
            return result.stdout[:MAX_DIFF_PER_FILE]
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    return ""


def analyze(context: Optional[str] = None) -> dict:
    """Main entry point. Analyze git state and return structured summary.

    Args:
        context: Optional agent-provided description of intent
                 (e.g., "fixed PTT hold release bug")

    Returns:
        Dict with changed_files, domains, intent, diff_summary
    """
    changed_files = get_changed_files()

    # Filter to Swift source files only (skip docs, configs, tests themselves)
    source_files = [
        f for f in changed_files
        if f["path"].endswith(".swift") and "Tests/" not in f["path"]
    ]

    # Infer domains
    all_domains = set()
    for f in source_files:
        for domain in infer_domains(f["path"]):
            all_domains.add(domain)

    # Get diff excerpts
    for f in source_files:
        f["diff_excerpt"] = get_file_diff(f["path"])
        f["domains"] = infer_domains(f["path"])

    # Build diff summary
    diff_parts = []
    for f in source_files:
        if f["diff_excerpt"]:
            diff_parts.append(f"{f['path']}:\n{f['diff_excerpt']}")

    return {
        "changed_files": source_files,
        "all_files": changed_files,
        "domains": sorted(all_domains),
        "intent": context,
        "diff_summary": "\n\n".join(diff_parts),
        "source_file_count": len(source_files),
        "total_file_count": len(changed_files),
    }


# CLI for manual testing
if __name__ == "__main__":
    import json
    context = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else None
    result = analyze(context)
    print(json.dumps(result, indent=2))
