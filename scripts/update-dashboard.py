#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

import os
import re
import subprocess
import sys
from pathlib import Path


def parse_log_file(path: Path) -> dict:
    data = {"overview": {}, "details": {}}

    def add_to_overview(pattern, key):
        match = re.search(pattern, line)
        if match:
            data["overview"][key] = match.group(1).strip()

    def add_to_details(pattern, key):
        match = re.search(pattern, line)
        if match and int(match.group(1)) > 0:
            data["details"][current_language][key] = int(match.group(1))

    overview_patterns = {
        "Total Inconsistent Filenames": r"Total inconsistent filename\(s\): (.+)",
        "Total Malformed or Outdated More Info Links": r"Total malformed or outdated more info link page\(s\): (.+)",
        "Total Missing Alias Pages": r"Total missing alias page\(s\): (.+)",
        "Total Mismatched Page Titles": r"Total mismatched page title\(s\): (.+)",
        "Total Missing TLDR Pages": r"Total missing TLDR page\(s\): (.+)",
        "Total Misplaced Pages": r"Total misplaced page\(s\): (.+)",
        "Total Outdated Pages (Command Count)": r"Total outdated page\(s\) based on number of commands: (.+)",
        "Total Outdated Pages (Command Content)": r"Total outdated page\(s\) based on the commands itself: (.+)",
        "Total Missing English Pages": r"Total missing English page\(s\): (.+)",
        "Total Missing Translated Pages": r"Total missing translated page\(s\): (.+)",
        "Total Lint Errors": r"Total lint error\(s\): (.+)",
    }

    detail_patterns = {
        "Inconsistent Filenames": r"(\d+) inconsistent filename",
        "Malformed Or Outdated More Info Links": r"(\d+) malformed or outdated",
        "Missing Alias Pages": r"(\d+) missing alias",
        "Mismatched Page Titles": r"(\d+) mismatched page title",
        "Missing TLDR Pages": r"(\d+) missing TLDR",
        "Misplaced Pages": r"(\d+) misplaced page",
        "Outdated Pages (Command Count)": r"(\d+) outdated page\(s\) based on number of commands",
        "Outdated Pages (Command Content)": r"(\d+) outdated page\(s\) based on the commands itself",
        "Missing English Pages": r"(\d+) missing English",
        "Missing Translated Pages": r"(\d+) missing translated",
        "Linter Errors": r"(\d+) linter error",
    }

    with path.open(encoding="utf-8") as f:
        lines = f.readlines()

    for line in lines:
        for key, pattern in overview_patterns.items():
            add_to_overview(pattern, key)

    current_language = None
    for line in lines:
        if line.startswith(
            "----------------------------------------------------------------------------------------------------"
        ):
            current_language = None
        match = re.match(r"^\d+.+in check-pages\.(\w+)/", line)
        if match:
            current_language = match.group(1).upper()
            if current_language not in data["details"]:
                data["details"][current_language] = {}

        if current_language:
            for key, pattern in detail_patterns.items():
                add_to_details(pattern, key)

    return data


def generate_dashboard(data):
    markdown = "# Translation Dashboard Status\n\n## Overview\n"
    overview = data["overview"]
    markdown += "| Metric                                       | Value             |\n"
    markdown += "|----------------------------------------------|-------------------|\n"

    for key, value in overview.items():
        markdown += f"| **{key}**                      | {value}            |\n"

    markdown += "\n## Detailed Breakdown by Language\n"

    for lang, details in data["details"].items():
        markdown += "<details>\n"
        markdown += f"\n<summary>{lang}</summary>\n\n"

        for key, value in details.items():
            markdown += f"- **{key}**: {value}\n"

        markdown += "</details>\n"

    return markdown


def update_github_issue(body):
    command = [
        "gh",
        "api",
        "--method",
        "PATCH",
        "-H",
        "Accept: application/vnd.github+json",
        "-H",
        "X-GitHub-Api-Version: 2022-11-28",
        "/repos/tldr-pages/tldr-maintenance/issues/25",
        "-f",
        f"body={body}",
    ]

    result = subprocess.run(command, capture_output=True, text=True)
    return result.returncode


def main():
    # Check if running in CI and in the correct repository
    if (
        os.getenv("CI") == "true"
        and os.getenv("GITHUB_REPOSITORY") == "tldr-pages/tldr-maintenance"
    ):
        log_file_path = Path("metrics.log")

        if not log_file_path.exists():
          sys.exit(0)

        parsed_data = parse_log_file(log_file_path)
        markdown_content = generate_dashboard(parsed_data)

        status_code = update_github_issue(markdown_content)

        sys.exit(status_code)
    else:
        print("Not in a CI or incorrect repository, refusing to run.", file=sys.stderr)
        sys.exit(0)


if __name__ == "__main__":
    main()
