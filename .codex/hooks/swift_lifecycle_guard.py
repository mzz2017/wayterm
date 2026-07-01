#!/usr/bin/env python3
"""Guard Swift edits with Waterm lifecycle review prompts.

Swift edits must happen after the agent has read
docs/engineering/swift-best-practices.md. The read itself is a human/agent
workflow action; this hook enforces the auditable marker that records it.
"""

from __future__ import annotations

import argparse
import json
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
BEST_PRACTICES_DOCUMENT = "docs/engineering/swift-best-practices.md"
BEST_PRACTICES_DOCUMENT_NAME = "swift-best-practices.md"
SWIFT_PATH_PATTERN = re.compile(r"(?m)(?:^|\s|['\"])([^'\"\s]+\.swift)(?:$|\s|['\"]|:)")


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


def string_mentions_best_practices_document(value: str) -> bool:
    normalized = value.replace("\\", "/")
    return (
        normalized.endswith(BEST_PRACTICES_DOCUMENT)
        or normalized.endswith(BEST_PRACTICES_DOCUMENT_NAME)
        or BEST_PRACTICES_DOCUMENT in normalized
    )


def command_reads_best_practices_document(command: str) -> bool:
    if not string_mentions_best_practices_document(command):
        return False
    return bool(re.search(r"\b(rtk\s+read|read|sed|cat|nl)\b", command))


def tool_use_marks_best_practices_read(payload: object) -> bool:
    if not isinstance(payload, dict):
        return False

    tool_name = str(
        payload.get("tool_name")
        or payload.get("tool")
        or payload.get("name")
        or payload.get("recipient_name")
        or payload.get("recipient")
        or ""
    )
    tool_input = (
        payload.get("tool_input")
        or payload.get("input")
        or payload.get("parameters")
        or payload.get("arguments")
        or payload.get("args")
        or {}
    )

    if not isinstance(tool_input, dict):
        return False

    nested_tool_uses = tool_input.get("tool_uses")
    if isinstance(nested_tool_uses, list):
        for nested in nested_tool_uses:
            if not isinstance(nested, dict):
                continue
            nested_payload = {
                "tool_name": nested.get("recipient_name") or nested.get("tool_name") or "",
                "tool_input": nested.get("parameters") or nested.get("tool_input") or {},
            }
            if tool_use_marks_best_practices_read(nested_payload):
                return True

    if re.search(r"(^|\.)Read$", tool_name):
        file_path = str(
            tool_input.get("file_path")
            or tool_input.get("path")
            or tool_input.get("uri")
            or tool_input.get("ref_id")
            or ""
        )
        return string_mentions_best_practices_document(file_path)

    if "exec_command" in tool_name:
        command = str(tool_input.get("cmd") or tool_input.get("command") or "")
        return command_reads_best_practices_document(command)

    return False


def any_nested_tool_use_marks_best_practices_read(value: object) -> bool:
    if tool_use_marks_best_practices_read(value):
        return True
    if isinstance(value, dict):
        return any(any_nested_tool_use_marks_best_practices_read(item) for item in value.values())
    if isinstance(value, list):
        return any(any_nested_tool_use_marks_best_practices_read(item) for item in value)
    if isinstance(value, str):
        return command_reads_best_practices_document(value)
    return False


def mark_best_practices_read_from_tool_use() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    if any_nested_tool_use_marks_best_practices_read(payload):
        return mark_best_practices_read()
    return 0


def string_mentions_swift_path(value: str) -> bool:
    normalized = value.replace("\\", "/")
    return ".swift" in normalized and SWIFT_PATH_PATTERN.search(normalized) is not None


def tool_use_touches_swift(payload: object) -> bool:
    if not isinstance(payload, dict):
        return False

    tool_name = str(
        payload.get("tool_name")
        or payload.get("tool")
        or payload.get("name")
        or payload.get("recipient_name")
        or payload.get("recipient")
        or ""
    )
    tool_input = (
        payload.get("tool_input")
        or payload.get("input")
        or payload.get("parameters")
        or payload.get("arguments")
        or payload.get("args")
        or {}
    )

    if "apply_patch" in tool_name:
        if isinstance(tool_input, str):
            return string_mentions_swift_path(tool_input)
        return any_nested_value_mentions_swift(tool_input)

    if re.search(r"(^|\.)(Edit|Write)$", tool_name):
        return any_nested_value_mentions_swift(tool_input)

    return any_nested_value_mentions_swift(tool_input)


def any_nested_value_mentions_swift(value: object) -> bool:
    if isinstance(value, str):
        return string_mentions_swift_path(value)
    if isinstance(value, dict):
        return any(any_nested_value_mentions_swift(item) for item in value.values())
    if isinstance(value, list):
        return any(any_nested_value_mentions_swift(item) for item in value)
    return False


def print_blocked_best_practices_notice() -> None:
    print("", file=sys.stderr)
    print("WATERM HOOK BLOCKED: Swift edit needs lifecycle prep", file=sys.stderr)
    print("---------------------------------------------------", file=sys.stderr)
    print(
        "Read docs/engineering/swift-best-practices.md before editing Swift files.",
        file=sys.stderr,
    )
    print(
        "Then mark the session:",
        file=sys.stderr,
    )
    print(
        "  python3 .codex/hooks/swift_lifecycle_guard.py --mark-best-practices-read",
        file=sys.stderr,
    )


def preflight_swift_edit_from_tool_use() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    if not tool_use_touches_swift(payload):
        return 0
    if has_best_practices_marker():
        return 0

    print_blocked_best_practices_notice()
    return 1


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
    parser.add_argument(
        "--mark-best-practices-read-from-tool-use",
        action="store_true",
        help="Record the marker when PostToolUse input shows the best-practices doc was read.",
    )
    parser.add_argument(
        "--preflight-swift-edit-from-tool-use",
        action="store_true",
        help="Block Swift edit tool use before the best-practices marker exists.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.mark_best_practices_read:
        return mark_best_practices_read()
    if args.reset_best_practices_marker:
        return reset_best_practices_marker()
    if args.mark_best_practices_read_from_tool_use:
        return mark_best_practices_read_from_tool_use()
    if args.preflight_swift_edit_from_tool_use:
        return preflight_swift_edit_from_tool_use()

    diff = swift_diff()
    if not diff:
        return 0

    if not has_best_practices_marker():
        print_blocked_best_practices_notice()
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
