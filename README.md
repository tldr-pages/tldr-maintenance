# tldr-maintenance

[![Calculate Metrics](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/calculate-metrics.yml/badge.svg)](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/calculate-metrics.yml)
[![Check links with Lychee](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/check-links.yml/badge.svg)](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/check-links.yml)

This repo runs a Bash script that calculates metrics about the current state of the [tldr-repo](https://github.com/tldr-pages/tldr).  
These [metrics](https://github.com/tldr-pages/tldr-maintenance/issues/25) will help contributors to quickly spot whether there is still work to do to maintain and improve the quality. It also helps to detect any issues in the [tldr-repo](https://github.com/tldr-pages/tldr).

> [!NOTE]
> Running [`set-alias-page.py`](https://github.com/tldr-pages/tldr/blob/main/scripts/set-alias-page.py) and [`wrong-filename.sh`](https://github.com/tldr-pages/tldr/blob/main/scripts/wrong-filename.sh) generates false-positives.
The results need to be checked by hand. It can be used by [CODEOWNERS](https://github.com/tldr-pages/tldr/blob/main/.github/CODEOWNERS) to watch their owned language to detect if there are changes needed.

## Metrics

### English

- **Malformed more-info link page(s)**  
  A page is malformed when the `> More information: <link>.` does not match the format in the Python script.
- **Missing TLDR page(s)**  
  A page is missing when there is a page that references another page (like `tldr example`), but the other page doesn't exist.
  Can also be seen implicit at [tldr translation](https://lukwebsforge.github.io/tldri18n/).
- **Misplaced page(s)**  
  A page is misplaced when the page isn’t inside a folder in the list of supported platforms.
  Can also be seen implicit at [tldr translation](https://lukwebsforge.github.io/tldri18n/).
- **Linter error(s)**  
  Run the `markdownlint` and `tldr-lint` with specific checks enabled (only applies to the `tldr-lint`).

### Other languages

- **Malformed or outdated more-info link page(s)**  
  A page is malformed when the `> More information: <link>.` does not match the format in the Python script.  
   A page is outdated when the `> More information: <link>.` does not match the link in the English page.
- **Missing TLDR page(s)**  
  A page is missing when there is a page that references another page (like `tldr example`), but the other page doesn't exist.
- **Misplaced page(s)**  
  A page is misplaced when the page isn’t inside a folder in the list of supported platforms.
  Can also be seen implicit at [tldr translation](https://lukwebsforge.github.io/tldri18n/).
- **Outdated page(s) based on number of commands**  
  A page is outdated when the number of commands differ from the number of commands in the English page.
  Can also be seen at [tldr translation](https://lukwebsforge.github.io/tldri18n/).
- **Outdated page(s) based on the commands itself**  
  A page is outdated when the commands itself (every line that starts with \`, but removing everything between `{{...}}`, `"..."` and `'...'`) differs from the English commands itself.
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
This summary is tracked in a [GitHub issue](https://github.com/tldr-pages/tldr-maintenance/issues/25), along with the metrics per translation. Some numbers include a percentage:

- Total malformed or outdated more info link page(s) [with percentage, calculated based on total pages]
- Total missing alias page(s)
- Total missing TLDR commands [with percentage, calculated based on total of TLDR commands]
- Total misplaced page(s) [with percentage, calculated based on total pages]
- Total outdated page(s) based on number of commands [with percentage, calculated based on total non-English pages]
- Total outdated page(s) based on the commands itself [with percentage, calculated based on total non-English pages]
- Total missing English page(s) [with percentage, calculated based on total unique non-English pages]
- Total missing translated page(s) [with percentage, calculated based on total of pages that need translation (total of English pages multiplied with number of languages)]
- Total lint error(s)

## Artifacts

After a [workflow run](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/calculate-metrics.yml) an artifact is created.  
This artifact can be downloaded and viewed to see the exact output per language per metric to see which page needs attention.
A summary can also be downloaded at the [latest GitHub Release](https://github.com/tldr-pages/tldr-maintenance/releases/tag/latest).
