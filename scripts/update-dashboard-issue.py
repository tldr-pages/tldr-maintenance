#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

import os
import re
import sys

from pathlib import Path
from enum import Enum
from _common import (
    get_datetime_pretty,
    strip_dynamic_content,
    get_github_issue,
    update_github_issue,
    generate_github_link,
    generate_github_edit_link,
    generate_github_new_link,
)


class Topics(str, Enum):
    def __str__(self):
        return str(
            self.value
        )  # make str(Topics.TOPIC) return the Topic instead of an Enum object

    INCONSISTENT_FILENAMES = "inconsistent filename(s)"
    MALFORMED_OR_OUTDATED_MORE_INFO_LINK_PAGES = (
        "malformed or outdated more info link page(s)"
    )
    MISSING_ALIAS_PAGES = "missing alias page(s)"
    MISMATCHED_PAGE_TITLES = "mismatched page title(s)"
    MISSING_TLDR_PAGES = "missing TLDR page(s)"
    MISPLACED_PAGES = "misplaced page(s)"
    OUTDATED_PAGES_BASED_ON_HEADER = "outdated page(s) based on header line count"
    OUTDATED_PAGES_BASED_ON_COMMAND_COUNT = (
        "outdated page(s) based on number of commands"
    )
    OUTDATED_PAGES_BASED_ON_COMMAND_CONTENTS = (
        "outdated page(s) based on the commands itself"
    )
    MISSING_ENGLISH_PAGES = "missing English page(s)"
    MISSING_TRANSLATED_PAGES = "missing translated page(s)"
    LINT_ERRORS = "linter error(s)"


def parse_log_file(path: Path) -> dict:
    data = {"overview": {}, "metrics": {}, "details": {}}
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

    process_overview(lines, overview_patterns, data)
    process_language_details(lines, detail_patterns, data)

    return data


def process_overview(lines, patterns, data):
    for line in lines:
        for key, pattern in patterns.items():
            match = re.search(pattern, line)
            if match:
                data["overview"][key] = match.group(1).strip()


def process_language_details(lines, patterns, data):
    current_language = None
    for line in lines:
        current_language = update_current_language(line, current_language, data)
        if current_language:
            add_language_details(line, patterns, current_language, data)


def update_current_language(line, current_language, data):
    if line.startswith("-" * 100):
        return None
    match = re.match(r"^\d+.+in check-pages\.(\w+)/", line)
    if match:
        new_language = match.group(1)
        if new_language not in data["details"]:
            data["details"][new_language] = {}
        return new_language
    return current_language


def add_language_details(line, patterns, current_language, data):
    for key, pattern in patterns.items():
        match = re.search(pattern, line)
        if match and int(match.group(1)) > 0:
            data["details"][current_language][key] = int(match.group(1))


def parse_seperate_text_files(data):
    for file in [
        Path("inconsistent-filenames.txt"),
        Path("malformed-or-outdated-more-info-link-pages.txt"),
        Path("missing-alias-pages.txt"),
        Path("mismatched-page-titles.txt"),
        Path("missing-tldr-pages.txt"),
        Path("misplaced-pages.txt"),
        Path("outdated-pages-based-on-command-count.txt"),
        Path("outdated-pages-based-on-command-contents.txt"),
        Path("missing-english-pages.txt"),
        Path("missing-translated-pages.txt"),
        Path("lint-errors.txt"),
    ]:
        if not file.is_file():
            continue
        topic_name = file.name.replace(".txt", "").replace("-", "_")
        if hasattr(Topics, topic_name.upper()):
            topic = getattr(Topics, topic_name.upper()).value
            if topic:
                with file.open(encoding="utf-8") as f:
                    lines = f.readlines()
                    add_metric_details(lines, data, topic_name, topic, file.name)
    return data


def add_metric_details(lines, data, topic_name, topic, file_name):
    data["metrics"][topic] = {
        "count": len(lines),
        "files": [],
        "url": f"https://github.com/tldr-pages/tldr-maintenance/releases/download/latest/{file_name}",
    }
    if len(lines) <= 100:
        match topic_name:
            case "inconsistent_filenames":
                data["metrics"][topic]["files"] = [f"{line.strip()}" for line in lines]
            case "missing_alias_pages":
                data["metrics"][topic]["files"] = [
                    f"{generate_github_new_link(line.strip())}" for line in lines
                ]
            case "missing_tldr_pages":
                data["metrics"][topic]["files"] = [
                    f"{generate_github_link(line.strip())}" for line in lines
                ]
            case _:
                data["metrics"][topic]["files"] = [
                    f"{generate_github_edit_link(line.strip())}" for line in lines
                ]


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

        parsed_data = parse_log_file(log_file_path)
        parsed_data = parse_seperate_text_files(parsed_data)

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
