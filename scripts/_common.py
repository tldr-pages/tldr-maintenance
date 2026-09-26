#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

"""
A Python file that makes some commonly used functions available for other scripts to use.
"""

from enum import Enum
import os
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
MAINTENANCE_REPO = f"{ORG_NAME}/tldr-maintenance"
API_URL = "https://api.github.com"
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


def decode_json(body: bytes) -> object:
    """Decode a JSON response body, or return the text when it isn't JSON (e.g. an HTML error page)."""

    if not body:
        return None
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return body.decode(errors="replace")


def github_request(
    path: str,
    params: dict | None = None,
    method: str = "GET",
    payload: dict | None = None,
) -> tuple[int, object]:
    """
    Perform a request against the GitHub REST API, waiting when rate limited and retrying server and network errors.

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
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {_token}",
        "X-GitHub-Api-Version": API_VERSION,
    }
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode()
    request = urllib.request.Request(url, data=data, headers=headers, method=method)

    for attempt in range(1, 6):
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, decode_json(response.read())
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
            # Creating something (POST) isn't retried, since it might have been created.
            if error.code >= 500 and method != "POST" and attempt < 5:
                print(
                    f"{method} {url} failed ({error.code}), retrying...",
                    file=sys.stderr,
                )
                time.sleep(2**attempt)
                continue
            return error.code, decode_json(error.read())
        except urllib.error.URLError as error:
            if method == "POST" or attempt == 5:
                raise SystemExit(f"{method} {url} failed: {error.reason}")
            print(
                f"{method} {url} failed ({error.reason}), retrying...", file=sys.stderr
            )
            time.sleep(2**attempt)
    raise SystemExit(f"Giving up on {url} after repeated rate limiting.")


def github_paginate(path: str, params: dict | None = None) -> list | None:
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
