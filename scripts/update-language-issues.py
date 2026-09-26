#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

"""
Update the "Translation Dashboard Status for <language>" issue of every language with the results of
calculate-metrics.sh (the check-pages[.<language>]/<metric>.txt files in the current directory).
"""

import os
import sys
from pathlib import Path

from _dashboard import (
    MAX_LISTED_RESULTS,
    RELEASE_URL,
    IssueSection,
    Metric,
    build_issue_body,
    create_github_issue,
    get_check_pages_dirs,
    get_github_issues,
    get_language_issue_title,
    get_last_updated,
    get_locale,
    get_metrics,
    read_results,
    strip_dynamic_content,
    update_github_issue,
)


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
        lang_data[metric] = read_results(directory / metric.file_name)

    return lang_data


def generate_markdown_for_language(
    language: str, directory_name: str, data: dict[Metric, list[str]]
) -> str:
    title = f"# {get_language_issue_title(language)}\n\n"
    header = title + f"## {language} language Issues\n"
    header += get_last_updated()

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

    for lang_dir in get_check_pages_dirs(Path.cwd()):
        locale = get_locale(lang_dir)
        print(f"Updating {locale}")

        title = get_language_issue_title(locale)
        issue_data = issues.get(title) or create_github_issue(title)
        if not issue_data:
            failed = True
            continue

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
