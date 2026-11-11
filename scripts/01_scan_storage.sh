#!/usr/bin/env bash
# Lists every file under the given folders with its size, space used on disk,
# mtime, inode, link count and owner. Uses find -printf only (directory listing + lstat),
# so file contents are never opened and archived files are not recalled.
#
# Usage: bash 01_scan_storage.sh [-o OUT_DIR] INPUT_DIR [INPUT_DIR ...]
#   -o OUT_DIR  output folder (default: ../data)
# Output: OUT_DIR/scan_<YYYY-MM-DD>.tsv.gz and scan_<date>.errors.log
#
# Run in sinteractive or sbatch, not on the login node. Examples:
#   bash 01_scan_storage.sh /researchers/your.name
#   bash 01_scan_storage.sh -o ../data/sample /researchers/your.name/projects
#   sbatch -p rhel_short -c 1 --mem=4G -t 0-08:00 \
#     --wrap "bash 01_scan_storage.sh -o ../data/all_folders /researchers"

set -uo pipefail

# Arguments: optional -o, then one or more input folders
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STORAGE_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$STORAGE_DIR/data"
usage="Usage: bash $0 [-o OUT_DIR] INPUT_DIR [INPUT_DIR ...]"
while getopts ":o:" opt; do
  case "$opt" in
    o) OUT_DIR="$OPTARG" ;;
    *) echo "$usage" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
if [[ $# -lt 1 ]]; then
  echo "$usage" >&2
  exit 1
fi

# Stop if an input folder doesn't exist
ROOTS=()
for r in "$@"; do
  r="${r%/}"
  if [[ ! -d "$r" ]]; then
    echo "ERROR: $r does not exist or is not a directory (is the share mounted here?)" >&2
    exit 1
  fi
  ROOTS+=("$r")
done

# Stop if one input is inside another (files would be counted twice)
for a in "${ROOTS[@]}"; do
  for b in "${ROOTS[@]}"; do
    if [[ "$a" != "$b" && "$b/" == "$a/"* ]]; then
      echo "ERROR: $b is inside $a - give only one of them" >&2
      exit 1
    fi
  done
done

STAMP="$(date +%Y-%m-%d)"
OUT="$OUT_DIR/scan_${STAMP}.tsv"
ERR="$OUT_DIR/scan_${STAMP}.errors.log"

# Don't overwrite today's scan
if [[ -e "$OUT.gz" ]]; then
  echo "ERROR: $OUT.gz already exists - move it away first" >&2
  exit 1
fi
mkdir -p "$OUT_DIR"

echo "Scanning on $(hostname):"
printf '  %s\n' "${ROOTS[@]}"
echo "  output: $OUT.gz"
echo "  errors: $ERR"
echo "  started: $(date)"

# One line per regular file. Skips this project's own folder and snapshot folders.
# %s size, %b 512-byte blocks allocated (small for archived stubs), %T@ mtime,
# %i inode, %n link count, %u owner (a number if the account has no name), %p path (last column). Symlinks are not followed.
# Written to .partial first so an interrupted run is obvious.
{
  printf 'size_bytes\talloc_blocks\tmtime_epoch\tinode\tnlinks\towner\tpath\n'
  find "${ROOTS[@]}" \( -path "$STORAGE_DIR" -o -name .snapshot -o -name '~snapshot' -o -name .zfs \) -prune \
    -o -type f -printf '%s\t%b\t%T@\t%i\t%n\t%u\t%p\n' 2>"$ERR"
} > "$OUT.partial"
status=$?

# Rename and compress once finished
mv "$OUT.partial" "$OUT"
n_files=$(($(wc -l < "$OUT") - 1))
gzip "$OUT"

# Report any errors (e.g. permission denied); the scan is kept either way
n_err=$(wc -l < "$ERR")
echo "  finished: $(date)"
echo "  files recorded: $n_files"
if [[ $status -ne 0 || $n_err -gt 0 ]]; then
  echo "WARNING: $n_err error line(s) (e.g. permission denied) - see $ERR" >&2
fi
