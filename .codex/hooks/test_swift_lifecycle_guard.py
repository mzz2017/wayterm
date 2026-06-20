#!/usr/bin/env python3
"""Tests for the Swift lifecycle Codex hook guard."""

from __future__ import annotations

import importlib.util
import io
import pathlib
import tempfile
import unittest
from contextlib import redirect_stderr
from unittest import mock


HOOK_PATH = pathlib.Path(__file__).with_name("swift_lifecycle_guard.py")


def load_guard_module():
    spec = importlib.util.spec_from_file_location("swift_lifecycle_guard", HOOK_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("Unable to load swift_lifecycle_guard.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SwiftLifecycleGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.guard = load_guard_module()

    def test_swift_diff_without_best_practices_marker_blocks(self) -> None:
        diff = """diff --git a/Foo.swift b/Foo.swift
--- a/Foo.swift
+++ b/Foo.swift
@@ -1 +1,2 @@
+Task {
+}
"""

        with tempfile.TemporaryDirectory() as tmpdir:
            state_dir = pathlib.Path(tmpdir)
            stderr = io.StringIO()
            with mock.patch.object(self.guard, "swift_diff", return_value=diff), \
                mock.patch.object(self.guard, "STATE_DIR", state_dir), \
                redirect_stderr(stderr):
                exit_code = self.guard.main([])

        self.assertEqual(exit_code, 1)
        self.assertIn("docs/engineering/swift-best-practices.md", stderr.getvalue())

    def test_swift_diff_with_best_practices_marker_passes(self) -> None:
        diff = """diff --git a/Foo.swift b/Foo.swift
--- a/Foo.swift
+++ b/Foo.swift
@@ -1 +1,2 @@
+Task {
+}
"""

        with tempfile.TemporaryDirectory() as tmpdir:
            state_dir = pathlib.Path(tmpdir)
            stderr = io.StringIO()
            with mock.patch.object(self.guard, "swift_diff", return_value=diff), \
                mock.patch.object(self.guard, "STATE_DIR", state_dir), \
                redirect_stderr(stderr):
                self.guard.best_practices_marker_path().write_text("read\n", encoding="utf-8")
                exit_code = self.guard.main([])

        self.assertEqual(exit_code, 0)
        self.assertIn("Swift lifecycle guard", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
