#!/usr/bin/env bash
# Build one page of one tab: the overview (02b_build_overview.R) or the cart with its file list
# (02_build_storage_report.R), into OUT_DIR/storage_report/<tab>/.
#
# Usage, from the scripts folder (run_my_report.sh does this for you, as a job or directly):
#   bash 04_build_page.sh OUT_DIR TAB overview|cart
# Settings from the environment: REPO_FILE (optional sequencing-repository list).
# Reads only the tab's part of the scan, never the scanned data.

set -uo pipefail
if [[ $# -ne 3 || ! "$3" =~ ^(overview|cart)$ ]]; then echo "Usage: bash $0 OUT_DIR TAB overview|cart" >&2; exit 1; fi
OUT_DIR="$1"; TAB="$2"; VIEW="$3"
TABS="$OUT_DIR/storage_report/tabs.tsv"
[[ -f "$TABS" ]] || { echo "ERROR: not found: $TABS (run 03_split_tabs.sh first)" >&2; exit 1; }
[[ -f 02_build_storage_report.R ]] || { echo "ERROR: run this from the toolkit's scripts folder" >&2; exit 1; }

# This tab's folder, project level and part of the scan
LINE="$(awk -F'\t' -v t="$TAB" 'NR > 1 && $1 == t' "$TABS")"
[[ -n "$LINE" ]] || { echo "ERROR: no tab $TAB in $TABS" >&2; exit 1; }
IFS=$'\t' read -r _ LABEL ROOT LEVEL SCAN FILES BYTES <<< "$LINE"
DEST="$OUT_DIR/storage_report/$TAB"
mkdir -p "$DEST" || exit 1
rm -f "$DEST/$VIEW.failed"

# Build the page; on failure leave a marker the index page shows, and the messages
if [[ "$VIEW" == overview ]]; then BUILDER=02b_build_overview.R; else BUILDER=02_build_storage_report.R; fi
echo "$(date '+%F %H:%M') $LABEL: building the $VIEW page from $FILES files"
if REPO_FILE="${REPO_FILE:-}" OUT="$DEST/$VIEW.html" REGISTER=none PROJECT_LEVEL="$LEVEL" \
     Rscript "$BUILDER" "$ROOT" "$SCAN" 2> "$DEST/${VIEW}_messages.txt"; then
  echo "$(date '+%F %H:%M') $LABEL: $VIEW page done"
else
  touch "$DEST/$VIEW.failed"
  echo "ERROR: $LABEL: the $VIEW page could not be built. Last messages:" >&2
  tail -5 "$DEST/${VIEW}_messages.txt" >&2
  exit 1
fi
