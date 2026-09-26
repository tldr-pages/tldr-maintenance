#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

# Calculate the metrics described in metrics.tsv for English and every language, used by the GitHub Action `calculate-metrics`.
# The results are written to check-pages[.<language>]/<metric>.txt, the totals to <metric>.txt and a summary to stdout.
# Exits with 1 when one of the checks failed to run.

set -o pipefail

SCRIPTS_DIR="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=scripts/_common.sh
source "$SCRIPTS_DIR/_common.sh"

mapfile -t METRICS < <(grep -v -e '^#' -e '^id	' -e '^$' "$SCRIPTS_DIR/metrics.tsv")
LANGUAGE_IDS=()
for folder in "$TLDR_ROOT_DIR"/pages.*; do
  # pages.en is a symlink to the English pages.
  if [ -d "$folder" ] && [ ! -L "$folder" ]; then
    LANGUAGE_IDS+=("${folder##*/pages.}")
  fi
done

MAX_JOBS=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
JOBS_DIR=$(mktemp -d)
RESULTS_DIR="$JOBS_DIR/results"
mkdir -p "$RESULTS_DIR"
trap 'rm -rf "$JOBS_DIR"' EXIT
JOB_FAILED=false

# Remove the results of a previous run.
rm -rf ./check-pages ./check-pages.*
for metric in "${METRICS[@]}"; do
  rm -f "./${metric%%	*}.txt"
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

# Run a script of the tldr repository in dry-run synchronization mode and write its output to a result.
# The colors and the given text (with sed) are removed from its output.
# shellcheck disable=SC2329 # Invoked by run_tldr_scripts.
run_tldr_sync_script() {
  local script_name="$1"
  local remove_text="$2"
  shift 2

  "$TLDR_ROOT_DIR/scripts/$script_name.py" -Sn "$@" | sed -e 's/\x1b\[[0-9;]*m//g' -e "$remove_text"
}

# Run the scripts of the tldr repository and write their results (used as source in metrics.tsv) to RESULTS_DIR.
# shellcheck disable=SC2329 # Invoked with start_job.
run_tldr_scripts() {
  local status=0
  local pages_dirs wrong_filename_script

  run_tldr_sync_script "set-more-info-link" 's/ link would be.*$//' > "$RESULTS_DIR/set-more-info-link" || status=1

  # A missing "See also" mention would be "added", a malformed or outdated one would be "updated".
  run_tldr_sync_script "set-see-also" 's/ see also would be \(added\|updated\).*$/ \1/' > "$RESULTS_DIR/set-see-also" || status=1
  sed -n 's/ added$//p' "$RESULTS_DIR/set-see-also" > "$RESULTS_DIR/set-see-also-added"
  sed '/ added$/d; s/ updated$//' "$RESULTS_DIR/set-see-also" > "$RESULTS_DIR/set-see-also-updated"

  {
    run_tldr_sync_script "set-alias-page" 's/ page would be.*$//' &&
      run_tldr_sync_script "set-alias-page" 's/ page would be.*$//' -i
  } > "$RESULTS_DIR/set-alias-page" || status=1

  run_tldr_sync_script "set-page-title" 's/ title would be.*$//' > "$RESULTS_DIR/set-page-title" || status=1

  # wrong-filename.py checks the pages* folders in the current directory and writes its results there.
  # Run it in a separate directory with links to the pages folders, so nothing is written to the tldr repository.
  # The pages.en symlink is skipped, since it would check the English pages twice.
  pages_dirs="$JOBS_DIR/pages-dirs"
  mkdir -p "$pages_dirs"
  for folder in "$TLDR_ROOT_DIR"/pages "${LANGUAGE_IDS[@]/#/$TLDR_ROOT_DIR/pages.}"; do
    ln -s "$(realpath "$folder")" "$pages_dirs/${folder##*/}"
  done
  wrong_filename_script="$(realpath "$TLDR_ROOT_DIR/scripts/wrong-filename.py")"
  (cd "$pages_dirs" && "$wrong_filename_script") || status=1
  mv "$pages_dirs/inconsistent-filenames.txt" "$RESULTS_DIR/wrong-filename" || status=1

  return "$status"
}

start_job "tldr-scripts" run_tldr_scripts
start_job "en" "$SCRIPTS_DIR/check-pages.sh" -v
for language_id in "${LANGUAGE_IDS[@]}"; do
  start_job "$language_id" "$SCRIPTS_DIR/check-pages.sh" -l "$language_id" -v
done

# Calculate the denominators of metrics.tsv while the jobs are running.
total_pages=0
total_non_english_pages=0
total_pages_need_translation=0
total_pages_need_see_also_mention=0
total_tldr_references=0
total_see_also_references=0

mapfile -t english_pages < <(list_pages "$TLDR_ROOT_DIR/pages")
# Only translated pages whose English page has a "See also" mention need a (translated) "See also" mention.
mapfile -t english_pages_with_see_also_mention < <(list_pages_with_see_also_mention "${english_pages[@]}")

for language_id in "" "${LANGUAGE_IDS[@]}"; do
  folder="$TLDR_ROOT_DIR/pages${language_id:+.$language_id}"
  see_also_prefix=$(get_see_also_prefix "${language_id:-en}")
  mapfile -t pages < <(list_pages "$folder")

  total_pages=$((total_pages + ${#pages[@]}))
  # Every reference is counted once per page, like the results.
  total_tldr_references=$((total_tldr_references + $(list_tldr_references "${pages[@]}" | sort -u | wc -l)))
  total_see_also_references=$((total_see_also_references + $(list_see_also_references "$see_also_prefix" "${pages[@]}" | sort -u | wc -l)))

  if [ -n "$language_id" ]; then
    total_non_english_pages=$((total_non_english_pages + ${#pages[@]}))
    total_pages_need_translation=$((total_pages_need_translation + ${#english_pages[@]}))

    # set-see-also.py only checks languages with a translation template.
    if [ -n "$see_also_prefix" ]; then
      for page in "${english_pages_with_see_also_mention[@]}"; do
        if [ -f "$folder${page#"$TLDR_ROOT_DIR/pages"}" ]; then
          total_pages_need_see_also_mention=$((total_pages_need_see_also_mention + 1))
        fi
      done
    fi
  fi
done

wait

# Display the number of results of every metric that applies to the language.
display_language() {
  local language_id="$1"
  local output_dir="./check-pages${language_id:+.$language_id}"
  local id languages source label
  local output_file

  display_job "${language_id:-en}"

  for metric in "${METRICS[@]}"; do
    IFS=$'\t' read -r id languages source _ _ label <<< "$metric"
    if [ "$languages" != "all" ] && [ -z "$language_id" ]; then
      continue
    fi

    output_file="$output_dir/$id.txt"
    if [ "$source" != "check-pages" ]; then
      mkdir -p "$output_dir"
      grep -F "pages${language_id:+.$language_id}/" "$RESULTS_DIR/$source" 2>/dev/null | sort -u > "$output_file"
    fi

    if [ -f "$output_file" ]; then
      echo "$(wc -l < "$output_file") $label in ${output_file#./}."
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

# Merge the results of all languages and display the total.
display_total() {
  local id="$1"
  local denominator="$2"
  local label="$3"
  local results total

  mapfile -t results < <(find ./check-pages ./check-pages.* -maxdepth 1 -type f -name "$id.txt" 2>/dev/null | sort)
  cat /dev/null "${results[@]}" | sort -u > "./$id.txt"
  total=$(wc -l < "./$id.txt")

  if [ "$denominator" = "-" ]; then
    echo "Total $label: $total"
  else
    echo "Total $label: $total/${!denominator} - $(calculate_percentage "$total" "${!denominator}")%"
  fi
}

printf "# Metrics for tldr\n\n"

display_job "tldr-scripts"

display_language ""
for language_id in "${LANGUAGE_IDS[@]}"; do
  display_language "$language_id"
done

for metric in "${METRICS[@]}"; do
  IFS=$'\t' read -r id _ _ denominator _ label <<< "$metric"
  display_total "$id" "$denominator" "$label"
done

# Remove empty results.
for metric in "${METRICS[@]}"; do
  find . ./check-pages ./check-pages.* -maxdepth 1 -type f -name "${metric%%	*}.txt" -size 0 -delete 2>/dev/null
done

if [ "$JOB_FAILED" = true ]; then
  exit 1
fi
