#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

"""
A Python file that makes some commonly used functions available for other scripts to use.
"""

from enum import Enum
from pathlib import Path
from datetime import datetime, timezone
import os
import re
import json
import subprocess
import urllib.parse


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


def create_github_issue(title: str) -> list[dict]:
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

    return [
        {"number": issue["number"], "title": issue["title"], "url": issue["html_url"]}
        for issue in data
    ]


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
        "-f",
        f"title={title}",
        "-f",
        f"body={body}",
    ]

    result = subprocess.run(command, capture_output=True, text=True)

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

    return re.sub(r"pages\..*\.md", replace_reference, item)


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
