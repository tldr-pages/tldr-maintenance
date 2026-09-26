#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

"""
Report differences between MAINTAINERS.md and the actual roles on GitHub.

MAINTAINERS.md marks everyone who currently has a role in bold, in the section of their
highest role. This script compares those entries with GitHub:

- repository collaborators: outside collaborators of tldr-pages/tldr,
- organization members: members of the tldr-pages organization,
- organization owners: owners (admins) of the tldr-pages organization.

Criteria (see COMMUNITY-ROLES.md):

- fix: the role on GitHub differs from MAINTAINERS.md, or the person has a role on GitHub
  but isn't listed as current in MAINTAINERS.md.
- fix: two-factor authentication is disabled, which COMMUNITY-ROLES.md requires.
- check: the organization membership isn't public, which COMMUNITY-ROLES.md requires.

Private organization members, outside collaborators and the two-factor authentication
status are only visible to organization owners. With another token, the roles that can't
be seen are reported as unknown.

The result is a Markdown report on stdout, suitable for $GITHUB_STEP_SUMMARY.

Usage:
    GITHUB_TOKEN=... python3 scripts/check-maintainers.py [--maintainers tldr/MAINTAINERS.md]
"""

import argparse
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from _common import ORG_NAME, REPO, github_paginate

COLLABORATOR = "repository collaborator"
MEMBER = "organization member"
OWNER = "organization owner"
NONE = "none"
UNKNOWN = "unknown"

SECTIONS = {
    "## Repository collaborators": COLLABORATOR,
    "## Organization members": MEMBER,
    "## Organization owners": OWNER,
}

ENTRY_REGEX = re.compile(r"^- \*\*.*\(\[@([^\]]+)\]")


def parse_maintainers(path: Path) -> dict[str, tuple[str, str]]:
    """
    Map each current maintainer (lowercase login) to their name as written in the file
    and their role. Only bold entries are current, see the note in MAINTAINERS.md.
    """

    maintainers = {}
    role = None
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("## "):
            role = SECTIONS.get(line.strip())
            continue
        if role and (match := ENTRY_REGEX.match(line)):
            maintainers[match.group(1).lower()] = (match.group(1), role)
    return maintainers


def get_logins(path: str, params: dict = None) -> dict[str, str] | None:
    """
    Map the lowercase logins of a list endpoint to their name on GitHub.
    """

    users = github_paginate(path, params)
    if users is None:
        return None
    return {user["login"].lower(): user["login"] for user in users}


@dataclass
class Maintainer:
    login: str
    name: str
    listed_role: str = NONE
    actual_role: str = UNKNOWN
    public_member: bool | None = None
    two_factor: bool | None = None
    verdict: str = "ok"
    reasons: list[str] = field(default_factory=list)


def with_article(role: str) -> str:
    return ("an " if role[0] in "aeiou" else "a ") + role


def get_actual_role(login: str, owners, members, collaborators, complete) -> str:
    """
    Get the role of the user on GitHub. When the token can't see all roles (complete is
    False), not finding the user doesn't mean they have no role.
    """

    if owners is not None and login in owners:
        return OWNER
    if members is not None and login in members:
        return MEMBER
    if collaborators is not None and login in collaborators:
        return COLLABORATOR
    return NONE if complete else UNKNOWN


def assess(maintainer: Maintainer):
    if maintainer.actual_role == UNKNOWN:
        maintainer.verdict = "unknown"
        return
    if maintainer.listed_role == NONE:
        maintainer.verdict = "fix"
        maintainer.reasons.append(
            f"is {with_article(maintainer.actual_role)} but not listed as current"
        )
    elif maintainer.listed_role != maintainer.actual_role:
        maintainer.verdict = "fix"
        maintainer.reasons.append(
            f"listed as {maintainer.listed_role}, but is "
            + (
                "not in any role"
                if maintainer.actual_role == NONE
                else with_article(maintainer.actual_role)
            )
        )

    if maintainer.two_factor is False and maintainer.actual_role != NONE:
        maintainer.verdict = "fix"
        maintainer.reasons.append("two-factor authentication is disabled")

    if maintainer.actual_role in (MEMBER, OWNER) and not maintainer.public_member:
        maintainer.verdict = "check" if maintainer.verdict == "ok" else "fix"
        maintainer.reasons.append("organization membership isn't public")


def render_report(maintainers: list[Maintainer], args, now: datetime) -> str:
    icons = {"fix": "🔴", "check": "🟡", "ok": "🟢"}
    order = {"fix": 0, "check": 1, "ok": 2}
    unknown = sorted(m.name for m in maintainers if m.verdict == "unknown")
    shown = sorted(
        (
            m
            for m in maintainers
            if m.verdict in ("fix", "check")
            or (m.verdict == "ok" and not args.only_flagged)
        ),
        key=lambda m: (order[m.verdict], m.login),
    )

    lines = [
        "# Maintainers report",
        "",
        f"Generated on {now.strftime('%Y-%m-%d %H:%M UTC')} for `{REPO}`, "
        "comparing the current (bold) entries in MAINTAINERS.md with GitHub.",
        "",
        "- 🔴 **fix**: the role on GitHub differs from MAINTAINERS.md, "
        "or two-factor authentication is disabled.",
        "- 🟡 **check**: the organization membership isn't public.",
        "- 🟢 **ok**",
        "",
    ]
    if unknown:
        lines += [
            f"> [!NOTE]\n> The roles of {len(unknown)} maintainer(s) and two-factor "
            "authentication can't be checked with this token. "
            "Run the script with a token of an organization owner to check them.",
            "",
        ]
    lines += [
        "| | Maintainer | Listed as | Role on GitHub | Public member | 2FA | Reasons |",
        "|-|-|-|-|-|-|-|",
    ]
    for maintainer in shown:
        public = {True: "yes", False: "**no**", None: "-"}[maintainer.public_member]
        if maintainer.actual_role not in (MEMBER, OWNER):
            public = "-"
        lines.append(
            "| "
            + " | ".join(
                [
                    icons[maintainer.verdict],
                    f"[@{maintainer.name}](https://github.com/{maintainer.name})",
                    maintainer.listed_role,
                    maintainer.actual_role,
                    public,
                    {True: "yes", False: "**no**", None: "unknown"}[
                        maintainer.two_factor
                    ],
                    "; ".join(maintainer.reasons) or "-",
                ]
            )
            + " |"
        )

    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.strip().split("\n\n")[0])
    parser.add_argument(
        "--maintainers",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "tldr/MAINTAINERS.md",
        help="path to the MAINTAINERS.md file (default: the tldr submodule's)",
    )
    parser.add_argument(
        "--only-flagged", action="store_true", help="omit maintainers without findings"
    )
    args = parser.parse_args()

    owners = get_logins(f"/orgs/{ORG_NAME}/members", {"role": "admin"})
    members = get_logins(f"/orgs/{ORG_NAME}/members", {"role": "member"})
    collaborators = get_logins(
        f"/repos/{REPO}/collaborators", {"affiliation": "outside"}
    )
    public_members = get_logins(f"/orgs/{ORG_NAME}/public_members") or {}

    # Only organization owners can filter on two-factor authentication. This also tells
    # whether the token can see private members and outside collaborators.
    members_without_2fa = get_logins(
        f"/orgs/{ORG_NAME}/members", {"filter": "2fa_disabled"}
    )
    collaborators_without_2fa = get_logins(
        f"/orgs/{ORG_NAME}/outside_collaborators", {"filter": "2fa_disabled"}
    )
    complete = None not in (
        owners,
        members,
        collaborators,
        members_without_2fa,
        collaborators_without_2fa,
    )

    listed = parse_maintainers(args.maintainers)
    names = {**(collaborators or {}), **(members or {}), **(owners or {})}
    names.update({login: name for login, (name, _) in listed.items()})

    maintainers = []
    for login, name in names.items():
        maintainer = Maintainer(login, name)
        if login in listed:
            maintainer.listed_role = listed[login][1]
        maintainer.actual_role = get_actual_role(
            login, owners, members, collaborators, complete
        )
        maintainer.public_member = login in public_members
        if complete:
            maintainer.two_factor = (
                login not in members_without_2fa
                and login not in collaborators_without_2fa
            )
        assess(maintainer)
        maintainers.append(maintainer)

    print(render_report(maintainers, args, datetime.now(timezone.utc)), end="")


if __name__ == "__main__":
    main()
