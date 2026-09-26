#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# shellcheck disable=SC2329 # The checks are invoked through CHECK_OF.

# Check the pages of one language for the metrics in metrics.tsv with "check-pages" as source (see the README for
# a description of every metric). The results are written to check-pages[.<language>]/<metric>.txt and the totals
# the percentages are calculated on to check-pages[.<language>]/totals.tsv.
#
# Usage: ./check-pages.sh [-l language_id] [-c metric_ids] [-v]
#   - language_id (optional): the language to check (e.g. "fr" or "pt_BR"). Without it, the English pages are checked.
#   - metric_ids (optional): a comma-separated list of the metrics to check (e.g. "missing-tldr-pages,lint-errors"),
#     by default all of them. Metrics that don't apply to the language are skipped.
#   - -v enables verbose logging to check-pages[.<language>]/debug.log.
#
# Exits with 1 when a check failed to run.

set -o pipefail

# shellcheck source=scripts/_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

PLATFORMS=("android" "common" "linux" "openbsd" "freebsd" "netbsd" "osx" "sunos" "windows" "cisco-ios" "dos")

# The function that checks a metric. A function can check several metrics at once.
declare -A CHECK_OF=(
  [missing-tldr-pages]=check_missing_tldr_pages
  [missing-see-also-pages]=check_missing_see_also_pages
  [misplaced-pages]=check_misplaced_pages
  [outdated-pages-based-on-command-count]=check_outdated_pages
  [outdated-pages-based-on-command-contents]=check_outdated_pages
  [outdated-pages-based-on-header-line-count]=check_outdated_pages
  [missing-english-pages]=check_missing_english_pages
  [missing-translated-pages]=check_missing_translated_pages
  [lint-errors]=lint
)

usage() {
  echo "Usage: $0 [-l language_id] [-c metric_ids] [-v]" >&2
  exit 1
}

LANGUAGE_ID=""
SELECTED_METRICS=""
VERBOSE=false

while getopts ":l:c:v" opt; do
  case "$opt" in
  l)
    LANGUAGE_ID="$OPTARG"
    ;;
  c)
    SELECTED_METRICS="$OPTARG"
    ;;
  v)
    VERBOSE=true
    ;;
  *)
    usage
    ;;
  esac
done
shift $((OPTIND - 1))
if [ "$#" -gt 0 ]; then
  usage
fi

# pages.en is a symlink to the English pages.
if [ "$LANGUAGE_ID" = "en" ]; then
  LANGUAGE_ID=""
fi

FOLDER_PATH="$TLDR_ROOT_DIR/pages${LANGUAGE_ID:+.$LANGUAGE_ID}"
if [ ! -d "$FOLDER_PATH" ]; then
  echo "The specified path does not exist: $FOLDER_PATH" >&2
  exit 1
fi

# Read the metrics of this script from metrics.tsv.
metrics_output=$(list_metrics) || exit 1
mapfile -t metrics <<< "$metrics_output"
declare -A metric_languages metric_sources
check_metrics=()
for metric in "${metrics[@]}"; do
  IFS=$'\t' read -r id languages source _ <<< "$metric"
  metric_sources[$id]="$source"
  if [ "$source" = "check-pages" ]; then
    if [ -z "${CHECK_OF[$id]}" ]; then
      echo "There is no check for the metric $id of metrics.tsv." >&2
      exit 1
    fi
    metric_languages[$id]="$languages"
    check_metrics+=("$id")
  fi
done
for id in "${!CHECK_OF[@]}"; do
  if [ -z "${metric_languages[$id]}" ]; then
    echo "The metric $id is missing in metrics.tsv (with check-pages as source)." >&2
    exit 1
  fi
done

if [ -n "$SELECTED_METRICS" ]; then
  IFS=',' read -ra selected_metrics <<< "$SELECTED_METRICS"
  for id in "${selected_metrics[@]}"; do
    if [ -z "${metric_sources[$id]}" ]; then
      echo "Unknown metric: $id" >&2
      usage
    elif [ -z "${metric_languages[$id]}" ]; then
      echo "The metric $id isn't checked by this script, but by ${metric_sources[$id]} (see calculate-metrics.sh)." >&2
      usage
    fi
  done
else
  selected_metrics=("${check_metrics[@]}")
fi

OUTPUT_DIR="check-pages${LANGUAGE_ID:+.$LANGUAGE_ID}"
mkdir -p "$OUTPUT_DIR" || exit 1

WORK_DIR=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK_DIR"' EXIT

if [ $VERBOSE = true ]; then
  exec {BASH_XTRACEFD}> "$OUTPUT_DIR/debug.log"
  export BASH_XTRACEFD
  set -x
fi

# The results file of every metric that is checked, and the functions to run (in the order of the checks).
declare -A OUTPUT_FILE
checks=()
for id in "${selected_metrics[@]}"; do
  if [ "${metric_languages[$id]}" = "all" ] || [ -n "$LANGUAGE_ID" ]; then
    OUTPUT_FILE[$id]="$OUTPUT_DIR/$id.txt"
    : > "${OUTPUT_FILE[$id]}" || exit 1
    if [[ " ${checks[*]} " != *" ${CHECK_OF[$id]} "* ]]; then
      checks+=("${CHECK_OF[$id]}")
    fi
  fi
done

# The pages of the language and the English pages, as array and as file (one page per line) for the helpers of
# _common.sh, which read the pages from stdin and refer to a page by its line number.
PAGES_FILE="$WORK_DIR/pages"
ENGLISH_PAGES_FILE="$WORK_DIR/english-pages"
list_pages "$FOLDER_PATH" > "$PAGES_FILE" || exit 1
list_pages "$TLDR_ROOT_DIR/pages" > "$ENGLISH_PAGES_FILE" || exit 1
mapfile -t files < "$PAGES_FILE"
mapfile -t english_files < "$ENGLISH_PAGES_FILE"
SEE_ALSO_PREFIX=$(get_see_also_prefix "${LANGUAGE_ID:-en}") || exit 1

# Node.js warnings (e.g. deprecations) would end up between the lint errors.
export NODE_NO_WARNINGS=1

# The checks below avoid starting processes per page, since a folder can contain thousands of pages.
# Instead, external tools (awk, sed) process all pages at once and Bash only loops over their output,
# which is stored in a file first, so a failure of the external tools is noticed.
# For the same reason, paths are changed with parameter expansion instead of command substitution.

# Add a result to a metric, when the metric is checked.
add_result() {
  local id="$1"
  local result="$2"

  if [ -n "${OUTPUT_FILE[$id]}" ]; then
    echo "$result" >> "${OUTPUT_FILE[$id]}"
  fi
}

page_exists() {
  local command="$1"
  local platform

  for platform in "${PLATFORMS[@]}"; do
    if [ -f "$FOLDER_PATH/$platform/$command.md" ]; then
      return 0
    fi
  done

  return 1
}

# Add the references (lines with "<index>\t<command>") that don't have a page to the results of a metric.
add_missing_references() {
  local id="$1"
  local references_file="$2"
  local index command

  while IFS=$'\t' read -r index command; do
    if ! page_exists "${command,,}"; then
      add_result "$id" "$command does not exist yet! Command referenced in ${files[index - 1]#"$TLDR_ROOT_DIR"/}"
    fi
  done < "$references_file"
}

# Write the references with `tldr <command>` to $WORK_DIR/tldr-references (once).
list_tldr_references_once() {
  if [ ! -f "$WORK_DIR/tldr-references" ]; then
    list_tldr_references < "$PAGES_FILE" > "$WORK_DIR/tldr-references.tmp" || return 1
    mv "$WORK_DIR/tldr-references.tmp" "$WORK_DIR/tldr-references"
  fi
}

# Write the references of the "See also" mentions to $WORK_DIR/see-also-references (once).
list_see_also_references_once() {
  if [ ! -f "$WORK_DIR/see-also-references" ]; then
    list_see_also_references "$SEE_ALSO_PREFIX" < "$PAGES_FILE" > "$WORK_DIR/see-also-references.tmp" || return 1
    mv "$WORK_DIR/see-also-references.tmp" "$WORK_DIR/see-also-references"
  fi
}

check_missing_tldr_pages() {
  list_tldr_references_once || return 1
  add_missing_references missing-tldr-pages "$WORK_DIR/tldr-references"
}

check_missing_see_also_pages() {
  list_see_also_references_once || return 1
  add_missing_references missing-see-also-pages "$WORK_DIR/see-also-references"
}

check_misplaced_pages() {
  local file platform

  for file in "${files[@]}"; do
    platform="${file%/*}"
    platform="${platform##*/}"

    if [[ " ${PLATFORMS[*]} " != *" $platform "* ]]; then
      add_result misplaced-pages "${file#"$TLDR_ROOT_DIR"/}"
    fi
  done
}

# For every given page (read from stdin), print a line with its index, number of commands, number of header lines
# and its commands (stripped from placeholders, strings, etc.) joined by a space, separated by \037.
summarize_commands() {
  # shellcheck disable=SC2016
  awk '
    {
      page = $0
      print "\001" NR
      while ((status = (getline line < page)) > 0) {
        if (line ~ /^>/) print "\002"
        else if (line ~ /^`[^`]+`$/) print line
      }
      if (status < 0) { print "Cannot read " page > "/dev/stderr"; exit 1 }
      close(page)
    }
  ' |
    sed 's/{{\[\([^|]*|[^]]*\)\]}}/___\1___/g' |
    sed -E 's/\{\{([^}]|(\{[^}]*\}))*\}\}/{{}}/g' |
    sed -e 's/<[^>]*>//g' \
      -e 's/([^)]*)//g' \
      -e 's/"[^"]*"/""/g' \
      -e "s/'[^']*'//g" \
      -e 's/`//g' \
      -e 's/___\(.*\)___/{{\[\1\]}}/g' |
    awk '
      function print_page() {
        if (index_of_page != "") print index_of_page "\037" commands "\037" headers "\037" joined
      }
      /^\001/ { print_page(); index_of_page = substr($0, 2); commands = 0; headers = 0; joined = ""; next }
      $0 == "\002" { headers++; next }
      { joined = commands == 0 ? $0 : joined " " $0; commands++ }
      END { print_page() }
    '
}

# Checks the outdated-pages-based-on-command-count, -command-contents and -header-line-count metrics.
check_outdated_pages() {
  local file english_file filepath i index commands headers joined
  local pairs=()
  local -A command_counts header_counts commands_as_string

  # The translated pages with an English page, followed by that English page.
  for file in "${files[@]}"; do
    english_file="$TLDR_ROOT_DIR/pages${file#"$FOLDER_PATH"}"
    if [ -f "$english_file" ]; then
      pairs+=("$file" "$english_file")
    fi
  done

  if [ "${#pairs[@]}" -eq 0 ]; then
    return 0
  fi

  printf '%s\n' "${pairs[@]}" | summarize_commands > "$WORK_DIR/commands" || return 1

  while IFS=$'\037' read -r index commands headers joined; do
    command_counts[$index]="$commands"
    header_counts[$index]="$headers"
    commands_as_string[$index]="$joined"
  done < "$WORK_DIR/commands"

  # The pairs are at index i and i + 1, their lines in the input of summarize_commands at i + 1 and i + 2.
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    filepath="${pairs[i]#"$TLDR_ROOT_DIR"/}"

    if [ "${command_counts[$((i + 2))]}" != "${command_counts[$((i + 1))]}" ]; then
      add_result outdated-pages-based-on-command-count "$filepath"
    elif [ "${commands_as_string[$((i + 2))]}" != "${commands_as_string[$((i + 1))]}" ]; then
      add_result outdated-pages-based-on-command-contents "$filepath"
    fi

    if [ "${header_counts[$((i + 2))]}" != "${header_counts[$((i + 1))]}" ]; then
      add_result outdated-pages-based-on-header-line-count "$filepath"
    fi
  done
}

check_missing_english_pages() {
  local file

  for file in "${files[@]}"; do
    if [ ! -f "$TLDR_ROOT_DIR/pages${file#"$FOLDER_PATH"}" ]; then
      add_result missing-english-pages "${file#"$TLDR_ROOT_DIR"/}"
    fi
  done
}

check_missing_translated_pages() {
  local english_file translated_file

  for english_file in "${english_files[@]}"; do
    translated_file="$FOLDER_PATH${english_file#"$TLDR_ROOT_DIR/pages"}"
    if [ ! -f "$translated_file" ]; then
      add_result missing-translated-pages "${translated_file#"$TLDR_ROOT_DIR"/}"
    fi
  done
}

# Add the output of a linter to the lint errors, one line per error, and fail when it has other output.
# Both linters print a line per lint error, starting with the path of the page and the line number.
# tldr-lint prints the path followed by the parse error on the next lines for a page it can't parse,
# which is joined to one line.
add_lint_errors() {
  local linter="$1"
  local output_file="$2"

  # shellcheck disable=SC2016
  awk '
    function add_parse_error() {
      if (file != "") print file ":" line ": Parse error: " message
      file = ""
    }
    # Node.js warnings, e.g. "(node:123) [DEP0040] DeprecationWarning: ...".
    /^\(node:[0-9]+\) / || /^\(Use `node --trace-/ { next }
    /^[^ ].*\.md:[0-9]+[: ]/ { add_parse_error(); print; next }
    /^[^ ].*\.md:$/ { add_parse_error(); file = substr($0, 1, length($0) - 1); line = 1; message = ""; next }
    file != "" {
      if (match($0, /on line [0-9]+/)) line = substr($0, RSTART + 8, RLENGTH - 8)
      message = $0
      next
    }
    { print > "/dev/stderr"; unexpected = 1 }
    END { add_parse_error(); exit unexpected }
  ' "$output_file" >> "${OUTPUT_FILE[lint-errors]}" || {
    echo "$linter failed." >&2
    return 1
  }
}

lint() {
  local folder="${FOLDER_PATH##*/}"
  local ignore_checks=()
  local tldr_lint_options=()
  local linter status

  if [ "${#files[@]}" -eq 0 ]; then
    return 0
  fi

  case "$LANGUAGE_ID" in
    "")
      ;;
    "ar" | "bn" | "fa" | "hi" | "ja" | "ko" | "lo" | "ml" | "ne" | "ta" | "th" | "tr")
      ignore_checks=("TLDR104" "TLDR003" "TLDR004" "TLDR015")
      ;;
    "zh_TW" | "zh")
      ignore_checks=("TLDR104" "TLDR003" "TLDR004" "TLDR005" "TLDR015")
      ;;
    *)
      ignore_checks=("TLDR104")
      ;;
  esac

  if [ "${#ignore_checks[@]}" -gt 0 ]; then
    tldr_lint_options=(--ignore "$(IFS=,; echo "${ignore_checks[*]}")")
  fi

  for linter in markdownlint tldr-lint; do
    if ! command -v "$linter" > /dev/null; then
      echo "$linter is not installed, run \`npm ci\` and add node_modules/.bin to PATH." >&2
      return 1
    fi
  done

  # The linters run inside the tldr repository, so the results contain the path relative to it.
  (cd "$TLDR_ROOT_DIR" && markdownlint "$folder" -c .markdownlint.json) > "$WORK_DIR/markdownlint" 2>&1
  status=$?
  # markdownlint exits with 1 when it finds lint errors and with a higher code when it failed to run.
  if [ "$status" -gt 1 ]; then
    cat "$WORK_DIR/markdownlint" >&2
    echo "markdownlint failed with exit code $status." >&2
    return 1
  fi
  add_lint_errors markdownlint "$WORK_DIR/markdownlint" || return 1

  (cd "$TLDR_ROOT_DIR" && tldr-lint "${tldr_lint_options[@]}" "$folder") > "$WORK_DIR/tldr-lint" 2>&1
  status=$?
  # tldr-lint exits with 1 when it finds lint errors, but also when it failed to run (then its output shows why).
  if [ "$status" -gt 1 ]; then
    cat "$WORK_DIR/tldr-lint" >&2
    echo "tldr-lint failed with exit code $status." >&2
    return 1
  fi
  add_lint_errors tldr-lint "$WORK_DIR/tldr-lint"
}

# Write the totals the percentages are calculated on (see TOTAL_NAMES in _common.sh and metrics.tsv).
write_totals() {
  local file english_file tldr_references see_also_references
  local english_pages_of_files=()
  local pages_need_see_also_mention=0

  list_tldr_references_once || return 1
  list_see_also_references_once || return 1
  tldr_references=$(sort -u "$WORK_DIR/tldr-references" | wc -l) || return 1
  see_also_references=$(sort -u "$WORK_DIR/see-also-references" | wc -l) || return 1

  # set-see-also.py only checks languages with a translation template.
  if [ -n "$SEE_ALSO_PREFIX" ]; then
    for file in "${files[@]}"; do
      english_file="$TLDR_ROOT_DIR/pages${file#"$FOLDER_PATH"}"
      if [ -f "$english_file" ]; then
        english_pages_of_files+=("$english_file")
      fi
    done
    if [ "${#english_pages_of_files[@]}" -gt 0 ]; then
      pages_need_see_also_mention=$(printf '%s\n' "${english_pages_of_files[@]}" | list_pages_with_see_also_mention | wc -l) || return 1
    fi
  fi

  local -A totals=(
    [pages]="${#files[@]}"
    [english-pages]="${#english_files[@]}"
    [pages-need-see-also-mention]="$pages_need_see_also_mention"
    [tldr-references]="$tldr_references"
    [see-also-references]="$see_also_references"
  )
  local name
  for name in "${TOTAL_NAMES[@]}"; do
    if [ -z "${totals[$name]}" ]; then
      echo "The total $name isn't counted." >&2
      return 1
    fi
    printf '%s\t%s\n' "$name" "${totals[$name]}"
  done > "$OUTPUT_DIR/totals.tsv"
}

status=0
for check in "${checks[@]}" write_totals; do
  if ! "$check"; then
    echo "$check failed for $FOLDER_PATH." >&2
    status=1
    # Remove the (partial) results of the metrics of the check, so they aren't mistaken for complete results.
    for id in "${!OUTPUT_FILE[@]}"; do
      if [ "${CHECK_OF[$id]}" = "$check" ]; then
        rm -f "${OUTPUT_FILE[$id]}"
        unset "OUTPUT_FILE[$id]"
      fi
    done
  fi
done

for output_file in "${OUTPUT_FILE[@]}"; do
  sort -u -o "$output_file" "$output_file" || status=1
done

exit "$status"
