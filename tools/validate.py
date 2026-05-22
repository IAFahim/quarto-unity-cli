import re
import sys
import glob
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
KNOWN_CALLOUTS = {"axiom", "gotcha", "failure", "verify"}


def check_yaml():
    failures = []
    for path in glob.glob(str(ROOT / "**/*.yml"), recursive=True):
        try:
            yaml.safe_load(Path(path).read_text())
        except Exception as exc:
            failures.append(f"YAML {path}: {exc}")
    return failures


def check_lua():
    try:
        from luaparser import ast
    except ImportError:
        return []
    failures = []
    for path in glob.glob(str(ROOT / "**/*.lua"), recursive=True):
        try:
            ast.parse(Path(path).read_text())
        except Exception as exc:
            failures.append(f"LUA {path}: {exc}")
    return failures


def fenced_blocks(text):
    return re.findall(r"^```\{([^}]*)\}\n(.*?)\n```", text, re.DOTALL | re.MULTILINE)


def check_totality(path, text):
    failures = []
    for attrs, body in fenced_blocks(text):
        if ".exec" in attrs:
            name = re.search(r'name="([^"]*)"', attrs)
            label = name.group(1) if name else "exec"
            if not re.search(r"\breturn\b", body):
                failures.append(f"PARTIAL exec in {path}: {label}")
    return failures


def check_callouts(path, text):
    failures = []
    for cls in re.findall(r"^::: \{\.(\w+)", text, re.MULTILINE):
        if cls not in KNOWN_CALLOUTS:
            failures.append(f"UNKNOWN callout .{cls} in {path}")
    return failures


def check_content():
    failures = []
    for path in glob.glob(str(ROOT / "**/*.qmd"), recursive=True):
        text = Path(path).read_text()
        failures += check_totality(path, text)
        failures += check_callouts(path, text)
    return failures


def main():
    failures = check_yaml() + check_lua() + check_content()
    if failures:
        for line in failures:
            print(line)
        print(f"\n{len(failures)} invariant(s) violated")
        return 1
    print("all invariants hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
