# Used by 02_build_storage_report.R:
# read scans, classify every file with the cleanup rules, suggest each project's status
# and sensitivity, and embed data into an HTML template. Function library only.
# Metadata only: reads scan files (01b output), never the scanned data.

suppressMessages(library(data.table))
source("cleanup_classifier.R")

# Read and classify one or more scans.
#   scans          scan_<date>.tsv.gz files from 01_scan_storage.sh
#   scan_root      folder whose sub-folders are the projects
#   project_level  folder levels below scan_root that make up a project
#   repo_file      sequencing-repository list (see data/README.md; "" = none: raw FASTQ all stay red). If
#                  repo_samples_hashed_<date>.tsv.gz (03d) sits beside it, that is used too.
#   register_file  project register .tsv (used only if it exists)
# Returns list(f = one row per file, proj = one row per project, n_outside, rules, rules_raw).
load_classified <- function(scans, scan_root, project_level = 1L, repo_file = "",
                            register_file = "../rules/project_register.tsv",
                            rules_file = "../rules/cleanup_rules.yaml", now = Sys.time()) {
  for (s in scans) if (!file.exists(s)) stop("scan file not found: ", s)
  scan_root <- sub("/+$", "", scan_root)
  rules <- load_rules(rules_file)
  rules_raw <- yaml::read_yaml(rules_file)

  # Read the scans. Sizes as plain numbers (integer64 breaks sums and comparisons);
  # hard links counted once; only files under scan_root are used, the rest are counted
  # Owner is text even when it looks like a number; scans made before v3 have no owner column.
  # Sizes are always numeric: read as integers, a person with no file over 2 GiB fails on summing them.
  rd <- function(f) {
    con <- gzfile(f); header <- strsplit(readLines(con, n = 1), "\t", fixed = TRUE)[[1]]; close(con)
    # A file name can hold a tab, which would stop the read part way through the scan without an
    # error. The path is the last column, so extra columns are joined back into it with a space.
    # A name holding a line break is kept under the part before the break, with its size; the short
    # line after it holds nothing usable, so it is left out and counted.
    join <- paste0("awk -F'\\t' -v OFS='\\t' 'NR==1{w=NF; print; next} NF==w{print; next} ",
                   "NF>w{p=$w; for(i=w+1;i<=NF;i++) p=p \" \" $i; print_line=\"\"; for(i=1;i<w;i++) print_line=print_line $i OFS; print print_line p; next} ",
                   "{bad++} END{if(bad>0) printf \"%d scan lines left out\\n\", bad > \"/dev/stderr\"}'")
    fread(cmd = paste("gzip -dc", shQuote(f), "|", join), sep = "\t", quote = "",
          colClasses = list(character = intersect(c("path", "owner"), header), numeric = intersect(c("size_bytes", "alloc_blocks"), header)), integer64 = "double")
  }
  s <- rbindlist(lapply(scans, rd), fill = TRUE)
  if ("inode" %in% names(s)) s <- s[is.na(inode) | !(nlinks > 1 & duplicated(inode))]
  inside <- startsWith(s$path, paste0(scan_root, "/"))
  n_outside <- sum(!inside)
  s <- s[inside]
  if (!nrow(s)) stop("no scanned file is under ", scan_root)

  # Project = the first project_level folders below scan_root; files higher up belong to
  # the folder they are in, and files directly in scan_root form "(top level)".
  # rel_root = path below scan_root (for folder trees), rel = path inside the project.
  rel_root <- substring(s$path, nchar(scan_root) + 2)
  project <- sub(sprintf("^([^/]+(?:/[^/]+){0,%d}).*$", project_level - 1), "\\1",
                 dirname(rel_root), perl = TRUE)
  f <- data.table(project = ifelse(project == ".", "(top level)", project),
                  rel = ifelse(project == ".", rel_root, substring(rel_root, nchar(project) + 2)),
                  rel_root = rel_root,
                  size_bytes = s$size_bytes, alloc_bytes = s$alloc_blocks * 512,
                  mtime = as.POSIXct(s$mtime_epoch, origin = "1970-01-01"),
                  inode = if ("inode" %in% names(s)) s$inode else seq_len(nrow(s)),
                  owner = if ("owner" %in% names(s)) s$owner else NA_character_)
  # find prints a number when an account has no name, often someone who has left
  f[is.na(owner) | owner == "", owner := "(not recorded)"]
  f[grepl("^[0-9]+$", owner), owner := sprintf("Unknown (ID %s)", owner)]

  # Archived (stubbed) files: >= 64 KiB with < 10 % allocated
  f[, stubbed := size_bytes >= 64 * 1024 & alloc_bytes < 0.10 * size_bytes]

  # Optional repository list (03a) for the raw-data rules
  repo <- if (nzchar(repo_file)) {
    if (!file.exists(repo_file)) stop("repository list not found: ", repo_file)
    rp <- fread(cmd = paste("gzip -dc", shQuote(repo_file)), sep = "\t", quote = "", integer64 = "double")
    # A hashed list (03c) has one column, key; a readable list (03a) has name and size
    if ("key" %in% names(rp)) rp[, .(key = as.character(key))] else rp[, .(name, size_bytes)]
  } else NULL

  # Optional repository sample list (03d), found beside the repository list
  repo_samples <- NULL
  if (nzchar(repo_file)) {
    sf <- file.path(dirname(repo_file), sub("^repo_fastqs(_hashed)?_", "repo_samples_hashed_", basename(repo_file)))
    if (file.exists(sf)) repo_samples <- fread(cmd = paste("gzip -dc", shQuote(sf)), sep = "\t", integer64 = "double",
                                               colClasses = list(character = "key"))
  }

  # Classify every file, then attach each rule's category
  cl <- classify_files(f[, .(project, rel, size_bytes, mtime, inode)], rules, repo = repo, now = now, repo_samples = repo_samples)
  cat_of <- c(setNames(vapply(rules$rules, `[[`, "", "category"), vapply(rules$rules, `[[`, "", "id")),
              setNames(rules$default$category, rules$default$id))
  f[, `:=`(rule_id = cl$rule_id, category = cat_of[cl$rule_id], file_class = cl$file_class,
           origin = cl$origin, lineage = cl$lineage, folder_idle_years = cl$folder_idle_years,
           repro_tier = cl$repro_tier, process_record = cl$process_record, rule_before_gate = cl$rule_before_gate)]

  # Per project: size, and when it last changed. Scratch and software files are ignored
  # for the date (a cache touched by a re-run does not make the research data newer).
  proj <- f[, .(files = .N, real = sum(size_bytes),
                last_change = { x <- mtime[!category %in% c("scratch", "software")]
                                if (length(x)) max(x) else max(mtime) }), by = project]

  # Suggested sensitivity: the register if the project is declared there (patient,
  # clinical or controlled = sensitive; none = not), otherwise sensitive when any path
  # looks like patient or controlled data (suspect_regex), otherwise not sensitive
  reg <- if (file.exists(register_file)) fread(register_file, sep = "\t") else
    data.table(project = character(), sensitivity = character())
  # Declarations added in rules 0.7.0; older registers simply don't have them
  for (col in c("required_record", "legal_hold")) if (!col %in% names(reg)) reg[, (col) := NA_character_]
  sus_rx <- rules_raw$sensitivity$suspect_regex
  hits <- f[grepl(sus_rx, rel, ignore.case = TRUE, perl = TRUE) & !not_data_evidence(rel, rules),
            .(hit = regmatches(rel[1], regexpr(sus_rx, rel[1], ignore.case = TRUE, perl = TRUE)), n_hit = .N),
            by = project]
  proj <- merge(proj, hits, by = "project", all.x = TRUE)
  proj <- merge(proj, reg[, .(project, sensitivity, required_record, legal_hold)], by = "project", all.x = TRUE)
  proj[, `:=`(
    sensitive = fifelse(!is.na(sensitivity), grepl("patient|clinical|controlled", sensitivity), !is.na(hit)),
    sensitive_why = fifelse(!is.na(sensitivity), paste0("register: ", sensitivity),
                            fifelse(!is.na(hit), sprintf("%s path(s) match '%s'", n_hit, hit),
                                    "nothing suspicious in the paths")))]

  # Suggested status: Active if anything changed within active_months, else not
  # published (the cautious choice - the owner says whether it was published)
  age_months <- as.numeric(difftime(now, proj$last_change, units = "days")) / 30.44
  proj[, status := fifelse(age_months <= rules$thresholds$active_months, "active", "inactive_unpublished")]
  # Data category for the retention matrix. A project nobody has declared has an unknown policy,
  # shown as policy_known = FALSE, and is treated by what its status and paths suggest.
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
  list(f = f, proj = proj, n_outside = n_outside, rules = rules, rules_raw = rules_raw,
       scan_root = scan_root)
}

# Final colour of every file, from most to least binding:
#  1. all_red categories (legal hold, diagnostic, permanent genetic) keep everything red
#  2. a required record's only copy is red; otherwise a required record is at most amber
#  3. trial and minors projects keep primary and derived files red
#  4. while a project's retention hold runs, raw data shows red and other held files amber
#  5. the category's max_colour caps what is left, so patient data never goes beyond amber
effective_colour <- function(f, proj, rules_raw, now = Sys.time()) {
  cats <- rbindlist(lapply(rules_raw$data_categories, function(x)
    data.table(data_category = x$id, max_colour = x$max_colour, all_red = isTRUE(x$all_red),
               derived_red = isTRUE(x$derived_red), years = as.numeric(x$retention_years))))
  st <- rbindlist(lapply(rules_raw$project_status, function(s) data.table(status = s$id, clock = s$clock, locked = list(unlist(s$locked)))))
  colours <- rbindlist(lapply(c(rules_raw$rules, list(rules_raw$default)), function(r) data.table(rule_id = r$id, colour = r$colour)))
  pj <- merge(merge(proj[, .(project, status, last_change, data_category, required_record)], st, by = "status"), cats, by = "data_category")
  pj[, held_years := as.numeric(difftime(now, as.POSIXct(as.Date(last_change)), units = "days")) / 365.25]
  x <- merge(f[, .(id = .I, project, rule_id, category, file_class, lineage)], pj, by = "project", sort = FALSE)
  x <- merge(x, colours, by = "rule_id", sort = FALSE)
  x[, held := mapply(function(cat, l) cat %in% l, category, locked) & (clock == "none" | held_years < years)]
  x[, eff := colour]
  x[held == TRUE & category == "raw", eff := "red"]
  x[held == TRUE & category != "raw" & eff == "green", eff := "amber"]
  x[max_colour == "amber" & eff == "green", eff := "amber"]
  x[required_record == TRUE & eff == "green", eff := "amber"]
  x[required_record == TRUE & lineage == "raw_not_found", eff := "red"]
  x[derived_red == TRUE & file_class %chin% c("primary", "derived"), eff := "red"]
  x[all_red == TRUE, eff := "red"]
  x[order(id), eff]
}

# The parts every page shares: rules, categories, statuses, retention and projects
page_common <- function(x) {
  rr <- x$rules_raw
  list(
    categories = lapply(rr$categories, function(c) c[c("id", "label", "description")]),
    statuses = lapply(rr$project_status, function(s)
      list(id = s$id, label = s$label, description = s$description, clock = s$clock, locked = I(unlist(s$locked)))),
    retention = list(nonsensitive_years = rr$retention$nonsensitive_years,
                     sensitive_years = rr$retention$sensitive_years,
                     sources = I(unlist(rr$retention$sources))),
    rules = lapply(c(rr$rules, list(rr$default)), function(r)
      list(id = r$id, title = r$title, colour = r$colour, category = r$category)),
    projects = lapply(seq_len(nrow(x$proj)), function(i) with(x$proj[i], list(
      name = project, files = files, real = real, last_change = format(last_change, "%Y-%m-%d"),
      sensitive = sensitive, sensitive_why = sensitive_why, status = status))))
}

# Index of each rule id in page_common()$rules (0-based, for JavaScript)
rule_index <- function(x, ids) {
  all_ids <- c(vapply(x$rules$rules, `[[`, "", "id"), x$rules$default$id)
  match(ids, all_ids) - 1L
}

# Write the data into the template's /*__DATA__*/null placeholder. "</" is escaped so
# no name can close the <script> tag.
embed_page <- function(data, template_file, out_file) {
  if (!file.exists(template_file)) stop("template not found: ", template_file)
  json <- gsub("</", "<\\/", jsonlite::toJSON(data, auto_unbox = TRUE, digits = NA), fixed = TRUE)
  page <- readLines(template_file, warn = FALSE)
  slot <- grep("/*__DATA__*/", page, fixed = TRUE)
  if (length(slot) != 1) stop("template must contain the /*__DATA__*/ placeholder exactly once")
  page[slot] <- sub("/*__DATA__*/null", json, page[slot], fixed = TRUE)
  dir.create(dirname(out_file), showWarnings = FALSE, recursive = TRUE)
  writeLines(page, out_file)
  invisible(file.size(out_file))
}
