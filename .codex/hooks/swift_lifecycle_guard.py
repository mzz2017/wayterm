#!/usr/bin/env python3
"""Warn about Swift lifecycle risk patterns in the current diff.

This hook is intentionally non-blocking. It prints review prompts for patterns
that often need human/agent judgment instead of trying to enforce architecture.
"""

from __future__ import annotations

import re
import subprocess
import sys


def run_git(args: list[str]) -> str:
    try:
        return subprocess.check_output(
            ["git", *args],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except subprocess.CalledProcessError:
        return ""


def swift_diff() -> str:
    unstaged = run_git(["diff", "--", "*.swift"])
    staged = run_git(["diff", "--cached", "--", "*.swift"])
    return "\n".join(part for part in [unstaged, staged] if part)


def added_lines(diff: str) -> list[str]:
    return [
        line[1:]
        for line in diff.splitlines()
        if line.startswith("+") and not line.startswith("+++")
    ]


def main() -> int:
    diff = swift_diff()
    if not diff:
        return 0

    added = "\n".join(added_lines(diff))
    warnings: list[str] = []

    if re.search(r"\bTask\.detached\s*\{|\bTask\.detached\s*\(", added):
        warnings.append(
            "Task.detached added in Swift diff. If lifecycle-critical, make it awaited or tracked."
        )

    if re.search(r"\bTask\s*\{", added):
        warnings.append(
            "Unstructured Task added in Swift diff. Check whether close/disconnect/auth/save/delete cleanup can outlive its owner."
        )

    if re.search(r"(dismantleUIView|dismantleNSView|onDisappear|deinit)", added) and re.search(
        r"(disconnect|closeShell|cancelShell|cleanup|delete|save|sync|auth)", added
    ):
        warnings.append(
            "SwiftUI lifecycle callback/deinit appears to perform resource work. Confirm application layer owns business lifecycle."
        )

    if re.search(r"\b(class|final class)\s+Coordinator\b", added) and re.search(
        r"(SSHClient|FileHandle|Timer|URLSession|Socket|OpaquePointer)", added
    ):
        warnings.append(
            "Coordinator appears to own a long-lived resource. Confirm a manager/actor/service is the stable owner."
        )

    if not warnings:
        return 0

    print("\nSwift lifecycle guard:", file=sys.stderr)
    for warning in dict.fromkeys(warnings):
        print(f"- {warning}", file=sys.stderr)
    print(
        "- For Swift lifecycle work, use $swift-apple-lifecycle and review docs/engineering/swift-best-practices.md.",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
