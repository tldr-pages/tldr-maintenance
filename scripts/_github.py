#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

"""
A minimal GitHub REST API client for the check-*.py report scripts.

It is kept apart from _common.py, which the Calculate Metrics workflow depends on,
so changes here don't trigger that workflow.
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

GITHUB_API_URL = "https://api.github.com"
GITHUB_API_VERSION = "2022-11-28"


def get_token() -> str:
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        return token
    try:
        return subprocess.run(
            ["gh", "auth", "token"], capture_output=True, text=True, check=True
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        sys.exit("Please set GITHUB_TOKEN or log in with `gh auth login`.")


_TOKEN = None


def github_request(path: str, params: dict = None) -> tuple[int, object]:
    """
    Perform a GET request against the GitHub REST API, waiting when rate limited.

    Returns:
    tuple: the HTTP status code and the decoded JSON body (None when there is no body).
    """

    global _TOKEN
    if _TOKEN is None:
        _TOKEN = get_token()

    url = f"{GITHUB_API_URL}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {_TOKEN}",
            "X-GitHub-Api-Version": GITHUB_API_VERSION,
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
