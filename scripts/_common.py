#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

"""
A Python file that makes some commonly used functions available for other scripts to use.
"""

from enum import Enum
from dataclasses import dataclass
from pathlib import Path
from datetime import datetime, timezone
import os
import re
import sys
import json
import time
import subprocess
import urllib.error
import urllib.parse
import urllib.request


class Colors(str, Enum):
    def __str__(self):
        return str(
            self.value
        )  # make str(Colors.COLOR) return the ANSI code instead of an Enum object

    RED = "\x1b[31m"
    GREEN = "\x1b[32m"
    BLUE = "\x1b[34m"
    CYAN = "\x1b[36m"
    RESET = "\x1b[0m"


ORG_NAME = "tldr-pages"
REPO_NAME = "tldr"
REPO = f"{ORG_NAME}/{REPO_NAME}"
API_URL = "https://api.github.com"
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


API_VERSION = "2022-11-28"


def get_token() -> str:
    """
    Get a GitHub token from GITHUB_TOKEN, GH_TOKEN or the GitHub CLI.
    """

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        return token
    try:
        return subprocess.run(
            ["gh", "auth", "token"], capture_output=True, text=True, check=True
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        sys.exit("Please set GITHUB_TOKEN or log in with `gh auth login`.")


_token = None


def github_request(
    path: str, params: dict = None, method: str = "GET", payload: dict = None
) -> tuple[int, object]:
    """
    Perform a request against the GitHub REST API, waiting when rate limited.

    Parameters:
    path (str): the path of the endpoint, e.g. "/repos/tldr-pages/tldr".
    params (dict): the query parameters.
    method (str): the HTTP method.
    payload (dict): the JSON body to send.

    Returns:
    tuple: the HTTP status code and the decoded JSON body (None when there is no body).
    """

    global _token
    if _token is None:
        _token = get_token()

    url = f"{API_URL}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(
        url,
        method=method,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {_token}",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": API_VERSION,
        },
    )

    for _ in range(5):
        try:
            with urllib.request.urlopen(request) as response:
                body = response.read()
                return response.status, json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            if error.code in (403, 429) and (
                error.headers.get("Retry-After")
                or error.headers.get("X-RateLimit-Remaining") == "0"
            ):
                wait = int(error.headers.get("Retry-After") or 0)
                if not wait:
                    reset = int(error.headers.get("X-RateLimit-Reset", time.time()))
                    wait = max(reset - int(time.time()), 0) + 1
                print(f"Rate limited, waiting {wait}s...", file=sys.stderr)
                time.sleep(wait)
                continue
            body = error.read()
            return error.code, json.loads(body) if body else None
    raise SystemExit(f"Giving up on {url} after repeated rate limiting.")


def github_paginate(path: str, params: dict = None) -> list | None:
    """
    Get all pages of a GitHub REST API list endpoint.

    Returns:
    list: all items, or None when the request isn't allowed (e.g. the token lacks access).
    """

    items = []
    page = 1
    while True:
        status, data = github_request(
            path, {**(params or {}), "per_page": 100, "page": page}
        )
        if status != 200:
            return None
        items += data
        if len(data) < 100:
            return items
        page += 1


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


def create_colored_line(start_color: str, text: str) -> str:
    """
    Create a colored line.

    Parameters:
    start_color (str): The color for the line.
    text (str): The text to display.

    Returns:
    str: A colored line
    """

    return f"{start_color}{text}{Colors.RESET}"


ISSUES_PATH = "/repos/tldr-pages/tldr-maintenance/issues"
RELEASE_URL = "https://github.com/tldr-pages/tldr-maintenance/releases/download/latest"
# GitHub rejects issue bodies with more characters.
MAX_ISSUE_BODY_LENGTH = 65536


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


def create_github_issue(title: str) -> dict:
    status, data = github_request(ISSUES_PATH, method="POST", payload={"title": title})
    if status != 201:
        raise SystemExit(f"Creating the issue {title} failed: {data}")

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

        return f"[{page}](https://github.com/tldr-pages/tldr/blob/main/{directory}/{filename})"

    return re.sub(r"pages(?:\.[^/\s]+)?/[^:]*?\.md(?=[:\s]|$)", replace_reference, item)


def generate_github_edit_link(page):
    directory = Path(page).parent
    filename = urllib.parse.quote(Path(page).name)

    page = replace_characters_for_link(page)

    return (
        f"[{page}](https://github.com/tldr-pages/tldr/edit/main/{directory}/{filename})"
    )


def generate_github_new_link(page):
    directory = Path(page).parent
    filename = urllib.parse.quote(Path(page).name)

    page = replace_characters_for_link(page)

    return f"[{page}](https://github.com/tldr-pages/tldr/new/main/{directory}?filename={filename})"


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

    return f"[{text}](https://github.com/tldr-pages/tldr/blob/main/{directory}/{filename}?plain=1#L{line_number})"
