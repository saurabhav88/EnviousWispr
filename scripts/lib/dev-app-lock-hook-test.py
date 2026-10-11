#!/usr/bin/env python3
"""Harness contracts: native lock routing against an isolated real lock owner."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent


class HookTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='lock-hook-test.')
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.card_path = root / 'lock/holder.json'
        lock_source = (HERE / 'dev-app-lock.py').read_text()
        anchor = 'LOCK_DIR = os.path.expanduser("~/Library/Caches/EnviousWispr/dev-app-lock")'
        self.assertEqual(lock_source.count(anchor), 1)
        lock_path = root / 'dev-app-lock.py'
        lock_path.write_text(lock_source.replace(anchor, f'LOCK_DIR = {str(root / "lock")!r}'))
        hook_source = (HERE / 'dev-app-lock-hook.py').read_text()
        anchor = "LOCK_TOOL = Path('/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/scripts/lib/dev-app-lock.py')"
        self.assertEqual(hook_source.count(anchor), 1)
        hook_path = root / 'hook.py'
        hook_path.write_text(hook_source.replace(anchor, f'LOCK_TOOL = Path({str(lock_path)!r})'))
        spec = importlib.util.spec_from_file_location('private_hook', hook_path)
        self.hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.hook)
        probe = patch.object(self.hook.lock, 'process_info', return_value=(1, 'host-start', 'codex'))
        probe.start()
        self.addCleanup(probe.stop)

    def event(self, name='PreToolUse', chat='chat-a', command=None, **fields):
        return dict(hook_event_name=name, session_id=chat, cwd='/tmp',
                    tool_name='Bash', tool_input={'command': command}, **fields)

    def denied(self, command, chat='chat-a'):
        result = self.hook.handle(self.event(command=command, chat=chat))
        return result.get('hookSpecificOutput', {}).get('permissionDecision') == 'deny'

    def test_free_action_refused_own_action_passes_peer_refused(self):
        action = '/tmp/build-dev-app.sh'
        self.assertTrue(self.denied(action))
        self.hook.invoke('chat-a', 'claim')
        self.assertFalse(self.denied(action))
        self.assertTrue(self.denied(action, 'chat-b'))

    def test_executed_routes_and_wrappers(self):
        for command in [
                'bash /tmp/build-dev-app.sh',
                'source /tmp/build-dev-app.sh',
                '. /tmp/build-dev-app.sh',
                'source -- /tmp/build-dev-app.sh',
                '. -- /tmp/build-dev-app.sh',
                'python3.12 /tmp/Tests/RuntimeUAT/uat.py run',
                'env FOO=x python3 -B /tmp/Tests/RuntimeUAT/uat.py run',
                'command open "/tmp/build/EnviousWispr Local.app"',
                'open -a "EnviousWispr Local"',
                'python3 -X utf8 /tmp/Tests/RuntimeUAT/uat.py run',
                'python3 -W ignore /tmp/Tests/RuntimeUAT/uat.py run',
                '/tmp/validate-pr.sh --help',
                '/tmp/validate-pr.sh ignored --self-test',
                'nohup "/tmp/build/EnviousWispr Local.app/Contents/MacOS/EnviousWispr"',
                'bash -lc \'open "/tmp/build/EnviousWispr Local.app"\'',
                'echo "$(/tmp/build-dev-app.sh)"',
                '/tmp/build-dev-app.sh --help',
                'python3 /tmp/Tests/RuntimeUAT/uat.py run --sentence list',
                'osascript -e \'tell application "EnviousWispr Local" to quit\'']:
            with self.subTest(command=command):
                self.assertTrue(self.denied(command))

    def test_readers_prose_heredoc_and_unrelated_apps_pass(self):
        for command in [
                'rg "build-dev-app.sh" scripts',
                'cat scripts/build-dev-app.sh',
                'echo \'open "EnviousWispr Local.app"\'',
                'printf "%s\\n" "kill 123"',
                'cat <<\'TEXT\'\nopen "EnviousWispr Local.app"\nTEXT',
                '# open "EnviousWispr Local.app"\necho ok',
                'open /Applications/Notes.app',
                'open /Applications/EnviousWispr.app',
                'python3 /tmp/Tests/RuntimeUAT/uat.py recipes',
                'python3 /tmp/Tests/RuntimeUAT/uat.py verdict']:
            with self.subTest(command=command):
                self.assertFalse(self.denied(command))
        for command in ('bash /tmp/validate-pr.sh --self-test -c',
                        'bash /tmp/validate-pr.sh --self-test -c \'open "EnviousWispr Local.app"\'',
                        'bash -n /tmp/build-dev-app.sh',
                        'sh -n /tmp/build-dev-app.sh',
                        'zsh -n /tmp/build-dev-app.sh',
                        'bash -nc \'open "EnviousWispr Local.app"\''):
            self.assertFalse(self.denied(command))
        self.assertFalse(self.denied('/tmp/validate-pr.sh --self-test'))
        for script in ('uat.py', 'uat_catalog.py', 'log_verdict.py', 'preflight.py'):
            self.assertFalse(self.denied(f'python3 /tmp/Tests/RuntimeUAT/{script} --self-test'))
        self.assertTrue(self.denied('python3 /tmp/Tests/RuntimeUAT/unknown.py --self-test'))

    def test_release_and_protected_action_never_share_call(self):
        self.hook.invoke('chat-a', 'claim')
        release = f'python3 {self.hook.LOCK_TOOL} release'
        launch = 'open "EnviousWispr Local.app"'
        for command in [f'{release}; {launch}', f'{launch} && {release}',
                        f'{release} & {launch}', f'bash -c \'{release}; {launch}\'',
                        f'echo "$({release})"; {launch}',
                        f'python3 -X utf8 {self.hook.LOCK_TOOL} release; {launch}']:
            with self.subTest(command=command):
                self.assertTrue(self.denied(command))
        self.assertFalse(self.denied(release))
        self.assertTrue(self.card_path.exists())  # hook has no ownership side effects

    def test_claim_in_compound_does_not_satisfy_check(self):
        command = f'python3 {self.hook.LOCK_TOOL} claim && /tmp/build-dev-app.sh'
        self.assertTrue(self.denied(command))
        self.assertFalse(self.card_path.exists())

    def test_old_copy_mutation_refused_after_release(self):
        for command in ('python3 /tmp/old/dev-app-lock.py claim',
                        'python3 -X utf8 /tmp/old/dev-app-lock.py claim',
                        'python3 -W ignore /tmp/old/dev-app-lock.py release',
                        'python3 scripts/lib/dev-app-lock.py claim'):
            with self.subTest(command=command), self.assertRaises(ValueError):
                self.hook.handle(self.event(command=command))
        self.hook.invoke('chat-a', 'claim')
        self.hook.invoke('chat-a', 'release')
        with self.assertRaises(ValueError):
            self.hook.handle(self.event(command='python3 /tmp/old/dev-app-lock.py claim'))

    def test_stop_continues_once_and_callbacks_never_release(self):
        self.hook.invoke('chat-a', 'claim')
        before = self.card_path.read_bytes()
        self.assertEqual(self.hook.handle(self.event(name='Stop')).get('decision'), 'block')
        self.assertNotIn('decision', self.hook.handle(self.event(name='Stop', stop_hook_active=True)))
        for name in ('SessionEnd', 'Interrupt'):
            self.assertIn('systemMessage', self.hook.handle(self.event(name=name)))
            self.assertEqual(self.hook.handle(self.event(name=name, chat='chat-b')), {})
            self.assertEqual(self.card_path.read_bytes(), before)
        self.hook.invoke('chat-a', 'release')
        self.assertEqual(self.hook.handle(self.event(name='Stop')), {})

    def test_native_reminder_only_reaches_holder(self):
        self.hook.invoke('chat-a', 'claim')
        card = json.loads(self.card_path.read_text())
        card['reminded_at'] -= 3600
        self.card_path.write_text(json.dumps(card))
        self.assertEqual(self.hook.handle(self.event(name='PostToolUse', chat='chat-b')), {})
        message = self.hook.handle(self.event(name='PostToolUse'))
        self.assertEqual(message['hookSpecificOutput']['hookEventName'], 'PostToolUse')
        self.assertIn('release', message['hookSpecificOutput']['additionalContext'])

    def test_literal_kill_checks_actual_executable(self):
        from subprocess import CompletedProcess
        for path, expected in [('/tmp/build/EnviousWispr Local.app/Contents/MacOS/EnviousWispr', True),
                               ('/Applications/EnviousWispr.app/Contents/MacOS/EnviousWispr', False),
                               ('/usr/bin/sleep', False)]:
            with self.subTest(path=path), patch.object(self.hook.subprocess, 'run',
                    return_value=CompletedProcess([], 0, path + '\n', '')):
                self.assertEqual(self.denied('kill -TERM 123'), expected)
                for probe in ('kill -0 123', 'kill -s 0 123', 'kill --signal=0 123', 'kill -n 0 123'):
                    self.assertFalse(self.denied(probe))

    def test_malformed_native_identity_and_shell_are_refused(self):
        for event in (self.event(chat=None, command='echo ok'),
                      self.event(chat='bad id', command='echo ok'),
                      self.event(command='open "')):
            with self.subTest(event=event), self.assertRaises((ValueError, self.hook.lock.Undecided)):
                self.hook.handle(event)


if __name__ == '__main__':
    unittest.main()
