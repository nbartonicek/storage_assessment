#!/usr/bin/env bash
# Plan the report's tabs and give each its own part of the scan, so a small tab is built with
# little memory even when the whole scan is large.
#
# Usage: bash 03_split_tabs.sh OUT_DIR SCAN ROOT FOLDER [FOLDER ...]
#   OUT_DIR  the run's results folder; SCAN  its scan_<date>.tsv.gz
#   ROOT     the folders' closest shared parent ("/" when they share none)
# Tabs: with one folder, just that folder; with several, a Total over all of them, then one per
# folder. In each folder's tab, the folder's sub-folders are the projects.
# Output: OUT_DIR/tabs/<tab>.tsv.gz (scan lines under that folder, same columns as the scan) and
#   OUT_DIR/storage_report/tabs.tsv: tab, label, root, project_level, scan, files, bytes
# Reads only the scan, never the scanned folders.

set -uo pipefail
if [[ $# -lt 4 ]]; then echo "Usage: bash $0 OUT_DIR SCAN ROOT FOLDER [FOLDER ...]" >&2; exit 1; fi
OUT_DIR="$1"; SCAN="$2"; ROOT="$3"; shift 3
REPORT_DIR="$OUT_DIR/storage_report"
mkdir -p "$OUT_DIR/tabs" "$REPORT_DIR" || exit 1
rm -f "$OUT_DIR"/tabs/*.tsv.gz

# A folder name for each folder's tab: its path below ROOT (or the full path), as plain characters.
# Two folders that would get the same name are numbered.
NAMES=()
for f in "$@"; do
  rel="${f#"$ROOT"}"; rel="${rel#/}"; [[ -z "$rel" ]] && rel="$f"
  n="$(echo "$rel" | sed 's/[^A-Za-z0-9._-]/_/g; s/^[._-]*//')"; [[ -z "$n" ]] && n="folder"
  base="$n"; i=2
  for m in ${NAMES[@]+"${NAMES[@]}"} total; do [[ "$m" == "$n" ]] && { n="${base}_$i"; i=$((i + 1)); }; done
  NAMES+=("$n")
done

# Split the scan in one pass: each line goes to the tab of the folder its path is under, and its
# files and bytes are counted. Lines under no folder are not expected (the scan lists only them).
printf '%s\n' "$@" > "$OUT_DIR/tabs/folders.txt"
printf '%s\n' "${NAMES[@]}" > "$OUT_DIR/tabs/names.txt"
gzip -dc "$SCAN" | awk -F'\t' -v dir="$OUT_DIR/tabs" '
  BEGIN { while ((getline f < (dir "/folders.txt")) > 0) { k++; fol[k] = f "/" }
          k = 0; while ((getline n < (dir "/names.txt")) > 0) { k++; nam[k] = n; cmd[k] = "gzip > \"" dir "/" n ".tsv.gz\"" } }
  NR == 1 { for (i = 1; i <= k; i++) print | cmd[i]; next }
  { for (i = 1; i <= k; i++) if (index($7, fol[i]) == 1) { print | cmd[i]; c[i]++; b[i] += $1; break } }
  END { for (i = 1; i <= k; i++) { close(cmd[i]); printf "%s\t%d\t%.0f\n", nam[i], c[i] + 0, b[i] + 0 > (dir "/counts.tsv") } }' \
  || { echo "ERROR: could not split the scan into tabs" >&2; exit 1; }

# The tab list. With several folders the Total comes first: the whole scan, with the folders
# directly below ROOT as projects (two levels when ROOT is "/", e.g. researchers/your.name).
{
  printf 'tab\tlabel\troot\tproject_level\tscan\tfiles\tbytes\n'
  if [[ $# -gt 1 ]]; then
    awk -F'\t' -v OFS='\t' -v root="$ROOT" -v scan="$SCAN" '
      { f += $2; b += $3 } END { printf "total\tTotal\t%s\t%d\t%s\t%d\t%.0f\n", root, (root == "/" ? 2 : 1), scan, f, b }' "$OUT_DIR/tabs/counts.tsv"
  fi
  i=0
  for f in "$@"; do
    n="${NAMES[$i]}"; i=$((i + 1))
    awk -F'\t' -v OFS='\t' -v n="$n" -v f="$f" -v s="$OUT_DIR/tabs/$n.tsv.gz" '$1 == n { print n, f, f, 1, s, $2, $3 }' "$OUT_DIR/tabs/counts.tsv"
  done
} > "$REPORT_DIR/tabs.tsv"

# Say what was found
echo "Tabs:"
awk -F'\t' 'NR > 1 { printf "  %-40s %12d files  %10.2f TiB\n", $2, $6, $7 / 1024^4 }' "$REPORT_DIR/tabs.tsv"
