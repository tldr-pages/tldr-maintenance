#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

"""
Update the "Translation Dashboard Status" issue with the output of calculate-metrics.sh
(metrics-log.md and the <metric>.txt files in the current directory).
"""

import os
import re
import sys

from pathlib import Path
from _common import (
    RELEASE_URL,
    IssueSection,
    Metric,
    build_issue_body,
    get_metrics,
    get_datetime_pretty,
    strip_dynamic_content,
    get_github_issues,
    update_github_issue,
)

ISSUE_TITLE = "Translation Dashboard Status"
# Only list the results of a metric when there aren't too many.
MAX_LISTED_RESULTS = 100


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
            "results": (
                [metric.format_result(line) for line in lines]
                if len(lines) <= MAX_LISTED_RESULTS
                else []
            ),
            "url": f"{RELEASE_URL}/{metric.file_name}",
        }

    return data


def generate_dashboard(data: dict, issues: dict[str, dict]) -> str:
    DETAILS_OPENING = "<details>\n"
    DETAILS_CLOSING = "\n</details>\n"

    header = f"# {ISSUE_TITLE}\n\n"
    header += "<!-- __NOUPDATE__ -->\n"
    header += f"**Last updated:** {get_datetime_pretty()}\n"
    header += "<!-- __END_NOUPDATE__ -->\n"
    header += "## Overview\n"
    header += "| Metric | Value |\n"
    header += "|--------|-------|\n"

    for key, value in data["overview"].items():
        header += f"| **{key}**  | {value} |\n"

    header += "\n## Detailed Breakdown by Metric\n\n"

    sections = []
    for label, metric in data["metrics"].items():
        summary = f"{DETAILS_OPENING}<summary>{metric['count']} {label}</summary>\n\n"
        see_artifact = f"- Too many results to list here, please view the [release artifact]({metric['url']}).\n{DETAILS_CLOSING}"

        if metric["results"]:
            results = "".join(f"- {result}\n" for result in metric["results"])
            sections.append(
                IssueSection(
                    summary + results + DETAILS_CLOSING, summary + see_artifact
                )
            )
        else:
            sections.append(
                IssueSection(summary + see_artifact, summary + see_artifact)
            )

    breakdown_by_language = "\n## Detailed Breakdown by Language\n\n"
    for lang, details in data["details"].items():
        breakdown_by_language += DETAILS_OPENING
        language_issue = issues.get(f"{ISSUE_TITLE} for {lang}")
        if language_issue:
            breakdown_by_language += (
                f'\n<summary><a href="{language_issue["url"]}">{lang}</a></summary>\n\n'
            )
        else:
            breakdown_by_language += f"\n<summary>{lang}</summary>\n\n"

        for label, count in details.items():
            breakdown_by_language += f"- {count} {label}\n"

        breakdown_by_language += DETAILS_CLOSING

    sections.append(IssueSection(breakdown_by_language, breakdown_by_language))

    return build_issue_body(header, sections)


def main():
    # Check if running in CI and in the correct repository
    if (
        os.getenv("CI") != "true"
        or os.getenv("GITHUB_REPOSITORY") != "tldr-pages/tldr-maintenance"
    ):
        print("Not in a CI or incorrect repository, refusing to run.", file=sys.stderr)
        sys.exit(0)

    log_file_path = Path("metrics-log.md")
    if not log_file_path.exists():
        sys.exit("metrics-log.md not found.")

    issues = get_github_issues()
    issue_data = issues.get(ISSUE_TITLE)
    if not issue_data:
        sys.exit(f"The {ISSUE_TITLE} issue is not found.")

    metrics = get_metrics()
    parsed_data = parse_log_file(log_file_path, metrics)
    parsed_data = parse_result_files(parsed_data, metrics)

    markdown_content = generate_dashboard(parsed_data, issues)

    if strip_dynamic_content(markdown_content) == strip_dynamic_content(
        issue_data["body"]
    ):
        print(
            "new issue body (sans dynamic content) identical to existing issue body, not updating"
        )
        sys.exit(0)

    if not update_github_issue(issue_data["number"], ISSUE_TITLE, markdown_content):
        sys.exit(1)


if __name__ == "__main__":
    main()
