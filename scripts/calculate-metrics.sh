#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

# This script is used by the GitHub Action `calculate-metrics`.
# Exit codes: 0 when no issues are found, 1 when issues are found and 2 when one of the checks failed to run.

# shellcheck source=scripts/_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

total_pages=$(find ./tldr/pages* -type f | wc -l)
total_non_english_pages=$(find ./tldr/pages.* -type f | wc -l)
total_english_pages=$(find ./tldr/pages -type f | wc -l)

total_translation_folders=$(find ./tldr -maxdepth 1 -type d -name "pages.*" | wc -l)
total_pages_need_translation=$((total_english_pages * total_translation_folders))
# shellcheck disable=SC2016
total_tldr_pages=$(find ./tldr/pages* -type f -exec grep -o '`tldr [^`]*' {} + | wc -l)
total_unique_non_english_pages=$(find ./tldr/pages.* -type f | awk -F/ '{print $NF}' | sort -u | wc -l)

# Only translated pages whose English page has a "See also" mention need a (translated) "See also" mention.
mapfile -t english_pages < <(find ./tldr/pages -type f -name "*.md" -readable | sort -u)
mapfile -t english_pages_with_see_also_mention < <(list_pages_with_see_also_mention "${english_pages[@]}" | sed 's|^\./tldr/pages/||')
total_pages_need_see_also_mention=0
# Every "See also" mention references one or more pages, count the references of all languages.
total_see_also_references=0
for folder in $(find ./tldr -maxdepth 1 -type d -name "pages*" | sort); do
  language_id="${folder##*/pages}"
  language_id="${language_id#.}"

  see_also_prefix=$(get_see_also_prefix "${language_id:-en}")
  if [ -z "$see_also_prefix" ]; then
    continue
  fi

  if [ -n "$language_id" ]; then
    for page in "${english_pages_with_see_also_mention[@]}"; do
      if [ -f "$folder/$page" ]; then
        total_pages_need_see_also_mention=$((total_pages_need_see_also_mention + 1))
      fi
    done
  fi

  mapfile -t pages < <(find "$folder" -type f -name "*.md" -readable | sort -u)
  if [ "${#pages[@]}" -gt 0 ]; then
    references=$(list_see_also_references "$see_also_prefix" "${pages[@]}" | wc -l)
    total_see_also_references=$((total_see_also_references + references))
  fi
done

EXIT_CODE=0
JOB_FAILED=false
MAX_JOBS=$(nproc)
JOBS_DIR=$(mktemp -d)
trap 'rm -rf "$JOBS_DIR"' EXIT

# Run a command as a named background job, with at most MAX_JOBS jobs at the same time.
# Its output and exit code are stored, so they can be displayed together with the results.
start_job() {
  local name="$1"
  shift

  while [ "$(jobs -rp | wc -l)" -ge "$MAX_JOBS" ]; do
    wait -n
  done

  {
    "$@"
    echo "$?" > "$JOBS_DIR/$name.status"
  } > "$JOBS_DIR/$name.log" 2>&1 &
}

# Display the output of a job and report it when it failed.
display_job() {
  local name="$1"
  local status

  cat "$JOBS_DIR/$name.log"

  status=$(cat "$JOBS_DIR/$name.status" 2>/dev/null)
  if [ "$status" != 0 ]; then
    echo "Error: the $name job failed with exit code ${status:-unknown}." >&2
    JOB_FAILED=true
  fi
}

# Run a Python script of the tldr repository in dry-run synchronization mode.
# The colors and the given text (with sed) are removed from its output.
# shellcheck disable=SC2329 # Invoked by run_python_scripts.
run_python_script() {
  local script_name="$1"
  local remove_text="$2"
  shift 2

  ./tldr/scripts/"$script_name.py" -Sn "$@" | sed -e 's/\x1b\[[0-9;]*m//g' -e "$remove_text"
}

# shellcheck disable=SC2329 # Invoked with start_job.
run_python_scripts() (
  set -o pipefail
  status=0

  run_python_script "set-more-info-link" 's/ link would be.*$//' > "set-more-info-link.txt" || status=1
  sort -u "set-more-info-link.txt" -o "set-more-info-link.txt"

  # A missing "See also" mention would be "added", a malformed or outdated one would be "updated".
  run_python_script "set-see-also" 's/ see also would be \(added\|updated\).*$/ \1/' > "set-see-also.txt" || status=1
  sed -n 's/ added$//p' "set-see-also.txt" | sort -u > "set-see-also-added.txt"
  sed '/ added$/d; s/ updated$//' "set-see-also.txt" | sort -u > "set-see-also-updated.txt"

  run_python_script "set-alias-page" 's/ page would be.*$//' > "set-alias-page.txt" || status=1
  run_python_script "set-alias-page" 's/ page would be.*$//' -i >> "set-alias-page.txt" || status=1
  sort -u "set-alias-page.txt" -o "set-alias-page.txt"

  run_python_script "set-page-title" 's/ title would be.*$//' > "set-page-title.txt" || status=1
  sort -u "set-page-title.txt" -o "set-page-title.txt"

  # wrong-filename.py checks the pages in the current directory and writes its results to that directory.
  # It also finds the English pages through the `pages.en` symlink, these duplicates are skipped.
  rm -f "./tldr/inconsistent-filenames.txt"
  if (cd ./tldr && ./scripts/wrong-filename.py); then
    sed '/file: pages\.en\//d' "./tldr/inconsistent-filenames.txt" | sort -u > "inconsistent-filenames.txt"
  else
    status=1
  fi
  rm -f "./tldr/inconsistent-filenames.txt"

  exit "$status"
)

# Run the Python scripts and the checks for English and every language in parallel, the results are displayed below.
folders=$(find ./tldr -type d -name "pages.*" | sort -u)
start_job "python" run_python_scripts
start_job "en" ./scripts/check-pages.sh -v
for folder in $folders; do
  start_job "${folder##*/pages.}" ./scripts/check-pages.sh -l "${folder##*/pages.}" -v
done
wait

count_and_display() {
  local file="$1"
  local message="$2"
  local count
  count=$(wc -l < "$file")

  echo "$count $message in ${file#./}."
}

grep_count_and_display() {
  local grep_string="$1"
  local input_file="$2"
  local output_file="$3"
  local message="$4"

  if [ ! -e "$input_file" ]; then
    return
  fi

  grep -F "$grep_string" "$input_file" > "$output_file"
  count_and_display "$output_file" "$message"
}

printf "# Metrics for tldr\n\n"

display_job "python"
display_job "en"

grep_count_and_display "pages/" "./inconsistent-filenames.txt" "./check-pages/inconsistent-filenames.txt" "inconsistent filename(s)"
grep_count_and_display "pages.en/" "./set-more-info-link.txt" "./check-pages/malformed-more-info-link-pages.txt" "malformed more info link page(s)"

count_and_display "./check-pages/missing-tldr-pages.txt" "missing TLDR page(s)"
count_and_display "./check-pages/missing-see-also-referenced-pages.txt" "missing see also page(s)"
count_and_display "./check-pages/misplaced-pages.txt" "misplaced page(s)"
count_and_display "./check-pages/lint-errors.txt" "linter error(s)"

printf -- '_%.0s' {1..100}; echo

for folder in $folders; do
  folder_suffix="${folder##*/pages.}"

  display_job "$folder_suffix"

  grep_count_and_display "pages.$folder_suffix/" "./inconsistent-filenames.txt" "./check-pages.$folder_suffix/inconsistent-$folder_suffix-filenames.txt" "inconsistent filename(s)"
  grep_count_and_display "pages.$folder_suffix/" "./set-more-info-link.txt" "./check-pages.$folder_suffix/malformed-or-outdated-more-info-link-$folder_suffix-pages.txt" "malformed or outdated more info link page(s)"
  grep_count_and_display "pages.$folder_suffix/" "./set-see-also-updated.txt" "./check-pages.$folder_suffix/malformed-or-outdated-see-also-mentions-$folder_suffix-pages.txt" "malformed or outdated see also mention(s)"
  grep_count_and_display "pages.$folder_suffix/" "./set-see-also-added.txt" "./check-pages.$folder_suffix/missing-see-also-mentions-$folder_suffix-pages.txt" "missing see also mention(s)"
  grep_count_and_display "pages.$folder_suffix/" "./set-alias-page.txt" "./check-pages.$folder_suffix/missing-$folder_suffix-alias-pages.txt" "missing alias page(s)"
  grep_count_and_display "pages.$folder_suffix/" "./set-page-title.txt" "./check-pages.$folder_suffix/mismatched-$folder_suffix-page-titles.txt" "mismatched page title(s)"

  count_and_display "./check-pages.$folder_suffix/missing-tldr-$folder_suffix-pages.txt" "missing TLDR page(s)"
  count_and_display "./check-pages.$folder_suffix/missing-see-also-referenced-$folder_suffix-pages.txt" "missing see also page(s)"
  count_and_display "./check-pages.$folder_suffix/misplaced-$folder_suffix-pages.txt" "misplaced page(s)"
  count_and_display "./check-pages.$folder_suffix/outdated-$folder_suffix-pages-based-on-command-count.txt" "outdated page(s) based on number of commands"
  count_and_display "./check-pages.$folder_suffix/outdated-$folder_suffix-pages-based-on-command-contents.txt" "outdated page(s) based on the commands itself"
  count_and_display "./check-pages.$folder_suffix/outdated-$folder_suffix-pages-based-on-header-line-count.txt" "outdated page(s) based on number of header lines"
  count_and_display "./check-pages.$folder_suffix/missing-english-$folder_suffix-pages.txt" "missing English page(s)"
  count_and_display "./check-pages.$folder_suffix/missing-translated-$folder_suffix-pages.txt" "missing translated page(s)"
  count_and_display "./check-pages.$folder_suffix/lint-errors-$folder_suffix.txt" "linter error(s)"

  printf -- '_%.0s' {1..100}; echo
done

rm -f "./set-more-info-link.txt" "./set-see-also.txt" "./set-see-also-added.txt" "./set-see-also-updated.txt" "./set-alias-page.txt" "./set-page-title.txt"

merge_files_and_calculate_total() {
  local files_pattern="$1"
  local merge_file="$2"
  local files

  mapfile -t files < <(find ./check-pages* -type f -path "$files_pattern" | sort -u)
  cat /dev/null "${files[@]}" | sort -u > "$merge_file"

  wc -l < "$merge_file"
}

# Print the percentage with one decimal, rounded down so it only shows 100.0 when everything is affected.
calculate_percentage() {
  local part_of_total="$1"
  local total="$2"

  if [ "$total" -gt 0 ]; then
    awk -v part="$part_of_total" -v total="$total" 'BEGIN { printf "%.1f\n", int(part * 1000 / total) / 10 }'
  else
    echo "0.0"
  fi
}

calculate_and_display() {
  local files_pattern="$1"
  local output_file="$2"

  local total
  total=$(merge_files_and_calculate_total "$files_pattern" "$output_file")

  if [ "$total" -gt 0 ]; then
    EXIT_CODE=1
  fi

  if [ -n "$3" ]; then
    local percentage
    percentage=$(calculate_percentage "$total" "$3")
    echo "Total $4: $total/$3 - $percentage%"
  else
    echo "Total $4: $total"
  fi
}

calculate_and_display '*/check-pages*/inconsistent*filenames.txt' "./inconsistent-filenames.txt" "$total_pages" "inconsistent filename(s)"
calculate_and_display '*/check-pages*/malformed-or-outdated-more-info-link*pages.txt' "./malformed-or-outdated-more-info-link-pages.txt" "$total_pages" "malformed or outdated more info link page(s)"
calculate_and_display '*/check-pages*/malformed-or-outdated-see-also-mentions*pages.txt' "./malformed-or-outdated-see-also-mentions.txt" "$total_pages_need_see_also_mention" "malformed or outdated see also mention(s)"
calculate_and_display '*/check-pages*/missing-see-also-mentions*pages.txt' "./missing-see-also-mentions.txt" "$total_pages_need_see_also_mention" "missing see also mention(s)"
calculate_and_display '*/check-pages*/missing*alias-pages.txt' "./missing-alias-pages.txt" "" "missing alias page(s)"
calculate_and_display '*/check-pages*/mismatched*page-titles.txt' "./mismatched-page-titles.txt" "$total_unique_non_english_pages" "mismatched page title(s)"
calculate_and_display '*/check-pages*/missing-tldr*pages.txt' "./missing-tldr-pages.txt" "$total_tldr_pages" "missing TLDR page(s)"
calculate_and_display '*/check-pages*/missing-see-also-referenced*pages.txt' "./missing-see-also-referenced-pages.txt" "$total_see_also_references" "missing see also page(s)"
calculate_and_display '*/check-pages*/misplaced*pages.txt' "./misplaced-pages.txt" "$total_pages" "misplaced page(s)"
calculate_and_display '*/check-pages*/outdated*pages-based-on-command-count.txt' "./outdated-pages-based-on-command-count.txt" "$total_non_english_pages" "outdated page(s) based on number of commands"
calculate_and_display '*/check-pages*/outdated*pages-based-on-command-contents.txt' "./outdated-pages-based-on-command-contents.txt" "$total_non_english_pages" "outdated page(s) based on the commands itself"
calculate_and_display '*/check-pages*/outdated*pages-based-on-header-line-count.txt' "./outdated-pages-based-on-header-line-count.txt" "$total_non_english_pages" "outdated page(s) based on number of header lines"
calculate_and_display '*/check-pages*/missing-english*pages.txt' "./missing-english-pages.txt" "$total_unique_non_english_pages" "missing English page(s)"
calculate_and_display '*/check-pages*/missing-translated*pages.txt' "./missing-translated-pages.txt" "$total_pages_need_translation" "missing translated page(s)"
calculate_and_display '*/check-pages*/lint-errors*.txt' "./lint-errors.txt" "" "lint error(s)"

# Remove empty results, only in the directories this script writes to.
find . -maxdepth 1 -type f -name "*.txt" -size 0 -delete
find ./check-pages* -type f -name "*.txt" -size 0 -delete

if [ "$JOB_FAILED" = true ]; then
  exit 2
fi

exit $EXIT_CODE
