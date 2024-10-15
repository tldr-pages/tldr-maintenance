#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

from pathlib import Path
import re
import json
import subprocess

ORG_NAME = "tldr-pages"
REPO_NAME = "tldr"


def run_gh_command(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error running command: {command}\n{result.stderr}")
        return None
    return result.stdout


def get_repo_collaborators():
    command = [
        "gh",
        "api",
        "-H",
        "X-GitHub-Api-Version: 2022-11-28",
        f"/repos/{ORG_NAME}/{REPO_NAME}/collaborators",
        "--paginate",
        "--slurp",
    ]
    output = run_gh_command(command)

    if output:
        collaborators = json.loads(output)[0]
        return sorted(set(collaborator["login"] for collaborator in collaborators))
    return []


def get_org_members():
    command = [
        "gh",
        "api",
        "-H",
        "X-GitHub-Api-Version: 2022-11-28",
        f"/orgs/{ORG_NAME}/members",
    ]
    output = run_gh_command(command)
    if output:
        org_members = json.loads(output)
        return sorted(set(org_member["login"] for org_member in org_members))
    return []


def is_member_admin(username):
    command = [
        "gh",
        "api",
        "-H",
        "X-GitHub-Api-Version: 2022-11-28",
        f"/orgs/{ORG_NAME}/memberships/{username}",
    ]
    output = run_gh_command(command)

    if output:
        membership_info = json.loads(output)
        return membership_info["role"] == "admin"

    return False


def verify_roles(users):
    collaborators = get_repo_collaborators()
    org_members = get_org_members()

    for role, users in users.items():
        verify_user_role(users, role, collaborators, org_members)


def verify_user_role(users, role, collaborators, org_members):
    if role == "repository collaborators":
        verify_collaborator(users, collaborators)
    elif role == "organization members":
        verify_member(users, org_members)
    elif role == "organization owners":
        verify_owner(users)
    else:
        print(f"Unknown role {role} for {users}.")


def verify_collaborator(users, collaborators):
    for user in users:
        if user not in collaborators:
            print(f"{user} is not a collaborator.")


def verify_member(users, org_members):
    for user in users:
        if user not in org_members:
            print(f"{user} is not an organization member.")


def verify_owner(users):
    for user in users:
        if not is_member_admin(user):
            print(f"{user} is not an organization owner.")


def parse_maintainers_file(file_path):
    maintainers = {
        "repository collaborators": [],
        "organization members": [],
        "organization owners": [],
    }

    with file_path.open(encoding="utf-8") as f:
        file_content = f.read()

    current_role = None

    lines = file_content.split("\n")

    for line in lines:
        if any(
            role in line
            for role in [
                "## Repository collaborators",
                "## Organization members",
                "## Organization owners",
            ]
        ):
            current_role = line.lower().lstrip("## ").strip()
            continue

        if line.startswith("-"):
            parts = line.split(":")

            name_info = parts[0].strip().lstrip("- ").strip()
            name_match = re.search(r"\*\*.*\(\[\@(.*)\].*", name_info)
            if name_match and current_role:
                maintainers[current_role].append(name_match.group(1))

    return maintainers


def main():
    maintainers_file_path = Path("tldr/MAINTAINERS.md")

    users_to_check = parse_maintainers_file(maintainers_file_path)

    verify_roles(users_to_check)


if __name__ == "__main__":
    main()
