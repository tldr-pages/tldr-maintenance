#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

import os
import sys

from pathlib import Path
from _common import (
    Metric,
    get_metrics,
    get_tldr_root,
    get_check_pages_dir,
    get_locale,
    get_datetime_pretty,
    strip_dynamic_content,
    create_github_issue,
    get_github_issue,
    update_github_issue,
)


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


def generate_markdown_for_language(language: str, data: dict[Metric, list[str]]) -> str:
    markdown = f"## {language} language Issues\n"
    markdown += "<!-- __NOUPDATE__ -->\n"
    markdown += f"**Last updated:** {get_datetime_pretty()}\n"
    markdown += "<!-- __END_NOUPDATE__ -->\n"

    has_issues = False

    for metric, items in data.items():
        number_of_items = len(items)
        if number_of_items >= 1000:
            has_issues = True
            markdown += f"\n{number_of_items} {metric.label}\n\n"
        elif items:
            has_issues = True
            markdown += f"\n<details>\n  <summary>{number_of_items} {metric.label}</summary>\n\n"
            for item in items:
                markdown += f"- {metric.format_result(item)}\n"
            markdown += "</details>\n"

    if not has_issues:
        markdown = f"No issues found for {language}.\n"

    return markdown


def main():
    # Check if running in CI and in the correct repository
    if (
        os.getenv("CI") == "true"
        and os.getenv("GITHUB_REPOSITORY") == "tldr-pages/tldr-maintenance"
    ):
        root = get_tldr_root()
        check_pages_dir = get_check_pages_dir(root)
        metrics = get_metrics()

        for lang_dir in check_pages_dir:
            locale = get_locale(lang_dir)
            print(f"Updating {locale}")

            title = f"Translation Dashboard Status for {locale}"

            issue_data = get_github_issue(title)

            if not issue_data:
                issue_data = create_github_issue(title)

            markdown_content = f"# {title}\n\n"

            lang_data = parse_language_directory(lang_dir, locale, metrics)
            markdown_content += generate_markdown_for_language(locale, lang_data)

            if strip_dynamic_content(markdown_content) == strip_dynamic_content(
                issue_data["body"]
            ):
                print(
                    f"new issue body (sans dynamic content) for language {locale} identical to existing issue body, not updating"
                )
                continue

            update_github_issue(issue_data["number"], title, markdown_content)
    else:
        print("Not in a CI or incorrect repository, refusing to run.", file=sys.stderr)
        sys.exit(0)


if __name__ == "__main__":
    main()
