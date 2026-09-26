#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

# This script can be executed to check several things for the translated pages. This could also be run on the English folder, be aware that some checks are not applicable.
# - Check if a page references missing TLDR pages.
#   A command is marked as missing when it is mentioned in a page (`tldr {{command}}`) but the referenced command doesn't have a (translated) page.
# - Check if a page references missing see also pages.
#   A command is marked as missing when it is mentioned in the "See also" line of a page but the referenced command doesn't have a (translated) page.
# - Check if a page is misplaced.
#   A page is marked as misplaced when the page isn't inside a folder in the list of supported platforms.
# - Check if a page is outdated.
#   A page is marked as outdated when the number of commands differ from the number of commands in the English page or the contents of the commands differ from the English page.
# - Check if a page is missing as English page (n/a for English).
#   A page is marked as missing when the filename can't be found as English page.
# - Check if a page is missing in the translation (n/a for English).
#   A page is marked as missing when the filename can't be found as translated page.
# - Run the markdownlint and tldr-lint.

# Usage: ./check-pages.sh [-l language_id] [-c check_names] [-v]
#   - language_id (optional): Specify a language identifier (e.g., 'id', 'fr') to filter results for a specific language.
#   - check_names (optional): Provide an array splitted by "," to only run specific checks [missing_tldr_page,missing_see_also_page,misplaced_page,outdated_page,missing_english_page,missing_translated_page,lint]
#   - Adding -v enables verbose logging.

# shellcheck source=scripts/_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

ROOT_DIR="${TLDR_ROOT:-./tldr}"
PLATFORMS=("android" "common" "linux" "openbsd" "freebsd" "netbsd" "osx" "sunos" "windows" "cisco-ios" "dos")

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
    echo "This argument is not valid for this script."
    ;;
  esac
done

IFS=',' read -ra CHECK_NAMES <<< "$CHECK_NAMES"

if [ -z "$LANGUAGE_ID" ]; then
  LANGUAGE_ID="${BASH_REMATCH[1]}"
fi

OUTPUT_DIR="check-pages${LANGUAGE_ID:+.$LANGUAGE_ID}"
mkdir -p "$OUTPUT_DIR"

if [ $VERBOSE = true ]; then
  DEBUG_LOG="$OUTPUT_DIR/debug.log"
  rm -f "$DEBUG_LOG" && touch "$DEBUG_LOG"
  exec {BASH_XTRACEFD}> "$DEBUG_LOG"
  export BASH_XTRACEFD
  set -x
fi

MISSING_TLDR_OUTPUT_FILE="$OUTPUT_DIR/missing-tldr${LANGUAGE_ID:+-$LANGUAGE_ID}-pages.txt"
MISSING_SEE_ALSO_OUTPUT_FILE="$OUTPUT_DIR/missing-see-also-referenced${LANGUAGE_ID:+-$LANGUAGE_ID}-pages.txt"
MISPLACED_OUTPUT_FILE="$OUTPUT_DIR/misplaced${LANGUAGE_ID:+-$LANGUAGE_ID}-pages.txt"
OUTDATED_BASED_ON_COMMAND_CONTENTS_FILE="$OUTPUT_DIR/outdated${LANGUAGE_ID:+-$LANGUAGE_ID}-pages-based-on-command-contents.txt"
OUTDATED_BASED_ON_COMMAND_COUNT_FILE="$OUTPUT_DIR/outdated${LANGUAGE_ID:+-$LANGUAGE_ID}-pages-based-on-command-count.txt"
OUTDATED_BASED_ON_HEADER_FILE="$OUTPUT_DIR/outdated${LANGUAGE_ID:+-$LANGUAGE_ID}-pages-based-on-header-line-count.txt"
MISSING_ENGLISH_OUTPUT_FILE="$OUTPUT_DIR/missing-english${LANGUAGE_ID:+-$LANGUAGE_ID}-pages.txt"
MISSING_TRANSLATED_OUTPUT_FILE="$OUTPUT_DIR/missing-translated${LANGUAGE_ID:+-$LANGUAGE_ID}-pages.txt"
LINT_FILE="$OUTPUT_DIR/lint-errors${LANGUAGE_ID:+-$LANGUAGE_ID}.txt"

OUTPUT_FILES=( "$MISSING_TLDR_OUTPUT_FILE" "$MISSING_SEE_ALSO_OUTPUT_FILE" "$MISPLACED_OUTPUT_FILE" "$OUTDATED_BASED_ON_COMMAND_CONTENTS_FILE" "$OUTDATED_BASED_ON_COMMAND_COUNT_FILE" "$OUTDATED_BASED_ON_HEADER_FILE" "$MISSING_ENGLISH_OUTPUT_FILE" "$MISSING_TRANSLATED_OUTPUT_FILE" "$LINT_FILE" )

for OUTPUT_FILE in  "${OUTPUT_FILES[@]}"; do
  rm -rf "$OUTPUT_FILE"
  touch "$OUTPUT_FILE"
done

# Create an array of files to loop over
folder_path="$ROOT_DIR/pages${LANGUAGE_ID:+.$LANGUAGE_ID}"
mapfile -t files < <(find "$folder_path" -type f -name "*.md" -readable | sort -u)

if [ ! -e "$folder_path" ]; then
  echo "The specified path does not exist: $folder_path"
  exit 1
fi

# The checks below avoid starting processes per page, since a folder can contain thousands of pages.
# Instead, external tools (awk, sed) process all pages at once and Bash only loops over their output.

has_check() {
  [[ " ${CHECK_NAMES[*]} " == *" $1 "* ]]
}

page_exists() {
  local filename="$1"

  for platform in "${PLATFORMS[@]}"; do
    if [ -f "$folder_path/$platform/$filename.md" ]; then
      return 0
    fi
  done

  return 1
}

check_missing_tldr_pages() {
  local index line command file

  # shellcheck disable=SC2016
  while IFS=$'\t' read -r index line; do
    file="${files[index - 1]}"
    line="${line#\`tldr }" # Remove "`tldr " prefix
    line="${line%\`}"      # Remove the last backtick

    command="$line"
    # Strip off "-p linux" from "wget -p common".
    if [[ $command =~ (.*)\ -[^\ ]\ [^\ ]+ ]]; then
      command="${BASH_REMATCH[1]}${command:${#BASH_REMATCH[0]}}"
    fi
    # Strip off "-p linux" from "-p linux awk".
    if [[ $command =~ -[^\ ]\ [^\ ]+\ (.*) ]]; then
      command="${command:0:${#command}-${#BASH_REMATCH[0]}}${BASH_REMATCH[1]}"
    fi
    command="${command// /-}"

    if ! [[ $command =~ ^-[^[:space:]] ]] && ! [[ $command =~ \{\{.*\}\} ]]; then # Exclude -p / -u / -o (tldr -u) commands and {{commands}}.
      if ! page_exists "${command,,}"; then
        echo "$command does not exist yet! Command referenced in ${file#./tldr/}" >> "$MISSING_TLDR_OUTPUT_FILE"
      fi
    fi
  done < <(awk '
    BEGIN { for (i = 1; i < ARGC; i++) index_of[ARGV[i]] = i }
    match($0, /`tldr .*`$/) { print index_of[FILENAME] "\t" substr($0, RSTART, RLENGTH) }
  ' "${files[@]}")
}

check_missing_see_also_pages() {
  local index command

  while IFS=$'\t' read -r index command; do
    if ! page_exists "${command,,}"; then
      echo "$command does not exist yet! Command referenced in ${files[index - 1]#./tldr/}" >> "$MISSING_SEE_ALSO_OUTPUT_FILE"
    fi
  done < <(list_see_also_references "$see_also_prefix" "${files[@]}")
}

check_misplaced_pages() {
  local file platform

  for file in "${files[@]}"; do
    platform="${file%/*}"
    platform="${platform##*/}"

    if [[ " ${PLATFORMS[*]} " != *" $platform "* ]]; then
      echo "${file#./tldr/}" >> "$MISPLACED_OUTPUT_FILE"
    fi
  done
}

# For every given page, print a line with \001 followed by the index of the page (starting at 1),
# a line with \002 for every header line and every command, stripped from placeholders, strings, etc.
strip_commands() {
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
  done < <(strip_commands "${pages[@]}")
  store_commands
}

check_outdated_pages() {
  local file english_file filepath
  local pages=()

  for file in "${files[@]}"; do
    english_file="./tldr/pages${file#./tldr/pages."$LANGUAGE_ID"}"
    if [ -f "$english_file" ]; then
      pages+=("$file" "$english_file")
    fi
  done

  if [ "${#pages[@]}" -eq 0 ]; then
    return
  fi

  load_commands "${pages[@]}"

  for ((i = 0; i < ${#pages[@]}; i += 2)); do
    file="${pages[i]}"
    english_file="${pages[i + 1]}"
    filepath="${file#./tldr/}"

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
  local file english_file

  for file in "${files[@]}"; do
    english_file="./tldr/pages${file#./tldr/pages."$LANGUAGE_ID"}"
    if [ ! -f "$english_file" ]; then
      echo "${file#./tldr/}" >> "$MISSING_ENGLISH_OUTPUT_FILE"
    fi
  done
}

check_missing_translated_pages() {
  local english_file translated_file
  local english_files

  mapfile -t english_files < <(find "$ROOT_DIR/pages" -type f -name "*.md" | sort -u)
  for english_file in "${english_files[@]}"; do
    translated_file="./tldr/pages.$LANGUAGE_ID${english_file#./tldr/pages}"
    if [ ! -f "$translated_file" ]; then
      echo "${translated_file#./tldr/}" >> "$MISSING_TRANSLATED_OUTPUT_FILE"
    fi
  done
}

lint() {
  local file="$1"

  markdownlint "$file" -c "./tldr/.markdownlint.json" >> "$LINT_FILE" 2>&1

  local ignore_checks=("TLDR104")

  case "$LANGUAGE_ID" in
    "") # LANGUAGE_ID is en
      ignore_checks=()
      ;;
    "ar" | "bn" | "fa" | "hi" | "ja" | "ko" | "lo" | "ml" | "ne" | "ta" | "th" | "tr")
      ignore_checks+=("TLDR003" "TLDR004" "TLDR015")
      ;;
    "zh_TW" | "zh")
      ignore_checks+=("TLDR003" "TLDR004" "TLDR005" "TLDR015")
      ;;
  esac

  mapfile -t ignore_checks < <(IFS=,; echo "${ignore_checks[*]}")

  if [ -n "$LANGUAGE_ID" ]; then
    tldr-lint --ignore "${ignore_checks[0]}" "$file" >> "$LINT_FILE" 2>&1
  else
    tldr-lint "$file" >> "$LINT_FILE" 2>&1
  fi
}

see_also_prefix=$(get_see_also_prefix "${LANGUAGE_ID:-en}")

if has_check lint; then
  lint "$folder_path"
fi

if has_check missing_tldr_page && [ "${#files[@]}" -gt 0 ]; then
  check_missing_tldr_pages
fi

if has_check missing_see_also_page && [ -n "$see_also_prefix" ] && [ "${#files[@]}" -gt 0 ]; then
  check_missing_see_also_pages
fi

if has_check misplaced_page; then
  check_misplaced_pages
fi

if [ -n "$LANGUAGE_ID" ] && has_check outdated_page; then
  check_outdated_pages
fi

if [ -n "$LANGUAGE_ID" ] && has_check missing_english_page; then
  check_missing_english_pages
fi

if [ -n "$LANGUAGE_ID" ] && has_check missing_translated_page; then
  check_missing_translated_pages
fi

for OUTPUT_FILE in  "${OUTPUT_FILES[@]}"; do
  sort -o "$OUTPUT_FILE" "$OUTPUT_FILE"
done
