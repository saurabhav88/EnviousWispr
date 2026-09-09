#!/usr/bin/env python3
"""Validate mutation recipes against a checkout without running Xcode."""

import argparse
import ast
import importlib.util
import json
import pathlib
import re
import sys


def load_battery():
    path = pathlib.Path(__file__).with_name("mutation-battery.py")
    spec = importlib.util.spec_from_file_location("mutation_battery", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def mask_noncode(source):
    """Preserve offsets while blanking comments and string literals."""
    masked = list(source)
    index = 0
    length = len(source)

    def blank(start, end):
        for position in range(start, end):
            if masked[position] != "\n":
                masked[position] = " "

    while index < length:
        raw_string = re.match(r'(?P<hashes>#+)(?P<quote>"""|")', source[index:])
        if raw_string:
            start = index
            hashes = raw_string.group("hashes")
            quote = raw_string.group("quote")
            closing = quote + hashes
            search_from = index + len(hashes) + len(quote)
            end = source.find(closing, search_from)
            index = length if end < 0 else end + len(closing)
            blank(start, index)
        elif source.startswith("//", index):
            end = source.find("\n", index)
            end = length if end < 0 else end
            blank(index, end)
            index = end
        elif source.startswith("/*", index):
            start = index
            depth = 1
            index += 2
            while index < length and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            blank(start, index)
        elif source.startswith('"""', index):
            start = index
            end = source.find('"""', index + 3)
            index = length if end < 0 else end + 3
            blank(start, index)
        elif source[index] == '"':
            start = index
            index += 1
            while index < length:
                if source[index] == "\\":
                    index += 2
                elif source[index] == '"':
                    index += 1
                    break
                else:
                    index += 1
            blank(start, min(index, length))
        else:
            index += 1
    return "".join(masked)


def mask_inactive_debug_branches(code):
    """Blank branches that cannot compile in the canonical Debug lane."""
    masked = list(code)
    stack = []
    active = True
    offset = 0

    def condition_value(expression):
        expression = expression.strip()
        if expression == "DEBUG":
            return True
        if expression == "!DEBUG":
            return False
        return None

    def blank(start, end):
        for position in range(start, end):
            if masked[position] != "\n":
                masked[position] = " "

    for line in code.splitlines(keepends=True):
        directive = re.match(r"\s*#(if|elseif|else|endif)\b(.*)", line)
        line_active = active
        if directive:
            kind, expression = directive.groups()
            if kind == "if":
                value = condition_value(expression)
                stack.append({
                    "parent": active,
                    "known": value is not None,
                    "taken": value is True,
                })
                active = active and (value if value is not None else True)
            elif not stack:
                raise RuntimeError("unbalanced conditional-compilation directive in test corpus")
            elif kind == "elseif":
                frame = stack[-1]
                value = condition_value(expression)
                if not frame["known"] or value is None:
                    frame["known"] = False
                    active = frame["parent"]
                else:
                    active = frame["parent"] and not frame["taken"] and value
                    frame["taken"] = frame["taken"] or value
            elif kind == "else":
                frame = stack[-1]
                active = frame["parent"] if not frame["known"] else (
                    frame["parent"] and not frame["taken"])
                frame["taken"] = True
            else:
                frame = stack.pop()
                active = frame["parent"]
            blank(offset, offset + len(line))
        elif not line_active:
            blank(offset, offset + len(line))
        offset += len(line)

    if stack:
        raise RuntimeError("unterminated conditional-compilation directive in test corpus")
    return "".join(masked)


def matching_delimiter(code, opening, left, right):
    depth = 0
    for index in range(opening, len(code)):
        if code[index] == left:
            depth += 1
        elif code[index] == right:
            depth -= 1
            if depth == 0:
                return index
    return None


def function_suffix(parameters):
    if not parameters.strip():
        return "()"
    pieces = []
    start = 0
    depths = {"(": 0, "[": 0, "<": 0}
    closing = {")": "(", "]": "[", ">": "<"}
    for index, character in enumerate(parameters):
        if character in depths:
            depths[character] += 1
        elif character in closing and depths[closing[character]]:
            depths[closing[character]] -= 1
        elif character == "," and not any(depths.values()):
            pieces.append(parameters[start:index])
            start = index + 1
    pieces.append(parameters[start:])

    labels = []
    for piece in pieces:
        head = piece.split(":", 1)[0]
        tokens = re.findall(r"\b[A-Za-z_]\w*\b|_", head)
        if not tokens:
            return None
        labels.append(tokens[0])
    return "(" + "".join(f"{label}:" for label in labels) + ")"


def has_runtime_gate(attribute_code):
    return re.search(r"\.(?:enabled|disabled)\s*\(", attribute_code) is not None


class SuiteGateMap:
    """Which declaration paths carry a runtime gate, and how far each gate reaches.

    A `.enabled(if:)`/`.disabled` on a declaration skips every test beneath it, including
    tests written in ANOTHER file inside a qualified extension of that type, which is why
    gates are keyed by target-qualified path rather than by brace range (#2669 review,
    round 3).

    A FILE-PRIVATE declaration is the exception, and #2688 is what the missing exception
    cost: two files each declaring `private struct S` both key to `Target/S`, so a gated
    one suppressed an ungated one hosting a live `@Test` in the other file and a VALID
    recipe was reported UNRUNNABLE. That direction is the expensive one — it sends a filer
    to fix a recipe that was already right. `private` cannot be extended from another file,
    so such a gate is recorded against its own file and read back only for tests written in
    that same file.

    One owner, because the write side and the read side must agree on the scope: recording
    a gate per file and reading it back globally would silently drop it.
    """

    @staticmethod
    def file_scoped(modifiers):
        """Does this declaration's modifier text make it FILE-scoped?

        `private(set)` is an access level on a property's setter and never on a type, so
        the lookahead keeps it out — it would otherwise scope a whole declaration to its
        file for a reason that has nothing to do with the declaration.
        """
        return re.search(r"\b(?:private|fileprivate)\b(?!\s*\()", modifiers) is not None

    def __init__(self):
        self._shared = {}
        self._by_file = {}

    def record(self, file_key, qualified, gated):
        """Remember a declaration's gate. `file_key` is None for a declaration other files
        can extend, and the file's path for a file-private one."""
        scope = self._shared if file_key is None else self._by_file.setdefault(file_key, {})
        scope[qualified] = scope.get(qualified, False) or gated

    def gated(self, file_key, qualified):
        """Is a test written in `file_key` gated by a declaration at `qualified`?"""
        return (self._shared.get(qualified, False)
                or self._by_file.get(file_key, {}).get(qualified, False))


def test_oracle(root):
    test_root = root / "Tests"
    sources = []
    for path in test_root.rglob("*.swift"):
        try:
            sources.append((path, path.read_text(errors="replace")))
        except OSError as error:
            raise RuntimeError(f"cannot read test source {path}: {error}") from error
    tests = "\n".join(source for _, source in sources)
    if len(sources) < 100 or len(tests) < 100_000:
        raise RuntimeError(
            f"test corpus read {len(sources)} files / {len(tests)} bytes — refusing to "
            "validate against a suspiciously small oracle")

    names_by_suite = {}
    # Pass one: every declaration's brace range and gate, for EVERY file, before any test
    # is extracted. Gates are keyed by target-qualified path (`Target/Outer/Inner`) so a
    # `.disabled` on a declaration in one file reaches a qualified extension of that type
    # in another file; a map rebuilt per file could not see across (#2669 review, round 4).
    # `SuiteGateMap` owns the one exception, a file-private declaration (#2688).
    parsed = []
    gates = SuiteGateMap()
    for path, part in sources:
        target = path.relative_to(test_root).parts[0]
        code = mask_inactive_debug_branches(mask_noncode(part))
        ranges = []
        # The name may be QUALIFIED: `extension Outer.Inner { @Test ... }` hosts tests for
        # the nested suite, and `swift test list` files them under `Outer/Inner/...`.
        # Capturing only the first segment filed them under `Outer`, so the validator
        # rejected a valid recipe for every extension-hosted nested test (#2669 review).
        # Swift also accepts trivia around the dot and backtick-escaped segments
        # (`extension Outer . \`Inner\``), which the inventory freeze already treats as the
        # same name; both are stripped so the spelling never decides the key. The dots
        # become the path separator the chain below already uses.
        for declaration in re.finditer(
            r"\b(?:struct|final\s+class|class|enum|actor|extension)\s+"
            r"(`?\w+`?(?:\s*\.\s*`?\w+`?)*)",
            code,
        ):
            opening = code.find("{", declaration.end())
            closing = matching_delimiter(code, opening, "{", "}") if opening >= 0 else None
            if closing is not None:
                suite_start = code.rfind("@Suite", max(0, declaration.start() - 2_000),
                                         declaration.start())
                suite_attribute = code[suite_start:declaration.start()] if suite_start >= 0 else ""
                if "{" in suite_attribute or "}" in suite_attribute:
                    suite_attribute = ""
                # Modifiers on the declaration's own line. `private`/`fileprivate` make it
                # FILE-scoped, which is what decides how far its gate may reach (#2688).
                # `private(set)` is an access level on a property, never on a type, so the
                # lookahead keeps it out.
                line_start = code.rfind("\n", 0, declaration.start()) + 1
                modifiers = code[line_start:declaration.start()]
                ranges.append((
                    opening, closing,
                    re.sub(r"[\s`]", "", declaration.group(1)).replace(".", "/"),
                    has_runtime_gate(suite_attribute),
                    SuiteGateMap.file_scoped(modifiers),
                ))

        # Gates by QUALIFIED PATH, not only by brace range. A test hosted in a top-level
        # `extension Outer.Inner` sits in no brace of `Outer`, so the chain of ranges
        # around it never sees a `.disabled` on `Outer`'s own declaration — yet Swift
        # Testing skips that test through the parent trait (#2669 review, round 3). Every
        # declaration records the gate on its own path, and a test is gated when any
        # prefix of its path is, whichever braces — and whichever file — it was written in.
        for opening, closing, name, gated, file_private in ranges:
            outer = sorted(
                ((end - start, outer_name) for start, end, outer_name, _, _ in ranges
                 if start < opening < end),
                key=lambda entry: -entry[0],
            )
            qualified = "/".join([target] + [outer_name for _, outer_name in outer] + [name])
            gates.record(str(path) if file_private else None, qualified, gated)
        parsed.append((path, target, part, code, ranges))

    # Pass two: the tests, each judged against the whole target's gates.
    for path, target, part, code, ranges in parsed:
        for attribute in re.finditer(r"@Test\b", code):
            function_match = re.search(r"\bfunc\s+(\w+)\s*\(", code[attribute.end():])
            if not function_match:
                continue
            function_start = attribute.end() + function_match.start()
            next_test = code.find("@Test", attribute.end(), function_start)
            if next_test >= 0:
                continue
            if has_runtime_gate(code[attribute.start():function_start]):
                continue
            function = function_match.group(1)
            opening = code.find("(", function_start)
            closing = matching_delimiter(code, opening, "(", ")")
            if closing is None:
                continue
            suffix = function_suffix(code[opening + 1:closing])
            if suffix is None:
                continue
            # Every declaration wrapping this test, outermost first. Brace ranges nest, so
            # the ranges containing one point form a chain, and the whole chain is the
            # suite's name: a @Suite nested inside another @Suite is `Outer/Inner`, which
            # is the path the test filter accepts. Keying by the innermost name alone put
            # the qualified path — the only one that runs — at "NOT FOUND" and accepted the
            # bare inner name, a filter that executes zero tests (#2525). A top-level suite
            # is a chain of one, so its name is unchanged.
            containing = sorted(
                ((end - start, name, gated) for start, end, name, gated, _ in ranges
                 if start < attribute.start() < end),
                key=lambda entry: -entry[0],
            )
            if not containing:
                continue
            # A `.enabled`/`.disabled` on any level of the chain gates every test beneath it,
            # whether that level is a brace around the test or the original declaration of
            # a type the hosting extension names.
            if any(gated for _, _, gated in containing):
                continue
            enclosing = "/".join(name for _, name, _ in containing)
            # Walk the PATH components, not the chain entries: a qualified extension is one
            # chain entry whose name already holds a `/`, and the gate it must inherit sits
            # on the shorter path (`Target/Outer`) that only a component walk reaches.
            components = enclosing.split("/")
            if any(gates.gated(str(path), "/".join([target] + components[:depth]))
                   for depth in range(1, len(components) + 1)):
                continue
            body = part[attribute.end():function_start]
            display_names = []
            display = re.match(r'\s*\(\s*"((?:[^"\\]|\\.)*)"', body)
            if display:
                literal = display.group(1)
                try:
                    display_names.append(json.loads(f'"{literal}"'))
                except json.JSONDecodeError:
                    display_names.append(
                        literal.replace('\\\"', '"').replace('\\\\', '\\'))
            canonical = f"{enclosing}/{function}{suffix}"
            aliases = display_names + [f"{function}{suffix}", canonical]
            suite_names = names_by_suite.setdefault(f"{target}/{enclosing}", {})
            for alias in aliases:
                suite_names.setdefault(alias, set()).add(canonical)
    name_count = sum(len(names) for names in names_by_suite.values())
    if name_count < 1_000:
        raise RuntimeError(
            f"extracted only {name_count} suite-scoped test names — refusing to validate against "
            "a suspiciously small oracle")
    return names_by_suite


def prefix_successor(name, known_names):
    """The one full test name `name` is a prefix of, or None when that is not decidable.

    Same population and the same rule `missing_test_problem` reports on, read here as a
    VALUE rather than as a sentence. Refuses on two candidates: a repair that picks one
    of several is a guess, which is the thing freezing a recipe exists to prevent.
    """
    if not name or name in known_names:
        return None
    near = [
        candidate for candidate in known_names
        if candidate and candidate != name and candidate.startswith(name)
    ]
    return near[0] if len(near) == 1 else None


def repaired_row(row, index, default_suite, root, battery, names_by_suite):
    """A corrected copy of an UNRUNNABLE row, or (None, why-not).

    Two classes, and no others. Both are decidable from the checkout with no model of
    what the recipe MEANT, which is the line this stops at:

    - **The anchor only moved in indentation.** Exactly one offset makes it match
      exactly once, and the replacement shifts with it. A formatter reflow or an
      extract-to-another-file retires a row while the behaviour it binds is untouched,
      and this is that case and only that case (#2529).
    - **An expectation names a PREFIX of exactly one real test.** The full name is read
      off the same oracle the refusal used.

    **Never applied, never written back.** It returns a row for a human to file on a NEW
    issue, because a frozen row is not edited in place — re-pointing one at what LOOKS
    like its successor is a guess about what the recipe meant, and that judgement is the
    author's rather than a script's (#2703 candidate 2).
    """
    if not isinstance(row, dict):
        return None, "the row is not an object"

    fixed = dict(row)
    notes = []

    anchor = row.get("anchor")
    path = row.get("file")
    # TYPE first, because a malformed row is exactly what the ordinary validator refuses
    # cleanly and what this path must not turn into a crash. `source.count(42)` raises
    # `TypeError` and takes every LATER row down with it, so one bad row would stop the
    # whole recipe being reported (#2703 review, P2).
    for field, value in (("anchor", anchor), ("file", path), ("replacement",
                                                              row.get("replacement"))):
        if value is not None and not isinstance(value, str):
            return None, f"the row's {field} is not a string"
    if anchor and path:
        target = (root / path).resolve()
        try:
            inside = target.is_relative_to(root.resolve())
        except (AttributeError, ValueError):
            inside = str(target).startswith(str(root.resolve()))
        if not inside:
            return None, f"the row's file resolves outside the checkout: {path}"
        if not target.is_file():
            return None, f"the row's file no longer exists: {path}"
        source = target.read_text(errors="replace")
        # ZERO, not "anything but one", and the difference is the whole safety property.
        #
        # The runner refuses an anchor that matches once (fine), never (moved or gone) and
        # MANY (ambiguous). Only the middle one is an indentation question. Re-cutting an
        # AMBIGUOUS anchor does not repair it — it silently picks one of its matches: a
        # `return false` at four spaces and again at eight matches twice, and shifting it
        # to eight makes it "unique" at a statement nothing says the row meant. The
        # corrected row would then validate and mutate the wrong line, which is the exact
        # guess this whole flag exists to refuse (#2703 review r3).
        #
        # A count of one is left alone for a different reason: the runner would apply it,
        # so it is not broken, and re-cutting it would rewrite a row that had nothing wrong.
        occurrences = source.count(anchor)
        if occurrences > 1:
            return None, (
                f"the anchor matches {occurrences} times, so it is AMBIGUOUS rather than "
                "moved — which of them the row meant is the author's call, not a shift")
        if occurrences == 0:
            offsets = battery.indentation_offsets(source, anchor)
            if len(offsets) != 1:
                return None, (
                    "the anchor is not recoverable by indentation alone — "
                    + (f"{len(offsets)} offsets match" if offsets else "no offset matches")
                    + "; what the row MEANT has to be decided before it is re-pointed")
            delta = offsets[0]
            shifted = battery.reindented(anchor, delta)
            replacement = row.get("replacement")
            # The replacement moves with the anchor or the pair stops describing one edit.
            # `reindented` returns None when a dedent would eat a non-space character, and
            # an empty replacement (a deletion) has nothing to shift.
            if replacement:
                shifted_replacement = battery.reindented(replacement, delta)
                if shifted_replacement is None:
                    return None, (
                        f"the anchor re-cuts at {delta:+d} spaces but the replacement "
                        "cannot be shifted with it without changing its text")
                fixed["replacement"] = shifted_replacement
            fixed["anchor"] = shifted
            notes.append(f"anchor re-cut at {delta:+d} spaces")

    # RE-READ the row before touching expectations, ALWAYS.
    #
    # `load_recipes` refuses at its FIRST defect and returns nothing, so every field it
    # would have resolved — the suite, `_must_fire`, `_must_not_fire`, the mode — is
    # absent for exactly the rows that have something to repair. Two review rounds each
    # found a different member of that one class: the corrected row lost its
    # `suite_default`, then a row with drift AND a resolvable prefix had the prefix
    # skipped. Reading the caller's post-refusal `normalized` at all is the defect, so it
    # is not read here — this recomputes from the row as it stands, whether or not the
    # anchor was touched, and there is no member left to find (#2703 review r1 and r2).
    _, normalized, suite, _ = row_problems(
        fixed, index, default_suite, root, battery, names_by_suite)
    suite_names = names_by_suite.get(suite, {})

    for field, key in (("_must_fire", "must_fire"), ("_must_not_fire", "must_not_fire")):
        names = normalized.get(field) or []
        if not names:
            continue
        rewritten = []
        changed = False
        for name in names:
            successor = prefix_successor(name, suite_names)
            rewritten.append(successor or name)
            if successor:
                changed = True
                notes.append(f"{key}: {name!r} -> {successor!r}")
        if changed:
            # `expect_fail` is the single-guard spelling of a one-element `must_fire`, so
            # a row that arrived in that form goes back out in it rather than silently
            # changing which contract it declares.
            if key == "must_fire" and "expect_fail" in fixed:
                fixed["expect_fail"] = rewritten[0]
            else:
                fixed[key] = rewritten

    if not notes:
        return None, "no mechanical class applies"
    return fixed, "; ".join(notes)


def missing_test_problem(name, known_names):
    if name in known_names:
        if len(known_names[name]) > 1:
            return (
                f"expectation name is AMBIGUOUS across {len(known_names[name])} tests: {name!r}")
        return None
    near = sorted(
        (candidate for candidate in known_names
         if candidate and candidate != name and candidate.startswith(name)),
        key=len,
    )
    if near:
        return (
            f"expectation name is a PREFIX, not a full test name; "
            f"did you mean {near[0]!r}")
    return f"expectation names a test that DOES NOT EXIST: {name!r}"


def _holds_flag(node, flag, aliases):
    """Is `node` the flag itself, a module-level name assigned the flag, or a
    one-element list/tuple/set literal holding either?"""
    if isinstance(node, ast.Constant):
        return node.value == flag
    if isinstance(node, ast.Name):
        return node.id in aliases
    if isinstance(node, (ast.List, ast.Tuple, ast.Set)):
        # An aggregate stands for the WHOLE argv tail, and the fixed command supplies
        # exactly one argument, so `["--verbose", "--self-test"]` is a branch that command
        # can never enter (#2672 review, round 3). Only a one-element aggregate matches.
        return len(node.elts) == 1 and _holds_flag(node.elts[0], flag, aliases)
    return False


def flag_aliases(tree, flag):
    """Module-level names bound to the flag by a plain assignment, `FLAG = "--self-test"`,
    so a module that compares through its own constant is read the same as one that
    compares the literal. Only the binding is followed; a name that is never compared or
    registered still proves nothing."""
    return {
        target.id
        for node in tree.body
        if isinstance(node, ast.Assign)
        and isinstance(node.value, ast.Constant) and node.value.value == flag
        for target in node.targets
        if isinstance(target, ast.Name)
    }


def reachable_nodes(tree):
    """`ast.walk`, minus the branches Python can never enter: the body of `if False:`,
    `if 0:` or `while False:`, and the else of `if True:`. A recognised check under one of
    those proves nothing about the command the validator prints, and `ast.walk` visits it
    anyway (#2672 review, round 2). Only a literal constant test is treated as static; a
    name or expression is assumed live, since deciding otherwise would need evaluation."""
    stack = [tree]
    while stack:
        node = stack.pop()
        yield node
        if isinstance(node, (ast.If, ast.While)) and isinstance(node.test, ast.Constant):
            stack.extend(node.body if node.test.value else node.orelse)
            continue
        stack.extend(ast.iter_child_nodes(node))


def parses_flag(node, flag, aliases=frozenset()):
    """Does this AST node PARSE the flag, rather than merely spell it?

    Two shapes count, because they are the ways a module answers the flag: a comparison
    with it as an operand (`cmd == "--self-test"`, `"--self-test" in sys.argv`,
    `sys.argv[1:] == ["--self-test"]`, or the same through a module constant bound to
    it), or an argparse registration (`parser.add_argument("--self-test", ...)`). A
    constant anywhere else — an unused module constant, a help string, a print, a
    docstring — is not evidence the module inspects its arguments for it, and the old
    check accepted every one of those (#2672 review). Unreachable branches are the
    caller's job: `self_test_problems` feeds this only the nodes `reachable_nodes` yields.
    """
    if isinstance(node, ast.Compare):
        return any(_holds_flag(operand, flag, aliases)
                   for operand in [node.left, *node.comparators])
    if isinstance(node, ast.Call):
        callee = node.func
        name = callee.attr if isinstance(callee, ast.Attribute) else getattr(callee, "id", None)
        return name == "add_argument" and any(
            _holds_flag(arg, flag, aliases) for arg in node.args)
    return False


def self_test_problems(battery, suite, root):
    """Prove a `RuntimeUAT/<module>` target exists and really parses `--self-test`.

    Nothing is executed: wispr_eyes imports Quartz transitively, so running it here would
    test the host's PyObjC, not the recipe. The module is parsed instead, and the flag must
    be an operand of a comparison or an argument to `add_argument` (see `parses_flag`) —
    a docstring, a constant, or a help message that merely spells `--self-test` is not
    evidence the module answers it.
    """
    source = root / battery.self_test_source(battery.self_test_module(suite))
    shown = source.relative_to(root)
    if not source.is_file():
        return [f"self-test target {shown} DOES NOT EXIST"]
    try:
        tree = ast.parse(source.read_text(errors="replace"), filename=str(shown))
    except SyntaxError as error:
        return [f"self-test target {shown} is not valid Python: {error}"]
    aliases = flag_aliases(tree, battery.SELF_TEST_FLAG)
    if not any(parses_flag(node, battery.SELF_TEST_FLAG, aliases)
               for node in reachable_nodes(tree)):
        return [f"self-test target {shown} does not parse {battery.SELF_TEST_FLAG}; "
                f"`{battery.self_test_command(suite, root)}` would prove nothing"]
    return []


def row_problems(row, index, default_suite, root, battery, names_by_suite):
    """Every problem with ONE row, plus what the runner made of it.

    Extracted so `--fix` can ask the SAME question of a corrected row that this asks of
    the filed one. A repair judged only by the defect it targeted prints a row that
    parses and that the runner still refuses — a drifted anchor whose expectation ALSO
    names a missing test comes back "repairable" and fails on the very next run
    (#2703 review, P2).
    """
    problems = []
    normalized = {}
    # One row per call, so the runner's first refusal cannot hide the rows behind
    # it. The cost is that the runner numbers every row as `row 1`; printed after
    # this loop's own `row N:` label that read as an anchor index (#2525). Only the
    # leading prefix is renumbered — a `row 1` inside a quoted path is left alone.
    single_row = {"suite_default": default_suite, "rows": [row]}
    try:
        normalized = battery.load_recipes(
            None, root, raw=json.dumps(single_row))[0]
    except battery.Refusal as error:
        problems.append(re.sub(
            r"^((?:human )?row )1\b", rf"\g<1>{index}", str(error)))

    suite = normalized.get("suite")
    suite_names = names_by_suite.get(suite, {})
    for name in normalized.get("_must_fire", []) + normalized.get("_must_not_fire", []):
        problem = missing_test_problem(name, suite_names)
        if problem:
            problems.append(problem)

    fire_ids = set().union(*(
        suite_names.get(name, set()) for name in normalized.get("_must_fire", [])
    ))
    silent_ids = set().union(*(
        suite_names.get(name, set()) for name in normalized.get("_must_not_fire", [])
    ))
    alias_overlap = sorted(fire_ids & silent_ids)
    if alias_overlap:
        problems.append(
            "must_fire and must_not_fire resolve to the same test(s): "
            + ", ".join(alias_overlap))
    for field in ("_must_fire", "_must_not_fire"):
        aliases_by_test = {}
        for name in normalized.get(field, []):
            for test_id in suite_names.get(name, set()):
                aliases_by_test.setdefault(test_id, []).append(name)
        duplicates = {
            test_id: aliases for test_id, aliases in aliases_by_test.items()
            if len(aliases) > 1
        }
        if duplicates:
            problems.append(
                f"{field.removeprefix('_')} names the same test through multiple aliases: "
                + "; ".join(
                    f"{test_id}: {', '.join(aliases)}"
                    for test_id, aliases in sorted(duplicates.items())
                ))

    # A `RuntimeUAT/<module>` suite is a Python self-test, not a Swift suite (#2570):
    # the oracle cannot know it, so it is proved against the checkout instead. The
    # runner has already refused it on a mechanical row and with test names attached.
    command = battery.self_test_command(suite, root)
    if command:
        if suite in names_by_suite:
            problems.append(
                f"suite {suite} is both a Swift suite and a self-test target — ambiguous")
        problems.extend(self_test_problems(battery, suite, root))
    elif suite and suite not in names_by_suite:
        problems.append(f"suite {suite} NOT FOUND in Tests/")
    return problems, normalized, suite, command


def validate(recipes, root, label, fix=False):
    names_by_suite = test_oracle(root)
    battery = load_battery()
    root = root.resolve()
    bad = 0
    total = 0
    repairs = []
    refusals = []

    for document in recipes:
        if not isinstance(document, dict) or not isinstance(document.get("rows"), list):
            print(f"{label}: UNRUNNABLE — recipe must be an object with a rows list")
            return 1
        if not document["rows"]:
            print(f"{label}: UNRUNNABLE — recipe declares no rows")
            return 1
        default_suite = document.get("suite_default")
        for index, row in enumerate(document["rows"], 1):
            total += 1
            problems, normalized, suite, command = row_problems(
                row, index, default_suite, root, battery, names_by_suite)
            suite_names = names_by_suite.get(suite, {})

            if problems:
                bad += 1
                print(f"row {index}: UNRUNNABLE — {'; '.join(problems)}")
                row_label = row.get("label", "(no label)") if isinstance(row, dict) else "(no label)"
                print(f"        {str(row_label)[:90]}")
                if fix:
                    corrected, why = repaired_row(
                        row, index, default_suite, root, battery, names_by_suite)
                    if corrected is None:
                        refusals.append((index, why))
                    else:
                        corrected["label"] = (
                            f"re-cut from row {index} of {label}: "
                            f"{str(row.get('label', '')).strip()}")
                        # A corrected row carries its filter EXPLICITLY, because the new
                        # issue it gets filed on has no `suite_default`. Prefer what the
                        # runner resolved; fall back to the row's own field and then to
                        # the document's default, both of which survive a refusal that
                        # leaves `normalized` empty (#2703 review, P2).
                        resolved_suite = (
                            suite or row.get("suite") or default_suite)
                        if resolved_suite:
                            corrected["suite"] = resolved_suite
                        # THE WHOLE CHECK, not the defect the repair aimed at. A row with
                        # indentation drift AND a second problem would otherwise be
                        # printed as repairable and refused on the very next run.
                        remaining, _, _, _ = row_problems(
                            corrected, index, default_suite, root, battery, names_by_suite)
                        if remaining:
                            refusals.append((
                                index,
                                "the mechanical part repairs (" + why + ") but the row "
                                "still does not validate: " + "; ".join(remaining)))
                        else:
                            repairs.append((index, why, corrected))
            else:
                status = "DEFERRED" if normalized.get("_mode") == "human" else "runnable"
                run = f" — run: {command}" if command else ""
                print(f"row {index}: {status:<10} | {str(normalized.get('label', ''))[:70]}{run}")

    print(f"\n{label}: {total - bad}/{total} rows runnable"
          + (f", {bad} UNRUNNABLE" if bad else ""))

    if fix:
        print("\n--fix: mechanical repairs only. Nothing was written.")
        for index, why in refusals:
            print(f"  row {index}: NOT mechanically repairable — {why}")
        for index, why, _ in repairs:
            print(f"  row {index}: repairable — {why}")
        if repairs:
            print(
                "\nFile these on a NEW issue; a frozen row is never edited in place.\n"
                "```json")
            print(json.dumps({"rows": [row for _, _, row in repairs]}, indent=2))
            print("```")
        elif bad:
            print("\n  Nothing here is repairable without deciding what the row MEANT.")

    return 1 if bad else 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--issue", type=int)
    source.add_argument("--recipes", type=pathlib.Path)
    parser.add_argument("--checkout", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument(
        "--fix", action="store_true",
        help="also print corrected rows for the UNRUNNABLE ones whose repair is "
             "mechanical — an anchor that only moved in indentation, or an expectation "
             "naming a prefix of exactly one real test. Prints; never writes, and never "
             "edits the issue: a frozen row is filed corrected on a NEW issue.")
    args = parser.parse_args(argv)

    try:
        battery = load_battery()
        if args.issue is not None:
            if args.issue <= 0:
                raise RuntimeError("issue number must be positive")
            try:
                raw = battery.recipes_from_issue(args.issue, args.checkout)
            except battery.Refusal as error:
                raise RuntimeError(str(error)) from error
            recipes = [json.loads(raw)]
            label = f"#{args.issue}"
        else:
            recipes = [json.loads(args.recipes.read_text())]
            label = str(args.recipes)
        if not recipes:
            print(f"{label}: NO PARSEABLE RECIPE — nothing to validate")
            return 2
        return validate(recipes, args.checkout, label, fix=args.fix)
    except (OSError, json.JSONDecodeError, RuntimeError) as error:
        print(f"REFUSED — {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
