#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Drop known, steady-state failures from the lychee report.

Some domains (Cisco, npmjs.com, several wikis, ...) block automated
link checkers while working fine for real users. Unlike .lycheeignore,
we don't want to stop requesting them entirely - that would also hide
a *real* future failure (the domain going dead, the page actually
moving). Instead every failure line is still checked against
.lycheeexpected: it's dropped only if its status tag matches exactly
what's expected for that URL. Anything else (a different status, a
domain that isn't listed) is left in the report.

Also writes the number of remaining failures to $GITHUB_OUTPUT as
"count", so the workflow can decide whether to open/update/close the
report issue based on the filtered result rather than lychee's raw
exit code.
"""
import os
import re
from pathlib import Path

EXPECTED_FILE = Path(".lycheeexpected")
OUTPUT_FILE = Path("lychee/out.md")

FAILURE_PATTERN = re.compile(r"^\* \[([^\]]+)\] <([^>]+)>.*$", re.MULTILINE)


def load_expected():
    expected = []
    if not EXPECTED_FILE.exists():
        return expected
    for line in EXPECTED_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        pattern, tag = line.split("\t")
        expected.append((pattern, tag))
    return expected


def is_expected(url, tag, expected):
    return any(pattern in url and tag == expected_tag for pattern, expected_tag in expected)


def main():
    expected = load_expected()
    text = OUTPUT_FILE.read_text(encoding="utf-8")

    remaining = 0

    def keep(match):
        nonlocal remaining
        tag, url = match.group(1), match.group(2)
        if is_expected(url, tag, expected):
            return ""
        remaining += 1
        return match.group(0)

    filtered = FAILURE_PATTERN.sub(keep, text)
    # Collapse blank lines left behind by dropped entries
    filtered = re.sub(r"\n{3,}", "\n\n", filtered)
    OUTPUT_FILE.write_text(filtered, encoding="utf-8")

    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as f:
            f.write(f"count={remaining}\n")
    print(f"{remaining} failure(s) remain after filtering known/expected ones")


if __name__ == "__main__":
    main()
