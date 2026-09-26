# tldr-maintenance

[![Calculate Metrics](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/calculate-metrics.yml/badge.svg)](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/calculate-metrics.yml)
[![Check links with Lychee](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/check-links.yml/badge.svg)](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/check-links.yml)

This repo runs a Bash script that calculates metrics about the current state of the [tldr-repo](https://github.com/tldr-pages/tldr).
These [metrics](https://github.com/tldr-pages/tldr-maintenance/issues/25) will help contributors to quickly spot whether there is still work to do to maintain and improve the quality. It also helps to detect any issues in the [tldr-repo](https://github.com/tldr-pages/tldr).

> [!NOTE]
> Running [`set-alias-page.py`](https://github.com/tldr-pages/tldr/blob/main/scripts/set-alias-page.py) and [`wrong-filename.py`](https://github.com/tldr-pages/tldr/blob/main/scripts/wrong-filename.py) generates false-positives.
The results need to be checked by hand. It can be used by [CODEOWNERS](https://github.com/tldr-pages/tldr/blob/main/.github/CODEOWNERS) to watch their owned language to detect if there are changes needed.

## Metrics

### English

- **Inconsistent filename(s)**
  A filename is inconsistent when it doesn't match the title (`# ...`) of the page.
- **Malformed more-info link page(s)**
  A page is malformed when the `> More information: <link>.` does not match the format in the [TLDR template](https://github.com/tldr-pages/tldr/blob/main/contributing-guides/translation-templates/more-info-link.md).
- **Missing TLDR page(s)**
  A page is missing when there is a page that references another page (like `tldr example`), but the other page doesn't exist.
  Can also be seen implicit at [tldr translation](https://lukwebsforge.github.io/tldri18n/).
- **Missing see also page(s)**
  A page is missing when there is a page that mentions another page in its first `> See also: ...` line, but the other page doesn't exist.
- **Misplaced page(s)**
  A page is misplaced when the page isn’t inside a folder in the list of supported platforms.
  Can also be seen implicit at [tldr translation](https://lukwebsforge.github.io/tldri18n/).
- **Linter error(s)**
  Run the `markdownlint` and `tldr-lint` with specific checks enabled (only applies to the `tldr-lint`).

### Other languages

- **Inconsistent filename(s)**
  A filename is inconsistent when it doesn't match the title (`# ...`) of the page.
- **Malformed or outdated more-info link page(s)**
  A page is malformed when the `> More information: <link>.` does not match the format in the [TLDR template](https://github.com/tldr-pages/tldr/blob/main/contributing-guides/translation-templates/more-info-link.md).
   A page is outdated when the `> More information: <link>.` does not match the link in the English page.
- **Malformed or outdated see also mention(s)**
  Only applies to pages whose English page has a `> See also: ...` mention as second to last line of the description.
  A mention is malformed when the translated mention does not match the format in the [TLDR template](https://github.com/tldr-pages/tldr/blob/main/contributing-guides/translation-templates/see-also-mentions.md).
  A mention is outdated when the mentioned pages do not match the pages mentioned in the English page.
- **Missing see also mention(s)**
  Only applies to pages whose English page has a `> See also: ...` mention as second to last line of the description.
  A mention is missing when the second to last line of the description of the translated page isn't a mention (a line like `` > ...: `...` ``).
  So a mention in the wrong place is reported as missing as well.
- **Missing alias page(s)**
  A translated alias page is missing when the English page is an alias page, but the translated page doesn't exist.
  This metric generates false-positives, so the results need to be checked by hand.
- **Mismatched page title(s)**
  A page title is mismatched when the title (`# ...`) doesn't match the title of the English page.
- **Missing TLDR page(s)**
  A page is missing when there is a page that references another page (like `tldr example`), but the other page doesn't exist.
- **Missing see also page(s)**
  A page is missing when there is a page that mentions another page in its first translated `> See also: ...` line, but the other page doesn't exist (yet) in that language.
- **Misplaced page(s)**
  A page is misplaced when the page isn’t inside a folder in the list of supported platforms.
  Can also be seen implicit at [tldr translation](https://lukwebsforge.github.io/tldri18n/).
- **Outdated page(s) based on number of commands**
  A page is outdated when the number of commands differ from the number of commands in the English page.
  Can also be seen at [tldr translation](https://lukwebsforge.github.io/tldri18n/).
- **Outdated page(s) based on the commands itself**
  A page is outdated when the commands itself (every line that starts with \`, but removing everything between `{{...}}`, `"..."` and `'...'`) differs from the English commands itself.
- **Outdated page(s) based on number of header lines**
  A page is outdated when the number of header lines (every line that starts with `>`) differs from the number of header lines in the English page.
- **Missing English page(s)**
  A page is missing when the filename can't be found as English page.
  Can also be seen implicit at [tldr translation](https://lukwebsforge.github.io/tldri18n/).
- **Missing translated page(s)**
  A page is missing when the English page can't be found as translated page.
  Can also be seen implicit at [tldr translation](https://lukwebsforge.github.io/tldri18n/).
- **Linter error(s)**
  Run the `markdownlint` and `tldr-lint` with specific checks enabled for the specific language (only applies to the `tldr-lint`).

## Summary

At the end of the [`metrics-log.md`](https://github.com/tldr-pages/tldr-maintenance/releases/download/latest/metrics-log.md) a summary is written.
This summary is tracked in a [GitHub issue](https://github.com/tldr-pages/tldr-maintenance/issues/25), along with the metrics per translation. Some numbers include a percentage (rounded down to one decimal):

- Total inconsistent filename(s) [with percentage, calculated based on total pages]
- Total malformed or outdated more info link page(s) [with percentage, calculated based on total pages]
- Total malformed or outdated see also mention(s) [with percentage, calculated based on total translated pages whose English page has a see also mention]
- Total missing see also mention(s) [with percentage, calculated based on total translated pages whose English page has a see also mention]
- Total missing alias page(s)
- Total mismatched page title(s) [with percentage, calculated based on total unique non-English pages]
- Total missing TLDR commands [with percentage, calculated based on total of TLDR commands]
- Total missing see also page(s) [with percentage, calculated based on total of pages mentioned in the first see also mention of every page, including English]
- Total misplaced page(s) [with percentage, calculated based on total pages]
- Total outdated page(s) based on number of commands [with percentage, calculated based on total non-English pages]
- Total outdated page(s) based on the commands itself [with percentage, calculated based on total non-English pages]
- Total outdated page(s) based on number of header lines [with percentage, calculated based on total non-English pages]
- Total missing English page(s) [with percentage, calculated based on total unique non-English pages]
- Total missing translated page(s) [with percentage, calculated based on total of pages that need translation (total of English pages multiplied with number of languages)]
- Total lint error(s)

## Artifacts

After a [workflow run](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/calculate-metrics.yml) an artifact is created.
This artifact can be downloaded and viewed to see the exact output per language per metric to see which page needs attention.
A summary can also be downloaded at the [latest GitHub Release](https://github.com/tldr-pages/tldr-maintenance/releases/tag/latest).

## Maintainer scripts

### CODEOWNERS activity

[`check-codeowners.py`](scripts/check-codeowners.py) reports [CODEOWNERS](https://github.com/tldr-pages/tldr/blob/main/.github/CODEOWNERS) who may no longer be active reviewers,
so PRs don't wait on review requests that won't be answered. It runs once a month (see the [workflow](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/check-codeowners.yml) summary) or locally:

```sh
GITHUB_TOKEN=... npm run --silent check-codeowners > codeowners-report.md
```

Without `GITHUB_TOKEN`, the token of the [GitHub CLI](https://cli.github.com/) (`gh auth login`) is used. Options are passed after `--`, e.g. `npm run check-codeowners -- --inactive-days 90`.

For every owner it looks up the last review, the last authored PR, the last comment and the open review requests in the tldr repository:

- 🔴 **remove**: the account no longer exists, has no write access (GitHub ignores such owners), or has had no activity for over 6 months,
  the same period used for [relieving inactive organization members](https://github.com/tldr-pages/tldr/blob/main/COMMUNITY-ROLES.md#when-to-change-roles).
- 🟡 **check**: no reviews for over 6 months while otherwise active, or 3 or more review requests pending for over 10 days,
  the CODEOWNERS fallback in the [maintainer's guide](https://github.com/tldr-pages/tldr/blob/main/contributing-guides/maintainers-guide.md#ii-handling-prs).

The report also lists the paths that would be left without any active owner. The periods can be changed with `--inactive-days`, `--stale-days` and `--stale-threshold`, and `--only-flagged` hides the owners without findings.
The write access check needs a token with push access to tldr-pages/tldr, otherwise it shows `unknown`.

### Maintainers

[`check-maintainers.py`](scripts/check-maintainers.py) compares the current (bold) entries in [MAINTAINERS.md](https://github.com/tldr-pages/tldr/blob/main/MAINTAINERS.md) with the actual roles on GitHub.
It runs once a month (see the [workflow](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/check-maintainers.yml) summary) or locally:

```sh
GITHUB_TOKEN=... npm run --silent check-maintainers > maintainers-report.md
```

- 🔴 **fix**: the role on GitHub differs from MAINTAINERS.md, someone has a role without being listed, or two-factor authentication is disabled.
- 🟡 **check**: the organization membership isn't public, which the [community roles](https://github.com/tldr-pages/tldr/blob/main/COMMUNITY-ROLES.md) require.

Private members, outside collaborators and the two-factor authentication status are only visible to organization owners.
The workflow uses the `MAINTAINERS_TOKEN` secret when it's set (a token of an organization owner), and otherwise reports those roles as unknown.
