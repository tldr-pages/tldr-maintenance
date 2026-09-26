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
                return replace_characters_for_link(result)


def get_metrics(path: Path = METRICS_FILE) -> list[Metric]:
    """
    Get the metrics described in metrics.tsv, in the order they are displayed.

    Returns:
    list (list of Metric's): the metrics.
    """

    metrics = []
    with path.open(encoding="utf-8") as file:
        for line in file:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or line.startswith("id\t"):
                continue
            metrics.append(Metric(*line.split("\t")))
    return metrics


def test_get_metrics():
    metrics = get_metrics()
    ids = [metric.id for metric in metrics]
    assert len(ids) == len(set(ids))
    assert all(metric.languages in ("all", "translations") for metric in metrics)
    assert all(
        metric.link in ("reference", "edit", "new", "lint", "none")
        for metric in metrics
    )


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


def github_request(path: str, params: dict = None) -> tuple[int, object]:
    """
    Perform a GET request against the GitHub REST API, waiting when rate limited.

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
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {_token}",
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


def get_tldr_root(lookup_path: Path = None) -> Path:
    """
    Get the path of the local tldr-maintenance repository, looking for it in each part of the given path. If it is not found, the path in the environment variable TLDR_ROOT is returned.

    Parameters:
    lookup_path (Path): the path to search for the tldr root. By default, the path of the script.

    Returns:
    Path: the local tldr-maintenance repository.
    """

    if lookup_path is None:
        absolute_lookup_path = Path(__file__).resolve()
    else:
        absolute_lookup_path = Path(lookup_path).resolve()
    if (
        tldr_root := next(
            (
                path
                for path in absolute_lookup_path.parents
                if path.name == "tldr-maintenance"
            ),
            None,
        )
    ) is not None:
        return tldr_root
    elif "TLDR_ROOT" in os.environ:
        return Path(os.environ["TLDR_ROOT"])
    raise SystemExit(
        f"{Colors.RED}Please set the environment variable TLDR_ROOT to the location of a clone of https://github.com/tldr-pages/tldr-maintenance{Colors.RESET}"
    )


def get_check_pages_dir(root: Path) -> list[Path]:
    """
    Get all check-pages directories.

    Parameters:
    root (Path): the path to search for the pages directories.

    Returns:
    list (list of Path's): Path's of page entry and platform, e.g. "page.fr/common".
    """

    return sorted([d for d in root.iterdir() if d.name.startswith("check-pages")])


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


def create_github_issue(title: str) -> dict:
    command = [
        "gh",
        "api",
        "--method",
        "POST",
        "-H",
        "Accept: application/vnd.github+json",
        "-H",
        "X-GitHub-Api-Version: 2022-11-28",
        "/repos/tldr-pages/tldr-maintenance/issues",
        "-f",
        f"title={title}",
    ]

    result = subprocess.run(command, capture_output=True, text=True)
    data = json.loads(result.stdout)

    return {
        "number": data["number"],
        "title": data["title"],
        "body": data.get("body") or "",
        "url": data["html_url"],
    }


def get_github_issue(title: str = None) -> list[dict]:
    command = [
        "gh",
        "api",
        "-H",
        "Accept: application/vnd.github+json",
        "-H",
        "X-GitHub-Api-Version: 2022-11-28",
        "/repos/tldr-pages/tldr-maintenance/issues?per_page=100",
    ]

    result = subprocess.run(command, capture_output=True, text=True)
    data = json.loads(result.stdout)

    simplified_data = [
        {
            "number": issue["number"],
            "title": issue["title"],
            "body": issue["body"],
            "url": issue["html_url"],
        }
        for issue in data
    ]

    if title:
        return next(
            (
                {
                    "number": issue["number"],
                    "title": issue["title"],
                    "body": issue["body"],
                    "url": issue["html_url"],
                }
                for issue in data
                if issue["title"] == title
            ),
            None,
        )
    else:
        return simplified_data


def update_github_issue(issue_number, title, body):
    payload = {
        "title": title,
        "body": body,
    }

    command = [
        "gh",
        "api",
        "--method",
        "PATCH",
        "-H",
        "Accept: application/vnd.github+json",
        "-H",
        "X-GitHub-Api-Version: 2022-11-28",
        f"/repos/tldr-pages/tldr-maintenance/issues/{issue_number}",
        "--input",
        "-",
    ]

    result = subprocess.run(
        command, input=json.dumps(payload), capture_output=True, text=True
    )

    if result.returncode != 0:
        print(
            create_colored_line(
                Colors.RED,
                f"Updating {title} (#{issue_number}) failed: {result.stderr}",
            )
        )
    else:
        print(
            create_colored_line(
                Colors.GREEN, f"Updating {title} (#{issue_number}) succeeded"
            )
        )

    return result


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

    return re.sub(r"pages(?:\.[^/\s]+)?/[^:]*\.md(?=:|$)", replace_reference, item)


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
