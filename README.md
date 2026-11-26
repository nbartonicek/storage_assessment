# Storage report toolkit (cart version, with tabbed and low-memory versions for large data)

Run your own storage report and cleanup list on the cluster. You run one command, wait for it to
finish, then open one web page in a browser. It shows how much storage your folders use, where it
sits, what kinds of files it holds, and how the cleanup rules (version 0.7.1, in
`rules/cleanup_rules.yaml`) classify them.

The job reads file details only: names, sizes, dates, owners and space on disk. It never opens your
files, so nothing is brought back from the archive, and it doesn't change, move, copy or delete
anything.

For several folders, folders on different volumes, or tens of millions of files, use the separate
`run_tabbed_report.sh` instead: one tab per folder, with build jobs sized to the data. See
[Tabbed report](#tabbed-report-for-several-folders-or-very-large-data). For the very largest data,
or millions of small files, `run_low_memory_report.sh` makes the same tabbed report in one job with
far less memory. See [Low-memory report](#low-memory-report-for-the-largest-data).

## What's in this repository

| File | What it does |
|---|---|
| `run_my_report.sh` | The job you submit. Runs the two steps below and says where the report is. |
| `run_tabbed_report.sh` | The tabbed version, for several folders or very large data: one tab per folder, each with an overview and a cart page (see [Tabbed report](#tabbed-report-for-several-folders-or-very-large-data)). |
| `scripts/03_split_tabs.sh`, `scripts/04_build_page.sh`, `scripts/05_write_index.sh` | Used by the tabbed version: split the scan into tabs, build one page, write the front page. |
| `scripts/02b_build_overview.R`, `scripts/storage_overview_template.html` | Used by the tabbed version: build the overview page. |
| `run_low_memory_report.sh` | The low-memory version of the tabbed report, for the largest data: every page built in one job (see [Low-memory report](#low-memory-report-for-the-largest-data)). |
| `scripts/01a_build_low_memory.R` | Used by the low-memory version: reads the scan once and builds every tab's overview and cart; combines small files in very large scans. |
| `scripts/01_scan_storage.sh` | Step 1: lists every file's details with `find -printf` into `scan_<date>.tsv.gz`. |
| `scripts/02_build_storage_report.R` | Step 2: classifies the files with the rules and writes `storage_report.html`. |
| `scripts/cleanup_classifier.R`, `scripts/storage_data.R` | Used by step 2: apply the rules and prepare the page's data. |
| `scripts/storage_report_template.html` | The report page that step 2 fills in. |
| `rules/cleanup_rules.yaml` | The cleanup rules, version 0.7.1, with what each rule means and why. |
| `data/` | Optional sequencing-repository list (see `data/README.md`). |

## What you need

- A cluster account with Slurm, and read access to the folder you want to report on.
- R, with the packages `data.table`, `yaml`, `jsonlite` and `digest`. Tested with R 4.5.1.
- A web browser on your own computer to open the report.

The job script asks for the `rhel_short` partition, 1 CPU, 4 GB of memory and 8 hours. If your
cluster uses other names or limits, change the `#SBATCH` lines at the top of `run_my_report.sh`.

## 1. Put the toolkit on the cluster

Log in, go to a folder you can write to, and download the toolkit:

```bash
git clone https://github.com/nbartonicek/storage_assessment.git
cd storage_assessment
```

## 2. Make R available

Load R the way you normally do on the cluster, in the same session you'll use for step 3. Then start
an interactive session and check the packages:

```bash
sinteractive
Rscript -e 'library(data.table); library(yaml); library(jsonlite); library(digest)'
```

If R reports that a package is missing, install it in that session. Type `exit` when you're done, and
load R again if you need to.

```bash
Rscript -e 'install.packages(c("data.table", "yaml", "jsonlite", "digest"))'
```

## 3. Submit the job

From inside the toolkit folder, give the folder you want to report on. Each sub-folder becomes one
project in the report.

```bash
sbatch run_my_report.sh /researchers/your.name/projects
```

Several folders in one report: list them, or use a wildcard. Check what a wildcard matches with
`echo` first, and include only folders you're allowed to scan.

```bash
echo /researchers/your.name/projects/mac*
sbatch run_my_report.sh /researchers/your.name/projects/mac*
sbatch run_my_report.sh /path/to/folder1 /path/to/folder2
```

The report then sits under the folders' closest shared parent, and each folder directly below that
parent becomes one project. All the folders share the job's 8-hour limit.

Please don't submit many at the same time: each scan puts load on the storage. Check on the job with
`squeue -u $USER`. It's finished when it's no longer listed.

## 4. Check that it worked

Look at the end of the job's log, which is in the toolkit folder:

```bash
tail storage_report_*.log
```

A successful job says `FINISHED` and gives the report's location. If it also says the report may be
incomplete, the scan couldn't read some folders. They're listed in the `errors.log` file next to the
report, and their contents aren't in your report.

## 5. Open the report

The report is `results/<name>/storage_report.html`, with the full file list
`storage_report_files.tsv.gz` beside it. Copy the page to your own computer and double-click it. It needs no internet connection. It lists folder and file names and the account
names of file owners, so share it only with people who should see them. Never add `results/` to a
public repository.

## Reading the report

The report has five steps:

| Step | What it's for |
|---|---|
| 1. Overview | Your totals, and one bar per project split by colour. |
| 2. Set project policy | Set each project's status and sensitivity, and add notes. Every colour follows your choices. |
| 3. Data classification | Five views of your data. Add files to the cart with the lasso, by right-clicking, or with the + buttons. |
| 4. Folder hierarchy | Your folder tree. + adds a folder and everything below it. |
| 5. Your cart | See what removing the cart's files would free, then download the list as a CSV, plus your project decisions. |

The colours are recommendations from the rules:

- **green**: likely removable
- **amber**: your judgement
- **red**: keep; removing it needs the data custodian's explicit agreement

Each cart holds one colour. Download one list, empty the cart, then switch colour for the next.
"Real size" is the full size of your files. "On disk" is what they occupy now, which is much smaller
for archived files.

> **Do not copy, move, open, compress or tar these files.** Most live only in the archive. Reading
> one brings it back, and doing that for many at once causes a recall storm that slows the storage
> for everyone.

### Folders with several people

If the files have more than one owner, **Usage by person** appears above the report, with one bar per
person. Tick one or more people and everything in the report shows only their files. A dark bar says
who is selected, and **Show everyone** clears it. With one owner, this section doesn't appear.

- Owner means the account that owns the file on disk, which may not be the person who made the data.
- "Unknown (ID n)" is an account with no name, often someone who has left.
- Colours don't change with the selection. Rules, project status and sensitivity always use the whole
  project.
- The cart keeps what you added, whoever is selected. Its totals and download always cover every file
  in it, and each file's owner is listed.

## Tabbed report for several folders or very large data

`run_tabbed_report.sh` is a separate job script for when one page isn't enough: several folders,
folders on different volumes, or tens of millions of files. Steps 1 and 2 above are the same. It uses
the same rules and the same cart page as `run_my_report.sh`, so the colours match.

What you get, in `results/<name>/storage_report/`:

- **One tab per folder you give**, plus a **Total** tab when you give several. In each folder's tab,
  its sub-folders are the projects. The folders may be on different volumes, e.g. a `/researchers`
  folder and a lab or department share.
- **Two pages per tab:** **Overview (by time)** shows where the data sits, which projects and people
  hold it, what kinds of files it is and how old it is. **Cart and files** is the page described in
  [Reading the report](#reading-the-report), with its full file list `cart_files.tsv.gz`.
- **`index.html`**, the front page: buttons at the top pick the tab and the page.

### Submit it

From inside the toolkit folder, as in step 3:

```bash
sbatch run_tabbed_report.sh /path/to/folder1 /path/to/folder2
```

The scan needs little memory, but it can take longer than 8 hours for tens of millions of files. Then
submit it on the long partition:

```bash
sbatch --partition=rhel_long --time=3-00:00:00 run_tabbed_report.sh /path/to/folder1 /path/to/folder2
```

After the scan, the job counts the files in every tab:

- **Up to 300,000 files in every tab:** it builds all the pages itself and its log ends with `FINISHED`.
- **More:** its log ends with `SCANNED` and lists the jobs it submitted, one per page (the overview
  and the cart of each tab, side by side). Each gets 10 GB per million files plus 4 GB. Tabs over
  2 million files go to `rhel_long` for up to 3 days. A last small job rewrites the front page when
  they have all ended. The report is ready when `squeue -u $USER` no longer lists them. Their logs are
  in `results/<name>/logs/`.
- **A tab needing more than 900 GB** is not submitted. The log prints its command (`NOT SUBMITTED`)
  so you can submit it where the memory is, then rewrite the front page as it says.

The Total tab holds every file, so it is the biggest. As a guide, 27 million files need about 275 GB
and many hours. Change the limits by setting them in front of `sbatch`, e.g.
`GB_PER_MILLION=12 MAX_MEM_GB=1000 sbatch run_tabbed_report.sh ...` (also `SHORT_PARTITION`,
`LONG_PARTITION`, `SHORT_TIME`, `LONG_TIME`, `SHORT_MAX_FILES`, `INLINE_MAX_FILES`). The build jobs use
the R you have loaded when you submit.

### Open it and share it

Open `index.html` in `results/<name>/storage_report/`. A page that is still being built, or failed,
says so.

**`index.html` alone is not the report.** It opens the pages in the sub-folders beside it, one per
tab, so copy or send the **whole `storage_report` folder**, e.g. as a zip:

```bash
cd results/<name> && zip -r storage_report.zip storage_report
```

The receiver unzips it and opens `index.html` from the unzipped folder, not from inside the zip.
Each tab's `cart_files.tsv.gz` is the biggest part. If the zip is too big to send, add
`-x '*/cart_files.tsv.gz'`; then only the cart's full-list download stops working. Share big reports
through a file-sharing link rather than email. As with the single page, the pages list folder, file
and account names, so share them only with people who should see them.

### If a page could not be built

Read `storage_report/<tab>/<page>_messages.txt` and the job's log in `results/<name>/logs/`. To build
one page again, e.g. with more memory after running out, from the `scripts` folder:

```bash
sbatch --partition=rhel_long --time=3-00:00:00 --mem=300G --wrap="bash 04_build_page.sh ../results/<name> <tab> cart"
bash 05_write_index.sh ../results/<name>
```

`<tab>` is the tab's folder name in `storage_report/` (e.g. `total`), and `cart` can be `overview`.
Submitting the same folders again on the same day reuses that day's scan and rebuilds every page.
`results/<name>/tabs/` holds a copy of the scan split by tab; delete it once the report is built.

## Low-memory report for the largest data

`run_low_memory_report.sh` makes the same report as `run_tabbed_report.sh` (a Total and one tab per
folder, each with an overview and a cart page) for data too large for it: tens of millions of files,
or folders full of small files. The tabbed version builds each page in its own job, and each job reads
and classifies the whole scan again. This version builds every page in **one job** that reads the
scan once and classifies each tab once (`scripts/01a_build_low_memory.R`).

Above 5 million files it also **combines small files**: files under 1 MB become one row per folder,
file type, owner, year last changed and archived status, named like `[12,345 files under 1 MB].bam`.
Small files usually hold little of the data but most of the rows, and memory grows with rows.
What stays exact: sizes, file counts, space on disk, archived sizes and the time view. What becomes
approximate: the colours of those small files (the rules see one row per folder and type), copies
among small files, and the cart's file list (it shows the combined rows). Small files the rules
need by name stay on their own (FASTQ, run records, RNA-SeQC summaries, Cell Ranger matrices and
others). The front page says when small files were combined.

**Checked**: on a 253,000-file scan with a Total and three folder tabs, every page was the same as
the tabbed version's, in half the time (192 s against 369 s). With small files combined, every tab's
size and file count were the same. On 2 million files with small files combined, the build peaked
at 3.1 GB, where the tabbed version plans 24 GB.

### Submit it

From the toolkit folder, as for the other versions:

```bash
sbatch run_low_memory_report.sh /path/to/folder1 /path/to/folder2
```

This job scans, then submits **one** build job with the memory the whole scan needs: 10 GB per
million files plus 4 up to 5 million files, and 2 GB per million plus 16 above that (so about 140 GB
for 60 million files). Up to 300,000 files the pages are built in the first job. Its log says which
build job was submitted and where its log is. To change the defaults, set them in front of `sbatch`,
e.g. `LUMP_GB_PER_MILLION=3 sbatch run_low_memory_report.sh ...`; `LUMP_ABOVE` sets when small files
are combined (e.g. `LUMP_ABOVE=0` to always combine them, a very large number to never).

The report opens and is shared the same way as the tabbed version's
([Open it and share it](#open-it-and-share-it)).

## If something goes wrong

| What you see in the log | What to do |
|---|---|
| not the toolkit folder | Go into the toolkit folder with `cd` and submit again. |
| folder not found | Check the path you gave, and that it's a path on the cluster. |
| is inside | One folder you listed is inside another. Give only one of them. |
| share no parent folder | These folders can't go in one report. Run them separately. |
| R is not available | Load R (step 2) in the same session, then submit again. |
| Missing R package | Install it (step 2), then submit again. |
| Time limit reached | Report on a smaller folder, such as one sub-folder. |
| Out of memory | Report on a smaller folder. |

Submitting the same folders again on the same day reuses that day's finished scan and only rebuilds
the page.

## Good to know

- The report deletes nothing. The CSV is a list for your data custodian to approve, and it contains
  no commands. Delete files only after that approval.
- Treat deletion as permanent. Don't assume a deleted file can be restored unless your storage team
  has confirmed it.
- Very large folders: to keep the page small enough to open, it shows the 20,000 largest folders
  (smaller ones are merged into their parent, so every file and byte still counts), and above
  250,000 files it leaves out the per-file list, so clicking a file type won't list its files and
  the cart is switched off. Every file is always in `storage_report_files.tsv.gz` next to the page
  (path, size, date, owner, project, rule), which opens in Excel or R. Change the limits with the
  `DIR_MAX` and `FILE_LIST_MAX` settings below.
- **Rebuild the report without scanning again:** the scan file stays valid, so after updating the
  toolkit you can rebuild the page from it. From the `scripts` folder:
  ```bash
  OUT=../results/<name>/storage_report.html Rscript 02_build_storage_report.R /the/folder/you/scanned ../results/<name>/scan_<date>.tsv.gz
  ```
  If you have the repository list, add `REPO_FILE=../data/repo_fastqs_<date>.tsv.gz` in front. Add
  `DIR_MAX=5000` or `FILE_LIST_MAX=100000` in front to make the page smaller still.
- **Sequencing repository list:** not included here. Without it, every raw FASTQ file stays red,
  because the toolkit can't tell whether the repository holds a copy. If you were given a list, put it
  in `data/` (see `data/README.md`).
- Retention periods and legal notes in the rules are minimum benchmarks for review, not legal advice.
  Check your own institution's policy before relying on them.
- Your choices stay with you: settings and notes are kept in your browser. Use **Save progress** to
  keep them in a file.
