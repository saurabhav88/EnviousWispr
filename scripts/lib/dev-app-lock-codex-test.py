#!/usr/bin/env python3
"""Harness contract: different Codex chats sharing a host cannot share a hold.

Runs an isolated, checked private copy. Never touches the live holder card.
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import subprocess
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch


class CodexOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="codex-lock-test.")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        source = Path(__file__).with_name("dev-app-lock.py").read_text()
        anchor = 'LOCK_DIR = os.path.expanduser("~/Library/Caches/EnviousWispr/dev-app-lock")'
        self.assertEqual(source.count(anchor), 1, "private lock rewrite must match once")
        self.lock_dir = root / "lock"
        copy = root / "lock.py"
        copy.write_text(source.replace(anchor, f"LOCK_DIR = {str(self.lock_dir)!r}"))
        spec = importlib.util.spec_from_file_location("private_lock", copy)
        self.lock = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.lock)
        self.copy = copy
        # Two chats have the SAME host PID and start time, as in Codex desktop.
        self.probe = patch.object(self.lock, "process_info", return_value=(1, "host-start", "codex"))
        self.process_probe = self.probe.start()
        self.addCleanup(self.probe.stop)

    def command(self, chat, *args):
        env = {k: v for k, v in os.environ.items()
               if k not in ("CODEX_THREAD_ID", "CODEX_SESSION_ID")}
        if chat is not None:
            env.update(CODEX_THREAD_ID=chat, CODEX_SESSION_ID=chat)
        out = io.StringIO()
        with patch.dict(os.environ, env, clear=True), contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            result = self.lock.main(list(args))
        return result, out.getvalue()

    def test_other_chat_on_same_host_cannot_claim_or_release(self):
        self.assertEqual(self.command("chat-a", "claim", "--label", "first")[0], 0)
        before = (self.lock_dir / "holder.json").read_bytes()
        self.assertEqual(self.command("chat-b", "claim")[0], 3)
        self.assertEqual(self.command("chat-b", "release")[0], 3)
        self.assertEqual((self.lock_dir / "holder.json").read_bytes(), before)
        self.assertEqual(self.command("chat-a", "claim")[0], 0)
        self.assertEqual(self.command("chat-a", "release")[0], 0)

    def test_codex_without_chat_id_refuses_instead_of_sharing_host(self):
        self.assertEqual(self.command(None, "claim")[0], 2)
        self.assertFalse((self.lock_dir / "holder.json").exists())

    def test_identity_combinations_and_native_override(self):
        for values, expected in [
                ({"CODEX_THREAD_ID": "a"}, "a"),
                ({"CODEX_SESSION_ID": "b"}, "b"),
                ({"CODEX_THREAD_ID": "a", "CODEX_SESSION_ID": "a"}, "a"),
                ({"CODEX_THREAD_ID": "a", "CODEX_SESSION_ID": "b"}, "a"),
                ({"CODEX_THREAD_ID": "a", "CODEX_SESSION_ID": "invalid legacy id"}, "a"),
                ({"CODEX_THREAD_ID": ""}, None),
                ({"CODEX_THREAD_ID": "a b"}, None),
                ({"CODEX_THREAD_ID": "a" * 129}, None)]:
            with self.subTest(values=values), patch.dict(os.environ, values, clear=True):
                if expected is None:
                    with self.assertRaises(self.lock.Undecided):
                        self.lock.find_session()
                else:
                    self.assertEqual(self.lock.find_session()["session_id"], expected)
                self.assertEqual(self.lock.find_session("native-hook-chat")["session_id"], "native-hook-chat")

    def test_codex_context_without_host_never_becomes_founder(self):
        self.process_probe.return_value = (1, "host-start", "/bin/zsh")
        self.assertEqual(self.command("chat-a", "claim")[0], 2)
        self.assertEqual(self.command(None, "claim")[0], 0)
        self.assertFalse((self.lock_dir / "holder.json").exists())

    def test_live_legacy_codex_card_is_not_adopted(self):
        self.command("chat-a", "claim")
        card_path = self.lock_dir / "holder.json"
        legacy = json.loads(card_path.read_text())
        legacy["version"] = 3
        del legacy["session_id"]
        card_path.write_text(json.dumps(legacy))
        before = card_path.read_bytes()
        self.assertEqual(self.command("chat-a", "claim")[0], 3)
        self.assertEqual(self.command("chat-a", "release")[0], 3)
        self.assertEqual(card_path.read_bytes(), before)

    def test_new_reader_preserves_legacy_claude_ownership(self):
        self.process_probe.return_value = (1, "host-start", "claude")
        self.command(None, "claim")
        path = self.lock_dir / "holder.json"
        card = json.loads(path.read_text())
        card["version"] = 3
        path.write_text(json.dumps(card))
        self.assertEqual(self.command(None, "claim")[0], 0)
        self.assertEqual(self.command(None, "release")[0], 0)

    def test_nonce_cannot_release_replacement_claim(self):
        self.command("chat-a", "claim")
        nonce = json.loads((self.lock_dir / "holder.json").read_text())["nonce"]
        self.assertEqual(self.command("chat-a", "release", "--nonce", nonce)[0], 0)
        self.command("chat-a", "claim")
        before = (self.lock_dir / "holder.json").read_bytes()
        self.assertEqual(self.command("chat-a", "release", "--nonce", nonce)[0], 3)
        self.assertEqual((self.lock_dir / "holder.json").read_bytes(), before)

    def test_check_and_holder_only_reminder(self):
        self.assertEqual(self.command("chat-a", "check")[0], 3)
        self.command("chat-a", "claim")
        self.assertEqual(self.command("chat-a", "check")[0], 0)
        self.assertEqual(self.command("chat-b", "check")[0], 3)
        path = self.lock_dir / "holder.json"
        card = json.loads(path.read_text())
        card["reminded_at"] -= 3600
        path.write_text(json.dumps(card))
        self.assertEqual(self.command("chat-b", "remind", "--event", "PostToolUse"), (0, ""))
        rc, message = self.command("chat-a", "remind", "--event", "PostToolUse")
        self.assertEqual(rc, 0)
        self.assertIn("release", json.loads(message)["hookSpecificOutput"]["additionalContext"])

    def test_concurrent_chats_same_host_have_one_winner(self):
        # Every child has this test process as its parent. A private ps fixture
        # reports that SAME parent as codex; lock/card operations are real.
        ps = Path(self.tmp.name) / "ps"
        ps.write_text('#!/bin/sh\nprintf "%s\\n" "1 Sun Oct 11 10:00:00 2026 S codex"\n')
        ps.chmod(0o755)
        text = self.copy.read_text()
        self.assertEqual(text.count('PS = "/bin/ps"'), 1)
        self.copy.write_text(text.replace('PS = "/bin/ps"', f"PS = {str(ps)!r}"))
        def claim(index):
            env = dict(os.environ, CODEX_THREAD_ID=f"chat-{index}", CODEX_SESSION_ID=f"chat-{index}")
            return subprocess.run([os.sys.executable, '-B', str(self.copy), 'claim'],
                                  env=env, capture_output=True, text=True, timeout=30)
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(claim, range(8)))
        self.assertEqual([r.returncode for r in results].count(0), 1)
        self.assertEqual([r.returncode for r in results].count(3), 7)
        self.assertEqual(json.loads((self.lock_dir / "holder.json").read_text())["pid"], os.getpid())

    def test_check_refuses_busy_mutex_without_waiting_for_release(self):
        ps = Path(self.tmp.name) / "ps"
        ps.write_text('#!/bin/sh\nprintf "%s\\n" "1 Sun Oct 11 10:00:00 2026 S codex"\n')
        ps.chmod(0o755)
        source = self.copy.read_text()
        self.assertEqual(source.count('PS = "/bin/ps"'), 1)
        self.copy.write_text(source.replace('PS = "/bin/ps"', f"PS = {str(ps)!r}"))
        with self.lock.Store():
            # deadline-fallback: the subject must refuse while the lock stays held
            result = subprocess.run([os.sys.executable, '-B', str(self.copy), 'check'],
                env=dict(os.environ, CODEX_THREAD_ID='chat-a'), capture_output=True,
                text=True, timeout=2)
        self.assertEqual(result.returncode, 2)
        self.assertIn('BlockingIOError', result.stderr)


if __name__ == "__main__":
    unittest.main()
