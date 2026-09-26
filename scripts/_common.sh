#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

# Shared variables and functions for `calculate-metrics.sh` and `check-pages.sh`, so both use the same rules.
# These scripts require Bash 4.3 or later and the GNU versions of the command-line tools (as on Linux).

# Sort the same way in every locale, without changing how characters are handled (e.g. lowercasing).
if [ -n "$LC_ALL" ]; then
  export LANG="$LC_ALL"
  unset LC_ALL
fi
export LC_COLLATE=C

# The local clone of the tldr repository.
TLDR_ROOT_DIR="${TLDR_ROOT:-./tldr}"
TLDR_ROOT_DIR="${TLDR_ROOT_DIR%/}"

SEE_ALSO_TEMPLATE="$TLDR_ROOT_DIR/contributing-guides/translation-templates/see-also-mentions.md"
METRICS_FILE="$(dirname "${BASH_SOURCE[0]}")/metrics.tsv"

# The totals check-pages.sh counts per language, used as denominator in metrics.tsv.
TOTAL_NAMES=("pages" "english-pages" "pages-need-see-also-mention" "tldr-references" "see-also-references")

# Print the metrics of metrics.tsv (one line per metric, with the columns separated by a tab), in their order.
# Fails when a line doesn't have 6 non-empty columns (`read` can't split empty columns) or has an invalid value.
# Usage: IFS=$'\t' read -r id languages source denominator link label <<< "$metric"
list_metrics() {
  awk -F '\t' -v total_names="${TOTAL_NAMES[*]}" '
    BEGIN {
      split(total_names, names, " ")
      for (i in names) valid_denominator[names[i]]
      valid_denominator["-"]
      valid_languages["all"]; valid_languages["translations"]
      valid_link["reference"]; valid_link["edit"]; valid_link["new"]; valid_link["lint"]
    }
    function fail(message) {
      print FILENAME ":" FNR ": " message > "/dev/stderr"
      failed = 1
      exit 1
    }
    { sub(/\r$/, "") }
    /^#/ || /^$/ || $1 == "id" { next }
    {
      if (NF != 6) fail("expected 6 columns separated by a tab")
      for (i = 1; i <= 6; i++) if ($i == "") fail("column " i " is empty")
      if ($1 in ids) fail("duplicate id " $1)
      if (!($2 in valid_languages)) fail("invalid languages " $2)
      if (!($4 in valid_denominator)) fail("invalid denominator " $4)
      if (!($5 in valid_link)) fail("invalid link " $5)
      ids[$1]
      count++
      print
    }
    END {
      if (!failed && count == 0) {
        print FILENAME ": no metrics" > "/dev/stderr"
        exit 1
      }
      exit failed
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

# The functions below read the paths of the pages from stdin (one per line), since there can be too many pages to
# pass as arguments. Their output refers to a page by its <index>: its line number in the input (starting at 1).
# They fail when a page can't be read.

# Print "<index>\t<command>" for every page referenced with `tldr <command>` at the end of a line of the given pages.
# Options like "-p linux" are removed and spaces are replaced by dashes (e.g. "git-commit").
# References to options (e.g. `tldr --update`) and placeholders (e.g. `tldr {{command}}`) are skipped.
list_tldr_references() {
  local references index command

  # shellcheck disable=SC2016
  references=$(awk '
    {
      page = $0
      while ((status = (getline line < page)) > 0) {
        if (match(line, /`tldr .*`$/)) print NR "\t" substr(line, RSTART + 6, RLENGTH - 7)
      }
      if (status < 0) { print "Cannot read " page > "/dev/stderr"; exit 1 }
      close(page)
    }
  ') || return 1

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
# every given page. Spaces are replaced by dashes (e.g. "git-commit") and empty mentions are skipped.
# Usage: list_see_also_references prefix < pages
list_see_also_references() {
  local prefix="$1"

  if [ -z "$prefix" ]; then
    cat > /dev/null
    return 0
  fi

  # The prefix is passed through the environment, since `awk -v` would interpret backslashes.
  # shellcheck disable=SC2016
  SEE_ALSO_PREFIX="$prefix" awk '
    BEGIN { prefix = ENVIRON["SEE_ALSO_PREFIX"] }
    {
      page = $0
      while ((status = (getline line < page)) > 0) {
        if (index(line, prefix) != 1) continue
        while (match(line, /`[^`]*`/)) {
          command = substr(line, RSTART + 1, RLENGTH - 2)
          line = substr(line, RSTART + RLENGTH)
          gsub(/ /, "-", command)
          if (command != "") print NR "\t" command
        }
        break
      }
      if (status < 0) { print "Cannot read " page > "/dev/stderr"; exit 1 }
      close(page)
    }
  '
}

# Print every given page that has a "See also" mention as recognized by `set-see-also.py`:
# the second to last line of the description starts with "> See also:" and mentions at least one command.
list_pages_with_see_also_mention() {
  # shellcheck disable=SC2016
  awk '
    {
      page = $0
      in_description = 0; before = ""; last = ""
      while ((status = (getline line < page)) > 0) {
        if (line ~ /^>/) { in_description = 1; before = last; last = line; continue }
        if (in_description) {
          if (before ~ /^> See also:/ && before ~ /`[^`]+`/) print page
          break
        }
        last = line
      }
      if (status < 0) { print "Cannot read " page > "/dev/stderr"; exit 1 }
      close(page)
    }
  '
}
