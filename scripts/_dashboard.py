#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

"""
Functions for the dashboard scripts (update-dashboard-issue.py and update-language-issues.py), which update GitHub
issues with the results of calculate-metrics.sh.
"""

import re
import sys
import urllib.parse
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from _common import (
    MAINTENANCE_REPO,
    REPO,
    Colors,
    create_colored_line,
    github_paginate,
    github_request,
)

METRICS_FILE = Path(__file__).parent / "metrics.tsv"


@dataclass(frozen=True)
class Metric:
    """A metric as described in metrics.tsv."""

    id: str
    languages: str
    source: str
    denominator: str
    link: str
    label: str

    @property
    def file_name(self) -> str:
        return f"{self.id}.txt"

    def applies_to(self, locale: str) -> bool:
        return self.languages == "all" or locale != "en"

    def format_result(self, result: str) -> str:
        """Format a line of a result file as Markdown, with a link to the page."""

        match self.link:
            case "reference":
                return generate_github_link(result)
            case "edit":
                return generate_github_edit_link(result)
            case "new":
                return generate_github_new_link(result)
            case "lint":
                return generate_github_lint_link(result)
            case _:
                raise ValueError(f"Unknown link type {self.link} of metric {self.id}")


def get_metrics(path: Path = METRICS_FILE) -> list[Metric]:
    """
    Get the metrics described in metrics.tsv, in the order they are displayed.

    Returns:
    list (list of Metric's): the metrics.
    """

    metrics = []
    with path.open(encoding="utf-8") as file:
        for number, line in enumerate(file, start=1):
            line = line.rstrip("\r\n")
            if not line or line.startswith("#") or line.startswith("id\t"):
                continue
            columns = line.split("\t")
            if len(columns) != 6 or not all(columns):
                raise SystemExit(
                    f"{path}:{number}: expected 6 non-empty columns separated by a tab"
                )
            metric = Metric(*columns)
            if metric.languages not in ("all", "translations") or metric.link not in (
                "reference",
                "edit",
                "new",
                "lint",
            ):
                raise SystemExit(f"{path}:{number}: invalid languages or link")
            metrics.append(metric)
    return metrics


def get_check_pages_dir(root: Path) -> list[Path]:
    """
    Get all directories with the results of check-pages.sh.

    Parameters:
    root (Path): the directory calculate-metrics.sh ran in.

    Returns:
    list (list of Path's): the result directories, e.g. "check-pages" (English) and "check-pages.fr".
    """

    return sorted(
        [d for d in root.iterdir() if d.is_dir() and d.name.startswith("check-pages")]
    )


def get_locale(path: Path) -> str:
    """
    Get the locale from the path.

    Parameters:
    path (Path): the path to extract the locale.

    Returns:
    str: a POSIX Locale Name in the form of "ll" or "ll_CC" (e.g. "fr" or "pt_BR").
    """

    # compute locale
    check_pages_dirname = path.name
    if "." in check_pages_dirname:
        _, locale = check_pages_dirname.split(".")
    else:
        locale = "en"

    return locale


ISSUES_PATH = f"/repos/{MAINTENANCE_REPO}/issues"
RELEASE_URL = f"https://github.com/{MAINTENANCE_REPO}/releases/download/latest"
# GitHub rejects issue bodies with more characters.
MAX_ISSUE_BODY_LENGTH = 65536
# The results of a metric are only listed in an issue when there aren't more.
MAX_LISTED_RESULTS = 1000
DASHBOARD_ISSUE_TITLE = "Translation Dashboard Status"


def get_language_issue_title(language: str) -> str:
    return f"{DASHBOARD_ISSUE_TITLE} for {language}"


def simplify_issue(issue: dict) -> dict:
    return {
        "number": issue["number"],
        "title": issue["title"],
        "body": issue.get("body") or "",
        "url": issue["html_url"],
    }


def get_github_issues() -> dict[str, dict]:
    """
    Get all open issues (without pull requests) of tldr-maintenance.

    Returns:
    dict: the issues by title.
    """

    issues = github_paginate(ISSUES_PATH, {"state": "open"})
    if issues is None:
        raise SystemExit("Getting the issues of tldr-maintenance failed.")

    return {
        issue["title"]: simplify_issue(issue)
        for issue in issues
        if "pull_request" not in issue
    }


def create_github_issue(title: str) -> dict | None:
    """
    Create an issue.

    Returns:
    dict: the issue, or None when creating it failed.
    """

    status, data = github_request(ISSUES_PATH, method="POST", payload={"title": title})
    if status != 201:
        print(
            create_colored_line(Colors.RED, f"Creating {title} failed: {data}"),
            file=sys.stderr,
        )
        return None

    return simplify_issue(data)


def update_github_issue(issue_number: int, title: str, body: str) -> bool:
    """
    Update the title and body of an issue.

    Returns:
    bool: whether the update succeeded.
    """

    status, data = github_request(
        f"{ISSUES_PATH}/{issue_number}",
        method="PATCH",
        payload={"title": title, "body": body},
    )

    if status != 200:
        print(
            create_colored_line(
                Colors.RED, f"Updating {title} (#{issue_number}) failed: {data}"
            ),
            file=sys.stderr,
        )
        return False

    print(
        create_colored_line(
            Colors.GREEN, f"Updating {title} (#{issue_number}) succeeded"
        )
    )
    return True


@dataclass
class IssueSection:
    """A section of an issue body, with a shorter version for when the body is too long."""

    full: str
    short: str


def build_issue_body(
    header: str, sections: list[IssueSection], max_length: int = MAX_ISSUE_BODY_LENGTH
) -> str:
    """
    Join the sections of an issue body. When it's too long, the sections that save the most are shortened first.
    When it's still too long, the end is cut off.
    """

    use_full = [True] * len(sections)

    def render() -> str:
        return header + "".join(
            section.full if full else section.short
            for section, full in zip(sections, use_full)
        )

    body = render()
    while len(body) > max_length and any(use_full):
        longest = max(
            (i for i, full in enumerate(use_full) if full),
            key=lambda i: len(sections[i].full) - len(sections[i].short),
        )
        use_full[longest] = False
        body = render()

    if len(body) > max_length:
        truncated = (
            "\n\n(The rest is cut off, since GitHub doesn't allow longer issues.)\n"
        )
        body = body[: max_length - len(truncated)] + truncated

    return body


def get_datetime_pretty():
    # Guarantee UTC to be fair to everyone, since we can't make this dynamic based on the browser's timezone
    date = datetime.now(timezone.utc)
    return date.strftime("%Y-%m-%d %H:%M:%S UTC")


def strip_dynamic_content(markdown):
    """
    Removes any dynamic content enclosed within `<!-- __NOUPDATE__ -->` and `<!-- __END_NOUPDATE__ -->` tags from the provided Markdown string.

    This function is used to remove any dynamic content (e.g. the last updated time) from the given string before updating a GitHub issue, ensuring that the issue content remains static if not *actual* content has changed

    Args:
            markdown (str): The Markdown content to be processed.

    Returns:
            str: The Markdown content with the dynamic content removed.
    """
    if not markdown:
        return ""
    regex = re.compile(
        r"<!--\s*__NOUPDATE__(.|\n)*__END_NOUPDATE__\s*-->", re.MULTILINE
    )
    return re.sub(regex, "", markdown)


def replace_characters_for_link(page):
    return str(
        page.replace("[", "\\[")
        .replace("]", "\\]")
        .replace(")", "\\)")
        .replace("(", "\\(")
    )


def generate_github_link(item):
    def replace_reference(match):
        page = match.group(0)

        directory = Path(page).parent
        filename = urllib.parse.quote(Path(page).name)

        page = replace_characters_for_link(page)

        return f"[{page}](https://github.com/{REPO}/blob/main/{directory}/{filename})"

    return re.sub(r"pages(?:\.[^/\s]+)?/[^:]*?\.md(?=[:\s]|$)", replace_reference, item)


def generate_github_edit_link(page):
    directory = Path(page).parent
    filename = urllib.parse.quote(Path(page).name)

    page = replace_characters_for_link(page)

    return f"[{page}](https://github.com/{REPO}/edit/main/{directory}/{filename})"


def generate_github_new_link(page):
    directory = Path(page).parent
    filename = urllib.parse.quote(Path(page).name)

    page = replace_characters_for_link(page)

    return (
        f"[{page}](https://github.com/{REPO}/new/main/{directory}?filename={filename})"
    )


def generate_github_lint_link(line):
    """
    Generate a Markdown link for a linter error line (from markdownlint or tldr-lint).

    The page path and line number are extracted from the error line, e.g.
    "tldr/pages.fr/common/tar.md:12: TLDR112 ..." links to line 12 of pages.fr/common/tar.md.
    Lines that don't reference a page are returned escaped, without a link.
    """

    match = re.match(r"^(?:\./)?(?:tldr/)?(pages[^:]*\.md):(\d+)(.*)$", line)
    if not match:
        return replace_characters_for_link(line)

    page, line_number, message = match.groups()

    directory = Path(page).parent
    filename = urllib.parse.quote(Path(page).name)

    text = replace_characters_for_link(f"{page}:{line_number}{message}")

    return f"[{text}](https://github.com/{REPO}/blob/main/{directory}/{filename}?plain=1#L{line_number})"
