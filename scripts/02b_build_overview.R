# Build the overview page: the same data as 02_build_storage_report.R, on a tabbed page
# with the time view (where the data sits, what it is, how old it is), without the cart.
#
# Usage (from the scripts folder):
#   OUT=overview.html Rscript 02b_build_overview.R SCAN_ROOT SCAN [SCAN ...]
# Takes the same settings as 02_build_storage_report.R, except that the template is fixed.
# Metadata only: reads the scan files, never the scanned data.

# Choose the overview's template and default output page
Sys.setenv(TEMPLATE = "storage_overview_template.html")
# No full file list beside the overview: it has no cart (the cart page writes the list)
Sys.setenv(WRITE_FILE_LIST = "0")
if (!nzchar(Sys.getenv("OUT"))) Sys.setenv(OUT = "../results/storage_overview.html")

# Leave out the category and status descriptions: the page doesn't show them,
# and they are written for the cleanup rules rather than for this page
prepare_page_data <- function(data) {
  data$categories <- lapply(data$categories, function(x) x[c("id", "label")])
  data$statuses <- lapply(data$statuses, function(x) x[setdiff(names(x), "description")])
  data
}

# Everything else is the same as the cart page
source("02_build_storage_report.R")
