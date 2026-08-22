#!/usr/bin/env python3
"""Validate mutation recipes against a checkout without running Xcode."""

import argparse
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
    for path, part in sources:
        target = path.relative_to(test_root).parts[0]
        code = mask_inactive_debug_branches(mask_noncode(part))
        ranges = []
        for declaration in re.finditer(
            r"\b(?:struct|final\s+class|class|enum|actor|extension)\s+(\w+)", code
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
                    opening, closing, declaration.group(1), has_runtime_gate(suite_attribute)
                ))

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
            containing = [
                (end - start, name, gated) for start, end, name, gated in ranges
                if start < attribute.start() < end
            ]
            if not containing:
                continue
            _, enclosing, suite_is_gated = min(containing)
            if suite_is_gated:
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
            single_row = {"suite_default": default_suite, "rows": [row]}
            try:
                normalized = battery.load_recipes(
                    None, root, raw=json.dumps(single_row))[0]
            except battery.Refusal as error:
                problems.append(str(error))

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

            if suite and suite not in names_by_suite:
                problems.append(f"suite {suite} NOT FOUND in Tests/")

            if problems:
                bad += 1
                print(f"row {index}: UNRUNNABLE — {'; '.join(problems)}")
                row_label = row.get("label", "(no label)") if isinstance(row, dict) else "(no label)"
                print(f"        {str(row_label)[:90]}")
            else:
                print(f"row {index}: runnable   | {str(normalized.get('label', ''))[:70]}")

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
