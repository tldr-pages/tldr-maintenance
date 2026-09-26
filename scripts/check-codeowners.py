#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

"""
Report CODEOWNERS of tldr-pages/tldr who may no longer be active reviewers.

The CODEOWNERS file automatically requests reviews for translations. When an owner is
no longer active, those requests are never answered and PRs wait for the 10-day
fallback of the maintainer's guide. This script collects, for every owner:

- whether the account still exists and has write access (GitHub ignores owners without it),
- when they last submitted a review, authored a PR and commented in the repository,
- how many open PRs are waiting on their review request for longer than the grace period.

Criteria (see contributing-guides/maintainers-guide.md and COMMUNITY-ROLES.md):

- remove: the account is gone, has no write access, or has had no activity in the
  repository for longer than --inactive-days (default: 6 months, the same period used
  for relieving inactive organization members).
- check: the owner has not reviewed anything for longer than --inactive-days but is
  otherwise active, or ignores --stale-threshold or more review requests that are
  older than --stale-days (default: 10 days, the CODEOWNERS fallback in the guide).

The result is a Markdown report on stdout, suitable for $GITHUB_STEP_SUMMARY.

Usage:
    GITHUB_TOKEN=... python3 scripts/check-codeowners.py [--inactive-days 182]
        [--stale-days 10] [--stale-threshold 3] [--codeowners tldr/.github/CODEOWNERS]
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

ORG_NAME = "tldr-pages"
REPO_NAME = "tldr"
REPO = f"{ORG_NAME}/{REPO_NAME}"
API_URL = "https://api.github.com"
API_VERSION = "2022-11-28"


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


TOKEN = None


def github_request(path: str, params: dict = None) -> tuple[int, object]:
    """
    Perform a GET request against the GitHub REST API, waiting when rate limited.

    Returns:
    tuple: the HTTP status code and the decoded JSON body (None when there is no body).
    """

    url = f"{API_URL}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {TOKEN}",
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


def search_issues(query: str, sort: str, per_page: int = 1) -> dict:
    status, data = github_request(
        "/search/issues",
        {
            "q": f"repo:{REPO} {query}",
            "sort": sort,
            "order": "desc",
            "per_page": per_page,
        },
    )
    if status != 200:
        raise SystemExit(f"Search `{query}` failed with {status}: {data}")
    return data


def parse_datetime(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def parse_codeowners(path: Path) -> dict[str, tuple[str, list[str]]]:
    """
    Map each CODEOWNER (lowercase login, teams are skipped) to their name as written in
    the file and the patterns they own. GitHub logins are case-insensitive.
    """

    owners = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        pattern, *names = line.split()
        for name in names:
            if not name.startswith("@") or "/" in name:
                continue
            owners.setdefault(name[1:].lower(), (name[1:], []))[1].append(pattern)
    return owners


@dataclass
class OwnerActivity:
    login: str
    patterns: list[str]
    name: str = ""
    exists: bool = True
    has_write_access: bool | None = None
    last_review: datetime | None = None
    last_pr: datetime | None = None
    last_comment: datetime | None = None
    open_requests: list[dict] = field(default_factory=list)
    stale_requests: list[dict] = field(default_factory=list)
    verdict: str = "ok"
    reasons: list[str] = field(default_factory=list)

    @property
    def last_activity(self) -> datetime | None:
        dates = [d for d in (self.last_review, self.last_pr, self.last_comment) if d]
        return max(dates, default=None)


def get_last_review(login: str) -> datetime | None:
    """
    Get the exact date of the latest review submitted by the user.

    A review updates the PR, so a PR updated before the best review found so far can't
    contain a newer one. This lets us stop after inspecting only a few PRs.
    """

    prs = search_issues(f"is:pr reviewed-by:{login}", "updated", per_page=10)["items"]
    latest = None
    for pr in prs:
        if latest and parse_datetime(pr["updated_at"]) < latest:
            break
        page = 1
        while True:
            status, reviews = github_request(
                f"/repos/{REPO}/pulls/{pr['number']}/reviews",
                {"per_page": 100, "page": page},
            )
            if status != 200 or not reviews:
                break
            for review in reviews:
                user = review.get("user") or {}
                if user.get("login", "").lower() == login and review.get(
                    "submitted_at"
                ):
                    submitted = parse_datetime(review["submitted_at"])
                    latest = max(latest, submitted) if latest else submitted
            if len(reviews) < 100:
                break
            page += 1
    return latest


def get_last_comment(login: str, since: datetime) -> datetime | None:
    """
    Get the exact date of the latest comment on an issue or PR by the user since the given date.

    The search only tells when a thread was last updated, which can be long after the
    user's comment, so the comments of the most recently updated threads are inspected.
    """

    since_param = since.strftime("%Y-%m-%dT%H:%M:%SZ")
    threads = search_issues(
        f"commenter:{login} updated:>={since.strftime('%Y-%m-%d')}", "updated", 20
    )["items"]
    latest = None
    for thread in threads:
        if latest and parse_datetime(thread["updated_at"]) < latest:
            break
        page = 1
        while True:
            status, comments = github_request(
                f"/repos/{REPO}/issues/{thread['number']}/comments",
                {"since": since_param, "per_page": 100, "page": page},
            )
            if status != 200 or not comments:
                break
            for comment in comments:
                user = comment.get("user") or {}
                created = parse_datetime(comment["created_at"])
                if user.get("login", "").lower() == login and created >= since:
                    latest = max(latest, created) if latest else created
            if len(comments) < 100:
                break
            page += 1
    return latest


def collect_activity(
    login: str,
    name: str,
    patterns: list[str],
    stale_before: datetime,
    inactive_before: datetime,
) -> OwnerActivity:
    owner = OwnerActivity(login, patterns, name)

    status, _ = github_request(f"/users/{login}")
    if status == 404:
        owner.exists = False
        return owner

    status, _ = github_request(f"/repos/{REPO}/collaborators/{login}")
    if status == 204:
        owner.has_write_access = True
    elif status == 404:
        owner.has_write_access = False
    # Any other status (e.g. 403) means the token can't tell, so leave it unknown.

    owner.last_review = get_last_review(login)

    prs = search_issues(f"is:pr author:{login}", "created")["items"]
    if prs:
        owner.last_pr = parse_datetime(prs[0]["created_at"])

    owner.last_comment = get_last_comment(login, inactive_before)

    requests = search_issues(
        f"is:pr is:open draft:false review-requested:{login}", "created", 100
    )["items"]
    owner.open_requests = requests
    owner.stale_requests = [
        pr for pr in requests if parse_datetime(pr["created_at"]) < stale_before
    ]

    return owner


def assess(owner: OwnerActivity, inactive_before: datetime, stale_threshold: int):
    if not owner.exists:
        owner.verdict = "remove"
        owner.reasons.append("account no longer exists")
        return
    if owner.has_write_access is False:
        owner.verdict = "remove"
        owner.reasons.append("no write access, so GitHub ignores this CODEOWNER")

    last_activity = owner.last_activity
    if not last_activity or last_activity < inactive_before:
        owner.verdict = "remove"
        owner.reasons.append("no reviews, PRs or comments in the inactivity period")
    elif not owner.last_review or owner.last_review < inactive_before:
        owner.verdict = "check" if owner.verdict == "ok" else owner.verdict
        owner.reasons.append("active, but no reviews in the inactivity period")

    if len(owner.stale_requests) >= stale_threshold:
        owner.verdict = "check" if owner.verdict == "ok" else owner.verdict
        owner.reasons.append(
            f"{len(owner.stale_requests)} review request(s) pending past the grace period"
        )


def format_date(value: datetime | None, missing: str = "never") -> str:
    return value.strftime("%Y-%m-%d") if value else missing


def format_write_access(value: bool | None) -> str:
    return {True: "yes", False: "**no**", None: "unknown"}[value]


def format_patterns(patterns: list[str], limit: int = 3) -> str:
    shown = ", ".join(f"`{p}`" for p in patterns[:limit])
    return shown + (f" +{len(patterns) - limit} more" if len(patterns) > limit else "")


def render_report(owners: list[OwnerActivity], args, now: datetime) -> str:
    inactive_before = now - timedelta(days=args.inactive_days)
    icons = {"remove": "🔴", "check": "🟡", "ok": "🟢"}
    order = {"remove": 0, "check": 1, "ok": 2}
    shown = sorted(
        (o for o in owners if o.verdict != "ok" or not args.only_flagged),
        key=lambda o: (order[o.verdict], o.login),
    )

    lines = [
        "# CODEOWNERS activity report",
        "",
        f"Generated on {now.strftime('%Y-%m-%d %H:%M UTC')} for `{REPO}`. "
        f"Inactivity period: {args.inactive_days} days "
        f"(since {inactive_before.strftime('%Y-%m-%d')}). "
        f"Review requests count as stale after {args.stale_days} days.",
        "",
        "- 🔴 **remove**: account gone, no write access, or no activity at all in the period.",
        "- 🟡 **check**: no reviews in the period, or "
        f"{args.stale_threshold}+ stale review requests. Consider pinging them first.",
        "- 🟢 **ok**",
        "",
        "| | Owner | Last review | Last PR | Last comment | Open / stale requests "
        "| Write access | Owns | Reasons |",
        "|-|-|-|-|-|-|-|-|-|",
    ]
    for owner in shown:
        stale_links = " ".join(
            f"[#{pr['number']}]({pr['html_url']})" for pr in owner.stale_requests[:5]
        )
        lines.append(
            "| "
            + " | ".join(
                [
                    icons[owner.verdict],
                    f"[@{owner.name}](https://github.com/{REPO}/pulls?"
                    f"q=is%3Apr+reviewed-by%3A{owner.login})",
                    format_date(owner.last_review),
                    format_date(owner.last_pr),
                    format_date(
                        owner.last_comment,
                        f"before {inactive_before.strftime('%Y-%m-%d')}",
                    ),
                    f"{len(owner.open_requests)} / {len(owner.stale_requests)}"
                    + (f" {stale_links}" if stale_links else ""),
                    format_write_access(owner.has_write_access),
                    format_patterns(owner.patterns),
                    "; ".join(owner.reasons) or "-",
                ]
            )
            + " |"
        )

    # Patterns whose owners are all flagged will not get a working review request at all.
    flagged = {o.login for o in owners if o.verdict == "remove"}
    orphaned = sorted(
        {
            p
            for o in owners
            for p in o.patterns
            if all(x.login in flagged for x in owners if p in x.patterns)
        }
    )
    if orphaned:
        lines += [
            "",
            "## Paths without an active CODEOWNER after removal",
            "",
            "Removing the owners above leaves these paths without automatic reviewers. "
            "Consider asking for new reviewers for these languages.",
            "",
        ]
        lines += [f"- `{p}`" for p in orphaned]

    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[1])
    parser.add_argument(
        "--codeowners",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "tldr/.github/CODEOWNERS",
        help="path to the CODEOWNERS file (default: the tldr submodule's)",
    )
    parser.add_argument("--inactive-days", type=int, default=182)
    parser.add_argument("--stale-days", type=int, default=10)
    parser.add_argument("--stale-threshold", type=int, default=3)
    parser.add_argument(
        "--only-flagged", action="store_true", help="omit owners without findings"
    )
    args = parser.parse_args()

    global TOKEN
    TOKEN = get_token()

    now = datetime.now(timezone.utc)
    inactive_before = now - timedelta(days=args.inactive_days)
    stale_before = now - timedelta(days=args.stale_days)

    owners = []
    for login, (name, patterns) in parse_codeowners(args.codeowners).items():
        print(f"Checking @{name}...", file=sys.stderr)
        owner = collect_activity(login, name, patterns, stale_before, inactive_before)
        assess(owner, inactive_before, args.stale_threshold)
        owners.append(owner)

    print(render_report(owners, args, now), end="")


if __name__ == "__main__":
    main()
