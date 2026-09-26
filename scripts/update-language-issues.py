#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

"""
Update the "Translation Dashboard Status for <language>" issue of every language with the results of
calculate-metrics.sh (the check-pages[.<language>]/<metric>.txt files in the current directory).
"""

import os
import sys

from pathlib import Path
from _common import (
    RELEASE_URL,
    IssueSection,
    Metric,
    build_issue_body,
    get_metrics,
    get_check_pages_dir,
    get_locale,
    get_datetime_pretty,
    strip_dynamic_content,
    create_github_issue,
    get_github_issues,
    update_github_issue,
)

# Only list the results of a metric when there aren't too many.
MAX_LISTED_RESULTS = 1000


def parse_file(filepath: Path) -> list[str]:
    with filepath.open(encoding="utf-8") as file:
        content = file.read().strip()
        return content.split("\n") if content else []


def parse_language_directory(
    directory: Path, locale: str, metrics: list[Metric]
) -> dict[Metric, list[str]]:
    """
    Get the results of every metric that applies to the language, from check-pages[.<language>]/<metric>.txt.
    """

    lang_data = {}
    for metric in metrics:
        if not metric.applies_to(locale):
            continue
        filepath = Path(directory) / metric.file_name
        lang_data[metric] = parse_file(filepath) if filepath.is_file() else []

    return lang_data


def get_issue_title(language: str) -> str:
    return f"Translation Dashboard Status for {language}"


def generate_markdown_for_language(
    language: str, directory_name: str, data: dict[Metric, list[str]]
) -> str:
    title = f"# {get_issue_title(language)}\n\n"
    header = title + f"## {language} language Issues\n"
    header += "<!-- __NOUPDATE__ -->\n"
    header += f"**Last updated:** {get_datetime_pretty()}\n"
    header += "<!-- __END_NOUPDATE__ -->\n"

    sections = []
    for metric, items in data.items():
        if not items:
            continue

        count = f"{len(items)} {metric.label}"
        short = f"\n{count} (see `{directory_name}/{metric.file_name}` in [metrics.zip]({RELEASE_URL}/metrics.zip))\n\n"
        if len(items) >= MAX_LISTED_RESULTS:
            sections.append(IssueSection(short, short))
            continue

        full = f"\n<details>\n  <summary>{count}</summary>\n\n"
        full += "".join(f"- {metric.format_result(item)}\n" for item in items)
        full += "</details>\n"
        sections.append(IssueSection(full, short))

    if not sections:
        return title + f"No issues found for {language}.\n"

    return build_issue_body(header, sections)


def main():
    # Check if running in CI and in the correct repository
    if (
        os.getenv("CI") != "true"
        or os.getenv("GITHUB_REPOSITORY") != "tldr-pages/tldr-maintenance"
    ):
        print("Not in a CI or incorrect repository, refusing to run.", file=sys.stderr)
        sys.exit(0)

    metrics = get_metrics()
    issues = get_github_issues()
    failed = False

    for lang_dir in get_check_pages_dir(Path.cwd()):
        locale = get_locale(lang_dir)
        print(f"Updating {locale}")

        title = get_issue_title(locale)
        issue_data = issues.get(title) or create_github_issue(title)

        lang_data = parse_language_directory(lang_dir, locale, metrics)
        markdown_content = generate_markdown_for_language(
            locale, lang_dir.name, lang_data
        )

        if strip_dynamic_content(markdown_content) == strip_dynamic_content(
            issue_data["body"]
        ):
            print(
                f"new issue body (sans dynamic content) for language {locale} identical to existing issue body, not updating"
            )
            continue

        if not update_github_issue(issue_data["number"], title, markdown_content):
            failed = True

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
