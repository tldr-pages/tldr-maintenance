#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

import os
import re
import sys

from pathlib import Path
from _common import (
    Metric,
    get_metrics,
    get_datetime_pretty,
    strip_dynamic_content,
    get_github_issue,
    update_github_issue,
)

RELEASE_URL = "https://github.com/tldr-pages/tldr-maintenance/releases/download/latest"


def parse_log_file(path: Path, metrics: list[Metric]) -> dict:
    """
    Parse the totals and the number of results per language from the output of calculate-metrics.sh.
    """

    data = {"overview": {}, "metrics": {}, "details": {}}

    with path.open(encoding="utf-8") as f:
        lines = f.read().splitlines()

    patterns = [
        (
            metric,
            re.compile(rf"^Total {re.escape(metric.label)}: (.+)$"),
            re.compile(rf"^(\d+) {re.escape(metric.label)} in check-pages\.(\w+)/"),
        )
        for metric in metrics
    ]

    for line in lines:
        for metric, total_pattern, detail_pattern in patterns:
            if match := total_pattern.match(line):
                data["overview"][f"Total {metric.label}"] = match.group(1).strip()
            elif (match := detail_pattern.match(line)) and int(match.group(1)) > 0:
                count, language = match.groups()
                data["details"].setdefault(language, {})[metric.label] = int(count)

    return data


def parse_result_files(data: dict, metrics: list[Metric]) -> dict:
    """
    Add the total results of every metric (the <metric>.txt files written by calculate-metrics.sh).
    """

    for metric in metrics:
        file = Path(metric.file_name)
        if not file.is_file():
            continue

        with file.open(encoding="utf-8") as f:
            lines = f.read().splitlines()

        data["metrics"][metric.label] = {
            "count": len(lines),
            # Only list the results when there aren't too many.
            "files": (
                [metric.format_result(line) for line in lines]
                if len(lines) <= 100
                else []
            ),
            "url": f"{RELEASE_URL}/{metric.file_name}",
        }

    return data


def generate_dashboard(data):
    DETAILS_OPENING = "<details>\n"
    DETAILS_CLOSING = "\n</details>\n"

    markdown = "# Translation Dashboard Status\n\n"
    markdown += "<!-- __NOUPDATE__ -->\n"
    markdown += f"**Last updated:** {get_datetime_pretty()}\n"
    markdown += "<!-- __END_NOUPDATE__ -->\n"
    markdown += "## Overview\n"
    markdown += "| Metric | Value |\n"
    markdown += "|--------|-------|\n"

    for key, value in data["overview"].items():
        markdown += f"| **{key}**  | {value} |\n"

    markdown += "\n## Detailed Breakdown by Metric\n\n"

    for key, metric in data["metrics"].items():
        markdown += DETAILS_OPENING

        markdown += f'<summary>{metric["count"]} {key}</summary>\n\n'

        if not metric["files"]:
            markdown += f"- More than 100 files, please view the [release artifact]({metric['url']}).\n"
            markdown += DETAILS_CLOSING
            continue

        for file in metric["files"]:
            markdown += f"- {file}\n"

        markdown += DETAILS_CLOSING

    markdown += "\n## Detailed Breakdown by Language\n\n"

    for lang, details in data["details"].items():
        markdown += DETAILS_OPENING
        link_to_github_issue = get_github_issue(
            f"Translation Dashboard Status for {lang}"
        )
        if link_to_github_issue:
            markdown += f'\n<summary><a href="{link_to_github_issue["url"]}">{lang}</a></summary>\n\n'
        else:
            markdown += f"\n<summary>{lang}</summary>\n\n"

        for key, value in details.items():
            markdown += f"- {value} {key}\n"

        markdown += DETAILS_CLOSING

    return markdown


def main():
    # Check if running in CI and in the correct repository
    if (
        os.getenv("CI") == "true"
        and os.getenv("GITHUB_REPOSITORY") == "tldr-pages/tldr-maintenance"
    ):
        log_file_path = Path("metrics-log.md")

        if not log_file_path.exists():
            print("metrics-log.md not found.", file=sys.stderr)
            sys.exit(0)

        issue_title = "Translation Dashboard Status"
        issue_data = get_github_issue(issue_title)

        if not issue_data:
            print(f"{issue_title}-issue not found.", file=sys.stderr)
            sys.exit(0)

        metrics = get_metrics()
        parsed_data = parse_log_file(log_file_path, metrics)
        parsed_data = parse_result_files(parsed_data, metrics)

        markdown_content = generate_dashboard(parsed_data)

        if strip_dynamic_content(markdown_content) == strip_dynamic_content(
            issue_data["body"]
        ):
            print(
                "new issue body (sans dynamic content) identical to existing issue body, not updating"
            )
            sys.exit(0)

        result = update_github_issue(
            issue_data["number"], issue_title, markdown_content
        )

        sys.exit(result.returncode)
    else:
        print("Not in a CI or incorrect repository, refusing to run.", file=sys.stderr)
        sys.exit(0)


if __name__ == "__main__":
    main()
