#!/usr/bin/env Rscript
root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))
path <- file.path(root, "artifacts", "midwife_organization_affiliation_report.csv")
ci_require_files(path, what = "the organization-affiliation report")
d <- read.csv(path, stringsAsFactors = FALSE, na.strings = "")
required <- c("certification_number", "npi", "organization_name", "source",
              "relationship", "evidence")
stopifnot(all(required %in% names(d)))
stopifnot(!"employer" %in% names(d))
stopifnot(all(nzchar(d$organization_name)))
stopifnot(all(is.na(d$organization_name) | nzchar(d$organization_name)))
stopifnot(all(d$source %in% c("Trilliant provider directory",
                              "NPPES Type-2 organization match",
                              "No reported organization")))
stopifnot(any(d$source == "Trilliant provider directory"))
stopifnot(any(d$source == "NPPES Type-2 organization match"))
stopifnot(length(unique(d$certification_number)) == 12171L)
cat(sprintf("PASS (%d rows; %d midwives)\n", nrow(d), length(unique(d$certification_number))))
