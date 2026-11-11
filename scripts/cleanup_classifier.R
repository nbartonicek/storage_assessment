# Classifier that applies rules/cleanup_rules.yaml to a file list.
# Function library only (no analysis, no figures): sourced by the .Rmd reports so the
# rules document, its tests and the cleanup reports all use exactly the same code.
#
# Main entry point:
#   classify_files(files, rules, repo = NULL, now = Sys.time(), repo_samples = NULL)
#     files  data.table: project, rel (path inside the project, no leading "/"),
#            size_bytes, mtime (POSIXct); optional inode (hard links share one and
#            are then never treated as copies of each other)
#     rules  list from load_rules()
#     repo   data.table of repository FASTQs with name, size_bytes (or NULL = none known)
#     repo_samples  data.table from 03d: key, dirs, bytes, newest, one row per repository
#            sample (or NULL = BAMs and trimmed FASTQ are only compared within the project)
#   returns files with added columns: rule_id, colour, rule_title, project_status, and the
#   separate fields file_class, origin, lineage, folder_idle_years

library(data.table)

# One-way key for a repository file: a salted SHA-256 of its name and exact size, cut to
# 16 characters. Lets a file be matched without the list showing any file names.
repo_key <- function(name, size_bytes) {
  if (!requireNamespace("digest", quietly = TRUE)) stop("R package 'digest' is needed for a hashed repository list")
  hash <- digest::getVDigest("sha256")
  substr(hash(paste0("storage_repo_v1\t", name, "\t", sprintf("%.0f", size_bytes)), serialize = FALSE), 1, 16)
}

# One-way key for a repository sample name, so samples can be matched without the list
# showing them.
sample_key <- function(sample) {
  if (!requireNamespace("digest", quietly = TRUE)) stop("R package 'digest' is needed for the repository sample list")
  hash <- digest::getVDigest("sha256")
  substr(hash(paste0("storage_repo_sample_v1\t", sample), serialize = FALSE), 1, 16)
}

# Read the YAML rules and expand "@name" shared patterns and named thresholds,
# so the rest of the code only sees plain regexes and numbers.
load_rules <- function(path) {
  r <- yaml::read_yaml(path)
  expand <- function(x) {
    if (is.null(x)) return(NULL)
    for (nm in names(r$patterns)) x <- gsub(paste0("@", nm), r$patterns[[nm]], x, fixed = TRUE)
    x
  }
  as_mb <- function(x) if (is.null(x)) NULL else if (is.character(x)) r$thresholds[[x]] else x
  expand_entry <- function(rule) {
    m <- rule$match
    m$name_regex <- expand(m$name_regex)
    m$path_regex <- expand(m$path_regex)
    m$exclude_path_regex <- expand(m$exclude_path_regex)
    m$min_mb <- as_mb(m$min_mb)
    m$max_mb <- as_mb(m$max_mb)
    m$ext <- if (is.null(m$ext)) NULL else tolower(sub("^\\.", "", unlist(m$ext)))
    rule$match <- m
    rule
  }
  # Rules and file classes use the same match keys
  r$rules <- lapply(r$rules, expand_entry)
  r$file_classes <- lapply(r$file_classes, expand_entry)
  r
}

# Extension used for matching: the last one after dropping a compression suffix,
# so x.fa.gz -> "fa" and x.fastq.ora -> "fastq". ORA (Illumina) counts as compression.
base_ext <- function(name) {
  n <- tolower(sub("\\.(gz|bz2|xz|zst|ora)$", "", name, ignore.case = TRUE))
  ifelse(grepl(".", n, fixed = TRUE), sub("^.*\\.", "", n), "")
}

# Sample name shared by a FASTQ and what was made from it, lower case. Only the end of the
# name is removed, one known piece at a time; anything unexpected is left in place, so an
# unusual name fails to match rather than matching the wrong sample.
.trim_end <- "([._](val_[12]|unpaired_[12]|trimmed|trim|paired|unpaired|fastp))+$"
sample_from_fastq <- function(name) {
  x <- tolower(sub("\\.(fastq|fq)(\\.(gz|bz2|xz|zst|ora))?$", "", name, ignore.case = TRUE))
  x <- sub(.trim_end, "", x, perl = TRUE)
  x <- sub("[._]r?[12](_001)?$", "", x, perl = TRUE)      # read number, once only
  x <- sub(.trim_end, "", x, perl = TRUE)
  x <- sub("_l00[1-8]$", "", x, perl = TRUE)
  sub("_s[0-9]+$", "", x, perl = TRUE)
}
# The same for a BAM. A bare _1 or _2 is kept: BAMs have no read number, so rep_1 and
# rep_2 are different samples here.
sample_from_bam <- function(name) {
  # A name that still carries its FASTQ name, such as x_R1.fastq.gz_trimmed_bismark_bt2.bam,
  # is read as that FASTQ, so its read number is removed too
  from_fq <- grepl("\\.(fastq|fq)(\\.gz)?[._]", name, ignore.case = TRUE, perl = TRUE)
  x <- tolower(sub("\\.bam$", "", name, ignore.case = TRUE))
  x <- sub("([._]?aligned\\.(sortedbycoord\\.out|out|totranscriptome\\.out)|[._](sorted|sort|markdup|md|dedup|rmdup|deduplicated|star|bwa|hisat2|bowtie2|bismark|bt2|mapped|aligned))+$", "", x, perl = TRUE)
  x[from_fq] <- sample_from_fastq(sub("(\\.(fastq|fq)(\\.gz)?).*$", "\\1", name[from_fq], ignore.case = TRUE, perl = TRUE))
  x <- sub(.trim_end, "", x, perl = TRUE)
  x <- sub("[._]r[12](_001)?$", "", x, perl = TRUE)
  x <- sub(.trim_end, "", x, perl = TRUE)
  x <- sub("_l00[1-8]$", "", x, perl = TRUE)
  sub("_s[0-9]+$", "", x, perl = TRUE)
}

# Every ancestor folder of each (project, folder): "a/b/c" -> "a", "a/b", "a/b/c".
# Files directly in the project root (dir ".") have none - the root itself is never
# compared as a folder copy.
anc_table <- function(proj, dir) {
  u <- unique(data.table(proj = proj, dir = dir))[dir != "."]
  parts <- strsplit(u$dir, "/", fixed = TRUE)
  data.table(proj = rep(u$proj, lengths(parts)), dir = rep(u$dir, lengths(parts)),
             anc = as.character(unlist(lapply(parts, function(p)
               Reduce(function(a, b) paste(a, b, sep = "/"), p, accumulate = TRUE)))))
}

# Does each file satisfy one rule's match block? (all listed keys must hold)
# Regexes are case-insensitive and Perl-style (needed for the (?!...) lookahead in G4).
rule_hits <- function(rule, ft, cond) {
  m <- rule$match
  hit <- rep(TRUE, nrow(ft))
  rx <- function(p, x) grepl(p, x, ignore.case = TRUE, perl = TRUE)
  if (!is.null(m$ext))                hit <- hit & ft$ext %in% m$ext
  if (!is.null(m$name_regex))         hit <- hit & rx(m$name_regex, ft$name)
  if (!is.null(m$path_regex))         hit <- hit & rx(m$path_regex, ft$relp)
  if (!is.null(m$exclude_path_regex)) hit <- hit & !rx(m$exclude_path_regex, ft$relp)
  if (!is.null(m$min_mb))             hit <- hit & ft$size_bytes >= m$min_mb * 1024^2
  if (!is.null(m$max_mb))             hit <- hit & ft$size_bytes <= m$max_mb * 1024^2
  for (req in unlist(m$requires)) {
    neg <- startsWith(req, "!")
    key <- sub("^!", "", req)
    if (is.null(cond[[key]])) stop("Rule ", rule$id, " uses unknown condition '", key, "'")
    hit <- hit & (if (neg) !cond[[key]] else cond[[key]])
  }
  hit
}

# Compute the per-file facts ("conditions") the rules refer to.
# Every condition named in the YAML must be produced here - rule_hits() stops otherwise.
compute_conditions <- function(ft, r, repo, now, repo_samples = NULL) {
  th <- r$thresholds
  rule_by_id <- setNames(r$rules, vapply(r$rules, `[[`, "", "id"))
  rx <- function(p, x) grepl(p, x, ignore.case = TRUE, perl = TRUE)

  # Tool caches (Nextflow work, .snakemake, Cell Ranger internals, Spark temp) and installed software
  # are ignored when judging a project's activity, code, raw data and duplicates - a
  # cached copy is not the real thing, and a conda env full of .py files is not "code".
  in_cache <- rx(r$patterns$nextflow_work, ft$relp) | rx(r$patterns$tool_cache, ft$relp) |
              rx(r$patterns$cellranger_internal, ft$relp) | rx(r$patterns$software_env, ft$relp) |
              rx(r$patterns$spark_tmp, ft$relp)
  n <- nrow(ft)
  # Without an inode column every row counts as its own file
  inode <- if ("inode" %in% names(ft)) ft$inode else seq_len(n)

  # Project activity from the newest non-cache file. Months = 30.44 days.
  # Hard-coded fallback: a project with only cache files uses all its files.
  ft[, newest := { x <- mtime[!in_cache[.I]]; if (length(x)) max(x) else max(mtime) }, by = project]
  age_months <- as.numeric(difftime(now, ft$newest, units = "days")) / 30.44
  ft[, project_status := fifelse(age_months <= th$active_months, "Active",
                         fifelse(age_months > th$old_months, "Old", "Inactive"))]

  # Second-level folder activity: the first folder inside the project, or the project itself
  # for files directly in it. Hard-coded fallback as above for folders with only cache files.
  folder <- paste(ft$project, ifelse(grepl("/", ft$rel, fixed = TRUE), sub("/.*$", "", ft$rel), ""), sep = "\t")
  fnew <- data.table(folder = folder, mt = as.numeric(ft$mtime), keep = !in_cache)
  fnew <- fnew[, .(newest = if (any(keep)) max(mt[keep]) else max(mt)), by = folder]
  folder_months <- (as.numeric(now) - fnew$newest[match(folder, fnew$folder)]) / 86400 / 30.44
  folder_idle <- folder_months >= th$byproduct_idle_months

  # Code = anything P1/P1b/P1c would protect, outside caches; raw = untrimmed FASTQ;
  # reads = any FASTQ, raw or trimmed (either can regenerate alignments)
  is_code <- (rule_hits(rule_by_id$P1, ft, list()) | rule_hits(rule_by_id$P1b, ft, list()) |
              rule_hits(rule_by_id$P1c, ft, list())) & !in_cache
  is_fastq <- ft$ext %in% c("fastq", "fq") & !in_cache
  is_raw <- is_fastq & !rx(r$patterns$trimmed_fastq, ft$name)
  ft[, `:=`(has_code = any(is_code[.I]), has_reads = any(is_fastq[.I])), by = project]

  # External public FASTQ: a folder starting with capital GSE, including the project's own
  # folder, or a file name starting with SRR. Case matters, unlike the other patterns.
  full_path <- paste(ft$project, ft$rel, sep = "/")
  acc_external <- grepl(r$patterns$external_folder, full_path, perl = TRUE) |
    grepl(r$patterns$external_file, ft$name, perl = TRUE) |
    grepl(r$patterns$external_accession, full_path, perl = TRUE)
  acc_controlled <- grepl(r$patterns$controlled_accession, full_path, perl = TRUE) |
    grepl(r$patterns$controlled_file, ft$name, ignore.case = TRUE, perl = TRUE)
  own_run <- rx(r$patterns$own_run, full_path)
  # Controlled access is checked first; a lab run ID beside an accession needs a person to look
  origin <- fifelse(acc_controlled, "controlled", fifelse(acc_external & own_run, "conflict",
                    fifelse(acc_external, "external", "lab")))
  external_fastq <- is_fastq & origin == "external"
  external_derived <- origin == "external" & folder_idle &
    ft$ext %in% c("bam", "cram", "bai", "crai", "csi", "bedgraph", "bdg", "bw", "bigwig", "wig", "tdf")

  # RNA-SeQC runs. Summaries sit directly in the RNA-SeQC folder or its QC folder; each run is
  # the RNA-SeQC folder itself.
  in_rq <- rx(r$patterns$rnaseqc_root, ft$relp) & !in_cache
  rnaseqc_bam <- in_rq & ft$ext %in% c("bam", "bai")
  rq_summary <- rx(r$patterns$rnaseqc_summary, ft$relp) & !ft$ext %in% c("bam", "bai", "gtf")
  rnaseqc_working <- in_rq & !rnaseqc_bam & !rq_summary
  rq_run <- paste(ft$project, sub("^((?:.*?/)?rna-?seqc[^/]*)/.*$", "\\1", ft$rel, ignore.case = TRUE, perl = TRUE), sep = "\t")
  rq_summary_runs <- unique(rq_run[in_rq & tolower(ft$name) %chin% c("metrics.tsv", "report.html", "countmetrics.html")])
  rnaseqc_summary_kept <- in_rq & rq_run %chin% rq_summary_runs

  # Cell Ranger results beside a BAM: a filtered matrix (folder or .h5) or molecule_info.h5
  cr_rx <- "^(?:(.*)/)?(?:(?:sample_)?filtered_(?:feature|gene|peak)_bc_matri[^/]*|sample_(?:filtered_)?feature_bc_matrix[^/]*|(?:sample_)?molecule_info\\.h5)(?:/.*)?$"
  cr_hits <- rx(cr_rx, ft$rel)
  cr_dirs <- unique(paste(ft$project[cr_hits], sub(cr_rx, "\\1", ft$rel[cr_hits], perl = TRUE), sep = "\t"))
  cr_dirs <- sub("\t$", "\t.", cr_dirs)
  cellranger_has_results <- paste(ft$project, ft$dir, sep = "\t") %chin% cr_dirs

  # Repository match on name + exact size (never name alone)
  # The repository list holds either readable names and sizes, or hashed keys (03c);
  # only FASTQ files need checking, so only those are hashed
  repo_match <- rep(FALSE, nrow(ft))
  if (!is.null(repo) && nrow(repo)) {
    if ("key" %in% names(repo)) repo_match[is_fastq] <- repo_key(ft$name[is_fastq], ft$size_bytes[is_fastq]) %chin% repo$key
    else repo_match <- is_fastq & paste(ft$name, ft$size_bytes) %chin% paste(repo$name, repo$size_bytes)
  }

  # Share of each project's raw FASTQ bytes that match the repository. External FASTQ have
  # their own rule, so they don't count against a project here.
  is_lab_raw <- is_raw & !external_fastq
  ft[, repo_pct := { raw <- is_lab_raw[.I]; tot <- sum(size_bytes[raw])
                     if (tot > 0) 100 * sum(size_bytes[raw & repo_match[.I]]) / tot else 0 },
     by = project]

  # Sibling checks within the same folder of the same project
  key <- paste(ft$project, ft$dir, ft$name, sep = "\t")
  sib <- function(nm) paste(ft$project, ft$dir, nm, sep = "\t") %chin% key
  stem_bam <- sub("\\.bam$", "", ft$name, ignore.case = TRUE)
  star_sorted <- sub("Aligned\\.out\\.bam$", "Aligned.sortedByCoord.out.bam", ft$name)
  bam_has_sorted <- ft$ext == "bam" & (
    sib(paste0(stem_bam, ".sorted.bam")) | sib(paste0(stem_bam, ".sort.bam")) |
    sib(paste0(stem_bam, "_sorted.bam")) |
    (star_sorted != ft$name & sib(star_sorted)))

  # A folder is a STAR index when it contains a file named SAindex
  star_dirs <- unique(paste(ft$project, ft$dir)[ft$name == "SAindex"])
  star_index_dir <- paste(ft$project, ft$dir) %chin% star_dirs

  # Duplicate-marked (all reads kept) vs duplicate-removed (reads dropped) siblings
  bam_has_markdup <- ft$ext == "bam" & (sib(paste0(stem_bam, ".markdup.bam")) |
    sib(paste0(stem_bam, ".md.bam")) | sib(paste0(stem_bam, "_markdup.bam")))
  bam_has_dedup <- ft$ext == "bam" & (sib(paste0(stem_bam, ".dedup.bam")) |
    sib(paste0(stem_bam, ".rmdup.bam")) | sib(paste0(stem_bam, "_dedup.bam")))

  # Uncompressed file with a compressed twin in the same folder
  compressed <- grepl("\\.(gz|bz2|xz|zst|zip)$", ft$name, ignore.case = TRUE)
  has_compressed_copy <- !compressed & (sib(paste0(ft$name, ".gz")) | sib(paste0(ft$name, ".bz2")) |
                                        sib(paste0(ft$name, ".xz")) | sib(paste0(ft$name, ".zst")))

  # Archive next to a folder of the same name. Folders are only known through the files
  # in them, so an unpacked folder that is empty is not seen.
  arch_rx <- "\\.(tar\\.gz|tgz|tar\\.bz2|tbz2|tar\\.xz|tar|zip)$"
  is_arch <- grepl(arch_rx, ft$name, ignore.case = TRUE)
  arch_target <- sub(arch_rx, "", ft$name, ignore.case = TRUE)
  arch_target <- ifelse(ft$dir == ".", arch_target, paste(ft$dir, arch_target, sep = "/"))
  at_all <- anc_table(ft$project, ft$dir)
  all_dirs <- unique(paste(at_all$proj, at_all$anc, sep = "\t"))
  archive_has_extracted <- is_arch & paste(ft$project, arch_target, sep = "\t") %chin% all_dirs

  # SRA file whose accession starts FASTQ names in the same project (SRR1 must not
  # match SRR12, so the next character must be "_" or ".")
  sra_has_fastq <- rep(FALSE, n)
  for (i in which(ft$ext == "sra")) {
    fq <- ft$name[ft$project == ft$project[i] & is_fastq]
    st <- sub("\\.sra$", "", ft$name[i], ignore.case = TRUE)
    nxt <- substr(fq, nchar(st) + 1, nchar(st) + 1)
    sra_has_fastq[i] <- any(startsWith(fq, st) & nxt %in% c("_", "."))
  }

  # Lane files whose exact summed size equals a non-lane FASTQ in the project.
  # Lanes are grouped by folder + name with the _L00N part removed.
  lane_rx <- "_L00[1-8]"
  is_lane <- is_fastq & grepl(lane_rx, ft$name)
  lane_key <- paste(ft$project, ft$dir, sub(lane_rx, "", ft$name), sep = "\t")
  lane_sum <- ave(ft$size_bytes * is_lane, lane_key, FUN = sum)
  n_lanes <- ave(as.integer(is_lane), lane_key, FUN = sum)
  merged <- is_fastq & !is_lane
  lanes_merged <- is_lane & n_lanes >= 2 &
    paste(ft$project, lane_sum) %chin% paste(ft$project[merged], ft$size_bytes[merged])

  # --- Raw FASTQ per sample: the source a trimmed FASTQ or BAM can be remade from. Trimmed
  #     files never count. Lanes already merged are left out, as the merged file stands in
  #     for them. Every other raw FASTQ stays recoverable under the rules: the repository
  #     or a public archive holds it (G4, A1, G7), a copy exists (A6, A6b) or it is red (R1).
  fq_rows <- which(is_raw & !lanes_merged)
  fq <- data.table(project = ft$project[fq_rows], sample = sample_from_fastq(ft$name[fq_rows]),
                   dir = ft$dir[fq_rows], size = ft$size_bytes[fq_rows], mt = as.numeric(ft$mtime[fq_rows]))
  fq <- fq[, .(fq_dirs = uniqueN(dir), fq_bytes = sum(size), fq_newest = max(mt)), by = .(project, sample)]

  # Look a sample up in the repository. Names are checked only when long enough to be
  # distinctive, since the repository covers the whole institute.
  repo_lookup <- function(sample) {
    out <- data.table(dirs = rep(NA_real_, length(sample)), bytes = NA_real_, newest = NA_real_)
    if (is.null(repo_samples) || !nrow(repo_samples) || !length(sample)) return(out)
    long <- which(nchar(sample) >= th$repo_sample_min_chars)
    at <- match(sample_key(sample[long]), repo_samples$key)
    out[long, `:=`(dirs = repo_samples$dirs[at], bytes = repo_samples$bytes[at], newest = repo_samples$newest[at])]
    out[]
  }

  # A trimmed FASTQ is covered when its own sample has a raw FASTQ in the project, or in
  # one repository folder at a size it could have been trimmed from
  trimmed_has_raw <- rep(FALSE, n)
  tr <- which(is_fastq & !is_raw)
  if (length(tr)) {
    tt <- data.table(i = tr, project = ft$project[tr], sample = sample_from_fastq(ft$name[tr]), size = ft$size_bytes[tr])
    tt[, tot := sum(size), by = .(project, sample)]
    rp <- repo_lookup(tt$sample)
    trimmed_has_raw[tr] <- paste(tt$project, tt$sample, sep = "\t") %chin% paste(fq$project, fq$sample, sep = "\t") |
      (!is.na(rp$bytes) & rp$dirs == 1 & 100 * tt$tot / rp$bytes <= th$trimmed_repo_max_pct)
  }

  # A BAM is matched to its sample's raw FASTQ, then every check below must pass. Headers
  # are never read (that would recall archived files), so this is evidence, not proof.
  bam_sample_match <- rep(FALSE, n); bam_regenerable <- rep(FALSE, n)
  derived_strong <- rep(FALSE, n); lineage <- rep("not_applicable", n); bam_tier_in <- rep("none", n)
  # RNA-SeQC's own BAM copies are left out, so they don't make a real BAM look like one of several
  bm <- which(ft$ext == "bam" & !in_cache & !in_rq)
  if (length(bm)) {
    b <- data.table(i = bm, project = ft$project[bm], sample = sample_from_bam(ft$name[bm]), dir = ft$dir[bm],
                    size = ft$size_bytes[bm], mt = as.numeric(ft$mtime[bm]), code = ft$has_code[bm],
                    processed = rx(r$patterns$bam_processed, ft$rel[bm]))
    b[, bam_dirs := uniqueN(dir), by = .(project, sample)]
    b[fq, `:=`(fq_dirs = i.fq_dirs, fq_bytes = i.fq_bytes, fq_newest = i.fq_newest), on = .(project, sample)]
    # No raw FASTQ in the project: the repository's copy of this sample is the source
    rp <- repo_lookup(b$sample)
    from_repo <- is.na(b$fq_bytes) & !is.na(rp$bytes)
    b[from_repo, `:=`(fq_dirs = rp$dirs[from_repo], fq_bytes = rp$bytes[from_repo], fq_newest = rp$newest[from_repo])]
    b[, pct := 100 * size / fq_bytes]
    b[, ok := !is.na(fq_bytes) & fq_dirs == 1 & bam_dirs == 1 & mt >= fq_newest & !processed & code &
        pct >= th$bam_size_min_pct & pct <= th$bam_size_max_pct]
    bam_sample_match[b$i] <- !is.na(b$fq_bytes)
    bam_regenerable[b$i] <- b$ok
    # Strong evidence: the checks on the raw FASTQ itself, without those on the BAM's history
    b[, strong := !is.na(fq_bytes) & fq_dirs == 1 & mt >= fq_newest &
        pct >= th$bam_size_min_pct & pct <= th$bam_size_max_pct]
    derived_strong[b$i] <- b$strong
    lineage[b$i] <- fifelse(!is.na(b$fq_bytes) & !from_repo, "raw_same_project",
                            fifelse(from_repo, "raw_in_repository",
                                    fifelse(nchar(b$sample) < th$repo_sample_min_chars, "name_too_short", "raw_not_found")))
    bam_tier_in[b$i] <- fifelse(b$strong, fifelse(b$processed, "presumed_only", "ok"), fifelse(is.na(b$fq_bytes), "none", "weak"))
    # An index follows its BAM, whether written x.bam.bai or x.bai
    ix <- which(ft$ext == "bai")
    if (length(ix)) {
      parent <- paste(ft$project[ix], ft$dir[ix], sub("(\\.bam)?\\.bai$", ".bam", ft$name[ix], ignore.case = TRUE), sep = "\t")
      at <- match(parent, paste(ft$project[b$i], ft$dir[b$i], ft$name[b$i], sep = "\t"))
      bam_sample_match[ix] <- !is.na(at) & !is.na(b$fq_bytes[at])
      bam_regenerable[ix] <- !is.na(at) & b$ok[at]
      derived_strong[ix] <- !is.na(at) & b$strong[at]
      lineage[ix] <- fifelse(is.na(at), "not_applicable", lineage[b$i[at]])
      bam_tier_in[ix] <- fifelse(is.na(at), "none", bam_tier_in[b$i[at]])
    }
  }

  # A BAM inside an RNA-SeQC run has a source when the same sample has a BAM outside RNA-SeQC, a
  # raw FASTQ in the project, or a repository sample. The tool's own endings are removed first.
  rnaseqc_bam_has_source <- rep(FALSE, n)
  rq <- which(rnaseqc_bam)
  if (length(rq)) {
    stem <- sub("(\\.bam)?(dups_marked)?(_rgadded)?\\.(bam|bai)(\\.bai)?$", ".bam", ft$name[rq], ignore.case = TRUE, perl = TRUE)
    s <- sample_from_bam(stem)
    other <- paste(ft$project[bm], sample_from_bam(ft$name[bm]), sep = "\t")
    here <- paste(ft$project[rq], s, sep = "\t")
    rnaseqc_bam_has_source[rq] <- nchar(s) >= th$repo_sample_min_chars &
      (here %chin% other | here %chin% paste(fq$project, fq$sample, sep = "\t") | !is.na(repo_lookup(s)$bytes))
    bam_tier_in[rq] <- fifelse(rnaseqc_bam_has_source[rq], "ok", "none")
  }

  # Lineage of SAM, CRAM and trimmed FASTQ, for reporting only; no rule depends on it
  track_ext <- c("bedgraph", "bdg", "bw", "bigwig", "wig", "tdf")
  ln <- which((ft$ext %in% c("sam", "cram", track_ext) | (is_fastq & !is_raw)) & !in_cache)
  if (length(ln)) {
    plain <- sub("\\.(gz|bz2|xz|zst)$", "", ft$name[ln], ignore.case = TRUE)
    s <- ifelse(ft$ext[ln] %in% c("fastq", "fq"), sample_from_fastq(ft$name[ln]),
                sample_from_bam(sub("\\.(sam|cram|bedgraph|bdg|bw|bigwig|wig|tdf)$", ".bam", plain, ignore.case = TRUE)))
    at_fq <- match(paste(ft$project[ln], s, sep = "\t"), paste(fq$project, fq$sample, sep = "\t"))
    rp <- repo_lookup(s)
    newest <- ifelse(!is.na(at_fq), fq$fq_newest[at_fq], rp$newest)
    dirs <- ifelse(!is.na(at_fq), fq$fq_dirs[at_fq], rp$dirs)
    lineage[ln] <- fifelse(!is.na(at_fq), "raw_same_project", fifelse(!is.na(rp$bytes), "raw_in_repository",
                           fifelse(nchar(s) < th$repo_sample_min_chars, "name_too_short", "raw_not_found")))
    bam_tier_in[ln] <- fifelse(is.na(newest), "none",
                               fifelse(dirs == 1 & as.numeric(ft$mtime[ln]) >= newest, "ok", "weak"))
  }

  # Cell Ranger names its BAM the same in every run, so the run folder above outs/ is the sample
  # name. Size is not compared: a single-cell BAM's size says little about its FASTQ.
  cr <- which(rx(r$patterns$cellranger_bam, ft$relp) & !in_cache & !in_rq)
  if (length(cr)) {
    s <- tolower(basename(dirname(ft$dir[cr])))
    at_fq <- match(paste(ft$project[cr], s, sep = "\t"), paste(fq$project, fq$sample, sep = "\t"))
    rp <- repo_lookup(s)
    newest <- ifelse(!is.na(at_fq), fq$fq_newest[at_fq], rp$newest)
    dirs <- ifelse(!is.na(at_fq), fq$fq_dirs[at_fq], rp$dirs)
    lineage[cr] <- fifelse(!is.na(at_fq), "raw_same_project", fifelse(!is.na(rp$bytes), "raw_in_repository",
                           fifelse(nchar(s) < th$repo_sample_min_chars, "name_too_short", "raw_not_found")))
    bam_tier_in[cr] <- fifelse(is.na(newest), "none", fifelse(dirs == 1 & as.numeric(ft$mtime[cr]) >= newest, "ok", "weak"))
  }

  # Reproducibility tier: is the source recoverable, do the checks pass, and is there a record of
  # how the file was made? A record is a script, scheduler log or pipeline file in the file's own
  # folder or one above it, or in a scripts or log folder beside one of those.
  rec_rx <- "(^|/)(_cmdline|_invocation|_mrosource|_versions|nextflow\\.config|\\.nextflow\\.log[^/]*|multiqc_report\\.html)$|(^|/)(pipeline_info|\\.nextflow)/|\\.[oe][0-9]{5,}$|(^|/)slurm-[0-9]+\\.out$"
  is_record <- is_code | rx(rec_rx, ft$relp)
  rec_dir <- ft$dir[is_record]
  beside <- grepl("(^|/)(slurm|scripts?|logs?|code|pipeline_info|\\.nextflow)$", rec_dir, ignore.case = TRUE)
  rec_dir[beside] <- dirname(rec_dir[beside])
  rec_set <- unique(paste(ft$project[is_record], rec_dir, sep = "\t"))
  at <- anc_table(ft$project, ft$dir)
  at[, has := paste(proj, anc, sep = "\t") %chin% rec_set]
  run_dirs <- at[has == TRUE, unique(paste(proj, dir, sep = "\t"))]
  process <- fifelse(paste(ft$project, ft$dir, sep = "\t") %chin% run_dirs, "run",
                     fifelse(ft$has_code, "project", "none"))

  # A public accession is itself a recoverable source; a trimmed FASTQ uses its existing check
  bam_tier_in[origin == "external" & !acc_controlled & !in_cache & bam_tier_in %chin% c("none", "weak")] <- "ok"
  repro_tier <- fifelse(bam_tier_in == "ok" & process == "run", "validated",
                        fifelse(bam_tier_in %chin% c("ok", "presumed_only"), "presumed", bam_tier_in))

  # Any MISO summary in the project, outside caches
  ft[, has_miso_summary := any(!in_cache[.I] & grepl("\\.miso_summary(\\.gz)?$", name, ignore.case = TRUE)), by = project]

  # --- Copies. Which copy to keep: project with scripts first, then the older
  #     (originals are older than copies made without cp -p), then the shorter path.

  # Repeated large files: same name + exact size, >= dup_min_mb, across ALL projects.
  # Hard links (same inode) are collapsed first, so they never count as copies.
  extra_copy_large <- rep(FALSE, n)
  big <- which(ft$size_bytes >= th$dup_min_mb * 1024^2 & !in_cache)
  if (length(big)) {
    # (column is "dupkey", not "key": key= is a reserved data.table() argument)
    b <- data.table(i = big, dupkey = paste(ft$name[big], ft$size_bytes[big]), inode = inode[big],
                    code = ft$has_code[big], mt = as.numeric(ft$mtime[big]),
                    len = nchar(ft$project[big]) + nchar(ft$rel[big]))
    b <- b[!duplicated(b[, .(dupkey, inode)])]
    setorder(b, dupkey, -code, mt, len)
    b[, extra := seq_len(.N) > 1, by = dupkey]
    # Flag every name of an extra copy: removing only one name of a hard-linked
    # file frees nothing
    extra_copy_large[big] <- inode[big] %in% b$inode[b$extra]
  }

  # Copied folders. Each folder gets the set of its files >= folder_key_min_mb as
  # "relative path + exact size" keys; folder B is a copy of A when B's matching keys
  # cover >= folder_copy_pct % of B's bytes. If both cover each other, the
  # less-preferred one is the copy; if only B is covered (e.g. a backup subset), B is.
  in_folder_copy <- rep(FALSE, n)
  kr <- which(ft$size_bytes >= th$folder_key_min_mb * 1024^2 & !in_cache)
  if (length(kr)) {
    k <- data.table(proj = ft$project[kr], dir = ft$dir[kr], rel = ft$rel[kr],
                    size = ft$size_bytes[kr], inode = inode[kr], mt = as.numeric(ft$mtime[kr]))
    K <- anc_table(k$proj, k$dir)[k, on = .(proj, dir), allow.cartesian = TRUE, nomatch = 0]
    K[, `:=`(key = paste(substring(rel, nchar(anc) + 2), size), folder = paste(proj, anc, sep = "/"))]
    code_by_proj <- ft[, .(code = has_code[1]), by = project]
    fb <- K[, .(bytes = sum(size), nfiles = .N, oldest = min(mt)), by = .(folder, proj)]
    fb[code_by_proj, code := i.code, on = .(proj = project)]
    fb[, pref := frank(list(-code, oldest, nchar(folder)), ties.method = "first")]
    fb <- fb[bytes >= th$folder_copy_min_mb * 1024^2 & nfiles >= th$folder_copy_min_files]
    Ke <- K[folder %chin% fb$folder, .(folder, key, size, inode)]
    if (nrow(Ke)) {
      # Pair every two eligible folders that share a key (excluding hard links of the same file)
      pr <- Ke[Ke, on = "key", allow.cartesian = TRUE, nomatch = 0][folder != i.folder & inode != i.inode]
      sh <- pr[, .(shared = sum(size)), by = .(A = i.folder, B = folder)]
      sh[fb, `:=`(bytesB = i.bytes, prefB = i.pref), on = .(B = folder)]
      sh[fb, `:=`(bytesA = i.bytes, prefA = i.pref), on = .(A = folder)]
      cut <- th$folder_copy_pct / 100
      sh[, `:=`(B_in_A = shared / bytesB >= cut, A_in_B = shared / bytesA >= cut)]
      extra_dirs <- sort(unique(sh[B_in_A & (!A_in_B | prefB > prefA), B]))
      # Keep only the top-most copied folders, then flag every file under them
      top <- extra_dirs[!vapply(extra_dirs, function(d)
        any(startsWith(d, paste0(setdiff(extra_dirs, d), "/"))), TRUE)]
      fpath <- paste(ft$project, ft$rel, sep = "/")
      for (d in top) in_folder_copy <- in_folder_copy | startsWith(fpath, paste0(d, "/"))
    }
  }

  out <- list(project_active = ft$project_status == "Active",
       project_has_code = ft$has_code,
       project_has_reads = ft$has_reads,
       repo_match = repo_match,
       project_repo_pct_ok = ft$repo_pct >= th$repo_match_pct,
       miso_has_summary = ft$has_miso_summary,
       external_fastq = external_fastq,
       trimmed_has_raw = trimmed_has_raw,
       bam_sample_match = bam_sample_match,
       bam_regenerable = bam_regenerable,
       bam_has_sorted = bam_has_sorted,
       star_index_dir = star_index_dir,
       bam_has_markdup = bam_has_markdup,
       bam_has_dedup = bam_has_dedup,
       has_compressed_copy = has_compressed_copy,
       archive_has_extracted = archive_has_extracted,
       sra_has_fastq = sra_has_fastq,
       lanes_merged = lanes_merged,
       in_folder_copy = in_folder_copy,
       extra_copy_large = extra_copy_large,
       external_derived = external_derived,
       folder_idle = folder_idle,
       rnaseqc_working = rnaseqc_working,
       rnaseqc_bam = rnaseqc_bam,
       rnaseqc_summary_kept = rnaseqc_summary_kept,
       rnaseqc_bam_has_source = rnaseqc_bam_has_source,
       cellranger_has_results = cellranger_has_results,
       derived_strong_evidence = derived_strong,
       never = rep(FALSE, n),
       derived_old = as.numeric(difftime(now, ft$mtime, units = "days")) / 365.25 >= th$derived_min_years)
  # The separate descriptive fields travel with the conditions
  attr(out, "fields") <- list(origin = origin, lineage = lineage, folder_idle_years = folder_months / 12,
                                repro_tier = repro_tier, process_record = process)
  out
}

# Which code files and installed software a path points to. A suspect word in these says
# nothing about the data, so they are left out of the sensitivity suspicion check.
not_data_evidence <- function(rel, r) {
  code_ext <- sub("^\\.", "", unlist(Filter(function(x) x$id == "P1", yaml_rule_list(r))[[1]]$match$ext))
  base_ext(basename(rel)) %in% code_ext | grepl(r$patterns$software_env, paste0("/", rel), ignore.case = TRUE, perl = TRUE)
}
yaml_rule_list <- function(r) r$rules

# Apply the rules in order; the first matching rule decides each file.
classify_files <- function(files, r, repo = NULL, now = Sys.time(), repo_samples = NULL) {
  ft <- copy(as.data.table(files))
  ft[, `:=`(name = basename(rel), dir = dirname(rel), relp = paste0("/", rel))]
  ft[, ext := base_ext(name)]
  cond <- compute_conditions(ft, r, repo, now, repo_samples)

  # Every condition the YAML documents must exist in code, and vice versa
  missing <- setdiff(names(r$conditions), names(cond))
  if (length(missing)) stop("Conditions documented but not implemented: ", toString(missing))

  ft[, `:=`(rule_id = NA_character_, colour = NA_character_, rule_title = NA_character_)]
  for (rule in r$rules) {
    todo <- is.na(ft$rule_id)
    if (!any(todo)) break
    hit <- todo & rule_hits(rule, ft, cond)
    ft[hit, `:=`(rule_id = rule$id, colour = rule$colour, rule_title = rule$title)]
  }
  ft[is.na(rule_id), `:=`(rule_id = r$default$id, colour = r$default$colour,
                          rule_title = r$default$title)]

  # File class says what a file is, separately from its colour; first match wins
  ft[, file_class := NA_character_]
  for (cl in r$file_classes) {
    hit <- is.na(ft$file_class) & rule_hits(cl, ft, cond)
    ft[hit, file_class := cl$id]
  }
  ft[is.na(file_class), file_class := "unknown"]
  fields <- attr(cond, "fields")
  ft[, `:=`(origin = fields$origin, lineage = fields$lineage, folder_idle_years = fields$folder_idle_years,
            repro_tier = fields$repro_tier, process_record = fields$process_record)]

  # A green rule marked repro_gate stands only in a tier the committee has approved. Other green
  # rules rest on a copy, a cache or a kept result, so their files count as redundant.
  gated <- unlist(lapply(r$rules, function(x) if (isTRUE(x$repro_gate)) x$id))
  ft[colour == "green" & !rule_id %chin% gated, repro_tier := "redundant"]
  fb <- r$rules[[match(r$reproducibility$fallback_rule, vapply(r$rules, `[[`, "", "id"))]]
  blocked <- ft$rule_id %chin% gated & !ft$repro_tier %chin% unlist(r$reproducibility$green_tiers)
  ft[, rule_before_gate := rule_id]
  ft[blocked, `:=`(rule_id = fb$id, colour = fb$colour, rule_title = fb$title)]
  ft[, c("relp", "newest", "has_code", "has_reads", "has_miso_summary") := NULL]
  ft[]
}
