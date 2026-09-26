#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

# Check the pages of one language and write the results to check-pages[.<language>]/<metric>.txt,
# with the metrics as described in metrics.tsv:
# - missing-tldr-pages: a page mentions a command at the end of a line (`tldr command`), but the command doesn't have a page in the same language.
# - missing-see-also-pages: a page mentions a command in its first "See also" line (with the prefix of the translation template),
#   but the command doesn't have a page in the same language.
# - misplaced-pages: a page isn't inside a folder of a supported platform.
# - outdated-pages-based-on-command-count (not for English): the number of commands differs from the English page.
# - outdated-pages-based-on-command-contents (not for English): the commands (without placeholders, strings, etc.) differ from the English page.
# - outdated-pages-based-on-header-line-count (not for English): the number of lines starting with ">" differs from the English page.
# - missing-english-pages (not for English): the English page doesn't exist.
# - missing-translated-pages (not for English): the English page exists, but the translated page doesn't.
# - lint-errors: the output of markdownlint and tldr-lint.
#
# Usage: ./check-pages.sh [-l language_id] [-c check_names] [-v]
#   - language_id (optional): the language to check (e.g. "fr" or "pt_BR"). Without it, the English pages are checked.
#   - check_names (optional): a comma-separated list of the checks to run, by default all of them:
#     missing_tldr_page,missing_see_also_page,misplaced_page,outdated_page,missing_english_page,missing_translated_page,lint
#   - -v enables verbose logging to check-pages[.<language>]/debug.log.
#
# Exits with 1 when a check failed to run.

set -o pipefail

# shellcheck source=scripts/_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

PLATFORMS=("android" "common" "linux" "openbsd" "freebsd" "netbsd" "osx" "sunos" "windows" "cisco-ios" "dos")

LANGUAGE_ID=""
CHECK_NAMES="missing_tldr_page,missing_see_also_page,misplaced_page,outdated_page,missing_english_page,missing_translated_page,lint"
VERBOSE=false

while getopts ":l:c:v" opt; do
  case "$opt" in
  l)
    LANGUAGE_ID="$OPTARG"
    ;;
  c)
    CHECK_NAMES="$OPTARG"
    ;;
  v)
    VERBOSE=true
    ;;
  *)
    echo "Usage: $0 [-l language_id] [-c check_names] [-v]" >&2
    exit 1
    ;;
  esac
done

IFS=',' read -ra CHECK_NAMES <<< "$CHECK_NAMES"

# pages.en is a symlink to the English pages.
if [ "$LANGUAGE_ID" = "en" ]; then
  LANGUAGE_ID=""
fi

folder_path="$TLDR_ROOT_DIR/pages${LANGUAGE_ID:+.$LANGUAGE_ID}"
if [ ! -d "$folder_path" ]; then
  echo "The specified path does not exist: $folder_path" >&2
  exit 1
fi

OUTPUT_DIR="check-pages${LANGUAGE_ID:+.$LANGUAGE_ID}"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

if [ $VERBOSE = true ]; then
  exec {BASH_XTRACEFD}> "$OUTPUT_DIR/debug.log"
  export BASH_XTRACEFD
  set -x
fi

MISSING_TLDR_OUTPUT_FILE="$OUTPUT_DIR/missing-tldr-pages.txt"
MISSING_SEE_ALSO_OUTPUT_FILE="$OUTPUT_DIR/missing-see-also-pages.txt"
MISPLACED_OUTPUT_FILE="$OUTPUT_DIR/misplaced-pages.txt"
OUTDATED_BASED_ON_COMMAND_COUNT_FILE="$OUTPUT_DIR/outdated-pages-based-on-command-count.txt"
OUTDATED_BASED_ON_COMMAND_CONTENTS_FILE="$OUTPUT_DIR/outdated-pages-based-on-command-contents.txt"
OUTDATED_BASED_ON_HEADER_FILE="$OUTPUT_DIR/outdated-pages-based-on-header-line-count.txt"
MISSING_ENGLISH_OUTPUT_FILE="$OUTPUT_DIR/missing-english-pages.txt"
MISSING_TRANSLATED_OUTPUT_FILE="$OUTPUT_DIR/missing-translated-pages.txt"
LINT_FILE="$OUTPUT_DIR/lint-errors.txt"

OUTPUT_FILES=(
  "$MISSING_TLDR_OUTPUT_FILE"
  "$MISSING_SEE_ALSO_OUTPUT_FILE"
  "$MISPLACED_OUTPUT_FILE"
  "$OUTDATED_BASED_ON_COMMAND_COUNT_FILE"
  "$OUTDATED_BASED_ON_COMMAND_CONTENTS_FILE"
  "$OUTDATED_BASED_ON_HEADER_FILE"
  "$MISSING_ENGLISH_OUTPUT_FILE"
  "$MISSING_TRANSLATED_OUTPUT_FILE"
  "$LINT_FILE"
)
for output_file in "${OUTPUT_FILES[@]}"; do
  : > "$output_file"
done

mapfile -t files < <(list_pages "$folder_path")

# The checks below avoid starting processes per page, since a folder can contain thousands of pages.
# Instead, external tools (awk, sed) process all pages at once and Bash only loops over their output,
# which is stored in a file first, so a failure of the external tools is noticed.
# For the same reason, paths are changed with parameter expansion instead of command substitution.

has_check() {
  [[ " ${CHECK_NAMES[*]} " == *" $1 "* ]]
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

# Write the references (lines with "<index>\t<command>") that don't have a page to the output file.
report_missing_references() {
  local references_file="$1"
  local output_file="$2"
  local index command

  while IFS=$'\t' read -r index command; do
    if ! page_exists "${command,,}"; then
      echo "$command does not exist yet! Command referenced in ${files[index - 1]#"$TLDR_ROOT_DIR"/}" >> "$output_file"
    fi
  done < "$references_file"
}

check_missing_tldr_pages() {
  list_tldr_references "${files[@]}" > "$WORK_DIR/tldr-references" || return 1
  report_missing_references "$WORK_DIR/tldr-references" "$MISSING_TLDR_OUTPUT_FILE"
}

check_missing_see_also_pages() {
  local see_also_prefix="$1"

  list_see_also_references "$see_also_prefix" "${files[@]}" > "$WORK_DIR/see-also-references" || return 1
  report_missing_references "$WORK_DIR/see-also-references" "$MISSING_SEE_ALSO_OUTPUT_FILE"
}

check_misplaced_pages() {
  local file platform

  for file in "${files[@]}"; do
    platform="${file%/*}"
    platform="${platform##*/}"

    if [[ " ${PLATFORMS[*]} " != *" $platform "* ]]; then
      echo "${file#"$TLDR_ROOT_DIR"/}" >> "$MISPLACED_OUTPUT_FILE"
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
      echo "$filepath" >> "$OUTDATED_BASED_ON_COMMAND_COUNT_FILE"
    elif [ "${commands_as_string[$english_file]}" != "${commands_as_string[$file]}" ]; then
      echo "$filepath" >> "$OUTDATED_BASED_ON_COMMAND_CONTENTS_FILE"
    fi

    if [ "${header_counts[$english_file]:-0}" != "${header_counts[$file]:-0}" ]; then
      echo "$filepath" >> "$OUTDATED_BASED_ON_HEADER_FILE"
    fi
  done
}

check_missing_english_pages() {
  local file

  for file in "${files[@]}"; do
    if [ ! -f "$TLDR_ROOT_DIR/pages${file#"$folder_path"}" ]; then
      echo "${file#"$TLDR_ROOT_DIR"/}" >> "$MISSING_ENGLISH_OUTPUT_FILE"
    fi
  done
}

check_missing_translated_pages() {
  local english_file translated_file
  local english_files

  mapfile -t english_files < <(list_pages "$TLDR_ROOT_DIR/pages")
  for english_file in "${english_files[@]}"; do
    translated_file="$folder_path${english_file#"$TLDR_ROOT_DIR/pages"}"
    if [ ! -f "$translated_file" ]; then
      echo "${translated_file#"$TLDR_ROOT_DIR"/}" >> "$MISSING_TRANSLATED_OUTPUT_FILE"
    fi
  done
}

lint() {
  local ignore_checks=()

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

  # Both linters exit with an error when they find lint errors, so only a missing linter is a failure.
  for linter in markdownlint tldr-lint; do
    if ! command -v "$linter" > /dev/null; then
      echo "$linter is not installed, run \`npm ci\` and add node_modules/.bin to PATH." >&2
      return 1
    fi
  done

  markdownlint "$folder_path" -c "$TLDR_ROOT_DIR/.markdownlint.json" >> "$LINT_FILE" 2>&1

  if [ "${#ignore_checks[@]}" -gt 0 ]; then
    tldr-lint --ignore "$(IFS=,; echo "${ignore_checks[*]}")" "$folder_path" >> "$LINT_FILE" 2>&1
  else
    tldr-lint "$folder_path" >> "$LINT_FILE" 2>&1
  fi

  return 0
}

status=0
# Report a check that failed to run.
report_failure() {
  echo "The check $1 failed for $folder_path." >&2
  status=1
}

if has_check lint; then
  lint || report_failure lint
fi

if has_check missing_tldr_page; then
  check_missing_tldr_pages || report_failure missing_tldr_page
fi

if has_check missing_see_also_page; then
  check_missing_see_also_pages "$(get_see_also_prefix "${LANGUAGE_ID:-en}")" || report_failure missing_see_also_page
fi

if has_check misplaced_page; then
  check_misplaced_pages || report_failure misplaced_page
fi

if [ -n "$LANGUAGE_ID" ] && has_check outdated_page; then
  check_outdated_pages || report_failure outdated_page
fi

if [ -n "$LANGUAGE_ID" ] && has_check missing_english_page; then
  check_missing_english_pages || report_failure missing_english_page
fi

if [ -n "$LANGUAGE_ID" ] && has_check missing_translated_page; then
  check_missing_translated_pages || report_failure missing_translated_page
fi

for output_file in "${OUTPUT_FILES[@]}"; do
  sort -o "$output_file" "$output_file" || status=1
done

exit "$status"
