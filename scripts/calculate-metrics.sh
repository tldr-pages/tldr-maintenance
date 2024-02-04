#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

# This script is used by the GitHub Action `calculate-metrics`.

total_pages=$(find ./tldr/pages* -type f | wc -l)
total_non_english_pages=$(find ./tldr/pages.* -type f | wc -l)
total_english_pages=$(find ./tldr/pages -type f | wc -l)

total_translation_folders=$(find ./tldr -maxdepth 1 -type d -name "pages.*" | wc -l)
total_pages_need_translation=$((total_english_pages * total_translation_folders))
total_tldr_commands=$(find ./tldr/pages* -type f -exec grep -o '`tldr [^`]*' {} + | awk -F':' '{print $2}' | sort -u | wc -l)
total_unique_non_english_pages=$(find ./tldr/pages.* -type f | awk -F/ '{print $NF}' | sort -u | wc -l)

EXIT_CODE=0

run_python_script() {
  local script_name="$1"

  ./tldr/scripts/${script_name}.py -Sn > $script_name.txt
  sed 's/\x1b\[[0-9;]*m//g' $script_name.txt > $script_name.txt.tmp
  mv $script_name.txt.tmp $script_name.txt
  sort -o $script_name.txt $script_name.txt
}

run_python_script "set-more-info-link"
run_python_script "set-alias-page"

if [[ "$OSTYPE" != "darwin"* ]]; then
  (cd tldr && ./scripts/wrong-filename.sh && mv ./inconsistent-filenames.txt ../inconsistent-filenames.txt)
fi

./scripts/check-pages.sh

count_and_display() {
  local file="$1"
  local message="$2"
  local count
  count=$(wc -l < "$file")

  echo "$count $message in ${file#./}."
}

uniqify_file() {
  sort -u "$1" -o "$1"
}

grep_count_and_display() {
  local grep_string="$1"
  local input_file="$2"
  local output_file="$3"
  local message="$4"

  if [ ! -e "$input_file" ]; then
    return
  fi

  grep "$grep_string" $input_file > $output_file
  count_and_display "$output_file" "$message"
}

grep_count_and_display "pages/" "./inconsistent-filenames.txt" "./check-pages/inconsistent-filenames.txt" "inconsistent filename(s)"
grep_count_and_display "pages.en/" "./set-more-info-link.txt" "./check-pages/malformed-more-info-link-pages.txt" "malformed more info link page(s)"

grep "does not exist yet!" ./check-pages/missing-tldr-pages.txt | sed 's/Command referenced in.*$//' > ./check-pages/missing-tldr-commands.txt
uniqify_file ./check-pages/missing-tldr-commands.txt

count_and_display "./check-pages/missing-tldr-commands.txt" "missing TLDR page(s)"
count_and_display "./check-pages/misplaced-pages.txt" "misplaced page(s)"
count_and_display "./check-pages/lint-errors.txt" "linter error(s)"

printf -- '-%.0s' {1..100}; echo

folders=$(find ./tldr -type d -name "pages.*" | sort -u)
for folder in $folders; do
  number_of_platforms="$(find $folder -mindepth 1 -type d | wc -l)"
  if [[ "$number_of_platforms" -le 2 ]]; then
    echo "Skipping ${folder##*/} since it only has $number_of_platforms supported platform(s)."
    printf -- '-%.0s' {1..100}; echo
    continue
  fi

  folder_suffix="${folder##*/pages.}"

  ./scripts/check-pages.sh -l "$folder_suffix"

  grep_count_and_display "pages.$folder_suffix/" "./inconsistent-filenames.txt" "./check-pages.$folder_suffix/inconsistent-$folder_suffix-filenames.txt" "inconsistent filename(s)"
  grep_count_and_display "pages.$folder_suffix/" "./set-more-info-link.txt" "./check-pages.$folder_suffix/malformed-or-outdated-more-info-link-$folder_suffix-pages.txt" "malformed or outdated more info link page(s)"
  grep_count_and_display "pages.$folder_suffix/" "./set-alias-page.txt" "./check-pages.$folder_suffix/missing-$folder_suffix-alias-pages.txt" "missing alias page(s)"

  grep "does not exist yet!" ./check-pages.$folder_suffix/missing-tldr-$folder_suffix-pages.txt | sed 's/Command referenced in.*$//' > ./check-pages.$folder_suffix/missing-tldr-$folder_suffix-commands.txt
  uniqify_file ./check-pages.$folder_suffix/missing-tldr-$folder_suffix-commands.txt

  count_and_display "./check-pages.$folder_suffix/missing-tldr-$folder_suffix-commands.txt" "missing TLDR page(s)"
  count_and_display "./check-pages.$folder_suffix/misplaced-$folder_suffix-pages.txt" "misplaced page(s)"

  grep "based on number of commands" ./check-pages.$folder_suffix/outdated-$folder_suffix-pages.txt | sed 's/ (.*$//' > ./check-pages.$folder_suffix/outdated-$folder_suffix-pages-based-on-command-count.txt
  grep "based on the commands itself" ./check-pages.$folder_suffix/outdated-$folder_suffix-pages.txt  | sed 's/ (.*$//' > ./check-pages.$folder_suffix/outdated-$folder_suffix-pages-based-on-command-contents.txt

  count_and_display "./check-pages.$folder_suffix/outdated-$folder_suffix-pages-based-on-command-count.txt" "outdated page(s) based on number of commands"
  count_and_display "./check-pages.$folder_suffix/outdated-$folder_suffix-pages-based-on-command-contents.txt" "outdated page(s) based on the commands itself"
  count_and_display "./check-pages.$folder_suffix/missing-english-$folder_suffix-pages.txt" "missing English page(s)"
  count_and_display "./check-pages.$folder_suffix/missing-translated-$folder_suffix-pages.txt" "missing translated page(s)"
  count_and_display "./check-pages.$folder_suffix/lint-errors-$folder_suffix.txt" "linter error(s)"

  printf -- '-%.0s' {1..100}; echo
done

merge_files_and_calculate_total() {
  local files_pattern="$1"
  local merge_file="$2"

  for file in $(find . -type f -path $files_pattern | sort -u); do
    cat "$file"
  done > "$merge_file"
  uniqify_file "$merge_file"

  wc -l < "$merge_file"
}

calculate_percentage() {
  local part_of_total="$1"
  local total="$2"

  if [ "$part_of_total" -gt 0 ] && [ "$total" -gt 0 ]; then
    echo $((part_of_total * 100 / total))
  else
    echo 0
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
calculate_and_display '*/check-pages*/malformed*more-info-link*pages.txt' "./malformed-or-outdated-more-info-link-pages.txt" "$total_pages" "malformed or outdated more info link page(s)"
calculate_and_display '*/check-pages*/missing*alias-pages.txt' "./missing-alias-pages.txt" "" "missing alias page(s)"
calculate_and_display '*/check-pages*/missing-tldr*commands.txt' "./missing-tldr-commands.txt" "$total_tldr_commands" "missing TLDR commands"
calculate_and_display '*/check-pages*/misplaced*pages.txt' "./misplaced-pages.txt" "$total_pages" "misplaced page(s)"
calculate_and_display '*/check-pages*/outdated*pages-based-on-command-count.txt' "./outdated-pages-based-on-command-count.txt" "$total_non_english_pages" "outdated page(s) based on number of commands"
calculate_and_display '*/check-pages*/outdated*pages-based-on-command-contents.txt' "./outdated-pages-based-on-command-contents.txt" "$total_non_english_pages" "outdated page(s) based on the commands itself"
calculate_and_display '*/check-pages*/missing-english*pages.txt' "./missing-english-pages.txt" "$total_unique_non_english_pages" "missing English page(s)"
calculate_and_display '*/check-pages*/missing-translated*pages.txt' "./missing-translated-pages.txt" "$total_pages_need_translation" "missing translated page(s)"
calculate_and_display '*/check-pages*/lint-errors*.txt' "./lint-errors.txt" "" "lint error(s)"

find . -type f \( -path '*/check-pages*/*.txt' -o -path '*.txt' \) -size 0 -exec rm -f {} \;

exit $EXIT_CODE
