# Storage report toolkit (cart version)

Run your own storage report and cleanup list on the cluster. You run one command, wait for it to
finish, then open one web page in a browser. It shows how much storage your folders use, where it
sits, what kinds of files it holds, and how the cleanup rules (version 0.7.0, in
`rules/cleanup_rules.yaml`) classify them.

The job reads file details only: names, sizes, dates, owners and space on disk. It never opens your
files, so nothing is brought back from the archive, and it doesn't change, move, copy or delete
anything.

## What's in this repository

| File | What it does |
|---|---|
| `run_my_report.sh` | The job you submit. Runs the two steps below and says where the report is. |
| `scripts/01_scan_storage.sh` | Step 1: lists every file's details with `find -printf` into `scan_<date>.tsv.gz`. |
| `scripts/02_build_storage_report.R` | Step 2: classifies the files with the rules and writes `storage_report.html`. |
| `scripts/cleanup_classifier.R`, `scripts/storage_data.R` | Used by step 2: apply the rules and prepare the page's data. |
| `scripts/storage_report_template.html` | The report page that step 2 fills in. |
| `rules/cleanup_rules.yaml` | The cleanup rules, version 0.7.0, with what each rule means and why. |
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

The report is `results/<name>/storage_report.html`. Copy that one file to your own computer and
double-click it. It needs no internet connection. It lists folder and file names and the account
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
- Very large folders: above 500,000 files the page leaves out the per-file list, so clicking a file
  type won't list its files, and the cart is switched off.
- **Sequencing repository list:** not included here. Without it, every raw FASTQ file stays red,
  because the toolkit can't tell whether the repository holds a copy. If you were given a list, put it
  in `data/` (see `data/README.md`).
- Retention periods and legal notes in the rules are minimum benchmarks for review, not legal advice.
  Check your own institution's policy before relying on them.
- Your choices stay with you: settings and notes are kept in your browser. Use **Save progress** to
  keep them in a file.
