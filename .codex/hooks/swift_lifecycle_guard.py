#!/usr/bin/env python3
"""Guard Swift edits with VVTerm lifecycle review prompts.

Swift edits must happen after the agent has read
docs/engineering/swift-best-practices.md. The read itself is a human/agent
workflow action; this hook enforces the auditable marker that records it.
"""

from __future__ import annotations

import argparse
import pathlib
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


def repo_root() -> pathlib.Path:
    root = run_git(["rev-parse", "--show-toplevel"]).strip()
    return pathlib.Path(root) if root else pathlib.Path.cwd()


STATE_DIR = repo_root() / ".codex" / "state"
BEST_PRACTICES_MARKER = "swift-best-practices-read"


def best_practices_marker_path() -> pathlib.Path:
    return STATE_DIR / BEST_PRACTICES_MARKER


def has_best_practices_marker() -> bool:
    return best_practices_marker_path().exists()


def mark_best_practices_read() -> int:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    best_practices_marker_path().write_text(
        "docs/engineering/swift-best-practices.md\n",
        encoding="utf-8",
    )
    return 0


def reset_best_practices_marker() -> int:
    try:
        best_practices_marker_path().unlink()
    except FileNotFoundError:
        pass
    return 0


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


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mark-best-practices-read",
        action="store_true",
        help="Record that docs/engineering/swift-best-practices.md was read.",
    )
    parser.add_argument(
        "--reset-best-practices-marker",
        action="store_true",
        help="Clear the Swift best-practices read marker for a new session.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.mark_best_practices_read:
        return mark_best_practices_read()
    if args.reset_best_practices_marker:
        return reset_best_practices_marker()

    diff = swift_diff()
    if not diff:
        return 0

    if not has_best_practices_marker():
        print("\nSwift best-practices guard:", file=sys.stderr)
        print(
            "- Swift files changed, but this session has not recorded reading docs/engineering/swift-best-practices.md.",
            file=sys.stderr,
        )
        print(
            "- Read the document, then run: python3 .codex/hooks/swift_lifecycle_guard.py --mark-best-practices-read",
            file=sys.stderr,
        )
        return 1

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
