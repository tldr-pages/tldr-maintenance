#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

# Shared variables and functions for `calculate-metrics.sh` and `check-pages.sh`, so both use the same rules.
# These scripts require the GNU versions of the command-line tools (as on Linux).

# The local clone of the tldr repository.
TLDR_ROOT_DIR="${TLDR_ROOT:-./tldr}"
TLDR_ROOT_DIR="${TLDR_ROOT_DIR%/}"

SEE_ALSO_TEMPLATE="$TLDR_ROOT_DIR/contributing-guides/translation-templates/see-also-mentions.md"
METRICS_FILE="$(dirname "${BASH_SOURCE[0]}")/metrics.tsv"

# Print the metrics of metrics.tsv (one line per metric, with the columns separated by a tab), in their order.
# Fails when a line doesn't have 6 non-empty columns, since `read` can't split empty columns.
# Usage: IFS=$'\t' read -r id languages source denominator link label <<< "$metric"
list_metrics() {
  awk -F '\t' '
    { sub(/\r$/, "") }
    /^#/ || /^$/ || $1 == "id" { next }
    {
      for (i = 1; i <= 6; i++) if ($i == "") empty = 1
      if (NF != 6 || empty) {
        print FILENAME ":" FNR ": expected 6 non-empty columns separated by a tab" > "/dev/stderr"
        exit 1
      }
      print
    }
  ' "$METRICS_FILE"
}

# Print the pages (Markdown files) in a folder, sorted.
list_pages() {
  local folder="$1"

  find "$folder" -type f -name "*.md" | sort -u
}

# Print the "See also" prefix of a language (e.g. "> Voir aussi : ") from the translation template.
# Prints nothing when the language has no template.
get_see_also_prefix() {
  local language_id="$1"

  awk -v heading="### $language_id" '
    { line = $0; sub(/[ \t\r]+$/, "", line) }
    line == heading { found = 1; next }
    found && line == "---" { exit }
    found && /^>/ { sub(/`.*/, ""); print; exit }
  ' "$SEE_ALSO_TEMPLATE"
}

# Print "<index>\t<command>" for every page referenced with `tldr <command>` at the end of a line of the given pages,
# where <index> is the position of the page in the arguments (starting at 1).
# Options like "-p linux" are removed and spaces are replaced by dashes (e.g. "git-commit").
# References to options (e.g. `tldr --update`) and placeholders (e.g. `tldr {{command}}`) are skipped.
# Usage: list_tldr_references page...
list_tldr_references() {
  local references index command

  if [ "$#" -eq 0 ]; then
    return 0
  fi

  # shellcheck disable=SC2016
  references=$(awk '
    BEGIN { for (i = 1; i < ARGC; i++) index_of[ARGV[i]] = i }
    match($0, /`tldr .*`$/) { print index_of[FILENAME] "\t" substr($0, RSTART + 6, RLENGTH - 7) }
  ' "$@") || return 1

  while IFS=$'\t' read -r index command; do
    if [ -z "$index" ]; then
      continue
    fi

    # Remove "-p linux" from "wget -p linux".
    if [[ $command =~ (.*)\ -[^\ ]\ [^\ ]+ ]]; then
      command="${BASH_REMATCH[1]}${command:${#BASH_REMATCH[0]}}"
    fi
    # Remove "-p linux" from "-p linux awk".
    if [[ $command =~ -[^\ ]\ [^\ ]+\ (.*) ]]; then
      command="${command:0:${#command}-${#BASH_REMATCH[0]}}${BASH_REMATCH[1]}"
    fi
    command="${command// /-}"

    if [[ $command =~ ^-[^[:space:]] ]] || [[ $command =~ \{\{.*\}\} ]]; then
      continue
    fi

    printf '%s\t%s\n' "$index" "$command"
  done <<< "$references"
}

# Print "<index>\t<command>" for every command mentioned in the first line starting with the "See also" prefix of
# every given page, where <index> is the position of the page in the arguments (starting at 1).
# Spaces are replaced by dashes (e.g. "git-commit") and empty mentions are skipped.
# Usage: list_see_also_references prefix page...
list_see_also_references() {
  local prefix="$1"
  shift

  if [ -z "$prefix" ] || [ "$#" -eq 0 ]; then
    return 0
  fi

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
  if [ "$#" -eq 0 ]; then
    return 0
  fi

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
