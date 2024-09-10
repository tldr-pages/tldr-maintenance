#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

import os
import re
import sys
import urllib.parse

from pathlib import Path
from enum import Enum
from _common import (
    get_tldr_root,
    get_check_pages_dir,
    get_locale,
    create_github_issue,
    get_github_issue,
    update_github_issue,
)


class Topics(str, Enum):
    def __str__(self):
        return str(
            self.value
        )  # make str(Colors.COLOR) return the ANSI code instead of an Enum object

    INCONSISTENT = "inconsistent filename(s)"
    MALFORMED_OR_OUTDATED_MORE_INFO_LINK = (
        "malformed or outdated more info link page(s)"
    )
    ALIAS_PAGES = "missing alias page(s)"
    PAGE_TITLES = "mismatched page title(s)"
    MISSING_TLDR = "missing TLDR page(s)"
    MISPLACED = "misplaced page(s)"
    BASED_ON_COMMAND_COUNT = "outdated page(s) based on number of commands"
    BASED_ON_COMMAND_CONTENTS = "outdated page(s) based on the commands itself"
    MISSING_ENGLISH = "missing English page(s)"
    MISSING_TRANSLATED = "missing translated page(s)"
    LINT_ERRORS = "linter error(s)"


def generate_github_link(item):
    def replace_reference(match):
        page = match.group(0)

        directory = Path(page).parent
        filename = Path(page).name

        filename = urllib.parse.quote(filename)
        page = str(
            page.replace("[", "\\[")
            .replace("]", "\\]")
            .replace(")", "\\)")
            .replace("(", "\\(")
        )

        return f"[{page}](https://github.com/tldr-pages/tldr/blob/main/{directory}/{filename})"

    return re.sub(r"pages\..*\.md", replace_reference, item)


def generate_github_edit_link(page):
    directory = Path(page).parent
    filename = Path(page).name

    filename = urllib.parse.quote(filename)
    page = str(
        page.replace("[", "\\[")
        .replace("]", "\\]")
        .replace(")", "\\)")
        .replace("(", "\\(")
    )

    return (
        f"[{page}](https://github.com/tldr-pages/tldr/edit/main/{directory}/{filename})"
    )


def generate_github_new_link(page):
    directory = Path(page).parent
    filename = Path(page).name

    filename = urllib.parse.quote(filename)
    page = str(
        page.replace("[", "\\[")
        .replace("]", "\\]")
        .replace(")", "\\)")
        .replace("(", "\\(")
    )

    return f"[{page}](https://github.com/tldr-pages/tldr/new/main/{directory}?filename={filename})"


def parse_file(filepath):
    with filepath.open(encoding="utf-8") as file:
        return file.read().strip().split("\n")


def parse_language_directory(directory):
    topics = [
        "inconsistent",
        "malformed-or-outdated-more-info-link",
        "alias-pages",
        "page-titles",
        "missing-tldr",
        "misplaced",
        "based-on-command-count",
        "based-on-command-contents",
        "missing-english",
        "missing-translated",
        "lint-errors",
    ]
    lang_data = {topic: [] for topic in topics}

    for topic in topics:
        topic_files = [f for f in Path(directory).iterdir() if topic in f.name]
        for file in topic_files:
            filepath = Path(directory) / file
            lang_data[topic].extend(parse_file(filepath))

    return lang_data


def generate_markdown_for_language(language, data):
    markdown = f"## {language} language Issues\n"
    has_issues = False

    for topic, items in data.items():
        title = topic.replace("-", "_").upper()
        topic_title = getattr(Topics, title).value
        number_of_items = len(items)
        if number_of_items >= 1000:
            has_issues = True
            markdown += f"\n{number_of_items} {topic_title}\n\n"
        elif items:
            has_issues = True
            markdown += (
                f"\n<details>\n  <summary>{number_of_items} {topic_title}</summary>\n\n"
            )
            for item in items:
                match topic:
                    case "inconsistent":
                        markdown += f"- {item}\n"
                    case "alias-pages":
                        markdown += f"- {generate_github_new_link(item)}\n"
                    case "missing-tldr":
                        markdown += f"- {generate_github_link(item)}\n"
                    case _:
                        markdown += f"- {generate_github_edit_link(item)}\n"
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

        for lang_dir in check_pages_dir:
            locale = get_locale(lang_dir)

            title = f"Translation Dashboard Status for {locale}"

            issue_number = get_github_issue(title)["number"]

            if not issue_number:
                issue_number = create_github_issue(title)["number"]

            markdown_content = f"# {title}\n\n"

            lang_data = parse_language_directory(lang_dir)
            markdown_content += generate_markdown_for_language(locale, lang_data)

            update_github_issue(issue_number, title, markdown_content)
    else:
        print("Not in a CI or incorrect repository, refusing to run.", file=sys.stderr)
        sys.exit(0)


if __name__ == "__main__":
    main()
