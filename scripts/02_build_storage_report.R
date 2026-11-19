# Build the storage report: one self-contained HTML page (plain JavaScript, no
# libraries, nothing to install) showing what a person or group holds - real size vs
# what is on disk, where the space is, and the cleanup colour of every folder.
# The owner sets each project's status (active / inactive / published) and sensitivity
# on the page, and the colours follow.
#
# Usage (from the scripts folder):
#   Rscript 02_build_storage_report.R SCAN_ROOT SCAN [SCAN ...]
#     SCAN_ROOT  folder whose sub-folders are the projects, e.g. /researchers/your.name/projects
#     SCAN       scan_<date>.tsv.gz from 01_scan_storage.sh
# Optional settings as environment variables:
#   PROJECT_LEVEL  folder levels below SCAN_ROOT that make up a project (default 1)
#   REPO_FILE      sequencing-repository list (see data/README.md; .tsv.gz); unset = raw FASTQ all stay red
#   REGISTER       project register (.tsv); default ../rules/project_register.tsv if it exists
#   OUT            output page (default ../reports/storage_report_<SCAN_ROOT folder name>.html)
#   TEMPLATE       page template (default storage_report_template.html)
#   DIR_MAX        folders shown in the page (default 20,000, the largest); smaller ones are
#                  merged into their parent folder, so totals don't change
#   FILE_LIST_MAX  most files the page lists one by one (default 250,000); above it the cart is off
# The full file list is always written beside the page as <page name>_files.tsv.gz.
# Metadata only: reads the scan files, never the scanned data. The page contains folder
# paths, the names of the largest files and the account names of file owners - it is
# meant for the people working with these folders.

source("storage_data.R")

# Arguments and settings; fail fast on anything missing
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("Usage: Rscript 02_build_storage_report.R SCAN_ROOT SCAN [SCAN ...]")
repo_file <- Sys.getenv("REPO_FILE", "")
register_file <- Sys.getenv("REGISTER", "../rules/project_register.tsv")
out_file <- Sys.getenv("OUT", sprintf("../reports/storage_report_%s.html", basename(sub("/+$", "", args[1]))))
now <- Sys.time()

# Read and classify the scans (shared with the cleanup simulator)
x <- load_classified(args[-1], args[1], as.integer(Sys.getenv("PROJECT_LEVEL", "1")),
                     repo_file, register_file, now = now)
f <- x$f; proj <- x$proj
f[, `:=`(p = match(project, proj$project) - 1L, r = rule_index(x, rule_id))]

# File owners, largest first. With only one owner the page shows no person section.
owner_names <- f[, .(real = sum(size_bytes)), by = owner][order(-real), owner]
has_owners <- length(owner_names) > 1
f[, o := match(owner, owner_names) - 1L]

# Folder tree. Every folder that holds files, plus all its ancestors; "" is the scanned
# folder itself. Each folder keeps its name and parent; JavaScript adds the totals up.
f[, dir := fifelse(dirname(rel_root) == ".", "", dirname(rel_root))]
dirs_with_files <- unique(f$dir)
anc <- unique(unlist(lapply(strsplit(dirs_with_files[dirs_with_files != ""], "/", fixed = TRUE), function(p)
  Reduce(function(a, b) paste(a, b, sep = "/"), p, accumulate = TRUE))))
dirs <- data.table(path = c("", sort(anc)))
dirs[, `:=`(i = .I - 1L, name = fifelse(path == "", basename(x$scan_root), basename(path)),
            parent_path = fifelse(grepl("/", path), dirname(path), fifelse(path == "", NA_character_, "")))]
dirs[, depth := fifelse(path == "", 0L, lengths(regmatches(path, gregexpr("/", path, fixed = TRUE))) + 1L)]

# Cap the tree so the page stays small: rank folders by the real size of everything
# below them and keep the DIR_MAX largest (default 20,000), every project folder, and
# all their parents. A file in a folder that is left out is shown in its nearest kept
# parent, with the rest of its path in its name, so every file and byte still counts.
dir_max <- as.numeric(Sys.getenv("DIR_MAX", "20000"))
n_dirs_all <- nrow(dirs)
dirs[, below := 0]
own <- f[, .(real = sum(size_bytes)), by = dir]
dirs[own, below := i.real, on = .(path = dir)]
# Add each folder's total to its parent, deepest folders first
for (lv in rev(seq_len(max(dirs$depth)))) {
  up <- dirs[depth == lv, .(add = sum(below)), by = parent_path]
  dirs[up, below := below + i.add, on = .(path = parent_path)]
}
keep <- if (n_dirs_all <= dir_max) rep(TRUE, n_dirs_all) else
  seq_len(n_dirs_all) %in% head(order(-dirs$below), dir_max) | dirs$path %chin% c("", x$proj$project)
# A kept folder's parents are kept too (deepest level first, one level at a time)
par_row <- match(dirs$parent_path, dirs$path)
for (lv in rev(seq_len(max(dirs$depth)))) {
  kids <- which(dirs$depth == lv & keep)
  keep[par_row[kids]] <- TRUE
}
# Nearest kept folder for every folder (itself if kept), top-down
shown <- seq_len(n_dirs_all)
for (lv in seq_len(max(dirs$depth))) {
  dr <- which(dirs$depth == lv & !keep)
  shown[dr] <- shown[par_row[dr]]
}
# Files: their shown folder, and their name relative to it
f[, row := match(dir, dirs$path)]
f[, srow := shown[row]]
f[, fname := fifelse(srow == row, basename(rel_root),
                     substring(rel_root, fifelse(dirs$path[srow] == "", 1L, nchar(dirs$path[srow]) + 2L)))]
f[, shown_dir := dirs$path[srow]]
f[, c("row", "srow") := NULL]
dirs <- dirs[keep]
dirs[, i := .I - 1L]
dirs[, parent := match(parent_path, path) - 1L]
dirs[is.na(parent), parent := -1L]
f[, d := match(shown_dir, dirs$path) - 1L]

# The project each folder belongs to (same rule as for files: the first PROJECT_LEVEL
# folders); folders above project level belong to none (-1)
project_level <- as.integer(Sys.getenv("PROJECT_LEVEL", "1"))
dir_proj <- sub(sprintf("^([^/]+(?:/[^/]+){0,%d}).*$", project_level - 1), "\\1", dirs$path, perl = TRUE)
dir_proj[dirs$path == ""] <- "(top level)"
dirs[, p := match(dir_proj, proj$project) - 1L]
dirs[is.na(p), p := -1L]

# The three largest files directly in each folder (shown when hovering a folder)
dtop <- f[order(-size_bytes), .(names = list(head(fname, 3)), sizes = list(head(size_bytes, 3))), by = d]
dirs[, `:=`(top_names = list(character()), top_sizes = list(numeric()))]
dirs[dtop$d + 1L, `:=`(top_names = dtop$names, top_sizes = dtop$sizes)]

# Files directly in each folder, split by project, rule and owner: folder, project, rule,
# files, real size, on-disk size, archived real size, newest modification (epoch days), owner
cells <- f[, .(files = .N, real = sum(size_bytes), alloc = sum(alloc_bytes),
               arch = sum(size_bytes[stubbed]),
               mday = as.integer(as.numeric(max(mtime)) %/% 86400)), by = .(d, p, r, o)]

# File types: last extension, keeping a compression suffix (.fastq.gz, .tar.gz)
nm <- basename(f$rel_root)
has_ext <- grepl("\\.[A-Za-z0-9]{1,10}(\\.(gz|bz2|xz|zst))?$", nm, perl = TRUE)
f[, ext := "(no extension)"]
f[has_ext, ext := tolower(sub("^.*?((\\.[A-Za-z0-9]{1,10})(\\.(gz|bz2|xz|zst))?)$", "\\1", nm[has_ext], perl = TRUE))]
ext_names <- f[, .(real = sum(size_bytes)), by = ext][order(-real), ext]
types <- f[, .(files = .N, real = sum(size_bytes)), by = .(e = match(ext, ext_names) - 1L, p, r, o)]

# Real size per year the files were last changed, split so the By year tab can follow the
# project settings and the people and projects selected
f[, year := as.integer(format(mtime, "%Y"))]
years <- f[, .(files = .N, real = sum(size_bytes), arch = sum(size_bytes[stubbed])), by = .(year, p, r, o)]

# The 100 largest files: path below the scanned folder, project, rule, size, archived, date
# (k = the file's position in the file list below, 0-based, so the page can put it in the cart)
top_i <- head(order(-f$size_bytes), 100)
top <- f[top_i, .(path = rel_root, p, r, size = size_bytes, stubbed, date = format(mtime, "%Y-%m-%d"), o)]
top[, k := top_i - 1L]

# Every file, for the cart: folder, name, size, project, rule, archived (0/1).
# Left out of the page when there are more than FILE_LIST_MAX files (default 250,000),
# so the page stays small enough to open; the full list beside the page covers them.
file_max <- as.numeric(Sys.getenv("FILE_LIST_MAX", "250000"))
files <- if (nrow(f) <= file_max)
  list(d = I(f$d), name = I(f$fname), size = I(f$size_bytes), p = I(f$p),
       r = I(f$r), arch = I(as.integer(f$stubbed)), e = I(match(f$ext, ext_names) - 1L),
       o = if (has_owners) I(f$o)) else list()

# The full file list, always written beside the page (open it in Excel, R or zcat):
# path, size, last change, owner, project, the rule that decided it and that rule's colour.
# The colour here is before project settings; the page applies those.
rule_ids <- c(vapply(x$rules$rules, `[[`, "", "id"), x$rules$default$id)
rule_cols <- c(vapply(x$rules$rules, `[[`, "", "colour"), x$rules$default$colour)
list_file <- sub("\\.html?$", "", out_file)
list_file <- paste0(list_file, "_files.tsv.gz")
dir.create(dirname(list_file), showWarnings = FALSE, recursive = TRUE)
fwrite(f[order(-size_bytes), .(path = file.path(x$scan_root, rel_root), size_bytes, modified = format(mtime, "%Y-%m-%d"),
                               owner, project, rule = rule_ids[r + 1L], rule_colour = rule_cols[r + 1L], archived = as.integer(stubbed))],
       list_file, sep = "\t", quote = FALSE, compress = "gzip")

# Everything the page needs, then embed it in the template
data <- c(list(meta = list(
  scans = I(basename(args[-1])), scan_root = x$scan_root, n_outside = x$n_outside,
  repo_file = if (nzchar(repo_file)) basename(repo_file) else "",
  register = if (file.exists(register_file)) basename(register_file) else "",
  rules_version = x$rules$version, built = format(now, "%Y-%m-%d %H:%M"),
  active_months = x$rules$thresholds$active_months, n_files = nrow(f),
  project_level = project_level, has_files = length(files) > 0,
  n_dirs_all = n_dirs_all, n_dirs_shown = nrow(dirs), file_list = basename(list_file))),
  page_common(x),
  list(dirs = list(name = dirs$name, parent = dirs$parent, p = dirs$p,
                   top_names = dirs$top_names, top_sizes = dirs$top_sizes),
       files = files,
       owners = if (has_owners) I(owner_names) else I(character()),
       cells = unname(as.matrix(cells[, .(d, p, r, files, real, alloc, arch, mday, o)])),
       ext_names = I(ext_names),
       types = unname(as.matrix(types[, .(e, p, r, files, real, o)])),
       years = unname(as.matrix(years[, .(year, p, r, files, real, arch, o)])),
       top = list(path = I(top$path), p = I(top$p), r = I(top$r), size = I(top$size),
                  stubbed = I(top$stubbed), date = I(top$date), k = I(top$k), o = I(top$o))))
# A wrapper script can adjust the data and use its own template
if (exists("prepare_page_data")) data <- prepare_page_data(data)
size <- embed_page(data, Sys.getenv("TEMPLATE", "storage_report_template.html"), out_file)
cat(sprintf("Wrote %s (%.0f KB): %s files, %d folders, %d projects (%d outside %s left out), rules %s\n",
            out_file, size / 1024, format(nrow(f), big.mark = ","), nrow(dirs), nrow(proj),
            x$n_outside, x$scan_root, x$rules$version))
if (nrow(dirs) < n_dirs_all)
  cat(sprintf("Folders: the %s largest of %s are shown; smaller ones are merged into their parent folder.\n",
              format(nrow(dirs), big.mark = ","), format(n_dirs_all, big.mark = ",")))
if (!length(files))
  cat(sprintf("Files: %s is more than FILE_LIST_MAX (%s), so the page has no cart; the full list is beside it.\n",
              format(nrow(f), big.mark = ","), format(file_max, big.mark = ",", scientific = FALSE)))
cat(sprintf("Full file list: %s\n", list_file))
# Warn when the page may be slow to open
if (size > 50 * 1024^2)
  cat(sprintf("WARNING: the page is %.0f MB and may be slow or fail to open. Lower DIR_MAX or FILE_LIST_MAX, or report a smaller folder.\n", size / 1024^2))
