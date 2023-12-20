# tldr-maintenance

This repo will some scripts to help detect any issues in the [tldr-repo](https://github.com/tldr-pages/tldr).

- It runs a Bash script that calculates metrics about the current state of the [tldr-repo](https://github.com/tldr-pages/tldr).  
  These [metrics](metrics.log) will help contributors to quickly spot where there is still work to do to maintain and improve the quality.
- Run [`set-more-info-link.py`](https://github.com/tldr-pages/tldr/blob/main/scripts/set-more-info-link.py) to check if all pages are still up-to-date. [![Run set-more-info-link.py](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/run-set-more-info-link.yml/badge.svg)](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/run-set-more-info-link.yml)
- Run [`set-alias-page.py`](https://github.com/tldr-pages/tldr/blob/main/scripts/set-alias-page.py) to check if all alias pages are translated for all languages. [![Run set-alias-page.py](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/run-set-alias-page.yml/badge.svg)](https://github.com/tldr-pages/tldr-maintenance/actions/workflows/run-set-alias-page.yml)

> [!NOTE]
> Running [`set-alias-page.py`](https://github.com/tldr-pages/tldr/blob/main/scripts/set-alias-page.py) generates false-positives and the result needs to be checked by hand. It can be used by [CODEOWNERS](https://github.com/tldr-pages/tldr/blob/main/.github/CODEOWNERS) to watch their owned language to detect if there are changes needed.
