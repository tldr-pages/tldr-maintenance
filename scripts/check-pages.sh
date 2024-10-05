#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

# This script can be executed to check several things for the translated pages. This could also be run on the English folder, be aware that some checks are not applicable.
# - Check if a page references missing TLDR pages.
#   A command is marked as missing when it is mentioned in a page (`tldr {{command}}`) but the referenced command doesn't have a (translated) page.     
# - Check if a page is misplaced. 
#   A page is marked as misplaced when the page isn’t inside a folder in the list of supported platforms.
# - Check if a page is outdated. 
#   A page is marked as outdated when the number of commands differ from the number of commands in the English page or the contents of the commands differ from the English page.
# - Check if a page is missing as English page (n/a for English).
#   A page is marked as missing when the filename can't be found as English page.
# - Check if a page is missing in the translation (n/a for English).
#   A page is marked as missing when the filename can't be found as translated page.
# - Run the markdownlint and tldr-lint.

# Usage: ./check-pages.sh [-l language_id] [-c check_names] [-v]
#   - language_id (optional): Specify a language identifier (e.g., 'id', 'fr') to filter results for a specific language.
#   - check_names (optional): Provide an array splitted by "," to only run specific checks [missing_tldr_page,misplaced_page,outdated_page,missing_english_page,missing_translated_page,lint]
#   - Adding -v enables verbose logging.

ROOT_DIR="${TLDR_ROOT:-./tldr}"
PLATFORMS=("android" "common" "linux" "openbsd" "freebsd" "netbsd" "osx" "sunos" "windows")

# shellcheck disable=SC2016
COMMAND_REGEX='^`[^`]\+`$'
CHECK_NAMES="missing_tldr_page,misplaced_page,outdated_page,missing_english_page,missing_translated_page,lint"
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
MISPLACED_OUTPUT_FILE="$OUTPUT_DIR/misplaced${LANGUAGE_ID:+-$LANGUAGE_ID}-pages.txt"
OUTDATED_BASED_ON_COMMAND_CONTENTS_FILE="$OUTPUT_DIR/outdated${LANGUAGE_ID:+-$LANGUAGE_ID}-pages-based-on-command-contents.txt"
OUTDATED_BASED_ON_COMMAND_COUNT_FILE="$OUTPUT_DIR/outdated${LANGUAGE_ID:+-$LANGUAGE_ID}-pages-based-on-command-count.txt"
MISSING_ENGLISH_OUTPUT_FILE="$OUTPUT_DIR/missing-english${LANGUAGE_ID:+-$LANGUAGE_ID}-pages.txt"
MISSING_TRANSLATED_OUTPUT_FILE="$OUTPUT_DIR/missing-translated${LANGUAGE_ID:+-$LANGUAGE_ID}-pages.txt"
LINT_FILE="$OUTPUT_DIR/lint-errors${LANGUAGE_ID:+-$LANGUAGE_ID}.txt"

OUTPUT_FILES=( "$MISSING_TLDR_OUTPUT_FILE" "$MISPLACED_OUTPUT_FILE" "$OUTDATED_BASED_ON_COMMAND_CONTENTS_FILE" "$OUTDATED_BASED_ON_COMMAND_COUNT_FILE" "$MISSING_ENGLISH_OUTPUT_FILE" "$MISSING_TRANSLATED_OUTPUT_FILE" "$LINT_FILE" )

for OUTPUT_FILE in  "${OUTPUT_FILES[@]}"; do
  rm -rf "$OUTPUT_FILE"
  touch "$OUTPUT_FILE"
done

# Create an array of files to loop over
folder_path="$ROOT_DIR/pages${LANGUAGE_ID:+.$LANGUAGE_ID}"
mapfile -t files < <(find "$folder_path" -type f -name "*.md" | sort -u)

if [ ! -e "$folder_path" ]; then
  echo "The specified path does not exist: $folder_path"
  exit 1
fi

get_english_file() {
  local file="$1"

  echo "./tldr/pages${file#./tldr/pages."$LANGUAGE_ID"}"
}

get_translated_file() {
  local file="$1"

  echo "./tldr/pages.$LANGUAGE_ID${file#./tldr/pages}"
}

get_platform() {
  local file="$1"

  echo "$file" | awk -F/ '{print $(NF-1)}'
}

get_filepath_without_tldr() {
  local file="$1"

  echo "${file#./tldr/}"
}

count_commands() {
  local file="$1"

  grep -c "$COMMAND_REGEX" "$file"
}

strip_commands() {
  local file="$1"

  local stripped_commands=()
  
  mapfile -t stripped_commands < <(
    grep "$COMMAND_REGEX" "$file" | 
    sed 's/{{[^}]*}}/{{}}/g' | 
    sed 's/<[^>]*>//g' | 
    sed 's/([^)]*)//g' | 
    sed 's/"[^"]*"/""/g' | 
    sed "s/'[^']*'//g" | 
    sed 's/`//g'
  )

  printf "%s\n" "${stripped_commands[*]}"
}

check_missing_tldr_page() {
  local file="$1"
  
  while IFS= read -r line; do
    line="${line#\`tldr }" # Remove "`tldr " prefix
    line="${line%\`}"    # Remove the last backtick

    command=$(echo "$line" | sed -E 's/(.*) -[^ ] [^ ]+/\1/')    # Strip off "-p linux" from "wget -p common".
    command=$(echo "$command" | sed -E 's/-[^ ] [^ ]+ (.*)/\1/') # Strip off "-p linux" from "-p linux awk".
    command="${command// /-}"

    if ! [[ $command =~ ^-[^[:space:]] ]] && ! [[ $command =~ \{\{.*\}\} ]]; then # Exclude -p / -u / -o (tldr -u) commands and {{commands}}.
      local missing=true
      local filename="${command,,}"
      for platform in "${PLATFORMS[@]}"; do
        if [ -f "$folder_path/$platform/$filename.md" ]; then
          missing=false
          break
        fi
      done

      if [ "$missing" = true ]; then
        local filepath
        filepath=$(get_filepath_without_tldr "$file")

        echo "$command does not exist yet! Command referenced in $filepath" >> "$MISSING_TLDR_OUTPUT_FILE"
      fi
    fi
  done
}

check_misplaced_page() {
  local file="$1"
  local platform
  platform=$(get_platform "$file")

  if [[ ! " ${PLATFORMS[*]} " =~ $platform ]]; then
    local filepath
    filepath=$(get_filepath_without_tldr "$file")

    echo "$filepath" >> "$MISPLACED_OUTPUT_FILE"
  fi
}

check_outdated_page() {
  local file="$1"
  local english_file="$2"

  if [ ! -f "$english_file" ]; then
    return 1
  fi

  local english_commands
  local commands
  english_commands=$(count_commands "$english_file")
  commands=$(count_commands "$file")
  
  english_commands_as_string=$(strip_commands "$english_file")
  commands_as_string=$(strip_commands "$file")

  local filepath
  filepath=$(get_filepath_without_tldr "$file")

  if [ "$english_commands" != "$commands" ]; then
    echo "$filepath" >> "$OUTDATED_BASED_ON_COMMAND_COUNT_FILE"
  elif [ "$english_commands_as_string" != "$commands_as_string" ]; then
    echo "$filepath" >> "$OUTDATED_BASED_ON_COMMAND_CONTENTS_FILE"
  fi
}

check_missing_english_page() {
  local file="$1"
  local english_file="$2"

  if [ ! -f "$english_file" ]; then
    local filepath
    filepath=$(get_filepath_without_tldr "$file")

    echo "$filepath" >> "$MISSING_ENGLISH_OUTPUT_FILE"
  fi
}

check_missing_translated_page() {
  local file="$1"
  local translated_file="$2"

  if [ ! -f "$translated_file" ]; then
    local filepath
    filepath=$(get_filepath_without_tldr "$translated_file")

    echo "$filepath" >> "$MISSING_TRANSLATED_OUTPUT_FILE"
  fi
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

if [[ " ${CHECK_NAMES[*]} " =~ " lint " ]]; then
  lint "$folder_path"
fi

for file in "${files[@]}"; do
  if [ -n "$LANGUAGE_ID" ]; then
    english_file=$(get_english_file "$file")
  fi

  for check_name in "${CHECK_NAMES[@]}"; do
    case "$check_name" in
        "missing_tldr_page")
            # shellcheck disable=SC2016
            grep -o '`tldr \(.*\)`$' "$file" | check_missing_tldr_page "$file"
            ;;
        "misplaced_page")
            check_misplaced_page "$file"
            ;;
        "outdated_page")
            if [ -n "$english_file" ]; then
              check_outdated_page "$file" "$english_file"
            fi
            ;;
        "missing_english_page")
            if [ -n "$english_file" ]; then
              check_missing_english_page "$file" "$english_file"
            fi
            ;;
    esac
  done
done

if [ -n "$LANGUAGE_ID" ] && [[ " ${CHECK_NAMES[*]} " =~ " missing_translated_page " ]]; then
  mapfile -t english_files < <(find "$ROOT_DIR/pages" -type f -name "*.md" | sort -u)
  for english_file in "${english_files[@]}"; do
    translated_file=$(get_translated_file "$english_file")
    check_missing_translated_page "$english_file" "$translated_file"
  done
fi

for OUTPUT_FILE in  "${OUTPUT_FILES[@]}"; do
  sort -o "$OUTPUT_FILE" "$OUTPUT_FILE"
done
