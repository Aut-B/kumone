#!/usr/bin/env python3
"""Static Swift structure checks for machines without Xcode.

Three modes:

    check-swift-structure.py balance [PATH ...]
    check-swift-structure.py symbol NAME [PATH ...]
    check-swift-structure.py symbol --name NAME [--min-def N] [--min-use N] [PATH ...]
    check-swift-structure.py --self-test

Both modes strip string literals and comments before matching (line numbers are
kept), so text inside `"..."`, `// ...` or `/* ... */` can never satisfy a
check. `symbol` requires a symbol to have at least one declaration and at least
one use, so a half-finished edit cannot pass as done. Enum/switch `case`
patterns and `if let`/`guard let`/pattern bindings are intentionally not
treated as declarations. Paths default to `Sources`; relative paths resolve
from the working directory, then from the repository root.

Swift 5.7+ regex literals (`/.../`) are not special-cased; none occur in the
`Sources` tree today, so treat a balance failure next to one as a scanner
limit rather than a real defect.
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PATHS = ("Sources",)

OPENERS = {"(": ")", "[": "]", "{": "}"}

# `extension` is intentionally absent: it restates an existing type's name and
# would let `extension Foo {}` + `let x = Foo()` pass as a definition + use
# without proving the symbol is really defined anywhere.
DECLARATION = re.compile(
    r"\b(func|struct|class|enum|protocol|actor|typealias|let|var)\s+$"
)
PATTERN_BINDING = re.compile(
    r"\b(?:if|guard|while|for|catch)\s+(?:case\s+)?(?:let|var)\s+$"
    r"|\bcase\b[^\n;{}]*\b(?:let|var)\s+$"
)


def _hashes_follow(text, position, count):
    return text[position:position + count] == "#" * count


def _scan(text, issues=None):
    """Scan Swift source once, masking comments and string bodies.

    Returns a copy of `text` in which comments and the literal parts of strings
    are replaced by spaces. Newlines are preserved, so offsets and line numbers
    remain valid. Code inside `\\(...)` interpolation stays visible. Bracket and
    literal problems are appended to `issues` when a list is supplied.
    """
    mask = list(text)
    frames = [{"kind": "code", "stack": [], "interp": False}]
    line = 1
    position = 0
    length = len(text)

    def blank(start, end):
        for index in range(start, end):
            if mask[index] != "\n":
                mask[index] = " "

    def report(at_line, message):
        if issues is not None:
            issues.append((at_line, message))

    while position < length:
        frame = frames[-1]
        char = text[position]

        if frame["kind"] == "string":
            if char == "\\":
                cursor = position + 1
                hashes = 0
                while cursor < length and hashes < frame["hashes"] and text[cursor] == "#":
                    hashes += 1
                    cursor += 1
                if hashes != frame["hashes"]:
                    # A raw string only escapes with the delimiter's hashes;
                    # any other backslash is an ordinary character, as in #"a\"#.
                    blank(position, position + 1)
                    position += 1
                    continue
                if cursor < length and text[cursor] == "(":
                    blank(position, cursor + 1)
                    frames.append({"kind": "code", "stack": [], "interp": True})
                    position = cursor + 1
                    continue
                if cursor < length:
                    if text[cursor] == "\n":
                        line += 1
                    blank(position, cursor + 1)
                    position = cursor + 1
                else:
                    blank(position, length)
                    position = length
                continue
            if frame["multiline"]:
                if text.startswith('"""', position) and _hashes_follow(text, position + 3, frame["hashes"]):
                    end = position + 3 + frame["hashes"]
                    blank(position, end)
                    frames.pop()
                    position = end
                    continue
            elif char == '"' and _hashes_follow(text, position + 1, frame["hashes"]):
                end = position + 1 + frame["hashes"]
                blank(position, end)
                frames.pop()
                position = end
                continue
            elif char == "\n":
                report(line, "unterminated string literal")
                frames.pop()
                continue
            if char == "\n":
                line += 1
            blank(position, position + 1)
            position += 1
            continue

        if char == "/" and position + 1 < length and text[position + 1] == "/":
            end = text.find("\n", position)
            end = length if end < 0 else end
            blank(position, end)
            position = end
            continue
        if char == "/" and position + 1 < length and text[position + 1] == "*":
            start = position
            depth = 1
            position += 2
            while position < length and depth:
                if text.startswith("/*", position):
                    depth += 1
                    position += 2
                elif text.startswith("*/", position):
                    depth -= 1
                    position += 2
                else:
                    if text[position] == "\n":
                        line += 1
                    position += 1
            blank(start, position)
            if depth:
                report(line, "unterminated block comment")
            continue
        if char == "#":
            hashes = 0
            cursor = position
            while cursor < length and text[cursor] == "#":
                hashes += 1
                cursor += 1
            if cursor < length and text[cursor] == '"':
                multiline = text.startswith('"""', cursor)
                frames.append({"kind": "string", "hashes": hashes, "multiline": multiline})
                end = cursor + (3 if multiline else 1)
                blank(position, end)
                position = end
                continue
            blank(position, cursor)
            position = cursor
            continue
        if char == '"':
            multiline = text.startswith('"""', position)
            frames.append({"kind": "string", "hashes": 0, "multiline": multiline})
            end = position + (3 if multiline else 1)
            blank(position, end)
            position = end
            continue
        if char in OPENERS:
            frame["stack"].append((char, line))
            position += 1
            continue
        if char in ")]}":
            if not frame["stack"]:
                if char == ")" and frame["interp"]:
                    frames.pop()
                    blank(position, position + 1)
                    position += 1
                    continue
                report(line, f"unexpected '{char}' without a matching opener")
                position += 1
                continue
            opener, opened_line = frame["stack"].pop()
            if OPENERS[opener] != char:
                report(opened_line, f"'{opener}' opened here is closed by '{char}' on line {line}")
            position += 1
            continue
        if char == "\n":
            line += 1
        position += 1

    while frames:
        frame = frames[-1]
        if frame["kind"] == "string":
            report(line, "unterminated string literal")
        elif frame["interp"]:
            report(line, "unterminated string interpolation")
        else:
            for opener, opened_line in frame["stack"]:
                report(opened_line, f"'{opener}' has no matching close")
        frames.pop()

    return "".join(mask)


def balance_issues(text):
    """Return `(line, message)` for every unbalanced bracket or literal."""
    issues = []
    _scan(text, issues)
    return issues


def mask_non_code(text):
    """Return `text` with comments and string literal bodies blanked."""
    return _scan(text)


def symbol_usage(sources, name):
    """Return `(definitions, usages)` as `(label, line)` pairs."""
    pattern = re.compile(r"\b" + re.escape(name) + r"\b")
    definitions = []
    usages = []
    for label, text in sources.items():
        code = mask_non_code(text)
        for match in pattern.finditer(code):
            line = code.count("\n", 0, match.start()) + 1
            line_start = code.rfind("\n", 0, match.start()) + 1
            prefix = code[line_start:match.start()]
            declaration = DECLARATION.search(prefix)
            if declaration and not (
                declaration.group(1) in {"let", "var"} and PATTERN_BINDING.search(prefix)
            ):
                definitions.append((label, line))
            else:
                usages.append((label, line))
    return definitions, usages


def swift_files(arguments):
    files = []
    for argument in arguments or DEFAULT_PATHS:
        path = Path(argument)
        if not path.is_absolute():
            candidate = Path.cwd() / path
            path = candidate if candidate.exists() else ROOT / path
        if path.is_dir():
            files.extend(path.rglob("*.swift"))
        elif path.is_file():
            files.append(path)
        else:
            sys.exit(f"check-swift-structure: no such path: {argument}")
    unique = {path.resolve() for path in files}
    return sorted(unique)


def read_sources(files):
    return {str(path): path.read_text(encoding="utf-8", errors="replace") for path in files}


def display(path):
    path = Path(path)
    try:
        return str(path.resolve().relative_to(ROOT))
    except ValueError:
        return str(path)


def run_balance(arguments):
    files = swift_files(arguments)
    sources = read_sources(files)
    problems = 0
    for label, text in sources.items():
        for line, message in balance_issues(text):
            print(f"{display(label)}:{line}: {message}")
            problems += 1
    if problems:
        sys.exit(f"balance: {problems} problem(s) in {len(sources)} file(s)")
    print(f"balance: OK ({len(sources)} file(s))")


def run_symbol(arguments):
    """`symbol NAME [PATH ...]` or `symbol --name NAME [--min-def N] [--min-use N] [PATH ...]`.

    The flag form is what later batches' acceptance commands use; the
    positional form is kept for ad-hoc calls.
    """
    name = None
    minimum_definitions = 1
    minimum_usages = 1
    positional = []
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--name":
            index += 1
            if index >= len(arguments):
                sys.exit("symbol: --name needs a value")
            name = arguments[index]
        elif argument == "--min-def":
            index += 1
            if index >= len(arguments) or not arguments[index].isdigit():
                sys.exit("symbol: --min-def needs a number")
            minimum_definitions = int(arguments[index])
        elif argument == "--min-use":
            index += 1
            if index >= len(arguments) or not arguments[index].isdigit():
                sys.exit("symbol: --min-use needs a number")
            minimum_usages = int(arguments[index])
        else:
            positional.append(argument)
        index += 1
    if name is None:
        if not positional:
            sys.exit("usage: check-swift-structure.py symbol NAME [PATH ...]")
        name = positional.pop(0)
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        sys.exit(f"symbol: not a Swift identifier: {name}")
    files = swift_files(positional)
    definitions, usages = symbol_usage(read_sources(files), name)
    for label, line in definitions:
        print(f"definition {display(label)}:{line}")
    for label, line in usages:
        print(f"usage {display(label)}:{line}")
    if len(definitions) < minimum_definitions:
        sys.exit(
            f"symbol {name}: {len(definitions)} definition(s) found, need >= {minimum_definitions}"
        )
    if len(usages) < minimum_usages:
        sys.exit(f"symbol {name}: {len(usages)} usage(s) found, need >= {minimum_usages}")
    print(
        f"symbol {name}: OK ({len(definitions)} definition(s), {len(usages)} usage(s))"
    )


def run_self_test():
    failures = []

    def check(label, condition, detail=""):
        if condition:
            print(f"ok: {label}")
        else:
            print(f"FAIL: {label}{(': ' + detail) if detail else ''}")
            failures.append(label)

    def accepts(label, source):
        issues = balance_issues(source)
        check(label, not issues, f"unexpected issues {issues}")

    def rejects(label, source, fragment):
        messages = [message for _, message in balance_issues(source)]
        check(label, any(fragment in message for message in messages), f"got {messages}")

    def cli_status(*arguments):
        completed = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), *arguments],
            capture_output=True,
            text=True,
            cwd=str(ROOT),
        )
        return completed.returncode, (completed.stdout + completed.stderr).strip()

    accepts(
        "braces inside strings and comments do not count",
        'let a = "}"\n// {\n/* ( [ */\nlet b = "\\(1 + 2)"\nlet c = "( )"\n',
    )
    accepts(
        "raw and multiline strings are opaque",
        'let a = #"{"key": "value"}"#\nlet b = """\n{ ] )\n"""\nlet c = #"""\n}}}}\n"""#\n',
    )
    accepts(
        "raw strings keep backslashes that do not escape",
        'let a = #"C:\\"#\nlet b = #"line\\n"#\n',
    )
    accepts(
        "interpolation is scanned as code",
        'let a = "\\(dict["k"]!)"\nlet b = "\\(items.map { "{\\($0)}" }.count)"\n',
    )
    accepts(
        "nested block comments",
        'let a = 1 /* outer /* inner { */ still comment ) */\nfunc f() { print("x") }\n',
    )
    rejects(
        "missing closing brace is rejected",
        "struct A {\n    func f() {\n        print(1)\n    }\n",
        "no matching close",
    )
    rejects(
        "extra closing parenthesis is rejected",
        "func f() {\n    print(1))\n}\n",
        "closed by ')'",
    )
    rejects(
        "mismatched closer is rejected",
        "func f() {\n    print(1]\n}\n",
        "is closed by",
    )
    rejects(
        "unterminated string is rejected",
        'let a = "no end\nlet b = 1\n',
        "unterminated string",
    )
    rejects(
        "unterminated block comment is rejected",
        "/* no end\nlet a = 1\n",
        "unterminated block comment",
    )

    definitions, usages = symbol_usage(
        {"good": "struct CommentSource {}\nlet source = CommentSource()\n"}, "CommentSource"
    )
    check("symbol with definition and usage is accepted", definitions and usages)

    definitions, usages = symbol_usage({"bad": "struct CommentSource {}\n"}, "CommentSource")
    check(
        "symbol with only a definition is rejected",
        bool(definitions) and not usages,
    )

    definitions, usages = symbol_usage({"bad": "let source = CommentSource()\n"}, "CommentSource")
    check(
        "symbol with only a usage is rejected",
        not definitions and bool(usages),
    )

    definitions, usages = symbol_usage(
        {"switch": "let source = CommentSource()\nswitch source {\ncase CommentSource:\n    break\n}\n"},
        "CommentSource",
    )
    check(
        "switch case patterns are not declarations",
        not definitions and bool(usages),
        f"definitions={definitions} usages={usages}",
    )

    definitions, usages = symbol_usage(
        {"extension": "extension CommentSource {}\nlet x = CommentSource()\n"},
        "CommentSource",
    )
    check(
        "an extension alone is not a definition",
        not definitions and bool(usages),
        f"definitions={definitions} usages={usages}",
    )

    definitions, usages = symbol_usage(
        {"optional": "if let source = maybe() {}\nguard let other = source else { return }\n"},
        "source",
    )
    check(
        "optional bindings are not definitions",
        not definitions and len(usages) == 2,
        f"definitions={definitions} usages={usages}",
    )

    definitions, usages = symbol_usage(
        {"pattern": "switch value {\ncase .foo(let source):\n    print(source)\n}\n"},
        "source",
    )
    check(
        "pattern bindings are not definitions",
        not definitions and len(usages) == 2,
        f"definitions={definitions} usages={usages}",
    )

    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)

        def sample(name, source):
            path = directory / f"{name}.swift"
            path.write_text(source, encoding="utf-8")
            return str(path)

        good = sample("good", "struct CommentSource {}\nlet source = CommentSource()\n")
        status, output = cli_status("symbol", "CommentSource", good)
        check("CLI accepts a real definition and use", status == 0, output)

        comment_definition = sample(
            "comment_definition", "// struct CommentSource {}\nlet source = CommentSource()\n"
        )
        status, output = cli_status("symbol", "CommentSource", comment_definition)
        check(
            "CLI rejects a definition hidden in a comment",
            status != 0 and "0 definition(s) found" in output,
            output,
        )

        comment_usage = sample(
            "comment_usage", "struct CommentSource {}\n// let source = CommentSource()\n"
        )
        status, output = cli_status("symbol", "CommentSource", comment_usage)
        check(
            "CLI rejects a use hidden in a comment",
            status != 0 and "0 usage(s) found" in output,
            output,
        )

        string_definition = sample(
            "string_definition",
            'let fake = "struct CommentSource {}"\nlet source = CommentSource()\n',
        )
        status, output = cli_status("symbol", "CommentSource", string_definition)
        check(
            "CLI rejects a definition hidden in a string",
            status != 0 and "0 definition(s) found" in output,
            output,
        )

        string_usage = sample(
            "string_usage", 'struct CommentSource {}\nlet text = "CommentSource()"\n'
        )
        status, output = cli_status("symbol", "CommentSource", string_usage)
        check(
            "CLI rejects a use hidden in a string",
            status != 0 and "0 usage(s) found" in output,
            output,
        )

        switch_case = sample(
            "switch_case",
            "let source = CommentSource()\nswitch source {\ncase CommentSource:\n    break\n}\n",
        )
        status, output = cli_status("symbol", "CommentSource", switch_case)
        check(
            "CLI rejects a switch case as the only definition",
            status != 0 and "0 definition(s) found" in output,
            output,
        )

        extension_only = sample(
            "extension_only",
            "extension CommentSource {}\nlet x = CommentSource()\n",
        )
        status, output = cli_status("symbol", "CommentSource", extension_only)
        check(
            "CLI rejects an extension as the only definition",
            status != 0 and "0 definition(s) found" in output,
            output,
        )

        status, output = cli_status(
            "symbol", "--name", "CommentSource", "--min-def", "1", "--min-use", "1", good
        )
        check("CLI accepts the --name/--min-def/--min-use flag form", status == 0, output)

        status, output = cli_status(
            "symbol", "--name", "CommentSource", "--min-def", "2", "--min-use", "1", good
        )
        check(
            "CLI rejects fewer definitions than --min-def",
            status != 0,
            output,
        )

        status, output = cli_status(
            "symbol", "--name", "CommentSource", "--min-def", "1", "--min-use", "2", good
        )
        check(
            "CLI rejects fewer usages than --min-use",
            status != 0,
            output,
        )

    if failures:
        sys.exit(f"self-test: {len(failures)} failure(s)")
    print("self-test: OK")


def main(arguments):
    if arguments == ["--self-test"]:
        run_self_test()
    elif arguments and arguments[0] == "balance":
        run_balance(arguments[1:])
    elif arguments and arguments[0] == "symbol":
        run_symbol(arguments[1:])
    else:
        sys.exit(
            "usage: check-swift-structure.py balance [PATH ...]\n"
            "       check-swift-structure.py symbol NAME [PATH ...]\n"
            "       check-swift-structure.py symbol --name NAME [--min-def N] [--min-use N] [PATH ...]\n"
            "       check-swift-structure.py --self-test"
        )


if __name__ == "__main__":
    main(sys.argv[1:])
