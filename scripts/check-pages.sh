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

# pages.en is a symlink to the English pages.
if [ "$LANGUAGE_ID" = "en" ]; then
  LANGUAGE_ID=""
fi

folder_path="$TLDR_ROOT_DIR/pages${LANGUAGE_ID:+.$LANGUAGE_ID}"
if [ ! -d "$folder_path" ]; then
  echo "The specified path does not exist: $folder_path" >&2
  exit 1
fi

# Read the metrics of this script from metrics.tsv.
metrics_output=$(list_metrics) || exit 1
mapfile -t metrics <<< "$metrics_output"
declare -A metric_languages
check_metrics=()
for metric in "${metrics[@]}"; do
  IFS=$'\t' read -r id languages source _ <<< "$metric"
  if [ "$source" = "check-pages" ]; then
    if [ -z "${CHECK_OF[$id]}" ]; then
      echo "There is no check for the metric $id in metrics.tsv." >&2
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
    if [ -z "${metric_languages[$id]}" ]; then
      echo "Unknown metric: $id" >&2
      usage
    fi
  done
else
  selected_metrics=("${check_metrics[@]}")
fi

OUTPUT_DIR="check-pages${LANGUAGE_ID:+.$LANGUAGE_ID}"
mkdir -p "$OUTPUT_DIR"

WORK_DIR=$(mktemp -d)
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
    : > "${OUTPUT_FILE[$id]}"
    if [[ " ${checks[*]} " != *" ${CHECK_OF[$id]} "* ]]; then
      checks+=("${CHECK_OF[$id]}")
    fi
  fi
done

mapfile -t files < <(list_pages "$folder_path")
mapfile -t english_files < <(list_pages "$TLDR_ROOT_DIR/pages")
see_also_prefix=$(get_see_also_prefix "${LANGUAGE_ID:-en}")

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

  for platform in "${PLATFORMS[@]}"; do
    if [ -f "$folder_path/$platform/$command.md" ]; then
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
    list_tldr_references "${files[@]}" > "$WORK_DIR/tldr-references.tmp" || return 1
    mv "$WORK_DIR/tldr-references.tmp" "$WORK_DIR/tldr-references"
  fi
}

# Write the references of the "See also" mentions to $WORK_DIR/see-also-references (once).
list_see_also_references_once() {
  if [ ! -f "$WORK_DIR/see-also-references" ]; then
    list_see_also_references "$see_also_prefix" "${files[@]}" > "$WORK_DIR/see-also-references.tmp" || return 1
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

# For every given page, print a line with \001 followed by the index of the page (starting at 1),
# a line with \002 for every header line and every command, stripped from placeholders, strings, etc.
strip_commands() {
  if [ "$#" -eq 0 ]; then
    return 0
  fi

  # shellcheck disable=SC2016
  awk '
    BEGIN { for (i = 1; i < ARGC; i++) index_of[ARGV[i]] = i }
    FNR == 1 { print "\001" index_of[FILENAME] }
    /^>/ { print "\002" }
    /^`[^`]+`$/ { print }
  ' "$@" |
    sed 's/{{\[\([^|]*|[^]]*\)\]}}/___\1___/g' |
    sed -E 's/\{\{([^}]|(\{[^}]*\}))*\}\}/{{}}/g' |
    sed -e 's/<[^>]*>//g' \
      -e 's/([^)]*)//g' \
      -e 's/"[^"]*"/""/g' \
      -e "s/'[^']*'//g" \
      -e 's/`//g' \
      -e 's/___\(.*\)___/{{\[\1\]}}/g'
}

# Fill command_counts, header_counts and commands_as_string for all given pages.
declare -A command_counts header_counts commands_as_string
load_commands() {
  local pages=("$@")
  local line page="" commands=0 headers=0 as_string=""

  store_commands() {
    if [ -n "$page" ]; then
      command_counts["$page"]=$commands
      header_counts["$page"]=$headers
      commands_as_string["$page"]=$as_string
    fi
  }

  strip_commands "${pages[@]}" > "$WORK_DIR/commands" || return 1

  while IFS= read -r line; do
    case "$line" in
      $'\001'*)
        store_commands
        page="${pages[${line#?} - 1]}"
        commands=0
        headers=0
        as_string=""
        ;;
      $'\002')
        headers=$((headers + 1))
        ;;
      *)
        if [ "$commands" -eq 0 ]; then
          as_string="$line"
        else
          as_string+=" $line"
        fi
        commands=$((commands + 1))
        ;;
    esac
  done < "$WORK_DIR/commands"
  store_commands
}

# Checks the outdated-pages-based-on-command-count, -command-contents and -header-line-count metrics.
check_outdated_pages() {
  local file english_file filepath
  local pages=()

  for file in "${files[@]}"; do
    english_file="$TLDR_ROOT_DIR/pages${file#"$folder_path"}"
    if [ -f "$english_file" ]; then
      pages+=("$file" "$english_file")
    fi
  done

  load_commands "${pages[@]}" || return 1

  for ((i = 0; i < ${#pages[@]}; i += 2)); do
    file="${pages[i]}"
    english_file="${pages[i + 1]}"
    filepath="${file#"$TLDR_ROOT_DIR"/}"

    if [ "${command_counts[$english_file]:-0}" != "${command_counts[$file]:-0}" ]; then
      add_result outdated-pages-based-on-command-count "$filepath"
    elif [ "${commands_as_string[$english_file]}" != "${commands_as_string[$file]}" ]; then
      add_result outdated-pages-based-on-command-contents "$filepath"
    fi

    if [ "${header_counts[$english_file]:-0}" != "${header_counts[$file]:-0}" ]; then
      add_result outdated-pages-based-on-header-line-count "$filepath"
    fi
  done
}

check_missing_english_pages() {
  local file

  for file in "${files[@]}"; do
    if [ ! -f "$TLDR_ROOT_DIR/pages${file#"$folder_path"}" ]; then
      add_result missing-english-pages "${file#"$TLDR_ROOT_DIR"/}"
    fi
  done
}

check_missing_translated_pages() {
  local english_file translated_file

  for english_file in "${english_files[@]}"; do
    translated_file="$folder_path${english_file#"$TLDR_ROOT_DIR/pages"}"
    if [ ! -f "$translated_file" ]; then
      add_result missing-translated-pages "${translated_file#"$TLDR_ROOT_DIR"/}"
    fi
  done
}

lint() {
  local folder="${folder_path##*/}"
  local ignore_checks=()
  local tldr_lint_options=()
  local status

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
  (cd "$TLDR_ROOT_DIR" && markdownlint "$folder" -c .markdownlint.json) >> "${OUTPUT_FILE[lint-errors]}" 2>&1
  status=$?
  # markdownlint exits with 1 when it finds lint errors and with a higher code when it failed to run.
  if [ "$status" -gt 1 ]; then
    echo "markdownlint failed with exit code $status." >&2
    return 1
  fi

  (cd "$TLDR_ROOT_DIR" && tldr-lint "${tldr_lint_options[@]}" "$folder") > "$WORK_DIR/tldr-lint" 2>&1
  # tldr-lint also exits with 1 when it failed to run, so its output is checked instead. It prints a line per lint error,
  # or, for a page it can't parse, the path followed by the parse error on the next lines, which is joined to one line.
  # Any other output (e.g. an error before the first page) means it failed to run.
  # shellcheck disable=SC2016
  awk '
    function add_parse_error() {
      if (file != "") print file ":" line ": Parse error: " message
      file = ""
    }
    /^[^ ].*\.md:[0-9]+: / { add_parse_error(); print; next }
    /^[^ ].*\.md:$/ { add_parse_error(); file = substr($0, 1, length($0) - 1); line = 1; message = ""; next }
    file != "" {
      if (match($0, /on line [0-9]+/)) line = substr($0, RSTART + 8, RLENGTH - 8)
      message = $0
      next
    }
    { print > "/dev/stderr"; unexpected = 1 }
    END { add_parse_error(); exit unexpected }
  ' "$WORK_DIR/tldr-lint" >> "${OUTPUT_FILE[lint-errors]}" || {
    echo "tldr-lint failed." >&2
    return 1
  }
}

# Write the totals the percentages are calculated on (see the denominator column of metrics.tsv).
write_totals() {
  local file english_file
  local tldr_references see_also_references
  local english_pages_of_files=()
  local pages_need_see_also_mention=0

  list_tldr_references_once || return 1
  list_see_also_references_once || return 1
  tldr_references=$(sort -u "$WORK_DIR/tldr-references" | wc -l) || return 1
  see_also_references=$(sort -u "$WORK_DIR/see-also-references" | wc -l) || return 1

  # set-see-also.py only checks languages with a translation template.
  if [ -n "$see_also_prefix" ]; then
    for file in "${files[@]}"; do
      english_file="$TLDR_ROOT_DIR/pages${file#"$folder_path"}"
      if [ -f "$english_file" ]; then
        english_pages_of_files+=("$english_file")
      fi
    done
    pages_need_see_also_mention=$(list_pages_with_see_also_mention "${english_pages_of_files[@]}" | wc -l) || return 1
  fi

  printf '%s\t%s\n' \
    pages "${#files[@]}" \
    english-pages "${#english_files[@]}" \
    pages-need-see-also-mention "$pages_need_see_also_mention" \
    tldr-references "$tldr_references" \
    see-also-references "$see_also_references" > "$OUTPUT_DIR/totals.tsv"
}

status=0
for check in "${checks[@]}" write_totals; do
  if ! "$check"; then
    echo "$check failed for $folder_path." >&2
    status=1
  fi
done

for output_file in "${OUTPUT_FILE[@]}"; do
  sort -o "$output_file" "$output_file" || status=1
done

exit "$status"
