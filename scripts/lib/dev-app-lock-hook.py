#!/usr/bin/env python3
"""Native Codex guardrail for cooperative direct dev-app shell routes.

This isn't a shell/OS security boundary: arbitrary code, runtime expansions,
opaque computer-use and write_stdin remain instruction-governed. Never release
from a lifecycle callback: its payload cannot identify a replacement claim.
Run with the reviewed .codex/hooks/.venv Python (tree-sitter Bash parser).
"""
import contextlib
import getopt
import importlib.util
import io
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

LOCK_TOOL = Path('/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/scripts/lib/dev-app-lock.py')
spec = importlib.util.spec_from_file_location('dev_app_lock', LOCK_TOOL)
lock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lock)


def deny(reason):
    return {'hookSpecificOutput': {'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny', 'permissionDecisionReason': reason}}


def context(name, text):
    return {'hookSpecificOutput': {'hookEventName': name, 'additionalContext': text}}


def invoke(session_id, *argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        result = lock.main(list(argv), native_session_id=session_id)
    return result, out.getvalue().strip()


def commands(command, depth=0):
    """Syntax-tree precedent: quoted data/comments aren't executed commands."""
    from tree_sitter import Language, Parser
    import tree_sitter_bash
    if depth > 6 or not isinstance(command, str):
        raise ValueError('unsupported shell nesting or input')
    tree = Parser(Language(tree_sitter_bash.language())).parse(command.encode())
    if tree.root_node.has_error:
        raise ValueError('ambiguous shell grammar; use a direct command')
    pending = [tree.root_node]
    while pending:
        node = pending.pop()
        pending.extend(reversed(node.named_children))
        if node.type != 'command':
            continue
        fields = [node.child_by_field_name('name'), *node.children_by_field_name('argument')]
        argv = []
        for field in fields:
            if field is None:
                raise ValueError('missing command name')
            raw = field.text.decode()
            decoded = shlex.split(raw, comments=False)
            argv.append(decoded[0] if len(decoded) == 1 else raw)
        argv = unwrap(argv)
        if not argv:
            continue
        yield argv
        if Path(argv[0]).name in ('bash', 'sh', 'zsh'):
            for i, arg in enumerate(argv[1:], 1):
                if arg.startswith('-') and not arg.startswith('--') and 'c' in arg[1:]:
                    if i + 1 >= len(argv):
                        raise ValueError('missing shell -c command')
                    yield from commands(argv[i + 1], depth + 1)
                    break


WRAPPERS = {'env': ('iu:', ['ignore-environment', 'unset=']),
            'command': ('pvV', []), 'exec': ('cla:', []),
            'nohup': ('', ['help', 'version'])}


def unwrap(argv):
    while argv and Path(argv[0]).name in WRAPPERS:
        name = Path(argv[0]).name
        opts, argv = getopt.getopt(argv[1:], *WRAPPERS[name])
        if any(k in ('-v', '-V', '--help', '--version') for k, _ in opts):
            return []
        if name == 'env':
            while argv and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*=.*', argv[0], re.S):
                argv = argv[1:]
    return argv


def dev_path(text):
    return ('EnviousWispr Local.app' in text or 'com.enviouswispr.app.dev' in text)


def script_argument(argv):
    """Parse interpreter options before the script; never inspect script data."""
    if argv[0] == '.' or Path(argv[0]).name == 'source':
        rest = argv[2:] if argv[1:2] == ['--'] else argv[1:]
        return (rest[0], rest[1:]) if rest else (None, [])
    python = re.fullmatch(r'python(?:3(?:\.[0-9]+)?)?', Path(argv[0]).name) is not None
    if python or Path(argv[0]).name in ('bash', 'sh', 'zsh'):
        short = 'bBdEhiIOPqRsSuVvxW:X:c:m:' if python else 'abefhklmnptuvxBCEHPTc:o:O:'
        long = ['help', 'version', 'check-hash-based-pycs='] if python else ['noprofile', 'norc', 'posix', 'rcfile=']
        opts, rest = getopt.getopt(argv[1:], short, long)
        # Inline code/modules are outside this guard's direct-script scope.
        if any(key in ('-c', '-m', '-h', '--help', '-V', '--version') for key, _ in opts):
            return None, []
        return (rest[0], rest[1:]) if rest else (None, [])
    return argv[0], argv[1:]


def route(argv):
    """Return (protected action, lock mutation, release). Readers stay readers."""
    name = Path(argv[0]).name
    script, arguments = script_argument(argv)
    if script is not None and Path(script).name == 'dev-app-lock.py':
        mutation = arguments[:1] in (['claim'], ['release'])
        if mutation and (not Path(script).is_absolute() or Path(script).resolve() != LOCK_TOOL.resolve()):
            raise ValueError('use the main-checkout lock owner by absolute path')
        return False, mutation, arguments[:1] == ['release']
    if script is not None:
        if Path(script).name == 'build-dev-app.sh':
            return True, False, False  # It has no help/self-test argument contract.
        if Path(script).name == 'validate-pr.sh':
            # Its only reader entrypoint is literal first argument --self-test.
            return arguments[:1] != ['--self-test'], False, False
        if '/RuntimeUAT/' in '/' + script:
            reader = (Path(script).name == 'uat.py' and
                      arguments[:1] in (["recipes"], ["preflight"], ["verdict"], ["--help"]))
            return not reader, False, False
        if dev_path(script) and script.endswith('/Contents/MacOS/EnviousWispr'):
            return True, False, False
    if name == 'open':
        return any(dev_path(arg) or arg == 'EnviousWispr Local' for arg in argv[1:]), False, False
    if name in ('pkill', 'killall', 'osascript'):
        # Production ambiguity remains refused by the existing safety owners.
        return any(dev_path(arg) or 'EnviousWispr' in arg for arg in argv[1:]), False, False
    if name == 'kill':
        args = argv[1:]
        if args[:1] in (['-0'], ['--signal=0']):
            rest = args[1:]
        elif args[:2] in (['-s', '0'], ['-n', '0'], ['--signal', '0']):
            rest = args[2:]
        else:
            rest = []
        if rest and all(arg == '--' or re.fullmatch(r'-?[0-9]+', arg) for arg in rest):
            return False, False, False  # signal zero probes; no signal is sent
        targets = [arg for arg in argv[1:] if re.fullmatch(r'[0-9]+', arg)]
        for target in targets:
            probe = subprocess.run(['/bin/ps', '-o', 'comm=', '-p', target],
                capture_output=True, text=True, timeout=10)
            if probe.returncode == 1 and not probe.stdout.strip() and not probe.stderr.strip():
                continue
            if probe.returncode or probe.stderr.strip():
                raise ValueError('could not identify kill target')
            if dev_path(probe.stdout) and probe.stdout.strip().endswith('/Contents/MacOS/EnviousWispr'):
                return True, False, False
    return False, False, False


def handle(event):
    name = event.get('hook_event_name')
    session_id = event.get('session_id')
    # Every action/ownership query needs real native event identity.
    if not isinstance(session_id, str):
        raise ValueError('missing native event session_id')
    lock.codex_chat_id(session_id)
    if name == 'PreToolUse':
        if event.get('tool_name') != 'Bash':
            return {}
        routes = [route(argv) for argv in commands(event.get('tool_input', {}).get('command'))]
        protected = any(action for action, _, _ in routes)
        if protected and any(release for _, _, release in routes):
            return deny('Release and dev-app actions must be separate tool calls.')
        if protected:
            result, text = invoke(session_id, 'check')
            if result:
                return deny(text + f'. Run python3 {LOCK_TOOL} claim --label "<task>" separately first.')
        return {}
    if name in ('UserPromptSubmit', 'PostToolUse'):
        _, text = invoke(session_id, 'remind', '--event', name)
        return json.loads(text) if text else {}
    if name in ('Stop', 'SessionEnd', 'Interrupt'):
        result, text = invoke(session_id, 'check')
        if result == lock.EXIT_UNDECIDED:
            return {'systemMessage': text}
        if result:
            return {}
        reason = (f'This chat still holds the dev app. If app work is finished, run python3 {LOCK_TOOL} release '
                  'before reporting DONE. If protected background work remains, retain the hold and name the unfinished work and completion owner.')
        if name == 'Stop' and not event.get('stop_hook_active'):
            return {'decision': 'block', 'reason': reason}
        return {'systemMessage': reason}
    return {}


def main():
    event = {}
    try:
        event = json.load(sys.stdin)
        if not isinstance(event, dict):
            raise ValueError('invalid native hook event')
        result = handle(event)
    except Exception:
        result = (deny('Dev-app lock hook could not verify this action; use a direct command and inspect the hook.')
                  if isinstance(event, dict) and event.get('hook_event_name') == 'PreToolUse'
                  else {'systemMessage': 'Dev-app lock hook could not complete its ownership check; hold retained.'})
    print(json.dumps(result))


if __name__ == '__main__':
    main()
