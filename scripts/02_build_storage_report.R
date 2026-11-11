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
dirs[, parent := match(parent_path, path) - 1L]
dirs[is.na(parent), parent := -1L]
f[, d := match(dir, dirs$path) - 1L]

# The project each folder belongs to (same rule as for files: the first PROJECT_LEVEL
# folders); folders above project level belong to none (-1)
project_level <- as.integer(Sys.getenv("PROJECT_LEVEL", "1"))
dir_proj <- sub(sprintf("^([^/]+(?:/[^/]+){0,%d}).*$", project_level - 1), "\\1", dirs$path, perl = TRUE)
dir_proj[dirs$path == ""] <- "(top level)"
dirs[, p := match(dir_proj, proj$project) - 1L]
dirs[is.na(p), p := -1L]

# The three largest files directly in each folder (shown when hovering a folder)
dtop <- f[order(-size_bytes), .(names = list(head(basename(rel_root), 3)), sizes = list(head(size_bytes, 3))), by = d]
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

# Every file, for the export step: folder, name, size, project, rule, archived (0/1).
# Left out when there are more than FILE_LIST_MAX files (default 500,000) - the page
# would get too big - and the export then lists folders instead.
file_max <- as.numeric(Sys.getenv("FILE_LIST_MAX", "500000"))
files <- if (nrow(f) <= file_max)
  list(d = I(f$d), name = I(basename(f$rel_root)), size = I(f$size_bytes), p = I(f$p),
       r = I(f$r), arch = I(as.integer(f$stubbed)), e = I(match(f$ext, ext_names) - 1L),
       o = if (has_owners) I(f$o)) else list()

# Everything the page needs, then embed it in the template
data <- c(list(meta = list(
  scans = I(basename(args[-1])), scan_root = x$scan_root, n_outside = x$n_outside,
  repo_file = if (nzchar(repo_file)) basename(repo_file) else "",
  register = if (file.exists(register_file)) basename(register_file) else "",
  rules_version = x$rules$version, built = format(now, "%Y-%m-%d %H:%M"),
  active_months = x$rules$thresholds$active_months, n_files = nrow(f),
  project_level = project_level, has_files = length(files) > 0)),
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
