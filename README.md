# tldr-maintenance

[![Calculate Metrics](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/calculate-metrics.yml/badge.svg)](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/calculate-metrics.yml)
[![Check links with Lychee](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/check-links.yml/badge.svg)](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/check-links.yml)

This repo runs a Bash script that calculates metrics about the current state of the [tldr-repo](https://github.com/tldr-pages/tldr).
These [metrics](https://github.com/tldr-pages/tldr-maintenance/issues/25) will help contributors to quickly spot whether there is still work to do to maintain and improve the quality. It also helps to detect any issues in the [tldr-repo](https://github.com/tldr-pages/tldr).

> [!NOTE]
> Running [`set-alias-page.py`](https://github.com/tldr-pages/tldr/blob/main/scripts/set-alias-page.py) and [`wrong-filename.py`](https://github.com/tldr-pages/tldr/blob/main/scripts/wrong-filename.py) generates false-positives.
The results need to be checked by hand. It can be used by [CODEOWNERS](https://github.com/tldr-pages/tldr/blob/main/.github/CODEOWNERS) to watch their owned language to detect if there are changes needed.

## Metrics

The metrics are defined in [`metrics.tsv`](scripts/metrics.tsv), which is used by all scripts.
Every metric is calculated per language, the results are written to `check-pages/<metric>.txt` (English) and `check-pages.<language>/<metric>.txt`.
Some metrics don't apply to English, since they compare a translated page with the English page.

- **Inconsistent filename(s)** (`inconsistent-filenames`)
  A filename is inconsistent when it doesn't match the title (`# ...`) of the page, checked by [`wrong-filename.py`](https://github.com/tldr-pages/tldr/blob/main/scripts/wrong-filename.py).
- **Malformed or outdated more info link page(s)** (`malformed-or-outdated-more-info-links`, not for English)
  A page is malformed when the `> More information: <link>.` does not match the format in the [TLDR template](https://github.com/tldr-pages/tldr/blob/main/contributing-guides/translation-templates/more-info-link.md).
  A page is outdated when the `> More information: <link>.` does not match the link in the English page.
- **Malformed or outdated see also mention(s)** (`malformed-or-outdated-see-also-mentions`, not for English)
  Only applies to pages whose English page has a `> See also: ...` mention as second to last line of the description.
  A mention is malformed when the translated mention does not match the format in the [TLDR template](https://github.com/tldr-pages/tldr/blob/main/contributing-guides/translation-templates/see-also-mentions.md).
  A mention is outdated when the mentioned pages do not match the pages mentioned in the English page.
- **Missing see also mention(s)** (`missing-see-also-mentions`, not for English)
  Only applies to pages whose English page has a `> See also: ...` mention as second to last line of the description.
  A mention is missing when the second to last line of the description of the translated page isn't a mention (a line like `` > ...: `...` ``).
  So a mention in the wrong place is reported as missing as well.
- **Missing alias page(s)** (`missing-alias-pages`, not for English)
  A translated alias page is missing when the English page is an alias page, but the translated page doesn't exist.
  This metric generates false-positives, so the results need to be checked by hand.
- **Outdated alias page(s)** (`outdated-alias-pages`, not for English)
  A translated alias page is outdated when the English page is an alias page, but the translated alias page doesn't match the
  [TLDR template](https://github.com/tldr-pages/tldr/blob/main/contributing-guides/translation-templates/alias-pages.md) or refers to another command.
  This metric generates false-positives, so the results need to be checked by hand.
- **Mismatched page title(s)** (`mismatched-page-titles`, not for English)
  A page title is mismatched when the title (`# ...`) doesn't match the title of the English page.
- **Missing TLDR page(s)** (`missing-tldr-pages`)
  A page is missing when there is a page that references another page (like `tldr example`), but the other page doesn't exist (yet) in that language.
  Can also be seen implicit at [tldr translation](https://lukwebsforge.github.io/tldri18n/).
- **Missing see also page(s)** (`missing-see-also-pages`)
  A page is missing when there is a page that mentions another page in its first (translated) `> See also: ...` line, but the other page doesn't exist (yet) in that language.
- **Misplaced page(s)** (`misplaced-pages`)
  A page is misplaced when the page isn’t inside a folder in the list of supported platforms.
  Can also be seen implicit at [tldr translation](https://lukwebsforge.github.io/tldri18n/).
- **Outdated page(s) based on number of commands** (`outdated-pages-based-on-command-count`, not for English)
  A page is outdated when the number of commands differ from the number of commands in the English page.
  Can also be seen at [tldr translation](https://lukwebsforge.github.io/tldri18n/).
- **Outdated page(s) based on the commands itself** (`outdated-pages-based-on-command-contents`, not for English)
  A page is outdated when the commands itself (every line that starts with \`, but removing everything between `{{...}}`, `<...>`, `(...)`, `"..."` and `'...'`) differs from the English commands itself.
- **Outdated page(s) based on number of header lines** (`outdated-pages-based-on-header-line-count`, not for English)
  A page is outdated when the number of header lines (every line that starts with `>`) differs from the number of header lines in the English page.
- **Missing English page(s)** (`missing-english-pages`, not for English)
  A page is missing when the filename can't be found as English page.
  Can also be seen implicit at [tldr translation](https://lukwebsforge.github.io/tldri18n/).
- **Missing translated page(s)** (`missing-translated-pages`, not for English)
  A page is missing when the English page can't be found as translated page.
  Can also be seen implicit at [tldr translation](https://lukwebsforge.github.io/tldri18n/).
- **Linter error(s)** (`lint-errors`)
  The errors of `markdownlint` and `tldr-lint`. For translations, some checks of `tldr-lint` are ignored
  (`TLDR104` about the English tense, and capital letters and punctuation for some languages), see `lint` in [`check-pages.sh`](scripts/check-pages.sh).

## Summary

At the end of the [`metrics-log.md`](https://github.com/tldr-pages/tldr-maintenance/releases/download/latest/metrics-log.md) a summary is written, with the total of every metric
(the results of all languages, written to `<metric>.txt` when there are results).
The summary is also written to `summary.tsv`, with the number of results, the total and the percentage per language and for all languages (`total`).
This summary is tracked in a [GitHub issue](https://github.com/tldr-pages/tldr-maintenance/issues/25), along with the metrics per translation.
Most totals include a percentage (rounded down to one decimal), calculated based on the sum of a total that is counted per language (`check-pages[.<language>]/totals.tsv`) over the languages the metric applies to:

- **Total pages**: inconsistent filenames and misplaced pages.
- **Total non-English pages**: malformed or outdated more info links, mismatched page titles, outdated pages and missing English pages.
- **Total translated pages whose English page has a see also mention**: malformed or outdated see also mentions and missing see also mentions.
  Only languages with a [translation template](https://github.com/tldr-pages/tldr/blob/main/contributing-guides/translation-templates/see-also-mentions.md) are counted.
- **Total references** (every referenced page counted once per page): missing TLDR pages and missing see also pages.
- **Total pages that need a translation** (the number of English pages multiplied by the number of languages): missing translated pages.

## Artifacts

After a [workflow run](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/calculate-metrics.yml) an artifact is created.
This artifact can be downloaded and viewed to see the exact output per language per metric to see which page needs attention.
A summary can also be downloaded at the [latest GitHub Release](https://github.com/tldr-pages/tldr-maintenance/releases/tag/latest).

## Running locally

The scripts require Bash 4.3 or later and the GNU versions of the command-line tools (as on Linux), Python 3.10 or later and Node.js:

```sh
git submodule update --init
npm ci
npm run --silent calculate-metrics > metrics-log.md
```

The tldr repository is expected in `./tldr`, set `TLDR_ROOT` to use another clone.
The script exits with 1 when one of the checks failed to run, the found issues don't change the exit code.
To check a single language, run `scripts/check-pages.sh -l <language>`, optionally with `-c <metric>,<metric>` to only check some metrics (see the script for its options).
It needs the linters on the `PATH`: `PATH="$PWD/node_modules/.bin:$PATH" scripts/check-pages.sh -l fr`.

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
