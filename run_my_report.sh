#!/bin/bash
#SBATCH -J storage_report
#SBATCH --partition=rhel_short
#SBATCH --time=0-08:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH -o storage_report_%j.log
#SBATCH --mail-type=FAIL

# Scan one or more folders and build one storage report. Metadata only: no file is
# opened, so nothing is recalled from the archive.
#
# Usage, from inside this toolkit folder:
#   sbatch run_my_report.sh /researchers/your.name/projects
#   sbatch run_my_report.sh /researchers/your.name/projects/mac*
#   sbatch run_my_report.sh /path/to/folder1 /path/to/folder2
# One folder:  each of its sub-folders becomes one project in the report.
# Several:     they share one report, under their closest common parent folder. Each
#              folder directly below that parent becomes one project.
# Results go to results/<name>/ in this toolkit; progress goes to storage_report_<job>.log.

set -uo pipefail

# Which page this toolkit builds
BUILDER="02_build_storage_report.R"
REPORT_NAME="storage_report.html"

# Find the toolkit: Slurm runs a copy of this script, so use the folder it was submitted from
TOOLKIT="${SLURM_SUBMIT_DIR:-$PWD}"
if [[ ! -f "$TOOLKIT/scripts/$BUILDER" ]]; then
  echo "ERROR: $TOOLKIT is not the toolkit folder. Go into it with cd and submit again." >&2
  exit 1
fi

# Check the arguments: one or more existing folders, written as their real paths
if [[ $# -lt 1 ]]; then
  echo "ERROR: give at least one folder, e.g. sbatch run_my_report.sh /researchers/your.name/projects" >&2
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
if [[ ${#FOLDERS[@]} -eq 1 ]]; then
  ROOT="${FOLDERS[0]}"
else
  ROOT="$(dirname "${FOLDERS[0]}")"
  for f in "${FOLDERS[@]}"; do
    while [[ "$ROOT" != "/" && "$f/" != "$ROOT/"* ]]; do ROOT="$(dirname "$ROOT")"; done
  done
  if [[ "$ROOT" == "/" ]]; then
    echo "ERROR: these folders share no parent folder, so they can't go in one report." >&2
    exit 1
  fi
fi

# Check R and its four packages now, so a long scan isn't wasted
if ! command -v Rscript > /dev/null; then
  echo "ERROR: R is not available in this job. Load R first, then submit again (see the tutorial)." >&2
  exit 1
fi
if ! Rscript -e 'for (p in c("data.table", "yaml", "jsonlite", "digest")) if (!requireNamespace(p, quietly = TRUE)) { message("Missing R package: ", p); quit(status = 1) }'; then
  echo "ERROR: install the missing R package(s), then submit again (see the tutorial)." >&2
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

# Each selection of folders gets its own results folder, so re-using a scan is always safe
NAME="$(echo "${ROOT#/}" | tr '/' '_')"
if [[ ${#FOLDERS[@]} -gt 1 ]]; then
  SELECTION="$(printf '%s\n' "${FOLDERS[@]}" | sort | cksum | cut -d' ' -f1)"
  NAME="${NAME}_${#FOLDERS[@]}_folders_${SELECTION}"
fi
OUT_DIR="$TOOLKIT/results/$NAME"
mkdir -p "$OUT_DIR"
printf '%s\n' "${FOLDERS[@]}" > "$OUT_DIR/folders.txt"
SCAN="$OUT_DIR/scan_$(date +%Y-%m-%d).tsv.gz"
ERRORS="$OUT_DIR/scan_$(date +%Y-%m-%d).errors.log"

# Scan the folder, or reuse a scan that finished earlier today
cd "$TOOLKIT/scripts" || exit 1
if [[ -f "$SCAN" ]]; then
  echo "Using today's finished scan: $SCAN"
else
  bash 01_scan_storage.sh -o "$OUT_DIR" "${FOLDERS[@]}" || exit 1
fi

# Build the report page
REPORT="$OUT_DIR/$REPORT_NAME"
if ! REPO_FILE="$REPO_FILE" OUT="$REPORT" Rscript "$BUILDER" "$ROOT" "$SCAN"; then
  echo "ERROR: the report could not be built - see the messages above." >&2
  exit 1
fi

# Say where the report is, and whether the scan missed anything
N_ERRORS=$(wc -l < "$ERRORS" | tr -d ' ')
echo
echo "FINISHED. Your report: $REPORT"
if [[ "$N_ERRORS" -gt 0 ]]; then
  echo "NOTE: the report may be incomplete. $N_ERRORS scan problem(s), such as folders you can't read, are listed in $ERRORS"
else
  echo "The scan reported no problems."
fi
