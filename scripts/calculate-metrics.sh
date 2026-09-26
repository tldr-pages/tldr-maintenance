#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# shellcheck disable=SC2329 # The jobs are invoked through start_job.

# Calculate the metrics described in metrics.tsv for English and every language, used by the GitHub Action `calculate-metrics`.
# The results are written to check-pages[.<language>]/<metric>.txt and the totals to <metric>.txt (when not empty).
# A summary is written to stdout and, machine-readable, to summary.tsv.
# Exits with 1 when one of the checks failed to run.

set -o pipefail

SCRIPTS_DIR="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=scripts/_common.sh
source "$SCRIPTS_DIR/_common.sh"

# Don't write __pycache__ folders into the tldr repository.
export PYTHONDONTWRITEBYTECODE=1

# The job that writes a result of the tldr scripts to RESULTS_DIR, for the sources in metrics.tsv.
declare -A TLDR_SCRIPT_JOB_OF=(
  [set-more-info-link]=run_set_more_info_link
  [set-see-also-added]=run_set_see_also
  [set-see-also-updated]=run_set_see_also
  [set-alias-page]=run_set_alias_page
  [set-page-title]=run_set_page_title
  [wrong-filename]=run_wrong_filename
)

if [ ! -d "$TLDR_ROOT_DIR/pages" ]; then
  echo "The tldr repository isn't found in $TLDR_ROOT_DIR, run \`git submodule update --init\` or set TLDR_ROOT." >&2
  exit 1
fi

metrics_output=$(list_metrics) || exit 1
mapfile -t METRICS <<< "$metrics_output"

# The tldr script jobs to run.
TLDR_SCRIPT_JOBS=()
for metric in "${METRICS[@]}"; do
  IFS=$'\t' read -r id _ source _ <<< "$metric"
  if [ "$source" = "check-pages" ]; then
    continue
  fi
  job="${TLDR_SCRIPT_JOB_OF[$source]}"
  if [ -z "$job" ]; then
    echo "The source $source of the metric $id in metrics.tsv isn't known, see TLDR_SCRIPT_JOB_OF." >&2
    exit 1
  fi
  if [[ " ${TLDR_SCRIPT_JOBS[*]} " != *" $job "* ]]; then
    TLDR_SCRIPT_JOBS+=("$job")
  fi
done

LANGUAGE_IDS=()
for folder in "$TLDR_ROOT_DIR"/pages.*; do
  # pages.en is a symlink to the English pages.
  if [ -d "$folder" ] && [ ! -L "$folder" ]; then
    LANGUAGE_IDS+=("${folder##*/pages.}")
  fi
done

MAX_JOBS=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
JOBS_DIR=$(mktemp -d) || exit 1
trap 'rm -rf "$JOBS_DIR"' EXIT
RESULTS_DIR="$JOBS_DIR/results"
mkdir -p "$RESULTS_DIR" || exit 1
JOB_FAILED=false

# Remove the results of a previous run.
rm -rf ./check-pages ./check-pages.* ./summary.tsv
for metric in "${METRICS[@]}"; do
  IFS=$'\t' read -r id _ <<< "$metric"
  rm -f "./$id.txt"
done

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

# Run a script of the tldr repository in dry-run synchronization mode.
# The colors and the given text (with sed) are removed from its output.
run_tldr_sync_script() {
  local script_name="$1"
  local remove_text="$2"
  shift 2

  "$TLDR_ROOT_DIR/scripts/$script_name.py" -Sn "$@" | sed -e 's/\x1b\[[0-9;]*m//g' -e "$remove_text"
}

run_set_more_info_link() {
  run_tldr_sync_script "set-more-info-link" 's/ link would be.*$//' > "$RESULTS_DIR/set-more-info-link"
}

run_set_see_also() {
  # A missing "See also" mention would be "added", a malformed or outdated one would be "updated".
  run_tldr_sync_script "set-see-also" 's/ see also would be \(added\|updated\).*$/ \1/' > "$JOBS_DIR/set-see-also" || return 1
  sed -n 's/ added$//p' "$JOBS_DIR/set-see-also" > "$RESULTS_DIR/set-see-also-added" &&
    sed '/ added$/d; s/ updated$//' "$JOBS_DIR/set-see-also" > "$RESULTS_DIR/set-see-also-updated"
}

run_set_alias_page() {
  {
    run_tldr_sync_script "set-alias-page" 's/ page would be.*$//' &&
      run_tldr_sync_script "set-alias-page" 's/ page would be.*$//' -i
  } > "$RESULTS_DIR/set-alias-page"
}

run_set_page_title() {
  run_tldr_sync_script "set-page-title" 's/ title would be.*$//' > "$RESULTS_DIR/set-page-title"
}

run_wrong_filename() {
  local pages_dirs="$JOBS_DIR/pages-dirs"
  local folder script

  # wrong-filename.py checks the pages* folders in the current directory and writes its results there.
  # Run it in a separate directory with links to the pages folders, so nothing is written to the tldr repository.
  # The pages.en symlink is skipped, since it would check the English pages twice.
  mkdir -p "$pages_dirs" || return 1
  for folder in "$TLDR_ROOT_DIR"/pages "${LANGUAGE_IDS[@]/#/$TLDR_ROOT_DIR/pages.}"; do
    ln -s "$(realpath "$folder")" "$pages_dirs/${folder##*/}" || return 1
  done
  script="$(realpath "$TLDR_ROOT_DIR/scripts/wrong-filename.py")"
  (cd "$pages_dirs" && "$script") || return 1
  mv "$pages_dirs/inconsistent-filenames.txt" "$RESULTS_DIR/wrong-filename"
}

# The tldr scripts take longer than the checks of a language, so they are started first.
for job in "${TLDR_SCRIPT_JOBS[@]}"; do
  start_job "$job" "$job"
done
start_job "en" "$SCRIPTS_DIR/check-pages.sh"
for language_id in "${LANGUAGE_IDS[@]}"; do
  start_job "$language_id" "$SCRIPTS_DIR/check-pages.sh" -l "$language_id"
done
wait

# Print the result directories of the languages a metric applies to ("all" or "translations").
list_result_dirs() {
  local languages="$1"
  local language_id

  if [ "$languages" = "all" ]; then
    echo "./check-pages"
  fi
  for language_id in "${LANGUAGE_IDS[@]}"; do
    echo "./check-pages.$language_id"
  done
}

# Write the results of a tldr script for a language.
# The results contain the path of a page, e.g. "pages.fr/common/tar.md" or "Inconsistency found in file: pages/...".
write_tldr_script_results() {
  local source="$1"
  local language_id="$2"
  local output_file="$3"
  local results_file="$RESULTS_DIR/$source"

  if [ ! -f "$results_file" ]; then
    echo "Error: the results of $source are missing." >&2
    JOB_FAILED=true
    return
  fi

  grep -E "(^|[ :])pages${language_id:+\\.$language_id}/" "$results_file" | sort -u > "$output_file"
  # grep exits with 1 when no line matches.
  if [ "${PIPESTATUS[0]}" -gt 1 ]; then
    JOB_FAILED=true
  fi
}

# Display the number of results of every metric that applies to the language.
display_language() {
  local language_id="$1"
  local output_dir="./check-pages${language_id:+.$language_id}"
  local metric id languages source label output_file count

  display_job "${language_id:-en}"

  for metric in "${METRICS[@]}"; do
    IFS=$'\t' read -r id languages source _ _ label <<< "$metric"
    if [ "$languages" != "all" ] && [ -z "$language_id" ]; then
      continue
    fi

    output_file="$output_dir/$id.txt"
    if [ "$source" != "check-pages" ]; then
      mkdir -p "$output_dir"
      write_tldr_script_results "$source" "$language_id" "$output_file"
    fi

    if [ -f "$output_file" ]; then
      count=$(wc -l < "$output_file")
      echo "$count $label in ${output_file#./}."
      printf '%s\t%s\t%s\t-\t-\n' "${language_id:-en}" "$id" "$count" >> ./summary.tsv
    else
      echo "Error: ${output_file#./} is missing." >&2
      JOB_FAILED=true
    fi
  done

  printf -- '_%.0s' {1..100}; echo
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

# Print the sum of a total of check-pages[.<language>]/totals.tsv over the languages a metric applies to.
sum_totals() {
  local total_name="$1"
  local languages="$2"
  local sum=0 value dir

  while IFS= read -r dir; do
    value=$(awk -F '\t' -v name="$total_name" '$1 == name { print $2; found = 1 } END { exit !found }' "$dir/totals.tsv" 2>/dev/null) || return 1
    sum=$((sum + value))
  done < <(list_result_dirs "$languages")

  echo "$sum"
}

# Merge the results of all languages and display the total.
display_total() {
  local id="$1"
  local languages="$2"
  local denominator="$3"
  local label="$4"
  local results=() total dir denominator_total percentage

  while IFS= read -r dir; do
    if [ -f "$dir/$id.txt" ]; then
      results+=("$dir/$id.txt")
    fi
  done < <(list_result_dirs "$languages")
  cat /dev/null "${results[@]}" | sort -u > "./$id.txt"
  total=$(wc -l < "./$id.txt")

  if [ "$denominator" != "-" ] && denominator_total=$(sum_totals "$denominator" "$languages"); then
    percentage=$(calculate_percentage "$total" "$denominator_total")
    echo "Total $label: $total/$denominator_total - $percentage%"
    printf 'total\t%s\t%s\t%s\t%s\n' "$id" "$total" "$denominator_total" "$percentage" >> ./summary.tsv
  else
    # A missing totals.tsv (e.g. when a check failed) is already reported.
    echo "Total $label: $total"
    printf 'total\t%s\t%s\t-\t-\n' "$id" "$total" >> ./summary.tsv
  fi
}

printf 'language\tmetric\tresults\ttotal\tpercentage\n' > ./summary.tsv

printf "# Metrics for tldr\n\n"

for job in "${TLDR_SCRIPT_JOBS[@]}"; do
  display_job "$job"
done

display_language ""
for language_id in "${LANGUAGE_IDS[@]}"; do
  display_language "$language_id"
done

while IFS= read -r dir; do
  if [ ! -f "$dir/totals.tsv" ]; then
    echo "Error: ${dir#./}/totals.tsv is missing, so the percentages are incomplete." >&2
    JOB_FAILED=true
  fi
done < <(list_result_dirs all)

for metric in "${METRICS[@]}"; do
  IFS=$'\t' read -r id languages _ denominator _ label <<< "$metric"
  display_total "$id" "$languages" "$denominator" "$label"
done

# Remove the empty totals, so only totals with results are uploaded as release assets.
for metric in "${METRICS[@]}"; do
  IFS=$'\t' read -r id _ <<< "$metric"
  if [ ! -s "./$id.txt" ]; then
    rm -f "./$id.txt"
  fi
done

if [ "$JOB_FAILED" = true ]; then
  exit 1
fi
