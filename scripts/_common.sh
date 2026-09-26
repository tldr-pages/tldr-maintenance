#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

# Shared functions for `calculate-metrics.sh` and `check-pages.sh`, so both use the same rules.

SEE_ALSO_TEMPLATE="${TLDR_ROOT:-./tldr}/contributing-guides/translation-templates/see-also-mentions.md"

# Print the "See also" prefix of a language (e.g. "> Voir aussi : ") from the translation template.
# Prints nothing when the language has no template.
get_see_also_prefix() {
  local language_id="$1"

  awk -v heading="### $language_id" '
    $0 == heading { found = 1; next }
    found && /^---$/ { exit }
    found && /^>/ { sub(/`.*/, ""); print; exit }
  ' "$SEE_ALSO_TEMPLATE"
}

# Print "<index>\t<command>" for every command mentioned in the first line starting with the "See also" prefix of
# every given page, where <index> is the position of the page in the arguments (starting at 1).
# Spaces in the command are replaced by dashes (e.g. "git commit" becomes "git-commit") and empty mentions are skipped.
# Usage: list_see_also_references prefix page...
list_see_also_references() {
  local prefix="$1"
  shift

  # The prefix is passed through the environment, since `awk -v` would interpret backslashes.
  # shellcheck disable=SC2016
  SEE_ALSO_PREFIX="$prefix" awk '
    BEGIN {
      prefix = ENVIRON["SEE_ALSO_PREFIX"]
      for (i = 1; i < ARGC; i++) index_of[ARGV[i]] = i
    }
    index($0, prefix) == 1 && !(FILENAME in seen) {
      seen[FILENAME]
      line = $0
      while (match(line, /`[^`]*`/)) {
        command = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        gsub(/ /, "-", command)
        if (command != "") print index_of[FILENAME] "\t" command
      }
    }
  ' "$@"
}

# Print every given page that has a "See also" mention as recognized by `set-see-also.py`:
# the second to last line of the description starts with "> See also:" and mentions at least one command.
list_pages_with_see_also_mention() {
  # shellcheck disable=SC2016
  awk '
    FNR == 1 { state = 0; before = ""; last = "" }
    state == 2 { next }
    /^>/ { state = 1; before = last; last = $0; next }
    state == 1 {
      state = 2
      if (before ~ /^> See also:/ && before ~ /`[^`]+`/) print FILENAME
      next
    }
    { last = $0 }
  ' "$@"
}
