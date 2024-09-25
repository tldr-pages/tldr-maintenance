#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

import os
import re
import sys
from pathlib import Path
from _common import get_github_issue, update_github_issue


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
        "Total inconsistent filenames": r"Total inconsistent filename\(s\): (.+)",
        "Total malformed or outdated more info link pages": r"Total malformed or outdated more info link page\(s\): (.+)",
        "Total missing alias pages": r"Total missing alias page\(s\): (.+)",
        "Total mismatched page titles": r"Total mismatched page title\(s\): (.+)",
        "Total missing TLDR pages": r"Total missing TLDR page\(s\): (.+)",
        "Total misplaced pages": r"Total misplaced page\(s\): (.+)",
        "Total outdated pages (based on number of commands)": r"Total outdated page\(s\) based on number of commands: (.+)",
        "Total outdated pages (based on the commands itself)": r"Total outdated page\(s\) based on the commands itself: (.+)",
        "Total missing English pages": r"Total missing English page\(s\): (.+)",
        "Total missing translated pages": r"Total missing translated page\(s\): (.+)",
        "Total linter errors": r"Total lint error\(s\): (.+)",
    }

    detail_patterns = {
        "inconsistent filename(s)": r"(\d+) inconsistent filename",
        "malformed or outdated more info link page(s)": r"(\d+) malformed or outdated",
        "missing alias page(s)": r"(\d+) missing alias",
        "mismatched page title(s)": r"(\d+) mismatched page title",
        "missing TLDR page(s)": r"(\d+) missing TLDR",
        "misplaced page(s)": r"(\d+) misplaced page",
        "outdated pages (based on number of commands)": r"(\d+) outdated page\(s\) based on number of commands",
        "outdated pages (based on the commands itself)": r"(\d+) outdated page\(s\) based on the commands itself",
        "missing English page(s)": r"(\d+) missing English",
        "missing translated page(s)": r"(\d+) missing translated",
        "linter error(s)": r"(\d+) linter error",
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
            current_language = match.group(1)
            if current_language not in data["details"]:
                data["details"][current_language] = {}

        if current_language:
            for key, pattern in detail_patterns.items():
                add_to_details(pattern, key)

    return data


def generate_dashboard(data):
    markdown = "# Translation Dashboard Status\n\n## Overview\n"
    overview = data["overview"]
    markdown += "| Metric | Value |\n"
    markdown += "|--------|-------|\n"

    for key, value in overview.items():
        markdown += f"| **{key}**  | {value} |\n"

    markdown += "\n## Detailed Breakdown by Language\n"

    for lang, details in data["details"].items():
        markdown += "<details>\n"
        link_to_github_issue = get_github_issue(
            f"Translation Dashboard Status for {lang}"
        )
        if link_to_github_issue:
            markdown += f'\n<summary><a href="{link_to_github_issue["url"]}">{lang}</a></summary>\n\n'
        else:
            markdown += f"\n<summary>{lang}</summary>\n\n"

        for key, value in details.items():
            markdown += f"- {value} {key}\n"

        markdown += "</details>\n"

    return markdown


def main():
    # Check if running in CI and in the correct repository
    if (
        os.getenv("CI") == "true"
        and os.getenv("GITHUB_REPOSITORY") == "tldr-pages/tldr-maintenance"
    ):
        log_file_path = Path("metrics-log.md")

        if not log_file_path.exists():
            print("metrics.log not found.", file=sys.stderr)
            sys.exit(0)

        issue_title = "Translation Dashboard Status"
        issue_data = get_github_issue(issue_title)

        if not issue_data:
            print(f"{issue_title}-issue not found.", file=sys.stderr)
            sys.exit(0)
        
        parsed_data = parse_log_file(log_file_path)
        markdown_content = generate_dashboard(parsed_data)

        result = update_github_issue(
            issue_data["number"], issue_title, markdown_content
        )

        sys.exit(result.returncode)
    else:
        print("Not in a CI or incorrect repository, refusing to run.", file=sys.stderr)
        sys.exit(0)


if __name__ == "__main__":
    main()
