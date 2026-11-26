#!/bin/bash
#SBATCH -J storage_tabbed
#SBATCH --partition=rhel_short
#SBATCH --time=0-08:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH -o storage_tabbed_%j.log
#SBATCH --mail-type=FAIL

# Tabbed version of run_my_report.sh: scan one or more folders and build one storage report with
# a tab per folder, sized for very large data. Metadata only:
# no file is opened, so nothing is recalled from the archive.
#
# Usage, from inside this toolkit folder:
#   sbatch run_tabbed_report.sh /researchers/your.name/projects
#   sbatch run_tabbed_report.sh /path/to/folder1 /path/to/folder2
# One folder:  one tab; each of its sub-folders is one project.
# Several:     a Total tab over all of them, then one tab per folder.
# Each tab has two pages: an overview (where the data is, what it is, how old) and a cart with
# the file list. Small reports are built in this job. Bigger ones are built by jobs this job
# submits, each with the memory its tab needs (see the settings below); the log says which.
# Results go to results/<name>/storage_report/ (open index.html); progress goes to the log.

set -uo pipefail

# Settings for the build jobs. Memory: GB_PER_MILLION per million files plus 4 GB (measured: 3.5
# to over 8 GB per million files, most for many small files in deep folders). Tabs up to
# SHORT_MAX_FILES files run on SHORT_PARTITION, bigger ones on LONG_PARTITION; a tab needing more
# than MAX_MEM_GB is not submitted, its command is printed.
# Up to INLINE_MAX_FILES files in every tab, the pages are built in this job instead.
GB_PER_MILLION="${GB_PER_MILLION:-10}"
SHORT_PARTITION="${SHORT_PARTITION:-rhel_short}"; SHORT_TIME="${SHORT_TIME:-0-08:00}"
LONG_PARTITION="${LONG_PARTITION:-rhel_long}";   LONG_TIME="${LONG_TIME:-3-00:00:00}"
SHORT_MAX_FILES="${SHORT_MAX_FILES:-2000000}"
MAX_MEM_GB="${MAX_MEM_GB:-900}"
INLINE_MAX_FILES="${INLINE_MAX_FILES:-300000}"

# Find the toolkit: Slurm runs a copy of this script, so use the folder it was submitted from
TOOLKIT="${SLURM_SUBMIT_DIR:-$PWD}"
if [[ ! -f "$TOOLKIT/scripts/04_build_page.sh" ]]; then
  echo "ERROR: $TOOLKIT is not the toolkit folder. Go into it with cd and submit again." >&2
  exit 1
fi

# Check the arguments: one or more existing folders, written as their real paths
if [[ $# -lt 1 ]]; then
  echo "ERROR: give at least one folder, e.g. sbatch run_tabbed_report.sh /researchers/your.name/projects" >&2
  exit 1
fi
FOLDERS=()
for f in "$@"; do
  if [[ ! -d "$f" ]]; then
    echo "ERROR: folder not found: $f" >&2
    exit 1
  fi
  real="$(cd "$f" && pwd -P)"
  # Skip a folder given twice
  seen=0
  for g in ${FOLDERS[@]+"${FOLDERS[@]}"}; do [[ "$g" == "$real" ]] && seen=1; done
  [[ $seen -eq 0 ]] && FOLDERS+=("$real")
done

# The report's root: the folder itself, or the closest parent shared by all the folders
# ("/" when they are on different volumes, e.g. /researchers and /pathology)
if [[ ${#FOLDERS[@]} -eq 1 ]]; then
  ROOT="${FOLDERS[0]}"
else
  ROOT="$(dirname "${FOLDERS[0]}")"
  for f in "${FOLDERS[@]}"; do
    while [[ "$ROOT" != "/" && "$f/" != "$ROOT/"* ]]; do ROOT="$(dirname "$ROOT")"; done
  done
fi

# Check R and its four packages now, so a long scan isn't wasted
if ! command -v Rscript > /dev/null; then
  echo "ERROR: R is not available in this job. Load R first, then submit again (see README.md)." >&2
  exit 1
fi
if ! Rscript -e 'for (p in c("data.table", "yaml", "jsonlite", "digest")) if (!requireNamespace(p, quietly = TRUE)) { message("Missing R package: ", p); quit(status = 1) }'; then
  echo "ERROR: install the missing R package(s), then submit again (see README.md)." >&2
  exit 1
fi

# The sequencing-repository list is optional and not part of the public toolkit. With it in
# data/, raw FASTQ held in the repository can be recognised; without it, raw FASTQ all stay red.
shopt -s nullglob
REPO_FILES=("$TOOLKIT"/data/repo_fastqs_*.tsv.gz)
shopt -u nullglob
if [[ ${#REPO_FILES[@]} -gt 1 ]]; then
  echo "ERROR: more than one repo_fastqs_<date>.tsv.gz in $TOOLKIT/data; keep only one" >&2
  exit 1
fi
REPO_FILE="${REPO_FILES[0]:-}"
if [[ -z "$REPO_FILE" ]]; then
  echo "NOTE: no sequencing-repository list in $TOOLKIT/data, so raw FASTQ files all stay red (see README)."
fi
export REPO_FILE

# Each selection of folders gets its own results folder, so re-using a scan is always safe
NAME="$(echo "${ROOT#/}" | tr '/' '_')"; NAME="${NAME:-all_volumes}"
if [[ ${#FOLDERS[@]} -gt 1 ]]; then
  SELECTION="$(printf '%s\n' "${FOLDERS[@]}" | sort | cksum | cut -d' ' -f1)"
  NAME="${NAME}_${#FOLDERS[@]}_folders_${SELECTION}"
fi
OUT_DIR="$TOOLKIT/results/$NAME"
mkdir -p "$OUT_DIR"
printf '%s\n' "${FOLDERS[@]}" > "$OUT_DIR/folders.txt"
SCAN="$OUT_DIR/scan_$(date +%Y-%m-%d).tsv.gz"
ERRORS="$OUT_DIR/scan_$(date +%Y-%m-%d).errors.log"

# Scan the folders, or reuse a scan that finished earlier today
cd "$TOOLKIT/scripts" || exit 1
if [[ -f "$SCAN" ]]; then
  echo "Using today's finished scan: $SCAN"
else
  bash 01_scan_storage.sh -o "$OUT_DIR" "${FOLDERS[@]}" || exit 1
fi
N_ERRORS=$(wc -l < "$ERRORS" | tr -d ' ')
scan_note() {
  if [[ "$N_ERRORS" -gt 0 ]]; then
    echo "NOTE: the report may be incomplete. $N_ERRORS scan problem(s), such as folders you can't read, are listed in $ERRORS"
  else
    echo "The scan reported no problems."
  fi
}

# The tabs, each with its own part of the scan. A rebuild starts from clean pages.
REPORT_DIR="$OUT_DIR/storage_report"
rm -rf "$REPORT_DIR"
bash 03_split_tabs.sh "$OUT_DIR" "$SCAN" "$ROOT" "${FOLDERS[@]}" || exit 1
MAX_FILES="$(awk -F'\t' 'NR > 1 && $6 > m { m = $6 } END { print m + 0 }' "$REPORT_DIR/tabs.tsv")"

# Small report: build every page here, one after the other
if [[ "$MAX_FILES" -le "$INLINE_MAX_FILES" ]]; then
  FAILED=0
  while IFS=$'\t' read -r TAB _; do
    for VIEW in overview cart; do bash 04_build_page.sh "$OUT_DIR" "$TAB" "$VIEW" || FAILED=1; done
  done < <(tail -n +2 "$REPORT_DIR/tabs.tsv")
  bash 05_write_index.sh "$OUT_DIR" > /dev/null
  echo
  if [[ $FAILED -eq 0 ]]; then echo "FINISHED. Your report: $REPORT_DIR/index.html"
  else echo "FINISHED, but some pages could not be built (see above). Your report: $REPORT_DIR/index.html"; fi
  scan_note
  echo "To share it, send the whole storage_report folder (zipped): index.html opens the pages beside it."
  exit $FAILED
fi

# Bigger report: one job per page (overview and cart of each tab run side by side), each with the
# memory its tab needs, then a small job that writes the front page once they have all ended
mkdir -p "$OUT_DIR/logs"
JOBS=(); HELD=()
while IFS=$'\t' read -r TAB LABEL _ _ _ FILES _; do
  MEM=$(awk -v f="$FILES" -v g="$GB_PER_MILLION" 'BEGIN { m = f / 1e6 * g + 4; m = (m == int(m)) ? m : int(m) + 1; print (m < 4 ? 4 : m) }')
  if [[ "$FILES" -le "$SHORT_MAX_FILES" ]]; then P="$SHORT_PARTITION"; T="$SHORT_TIME"; else P="$LONG_PARTITION"; T="$LONG_TIME"; fi
  for VIEW in overview cart; do
    ARGS=(-J "storage_${VIEW}" --partition="$P" --time="$T" --cpus-per-task=1 --mem="${MEM}G"
          -o "$OUT_DIR/logs/${TAB}_${VIEW}_%j.log" --chdir="$TOOLKIT/scripts" --export=ALL
          --wrap="bash 04_build_page.sh '$OUT_DIR' '$TAB' $VIEW")
    if [[ "$MEM" -gt "$MAX_MEM_GB" ]]; then
      HELD+=("$LABEL ($VIEW, $FILES files, ${MEM} GB): sbatch $(printf '%q ' "${ARGS[@]}")")
      continue
    fi
    ID="$(sbatch --parsable "${ARGS[@]}")" || { echo "ERROR: could not submit the $VIEW job for $LABEL" >&2; exit 1; }
    JOBS+=("$ID")
    printf '  submitted %-8s %-40s %s, %s GB, %s\n' "$VIEW" "$LABEL" "$P" "$MEM" "job $ID"
  done
done < <(tail -n +2 "$REPORT_DIR/tabs.tsv")
DEP=""; [[ ${#JOBS[@]} -gt 0 ]] && DEP="--dependency=afterany:$(IFS=:; echo "${JOBS[*]}")"
IDX="$(sbatch --parsable -J storage_index --partition="$SHORT_PARTITION" --time=0-00:10 --mem=1G $DEP \
        -o "$OUT_DIR/logs/index_%j.log" --chdir="$TOOLKIT/scripts" --wrap="bash 05_write_index.sh '$OUT_DIR'")" \
  || { echo "ERROR: could not submit the front-page job" >&2; exit 1; }
bash 05_write_index.sh "$OUT_DIR" > /dev/null

# Say what happens next
echo
echo "SCANNED. The pages are being built by ${#JOBS[@]} job(s); the front page is rewritten by job $IDX when they end."
echo "Check on them with: squeue -u \$USER     Logs: $OUT_DIR/logs/"
if [[ ${#HELD[@]} -gt 0 ]]; then
  echo "NOT SUBMITTED (more than MAX_MEM_GB=$MAX_MEM_GB GB). Submit these yourself if your cluster has the memory,"
  echo "then run: cd $TOOLKIT/scripts && bash 05_write_index.sh '$OUT_DIR'"
  printf '  %s\n' "${HELD[@]}"
fi
echo "Your report, once built: $REPORT_DIR/index.html"
scan_note
echo "To share it, send the whole storage_report folder (zipped): index.html opens the pages beside it."
