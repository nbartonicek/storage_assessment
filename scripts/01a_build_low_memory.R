# Low-memory build of the tabbed report (run_low_memory_report.sh): every tab's overview and cart
# page in one R run. The scan is read once; each tab is classified once and gives both its pages.
# The pages are the same as the tabbed report's (02_build_storage_report.R, 02b_build_overview.R),
# whose code this uses, taken apart so one run can build every tab.
#
# For very large scans (over LUMP_ABOVE files, default 5 million), files under LUMP_MB (default 1) MB
# are combined into one row per folder, file type, owner, year last changed and archived status, so
# the build fits in memory. Sizes, file counts, archived sizes and the time view stay exact; those
# small files' colours become approximate, and the cart's file list shows the combined rows.
#
# Usage, from the scripts folder (run_low_memory_report.sh does this for you):
#   Rscript 01a_build_low_memory.R OUT_DIR SCAN ROOT FOLDER [FOLDER ...]
#     OUT_DIR  the run's results folder; the pages go to OUT_DIR/storage_report/<tab>/
#     SCAN     its scan_<date>.tsv.gz;  ROOT  the folders' closest shared parent ("/" if none)
# Tabs as in 03_split_tabs.sh: with one folder, that folder; with several, a Total, then one per folder.
# Writes OUT_DIR/storage_report/tabs.tsv for 05_write_index.sh, which then writes index.html.
# Settings from the environment: REPO_FILE, REGISTER (default none), DIR_MAX, FILE_LIST_MAX,
# LUMP_ABOVE, LUMP_MB. Metadata only: reads the scan file, never the scanned data.

source("storage_data.R")

# ---- Arguments ------------------------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4) stop("Usage: Rscript 01a_build_low_memory.R OUT_DIR SCAN ROOT FOLDER [FOLDER ...]")
out_dir <- args[1]; scan <- args[2]; root <- args[3]; folders <- args[-(1:3)]
for (t in c("storage_report_template.html", "storage_overview_template.html"))
  if (!file.exists(t)) stop("run this from the toolkit's scripts folder: ", t, " not found")
report_dir <- file.path(out_dir, "storage_report")
dir.create(report_dir, showWarnings = FALSE, recursive = TRUE)
stamp <- function() format(Sys.time(), "%H:%M:%S")

# ---- Tabs, named as 03_split_tabs.sh names them ------------------------------------------------------
# A folder's tab: its path below ROOT (or the full path), as plain characters; names that would
# clash are numbered. With several folders the Total comes first (two folder levels make a project
# when ROOT is "/", e.g. researchers/your.name).
tab_name <- function(f) {
  rel <- if (startsWith(f, root)) sub("^/", "", substring(f, nchar(root) + 1)) else ""
  if (rel == "") rel <- f
  n <- sub("^[._-]*", "", gsub("[^A-Za-z0-9._-]", "_", rel))
  if (n == "") "folder" else n
}
names_seen <- character()
tab_names <- character()
for (f in folders) {
  n <- tab_name(f); base <- n; i <- 2
  for (m in c(names_seen, "total")) if (m == n) { n <- paste0(base, "_", i); i <- i + 1 }
  names_seen <- c(names_seen, n); tab_names <- c(tab_names, n)
}
tabs <- data.frame(tab = tab_names, label = folders, root = folders, project_level = 1L, stringsAsFactors = FALSE)
if (length(folders) > 1)
  tabs <- rbind(data.frame(tab = "total", label = "Total", root = root, project_level = if (root == "/") 2L else 1L), tabs)

# ---- Reading the scan, once ------------------------------------------------------------------------
# As load_classified() reads it: sizes as plain numbers, tabs in names joined back into the path,
# stray bytes shown as <xx>, hard links counted once
read_scan <- function(scan) {
  if (!file.exists(scan)) stop("scan file not found: ", scan)
  con <- gzfile(scan); header <- strsplit(readLines(con, n = 1), "\t", fixed = TRUE)[[1]]; close(con)
  join <- paste0("awk -F'\\t' -v OFS='\\t' 'NR==1{w=NF; print; next} NF==w{print; next} ",
                 "NF>w{p=$w; for(i=w+1;i<=NF;i++) p=p \" \" $i; print_line=\"\"; for(i=1;i<w;i++) print_line=print_line $i OFS; print print_line p; next} ",
                 "{bad++} END{if(bad>0) printf \"%d scan lines left out\\n\", bad > \"/dev/stderr\"}'")
  s <- fread(cmd = paste("gzip -dc", shQuote(scan), "|", join), sep = "\t", quote = "",
             colClasses = list(character = intersect(c("path", "owner"), header), numeric = intersect(c("size_bytes", "alloc_blocks"), header)), integer64 = "double")
  bad <- !validUTF8(s$path)
  if (any(bad)) s[bad, path := iconv(path, "UTF-8", "UTF-8", sub = "byte")]
  # Hard links are counted once within each tab (classify_scope), as each tab's own scan part would be
  s
}

# The sequencing-repository lists, read once for all tabs, as load_classified() reads them
read_repo <- function(repo_file) {
  repo <- if (nzchar(repo_file)) {
    if (!file.exists(repo_file)) stop("repository list not found: ", repo_file)
    rp <- fread(cmd = paste("gzip -dc", shQuote(repo_file)), sep = "\t", quote = "", integer64 = "double")
    if ("key" %in% names(rp)) rp[, .(key = as.character(key))] else rp[, .(name, size_bytes)]
  } else NULL
  repo_samples <- NULL
  if (nzchar(repo_file)) {
    sf <- file.path(dirname(repo_file), sub("^repo_fastqs(_hashed)?_", "repo_samples_hashed_", basename(repo_file)))
    if (file.exists(sf)) repo_samples <- fread(cmd = paste("gzip -dc", shQuote(sf)), sep = "\t", integer64 = "double",
                                               colClasses = list(character = "key"))
  }
  list(repo = repo, repo_samples = repo_samples)
}

# ---- Very large scans: small files combined ---------------------------------------------------------
# Files under `mb` MB become one row per folder, file type, owner, year and archived status, keeping
# their summed sizes, newest date and number (n_files). Small files the rules look for by name stay
# on their own: RNA-SeQC summaries, STAR indexes, run records (as cleanup_classifier.R), Cell Ranger
# matrices and BAMs, FASTQ and SRA files, MISO summaries, and names that look sensitive.
lump_small <- function(s, rules, rules_raw, mb = 1) {
  # Hard links counted once over the whole scan first (combined rows can't be told apart later)
  if ("inode" %in% names(s)) s <- s[is.na(inode) | !(nlinks > 1 & duplicated(inode))]
  # Each file's archived status, decided before sizes are summed
  s[, stubbed := size_bytes >= 64 * 1024 & alloc_blocks * 512 < 0.10 * size_bytes]
  small <- which(s$size_bytes < mb * 1024^2)
  path <- s$path[small]
  name <- basename(path)
  rec_rx <- "(^|/)(_cmdline|_invocation|_mrosource|_versions|nextflow\\.config|\\.nextflow\\.log[^/]*|multiqc_report\\.html)$|(^|/)(pipeline_info|\\.nextflow)/|\\.[oe][0-9]{5,}$|(^|/)slurm-[0-9]+\\.out$"
  cr_name_rx <- "^(?:(?:sample_)?filtered_(?:feature|gene|peak)_bc_matri[^/]*|sample_(?:filtered_)?feature_bc_matrix[^/]*|(?:sample_)?molecule_info\\.h5)$"
  keep <- tolower(name) %chin% c("metrics.tsv", "report.html", "countmetrics.html") | name == "SAindex" |
    grepl(rec_rx, path, perl = TRUE) | grepl(cr_name_rx, name, perl = TRUE) |
    grepl(rules$patterns$cellranger_bam, path, ignore.case = TRUE, perl = TRUE) |
    grepl("\\.(f(ast)?q|sra)(\\.(gz|bz2|xz|zst|ora))?$", name, ignore.case = TRUE, perl = TRUE) |
    grepl("\\.miso_summary(\\.gz)?$", name, ignore.case = TRUE) |
    grepl(rules_raw$sensitivity$suspect_regex, name, ignore.case = TRUE, perl = TRUE)
  lump <- small[!keep]
  rm(path, keep)
  if (!length(lump)) { s[, n_files := 1L]; return(s) }
  # File type as the pages work it out, and the year as the pages show it
  L <- s[lump, .(size_bytes, alloc_blocks, mtime_epoch, owner, stubbed, dir = dirname(path))]
  nm <- name[match(lump, small)]
  rm(name)
  has_ext <- grepl("\\.[A-Za-z0-9]{1,10}(\\.(gz|bz2|xz|zst))?$", nm, perl = TRUE)
  L[, ext := ""]
  L[has_ext, ext := tolower(sub("^.*?((\\.[A-Za-z0-9]{1,10})(\\.(gz|bz2|xz|zst))?)$", "\\1", nm[has_ext], perl = TRUE))]
  rm(nm, has_ext)
  L[, year := as.integer(format(as.POSIXct(mtime_epoch, origin = "1970-01-01"), "%Y"))]
  G <- L[, .(size_bytes = sum(size_bytes), alloc_blocks = sum(alloc_blocks), mtime_epoch = max(mtime_epoch),
             n_files = .N), by = .(dir, ext, owner, year, stubbed)]
  rm(L)
  G[, path := sprintf("%s/[%s files under %s MB]%s", dir, format(n_files, big.mark = ",", trim = TRUE), mb, ext)]
  # Combined rows are not hard links of anything: each gets its own (negative) inode
  G[, `:=`(inode = -seq_len(.N), nlinks = 1L)]
  cat(sprintf("%s small files (under %s MB) combined into %s rows; %s lines in all now\n",
              format(length(lump), big.mark = ","), mb, format(nrow(G), big.mark = ","),
              format(nrow(s) - length(lump) + nrow(G), big.mark = ",")))
  s[, n_files := 1L]
  cols <- names(s)
  rbind(s[-lump], G[, ..cols])
}

# ---- One tab: its files classified (the rest of load_classified()) ---------------------------------------
# Each tab is classified on its own files: the rules look for copies across a page's projects, so
# the Total (which also finds copies between folders) can't stand in for the folder tabs.
classify_scope <- function(s, scan_root, project_level, rp, rules, rules_raw, register_file, now) {
  scan_root <- sub("/+$", "", scan_root)
  inside <- startsWith(s$path, if (scan_root == "") "/" else paste0(scan_root, "/"))
  # Lines outside this tab are in the other tabs; the page counts as "outside" only lines outside
  # every tab (n_outside_all, set below), as each tab's own scan part would
  n_outside <- n_outside_all
  # A tab holding every line uses the lines already read rather than a second copy of them
  if (!all(inside)) s <- s[inside]
  if (!nrow(s)) stop("no scanned file is under ", scan_root)
  # The tab's scan lines, as 03_split_tabs.sh counts them for the front page (before hard links)
  lines <- c(files = if ("n_files" %in% names(s)) sum(s$n_files) else nrow(s), bytes = sum(s$size_bytes))
  # Hard links counted once within the tab, as the tabbed report does
  if ("inode" %in% names(s) && any(s$nlinks > 1 & duplicated(s$inode), na.rm = TRUE))
    s <- s[is.na(inode) | !(nlinks > 1 & duplicated(inode))]
  # Project = the first project_level folders below scan_root
  rel_root <- substring(s$path, nchar(scan_root) + 2)
  project <- sub(sprintf("^([^/]+(?:/[^/]+){0,%d}).*$", project_level - 1), "\\1", dirname(rel_root), perl = TRUE)
  f <- data.table(project = ifelse(project == ".", "(top level)", project),
                  rel = ifelse(project == ".", rel_root, substring(rel_root, nchar(project) + 2)),
                  rel_root = rel_root,
                  size_bytes = s$size_bytes, alloc_bytes = s$alloc_blocks * 512,
                  mtime = as.POSIXct(s$mtime_epoch, origin = "1970-01-01"),
                  inode = if ("inode" %in% names(s)) s$inode else seq_len(nrow(s)),
                  owner = if ("owner" %in% names(s)) s$owner else NA_character_,
                  # files per row: 1, or the number of small files in a combined row
                  n = if ("n_files" %in% names(s)) s$n_files else 1L)
  # Archived (stubbed): >= 64 KiB with < 10 % allocated; a combined row was decided file by file
  if ("stubbed" %in% names(s)) f[, stubbed := s$stubbed] else
    f[, stubbed := size_bytes >= 64 * 1024 & alloc_bytes < 0.10 * size_bytes]
  rm(s, rel_root, project)
  f[is.na(owner) | owner == "", owner := "(not recorded)"]
  f[grepl("^[0-9]+$", owner), owner := sprintf("Unknown (ID %s)", owner)]
  # A modification date after the scan is impossible (a wrong clock or a damaged timestamp; seen up to
  # the year 2101). Such a file takes the newest real date in its folder, else in its project, else
  # the build time, so it can't make a project look recently changed. The count is reported.
  fut <- which(f$mtime > now)
  if (length(fut)) {
    fdir <- dirname(f$rel_root); need <- unique(fdir[fut])
    sel <- which(fdir %chin% need & f$mtime <= now)
    by_dir <- data.table(d = fdir[sel], t = as.numeric(f$mtime[sel]))[, .(t = max(t)), by = d]
    by_proj <- f[mtime <= now & project %chin% unique(f$project[fut]), .(t = max(as.numeric(mtime))), by = project]
    v <- by_dir$t[match(fdir[fut], by_dir$d)]
    miss <- is.na(v); v[miss] <- by_proj$t[match(f$project[fut][miss], by_proj$project)]
    v[is.na(v)] <- as.numeric(now)
    f[fut, mtime := as.POSIXct(v, origin = "1970-01-01")]
    message(sprintf("%d file(s) dated after the scan took the newest real date of their folder or project", length(fut)))
    rm(fdir, need, sel, by_dir, by_proj, v, miss)
  }
  rm(fut)
  # Classify every row, then attach each rule's category
  cl <- classify_files(f[, .(project, rel, size_bytes, mtime, inode)], rules, repo = rp$repo, now = now, repo_samples = rp$repo_samples)
  cat_of <- c(setNames(vapply(rules$rules, `[[`, "", "category"), vapply(rules$rules, `[[`, "", "id")),
              setNames(rules$default$category, rules$default$id))
  f[, `:=`(rule_id = cl$rule_id, category = cat_of[cl$rule_id], file_class = cl$file_class,
           origin = cl$origin, lineage = cl$lineage, folder_idle_years = cl$folder_idle_years,
           repro_tier = cl$repro_tier, process_record = cl$process_record, rule_before_gate = cl$rule_before_gate)]
  rm(cl)
  # Per project: size and when it last changed (scratch and software files ignored for the date)
  proj <- f[, .(files = sum(n), real = sum(size_bytes),
                last_change = { x <- mtime[!category %in% c("scratch", "software")]
                                if (length(x)) max(x) else max(mtime) }), by = project]
  # Suggested sensitivity: the register, else the suspect paths, else not sensitive
  reg <- if (file.exists(register_file)) fread(register_file, sep = "\t") else
    data.table(project = character(), sensitivity = character())
  for (col in c("required_record", "legal_hold")) if (!col %in% names(reg)) reg[, (col) := NA_character_]
  sus_rx <- rules_raw$sensitivity$suspect_regex
  hits <- f[grepl(sus_rx, rel, ignore.case = TRUE, perl = TRUE) & !not_data_evidence(rel, rules),
            .(hit = regmatches(rel[1], regexpr(sus_rx, rel[1], ignore.case = TRUE, perl = TRUE)), n_hit = sum(n)),
            by = project]
  proj <- merge(proj, hits, by = "project", all.x = TRUE)
  proj <- merge(proj, reg[, .(project, sensitivity, required_record, legal_hold)], by = "project", all.x = TRUE)
  proj[, `:=`(
    sensitive = fifelse(!is.na(sensitivity), grepl("patient|clinical|controlled", sensitivity), !is.na(hit)),
    sensitive_why = fifelse(!is.na(sensitivity), paste0("register: ", sensitivity),
                            fifelse(!is.na(hit), sprintf("%s path(s) match '%s'", n_hit, hit),
                                    "nothing suspicious in the paths")))]
  # Suggested status and data category
  age_months <- as.numeric(difftime(now, proj$last_change, units = "days")) / 30.44
  proj[, status := fifelse(age_months <= rules$thresholds$active_months, "active", "inactive_unpublished")]
  is_pub <- proj$status == "inactive_published"
  level <- function(w) grepl(w, ifelse(is.na(proj$sensitivity), "", proj$sensitivity))
  proj[, `:=`(policy_known = !is.na(sensitivity),
    required_record = required_record %chin% "yes",
    data_category = fifelse(legal_hold %chin% "yes", "legal_hold",
      fifelse(level("diagnostic|clinical"), "diagnostic",
      fifelse(level("permanent"), "permanent_genetic",
      fifelse(level("trial"), "clinical_trial",
      fifelse(level("minors"), "minors",
      fifelse(level("patient|controlled"), fifelse(is_pub, "patient_published", "patient_unpublished"),
      fifelse(is.na(sensitivity) & sensitive, "suspected_patient",
              fifelse(is_pub, "ordinary_published", "ordinary_unpublished")))))))))]
  setorder(proj, -real)
  list(f = f, proj = proj, n_outside = n_outside, rules = rules, rules_raw = rules_raw, scan_root = scan_root, lines = lines)
}

# ---- One tab: its page data, exactly as 02_build_storage_report.R builds it ------------------------------
page_data <- function(x, project_level, scan_name, repo_file, register_file, now) {
  f <- x$f; proj <- x$proj
  f[, `:=`(p = match(project, proj$project) - 1L, r = rule_index(x, rule_id))]
  # File owners, largest first (with only one owner the page shows no person section)
  owner_names <- f[, .(real = sum(size_bytes)), by = owner][order(-real), owner]
  has_owners <- length(owner_names) > 1
  f[, o := match(owner, owner_names) - 1L]
  # Folder tree: every folder that holds files, plus all its ancestors
  f[, dir := fifelse(dirname(rel_root) == ".", "", dirname(rel_root))]
  dirs_with_files <- unique(f$dir)
  anc <- unique(unlist(lapply(strsplit(dirs_with_files[dirs_with_files != ""], "/", fixed = TRUE), function(p)
    Reduce(function(a, b) paste(a, b, sep = "/"), p, accumulate = TRUE))))
  dirs <- data.table(path = c("", sort(anc)))
  dirs[, `:=`(i = .I - 1L, name = fifelse(path == "", basename(x$scan_root), basename(path)),
              parent_path = fifelse(grepl("/", path), dirname(path), fifelse(path == "", NA_character_, "")))]
  dirs[, depth := fifelse(path == "", 0L, lengths(regmatches(path, gregexpr("/", path, fixed = TRUE))) + 1L)]
  # Cap the tree at DIR_MAX folders (largest first, plus projects and their parents)
  dir_max <- as.numeric(Sys.getenv("DIR_MAX", "20000"))
  n_dirs_all <- nrow(dirs)
  dirs[, below := 0]
  own <- f[, .(real = sum(size_bytes)), by = dir]
  dirs[own, below := i.real, on = .(path = dir)]
  for (lv in rev(seq_len(max(dirs$depth)))) {
    up <- dirs[depth == lv, .(add = sum(below)), by = parent_path]
    dirs[up, below := below + i.add, on = .(path = parent_path)]
  }
  keep <- if (n_dirs_all <= dir_max) rep(TRUE, n_dirs_all) else
    seq_len(n_dirs_all) %in% head(order(-dirs$below), dir_max) | dirs$path %chin% c("", x$proj$project)
  par_row <- match(dirs$parent_path, dirs$path)
  for (lv in rev(seq_len(max(dirs$depth)))) {
    kids <- which(dirs$depth == lv & keep)
    keep[par_row[kids]] <- TRUE
  }
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
  # The project each folder belongs to; folders above project level belong to none (-1)
  dir_proj <- sub(sprintf("^([^/]+(?:/[^/]+){0,%d}).*$", project_level - 1), "\\1", dirs$path, perl = TRUE)
  dir_proj[dirs$path == ""] <- "(top level)"
  dirs[, p := match(dir_proj, proj$project) - 1L]
  dirs[is.na(p), p := -1L]
  # The three largest files directly in each folder
  dtop <- f[order(-size_bytes), .(names = list(head(fname, 3)), sizes = list(head(size_bytes, 3))), by = d]
  dirs[, `:=`(top_names = list(character()), top_sizes = list(numeric()))]
  dirs[dtop$d + 1L, `:=`(top_names = dtop$names, top_sizes = dtop$sizes)]
  # Files directly in each folder, by project, rule and owner
  cells <- f[, .(files = sum(n), real = sum(size_bytes), alloc = sum(alloc_bytes),
                 arch = sum(size_bytes[stubbed]),
                 mday = as.integer(as.numeric(max(mtime)) %/% 86400)), by = .(d, p, r, o)]
  # File types: last extension, keeping a compression suffix
  nm <- basename(f$rel_root)
  has_ext <- grepl("\\.[A-Za-z0-9]{1,10}(\\.(gz|bz2|xz|zst))?$", nm, perl = TRUE)
  f[, ext := "(no extension)"]
  f[has_ext, ext := tolower(sub("^.*?((\\.[A-Za-z0-9]{1,10})(\\.(gz|bz2|xz|zst))?)$", "\\1", nm[has_ext], perl = TRUE))]
  rm(nm, has_ext)
  ext_names <- f[, .(real = sum(size_bytes)), by = ext][order(-real), ext]
  types <- f[, .(files = sum(n), real = sum(size_bytes)), by = .(e = match(ext, ext_names) - 1L, p, r, o)]
  # Real size per year last changed
  f[, year := as.integer(format(mtime, "%Y"))]
  years <- f[, .(files = sum(n), real = sum(size_bytes), arch = sum(size_bytes[stubbed])), by = .(year, p, r, o)]
  # The 100 largest files (or combined rows)
  top_i <- head(order(-f$size_bytes), 100)
  top <- f[top_i, .(path = rel_root, p, r, size = size_bytes, stubbed, date = format(mtime, "%Y-%m-%d"), o)]
  top[, k := top_i - 1L]
  # Every row, for the cart (left out above FILE_LIST_MAX rows)
  file_max <- as.numeric(Sys.getenv("FILE_LIST_MAX", "250000"))
  files <- if (nrow(f) <= file_max)
    list(d = I(f$d), name = I(f$fname), size = I(f$size_bytes), p = I(f$p),
         r = I(f$r), arch = I(as.integer(f$stubbed)), e = I(match(f$ext, ext_names) - 1L),
         o = if (has_owners) I(f$o)) else list()
  # The full file list for beside the cart
  rule_ids <- c(vapply(x$rules$rules, `[[`, "", "id"), x$rules$default$id)
  rule_cols <- c(vapply(x$rules$rules, `[[`, "", "colour"), x$rules$default$colour)
  file_list <- function() f[order(-size_bytes), .(path = file.path(x$scan_root, rel_root), size_bytes, modified = format(mtime, "%Y-%m-%d"),
                                                 owner, project, rule = rule_ids[r + 1L], rule_colour = rule_cols[r + 1L], archived = as.integer(stubbed))]
  # Everything the page needs (meta$file_list is set per page)
  data <- c(list(meta = list(
    scans = I(scan_name), scan_root = x$scan_root, n_outside = x$n_outside,
    repo_file = if (nzchar(repo_file)) basename(repo_file) else "",
    register = if (file.exists(register_file)) basename(register_file) else "",
    rules_version = x$rules$version, built = format(now, "%Y-%m-%d %H:%M"),
    active_months = x$rules$thresholds$active_months, n_files = sum(f$n),
    project_level = project_level, has_files = length(files) > 0,
    n_dirs_all = n_dirs_all, n_dirs_shown = nrow(dirs), file_list = "")),
    page_common(x),
    list(dirs = list(name = I(dirs$name), parent = I(dirs$parent), p = I(dirs$p),   # I(): stays a list with one folder
                     top_names = dirs$top_names, top_sizes = dirs$top_sizes),
         files = files,
         owners = if (has_owners) I(owner_names) else I(character()),
         cells = unname(as.matrix(cells[, .(d, p, r, files, real, alloc, arch, mday, o)])),
         ext_names = I(ext_names),
         types = unname(as.matrix(types[, .(e, p, r, files, real, o)])),
         years = unname(as.matrix(years[, .(year, p, r, files, real, arch, o)])),
         top = list(path = I(top$path), p = I(top$p), r = I(top$r), size = I(top$size),
                    stubbed = I(top$stubbed), date = I(top$date), k = I(top$k), o = I(top$o))))
  list(data = data, file_list = file_list, n_files = sum(f$n), bytes = sum(f$size_bytes), n_dirs = nrow(dirs),
       n_dirs_all = n_dirs_all, file_max = file_max)
}

# The overview's changes to the data (as 02b_build_overview.R)
prepare_overview <- function(data) {
  data$categories <- lapply(data$categories, function(x) x[c("id", "label")])
  data$statuses <- lapply(data$statuses, function(x) x[setdiff(names(x), "description")])
  data
}

# ---- Build: settings shared by all tabs, then the scan, then each tab -----------------------------------
repo_file <- Sys.getenv("REPO_FILE", "")
register_file <- Sys.getenv("REGISTER", "none")
now <- Sys.time()
rules_file <- "../rules/cleanup_rules.yaml"
rules <- load_rules(rules_file)
rules_raw <- yaml::read_yaml(rules_file)
rp <- read_repo(repo_file)
t0 <- Sys.time()
s <- read_scan(scan)
cat(sprintf("%s read %s files from %s\n", stamp(), format(nrow(s), big.mark = ","), basename(scan)))
# Scan lines under none of the folders (none expected: the scan lists only them)
n_outside_all <- sum(!Reduce(`|`, lapply(folders, function(f) startsWith(s$path, paste0(sub("/+$", "", f), "/")))))

# Very large scans: small files combined, and the front page told so (lumped.txt)
lump_above <- as.numeric(Sys.getenv("LUMP_ABOVE", "5000000"))
lump_mb <- as.numeric(Sys.getenv("LUMP_MB", "1"))
unlink(file.path(report_dir, "lumped.txt"))
if (nrow(s) > lump_above) {
  s <- lump_small(s, rules, rules_raw, lump_mb)
  writeLines(sprintf("%s MB\t%s", lump_mb, format(sum(s$n_files[s$inode < 0]), big.mark = ",")), file.path(report_dir, "lumped.txt"))
  invisible(gc())
  cat(sprintf("%s combined small files\n", stamp()))
}

# Each tab: classify, build the page data once, write the overview and the cart (with its file list).
# A tab that fails leaves overview.failed / cart.failed and its message, as 04_build_page.sh does,
# and the other tabs still build. Its files and bytes go into tabs.tsv for the front page.
tabs$files <- 0; tabs$bytes <- 0; failed <- 0
for (i in seq_len(nrow(tabs))) {
  d <- file.path(report_dir, tabs$tab[i])
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  unlink(file.path(d, c("overview.failed", "cart.failed")))
  ok <- tryCatch({
    x <- classify_scope(s, tabs$root[i], tabs$project_level[i], rp, rules, rules_raw, register_file, now)
    cat(sprintf("%s %s: classified %s rows\n", stamp(), tabs$label[i], format(nrow(x$f), big.mark = ",")))
    pd <- page_data(x, tabs$project_level[i], basename(scan), repo_file, register_file, now)
    tabs$files[i] <- x$lines[["files"]]; tabs$bytes[i] <- x$lines[["bytes"]]
    ov <- pd$data; ov$meta$file_list <- ""
    embed_page(prepare_overview(ov), "storage_overview_template.html", file.path(d, "overview.html"))
    rm(ov)
    list_file <- file.path(d, "cart_files.tsv.gz")
    fwrite(pd$file_list(), list_file, sep = "\t", quote = FALSE, compress = "gzip")
    pd$data$meta$file_list <- basename(list_file)
    size <- embed_page(pd$data, "storage_report_template.html", file.path(d, "cart.html"))
    cat(sprintf("%s %s: overview and cart written (%s files, %d of %d folders shown)\n", stamp(), tabs$label[i],
                format(pd$n_files, big.mark = ","), pd$n_dirs, pd$n_dirs_all))
    if (!length(pd$data$files)) cat(sprintf("  more than FILE_LIST_MAX (%s) rows: the cart page has no cart; the full list is beside it\n",
                                            format(pd$file_max, big.mark = ",", scientific = FALSE)))
    if (size > 50 * 1024^2) cat(sprintf("  WARNING: cart.html is %.0f MB and may be slow or fail to open\n", size / 1024^2))
    rm(x, pd); invisible(gc())
    TRUE
  }, error = function(e) {
    for (v in c("overview", "cart")) { file.create(file.path(d, paste0(v, ".failed"))); writeLines(conditionMessage(e), file.path(d, paste0(v, "_messages.txt"))) }
    message("ERROR: ", tabs$label[i], ": ", conditionMessage(e))
    FALSE
  })
  if (!ok) failed <- failed + 1
}

# The tab list for 05_write_index.sh (same columns as 03_split_tabs.sh writes)
tabs$scan <- scan
fwrite(data.table(tab = tabs$tab, label = tabs$label, root = tabs$root, project_level = tabs$project_level,
                  scan = tabs$scan, files = tabs$files, bytes = sprintf("%.0f", tabs$bytes)),
       file.path(report_dir, "tabs.tsv"), sep = "\t", quote = FALSE)
cat(sprintf("%s all %d tab(s) done in %.1f min%s\n", stamp(), nrow(tabs), as.numeric(difftime(Sys.time(), t0, units = "mins")),
            if (failed) sprintf(", %d could not be built", failed) else ""))
if (failed) quit(status = 1)
