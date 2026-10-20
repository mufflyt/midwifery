#!/usr/bin/env Rscript
files <- file.path("artifacts", c("table_worksite_topology.csv",
                                   "table_worksite_settings.csv",
                                   "table_worksite_combinations.csv"))
stopifnot(all(file.exists(files)))
top <- read.csv(files[1], stringsAsFactors = FALSE)
set <- read.csv(files[2], stringsAsFactors = FALSE)
combo <- read.csv(files[3], stringsAsFactors = FALSE)
stopifnot(identical(top$setting, c("0", "1", "2", "3", "4", "5+")))
stopifnot(sum(top$n) == 12171L)
stopifnot(nrow(set) == 4L, all(set$n >= 0), all(set$percent >= 0))
stopifnot(sum(combo$n) == 12171L)
stopifnot(file.exists(file.path("docs", "table_worksite_combinations_upset.html")))
stopifnot(file.exists(file.path("docs", "table_worksite_combinations_upset.png")))
cat(sprintf("PASS (topology %d; settings %d; combinations %d)\n",
            nrow(top), nrow(set), nrow(combo)))
