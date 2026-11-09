#!/usr/bin/env Rscript

path <- "artifacts/table_trilliant_worksite_detail.csv"
stopifnot(file.exists(path))
stopifnot(file.exists("docs/table_trilliant_worksite_detail.html"))

d <- read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
required <- c("domain", "measure", "n_observed", "percent_of_cohort", "summary",
              "source_artifact", "source_fields")
stopifnot(all(required %in% names(d)))
stopifnot(nrow(d) >= 25L)
stopifnot(any(d$measure == "Named primary practice site"))
stopifnot(any(d$measure == "Maximum geographic distance between lower-48 sites (miles)"))
stopifnot(any(d$measure == "Midwives with multiple organizations at a work-site address"))
stopifnot(any(d$measure == "Strict hospital + birth-center practice"))
stopifnot(all(!is.na(d$source_artifact) & nzchar(d$source_artifact)))
stopifnot(all(!is.na(d$source_fields) & nzchar(d$source_fields)))

cat("OK: detailed Trilliant/work-site table has", nrow(d), "auditable rows\n")
