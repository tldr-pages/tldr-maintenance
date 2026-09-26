#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

"""
Report contributors of the tldr-pages organization who qualify to become a collaborator.

COMMUNITY-ROLES.md says that once a contributor has had at least 5 non-trivial pull
requests merged on a repository under the tldr-pages organization, they should be
invited to become a collaborator in that repository. This script looks at everyone who
had a pull request merged in the organization recently and reports, per repository,
the authors who reached the threshold and are not a collaborator yet.

An author is skipped when:

- they are a bot,
- GitHub reports them as a collaborator, member or owner of the repository,
- for tldr-pages/tldr only: they are listed in tldr/MAINTAINERS.md (current and past
  maintainers alike), or mentioned in an issue or PR with the `community` label, which
  is where role changes are proposed. This covers pending invitations and contributors
  who declined, which the API does not reveal without admin rights.

Whether the pull requests are non-trivial still needs a human, so the report links the
most recent ones and includes a pre-filled nomination issue for each candidate.

The result is a Markdown report on stdout, suitable for $GITHUB_STEP_SUMMARY.

Usage:
    GITHUB_TOKEN=... python3 scripts/check-collaborator-candidates.py
        [--since-days 90] [--threshold 5] [--maintainers tldr/MAINTAINERS.md]
"""

import argparse
import re
import sys
import urllib.parse
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

from _github import github_request

ORG_NAME = "tldr-pages"
COMMUNITY_REPO = f"{ORG_NAME}/tldr"
COMMUNITY_LABEL = "community"
HAS_WRITE_ACCESS = {"COLLABORATOR", "MEMBER", "OWNER"}
# The Search API returns at most 1000 results for a query.
SEARCH_LIMIT = 1000
RECENT_PRS = 10

MENTION_REGEX = re.compile(r"(?<![\w/`])@([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\b")
MAINTAINER_REGEX = re.compile(r"\[@([A-Za-z0-9-]+)\]")


@dataclass
class Candidate:
    login: str
    repo: str
    merged_recently: int = 0
    merged_total: int = 0
    recent_prs: list[dict] = field(default_factory=list)
    # True/False when the collaborator endpoint answered, None when the token can't tell.
    has_write_access: bool | None = None


def search_issues(query: str, per_page: int = 100, page: int = 1) -> dict:
    status, data = github_request(
        "/search/issues",
        {
            "q": query,
            "sort": "created",
            "order": "desc",
            "per_page": per_page,
            "page": page,
        },
    )
    if status != 200:
        raise SystemExit(f"Search `{query}` failed with {status}: {data}")
    return data


def repo_of(item: dict) -> str:
    # repository_url is https://api.github.com/repos/<owner>/<repo>
    return "/".join(item["repository_url"].split("/")[-2:])


def is_bot(user: dict) -> bool:
    return user.get("type") == "Bot" or user["login"].lower().endswith("[bot]")


def get_recently_merged(since: datetime) -> list[dict]:
    query = f"org:{ORG_NAME} is:pr is:merged merged:>={since.strftime('%Y-%m-%d')}"
    items = []
    page = 1
    while len(items) < SEARCH_LIMIT:
        data = search_issues(query, page=page)
        items += data["items"]
        if len(data["items"]) < 100 or len(items) >= data["total_count"]:
            break
        page += 1
    if len(items) >= SEARCH_LIMIT:
        print(
            f"Warning: more than {SEARCH_LIMIT} merged PRs since {since:%Y-%m-%d}, "
            "use a shorter --since-days to see all of them.",
            file=sys.stderr,
        )
    return items


def group_by_author(items: list[dict]) -> dict[tuple[str, str], Candidate]:
    """
    Group merged PRs per (repository, author), leaving out bots and authors who
    already have write access to that repository.
    """

    candidates = {}
    for item in items:
        user = item["user"]
        if is_bot(user) or item.get("author_association") in HAS_WRITE_ACCESS:
            continue
        key = (repo_of(item), user["login"].lower())
        candidate = candidates.setdefault(key, Candidate(user["login"], key[0]))
        candidate.merged_recently += 1
    return candidates


def get_maintainers(path: Path) -> set[str]:
    if not path.exists():
        print(f"Warning: {path} not found, not skipping maintainers.", file=sys.stderr)
        return set()
    return {
        login.lower()
        for login in MAINTAINER_REGEX.findall(path.read_text(encoding="utf-8"))
    }


def get_community_mentions() -> set[str]:
    """
    Collect everyone mentioned in an issue or PR labeled `community`, open or closed.
    """

    mentions = set()
    page = 1
    while True:
        status, issues = github_request(
            f"/repos/{COMMUNITY_REPO}/issues",
            {
                "labels": COMMUNITY_LABEL,
                "state": "all",
                "per_page": 100,
                "page": page,
            },
        )
        if status != 200:
            raise SystemExit(
                f"Listing `{COMMUNITY_LABEL}` issues failed with {status}: {issues}"
            )
        for issue in issues:
            text = f"{issue['title']}\n{issue.get('body') or ''}"
            mentions.update(login.lower() for login in MENTION_REGEX.findall(text))
        if len(issues) < 100:
            return mentions
        page += 1


def check_write_access(candidate: Candidate):
    status, _ = github_request(
        f"/repos/{candidate.repo}/collaborators/{candidate.login}"
    )
    if status == 204:
        candidate.has_write_access = True
    elif status == 404:
        candidate.has_write_access = False
    # Any other status (e.g. 403 for a token scoped to another repository) means the
    # token can't tell, so leave it unknown.


def count_merged(candidate: Candidate):
    data = search_issues(
        f"repo:{candidate.repo} is:pr is:merged author:{candidate.login}",
        per_page=RECENT_PRS,
    )
    candidate.merged_total = data["total_count"]
    candidate.recent_prs = data["items"]


def merged_prs_url(candidate: Candidate) -> str:
    query = urllib.parse.quote(f"is:pr is:merged author:{candidate.login}")
    return f"https://github.com/{candidate.repo}/pulls?q={query}"


def render_nomination(candidate: Candidate) -> str:
    """
    The issue from the "Adding new collaborators" section of COMMUNITY-ROLES.md.
    """

    return f"""\
**Title:** `MAINTAINERS: add @{candidate.login} as collaborator`

```md
Hi, @{candidate.login}! You seem to be enjoying contributing to the tldr-pages project.
You now have had five distinct pull requests [merged]({merged_prs_url(candidate)})!
That qualifies you to become a collaborator in this repository, as explained in our [community roles documentation](https://github.com/tldr-pages/tldr/blob/main/COMMUNITY-ROLES.md).

As a collaborator, you will have commit access to the repository.
That means you can merge pull requests, label and close issues, and perform various other maintenance tasks that are needed here and there.
Of course, all of this is voluntary — you're welcome to contribute to the project in whatever ways suit your liking.

If you do decide to start performing maintenance tasks, though, we only ask you to get familiar with the [maintainer's guide](https://github.com/tldr-pages/tldr/blob/main/contributing-guides/maintainers-guide.md).

So, what do you say? Can we add you as a collaborator?

Either way, thanks for all your work so far!

> [!NOTE]
> It is required to have a secure [two-factor authentication (2FA)](https://github.com/settings/security) method (Authenticator app/Security Keys/GitHub mobile) enabled for your
> GitHub account to be added as a collaborator to the {candidate.repo} repository.
```"""


def render_report(candidates: list[Candidate], args, now: datetime) -> str:
    since = now - timedelta(days=args.since_days)
    lines = [
        "# Collaborator candidates",
        "",
        f"Generated on {now.strftime('%Y-%m-%d %H:%M UTC')} for `{ORG_NAME}`. "
        f"Contributors with a PR merged since {since.strftime('%Y-%m-%d')} "
        f"and at least {args.threshold} merged PRs in the same repository, "
        f"who are not a collaborator yet and have no `{COMMUNITY_LABEL}` issue "
        f"in `{COMMUNITY_REPO}`.",
        "",
    ]
    if not candidates:
        return "\n".join(lines + ["No new candidates. 🎉"]) + "\n"

    lines += [
        "Check that the PRs are non-trivial, then open the nomination issue in the "
        f"repository with the `{COMMUNITY_LABEL}` label "
        "(see [COMMUNITY-ROLES.md](https://github.com/tldr-pages/tldr/blob/main/COMMUNITY-ROLES.md#adding-new-collaborators)).",
        "",
        "| Contributor | Repository | Merged PRs (recent) | Latest PRs | Write access |",
        "|-|-|-|-|-|",
    ]
    for candidate in candidates:
        latest = " ".join(
            f"[#{pr['number']}]({pr['html_url']} "
            f'"{pr["title"].replace(chr(34), chr(39))}")'
            for pr in candidate.recent_prs[:5]
        )
        write_access = {True: "yes", False: "no", None: "unknown"}[
            candidate.has_write_access
        ]
        lines.append(
            f"| [@{candidate.login}](https://github.com/{candidate.login}) "
            f"| `{candidate.repo}` "
            f"| [{candidate.merged_total}]({merged_prs_url(candidate)}) "
            f"({candidate.merged_recently}) "
            f"| {latest} | {write_access} |"
        )

    lines += ["", "## Nomination issues", ""]
    for candidate in candidates:
        lines += [
            "<details>",
            f"<summary>@{candidate.login} in {candidate.repo}</summary>",
            "",
            render_nomination(candidate),
            "",
            "</details>",
            "",
        ]
    return "\n".join(lines)


def find_candidates(args, now: datetime) -> list[Candidate]:
    since = now - timedelta(days=args.since_days)
    print(f"Searching PRs merged since {since:%Y-%m-%d}...", file=sys.stderr)
    grouped = group_by_author(get_recently_merged(since))

    # Both only tell about tldr-pages/tldr, so they don't hide progress in other repos.
    skip = get_maintainers(args.maintainers) | get_community_mentions()

    candidates = []
    for (repo, login), candidate in sorted(grouped.items()):
        if repo == COMMUNITY_REPO and login in skip:
            continue
        print(f"Checking @{candidate.login} in {candidate.repo}...", file=sys.stderr)
        count_merged(candidate)
        if candidate.merged_total < args.threshold:
            continue
        check_write_access(candidate)
        if candidate.has_write_access:
            continue
        candidates.append(candidate)

    return sorted(candidates, key=lambda c: (-c.merged_total, c.login.lower()))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[1])
    parser.add_argument(
        "--since-days",
        type=int,
        default=90,
        help="only consider contributors with a PR merged in this period (default: 90)",
    )
    parser.add_argument(
        "--threshold",
        type=int,
        default=5,
        help="merged PRs needed to become a collaborator (default: 5)",
    )
    parser.add_argument(
        "--maintainers",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "tldr/MAINTAINERS.md",
        help="path to the MAINTAINERS.md file (default: the tldr submodule's)",
    )
    args = parser.parse_args()

    now = datetime.now(timezone.utc)
    print(render_report(find_candidates(args, now), args, now), end="")


if __name__ == "__main__":
    main()
