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
    parsed = []
    gate_by_path = {}
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
                ranges.append((
                    opening, closing,
                    re.sub(r"[\s`]", "", declaration.group(1)).replace(".", "/"),
                    has_runtime_gate(suite_attribute)
                ))

        # Gates by QUALIFIED PATH, not only by brace range. A test hosted in a top-level
        # `extension Outer.Inner` sits in no brace of `Outer`, so the chain of ranges
        # around it never sees a `.disabled` on `Outer`'s own declaration — yet Swift
        # Testing skips that test through the parent trait (#2669 review, round 3). Every
        # declaration records the gate on its own path, and a test is gated when any
        # prefix of its path is, whichever braces — and whichever file — it was written in.
        for opening, closing, name, gated in ranges:
            outer = sorted(
                ((end - start, outer_name) for start, end, outer_name, _ in ranges
                 if start < opening < end),
                key=lambda entry: -entry[0],
            )
            qualified = "/".join([target] + [outer_name for _, outer_name in outer] + [name])
            gate_by_path[qualified] = gate_by_path.get(qualified, False) or gated
        parsed.append((target, part, code, ranges))

    # Pass two: the tests, each judged against the whole target's gates.
    for target, part, code, ranges in parsed:
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
                ((end - start, name, gated) for start, end, name, gated in ranges
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
            if any(gate_by_path.get("/".join([target] + components[:depth]), False)
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
    list/tuple/set literal holding either?"""
    if isinstance(node, ast.Constant):
        return node.value == flag
    if isinstance(node, ast.Name):
        return node.id in aliases
    if isinstance(node, (ast.List, ast.Tuple, ast.Set)):
        return any(_holds_flag(item, flag, aliases) for item in node.elts)
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


def parses_flag(node, flag, aliases=frozenset()):
    """Does this AST node PARSE the flag, rather than merely spell it?

    Two shapes count, because they are the ways a module answers the flag: a comparison
    with it as an operand (`cmd == "--self-test"`, `"--self-test" in sys.argv`,
    `sys.argv[1:] == ["--self-test"]`, or the same through a module constant bound to
    it), or an argparse registration (`parser.add_argument("--self-test", ...)`). A
    constant anywhere else — an unused module constant, a help string, a print, a
    docstring, an unreachable branch — is not evidence the module inspects its arguments
    for it, and the old check accepted every one of those (#2672 review).
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
    if not any(parses_flag(node, battery.SELF_TEST_FLAG, aliases) for node in ast.walk(tree)):
        return [f"self-test target {shown} does not parse {battery.SELF_TEST_FLAG}; "
                f"`{battery.self_test_command(suite)}` would prove nothing"]
    return []


def validate(recipes, root, label):
    names_by_suite = test_oracle(root)
    battery = load_battery()
    root = root.resolve()
    bad = 0
    total = 0

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
            command = battery.self_test_command(suite)
            if command:
                if suite in names_by_suite:
                    problems.append(
                        f"suite {suite} is both a Swift suite and a self-test target — ambiguous")
                problems.extend(self_test_problems(battery, suite, root))
            elif suite and suite not in names_by_suite:
                problems.append(f"suite {suite} NOT FOUND in Tests/")

            if problems:
                bad += 1
                print(f"row {index}: UNRUNNABLE — {'; '.join(problems)}")
                row_label = row.get("label", "(no label)") if isinstance(row, dict) else "(no label)"
                print(f"        {str(row_label)[:90]}")
            else:
                status = "DEFERRED" if normalized.get("_mode") == "human" else "runnable"
                run = f" — run: {command}" if command else ""
                print(f"row {index}: {status:<10} | {str(normalized.get('label', ''))[:70]}{run}")

    print(f"\n{label}: {total - bad}/{total} rows runnable"
          + (f", {bad} UNRUNNABLE" if bad else ""))
    return 1 if bad else 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--issue", type=int)
    source.add_argument("--recipes", type=pathlib.Path)
    parser.add_argument("--checkout", type=pathlib.Path, default=pathlib.Path.cwd())
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
        return validate(recipes, args.checkout, label)
    except (OSError, json.JSONDecodeError, RuntimeError) as error:
        print(f"REFUSED — {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
