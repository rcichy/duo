"""Lint only the lines a change adds: ruff with the given rules on the changed Python files of one git checkout.

Usage: new-code-check.py <checkout> <rules> <path prefix> [<strict rules>]
Prints "<prefix><file>:<line>: <code> <message>" for each finding on an added line (uncommitted changes against
HEAD, and every line of an untracked file). Old code around the change is not reported, so rules the codebase does
not follow yet (type annotations, say) can still be required of new code. The repo's own ruff config is used for
everything but the rule selection (excludes, per-file ignores, `# noqa`); <strict rules> apply even where the
repo's per-file ignores turn them off (a repo that exempts its tests from a rule the team requires everywhere).
"""

import json
import os
import re
import shutil
import subprocess
import sys


# pytest modules, classes and functions take no docstrings by convention: the test name says what it checks
TEST_FILE = re.compile(r"(^|/)(tests?/|test_[^/]*\.py$|[^/]*_test\.py$|conftest\.py$)")


def git(repo: str, *args: str) -> str:
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True).stdout


def added_lines(repo: str) -> dict[str, set[int] | None]:
    """Changed Python files -> their added line numbers; None for an untracked file (all of it is new)."""
    added: dict[str, set[int] | None] = {}
    for path in git(repo, "diff", "--name-only", "--diff-filter=AM", "HEAD").splitlines():
        if not path.endswith(".py"):
            continue
        lines: set[int] = set()
        for hunk in re.finditer(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@", git(repo, "diff", "-U0", "HEAD", "--", path), re.M):
            start, count = int(hunk[1]), int(hunk[2] if hunk[2] is not None else 1)
            lines.update(range(start, start + count))
        added[path] = lines
    for path in git(repo, "ls-files", "--others", "--exclude-standard").splitlines():
        if path.endswith(".py"):
            added[path] = None
    return added


def ruff_findings(ruff: str, repo: str, rules: str, files: list[str], *config: str) -> list[dict]:
    out = subprocess.run(
        [ruff, "check", "--no-cache", "--force-exclude", "--select", rules, *config, "--output-format", "json", *files],
        cwd=repo,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out or "[]")


def main() -> None:
    repo, rules, prefix = os.path.realpath(sys.argv[1]), sys.argv[2], sys.argv[3]
    strict = sys.argv[4] if len(sys.argv) > 4 else ""
    ruff = shutil.which("ruff")
    added = added_lines(repo)
    if not added or not ruff:
        return
    found = ruff_findings(ruff, repo, rules, list(added))
    if strict:
        found += ruff_findings(ruff, repo, strict, list(added), "--config", "lint.per-file-ignores = {}")
    seen = set()
    for finding in found:
        key = (finding["filename"], finding["location"]["row"], finding["location"]["column"], finding["code"])
        if key in seen:
            continue
        seen.add(key)
        path = os.path.relpath(os.path.realpath(finding["filename"]), repo)
        row = finding["location"]["row"]
        lines = added.get(path)
        if finding["code"].startswith("D") and TEST_FILE.search(path):
            continue
        if lines is None or row in lines:
            print(f"{prefix}{path}:{row}: {finding['code']} {finding['message']}")


if __name__ == "__main__":
    main()
