#!/usr/bin/env Rscript
# =============================================================================
# Contract: merging scrape checkpoints replaces records, never blends them
# =============================================================================
# Run as: Rscript tests/test_checkpoint_merge.R   (exit 1 on failure)
#
# A checkpoint is a named list of per-certificant data frames. Merging two of
# them -- recovery from a CSV, or folding a prior run in -- must REPLACE whole
# records by name. utils::modifyList() looks like the tool for this and is not:
# it recurses into any element that is itself a list, and a tibble IS a list, so
# it merges column by column INSIDE each certificant.
#
# That misbehaves three different ways, and only one of them is loud.
# =============================================================================
fail <- 0L
ok <- function(cond, msg) {
  cat(sprintf("  %-4s %s\n", if (isTRUE(cond)) "PASS" else "FAIL", msg))
  if (!isTRUE(cond)) fail <<- fail + 1L
}
suppressPackageStartupMessages(library(dplyr))

merge_checkpoints <- function(older, newer) {   # the correct operation
  older[names(newer)] <- newer
  older
}

cat("--- 1. whole-record replacement ---\n")
old <- tibble(certification_number = "CNM1", hg_practice = c("A", "B", "C"))
new <- tibble(certification_number = "CNM1", hg_practice = "A")
m <- merge_checkpoints(list(CNM1 = old), list(CNM1 = new))
ok(nrow(m$CNM1) == 1L, "fresh 1-row record replaces the stale 3-row one")
ok(identical(m$CNM1, new), "record is the new one, byte for byte")

cat("\n--- 2. modifyList silently recycles instead of replacing ---\n")
bad <- utils::modifyList(list(CNM1 = old), list(CNM1 = new))$CNM1
ok(nrow(bad) == 3L && all(bad$hg_practice == "A"),
   "modifyList yields 3 rows of 'A' -- the scalar recycled, not replaced")
ok(nrow(bad) != nrow(new), "so it does NOT reproduce the fresh record")

cat("\n--- 3. modifyList blends columns across scrapes ---\n")
a <- tibble(certification_number = "CNM2", hg_practice = "OLD", hg_city = "Denver")
b <- tibble(certification_number = "CNM2", hg_practice = "NEW")
mix <- utils::modifyList(list(CNM2 = a), list(CNM2 = b))$CNM2
ok("hg_city" %in% names(mix) && mix$hg_city == "Denver",
   "modifyList keeps hg_city from the OLD scrape beside the NEW practice")
m2 <- merge_checkpoints(list(CNM2 = a), list(CNM2 = b))$CNM2
ok(!"hg_city" %in% names(m2), "flat replacement carries no stale column")

cat("\n--- 4. non-recyclable row counts error outright ---\n")
err <- inherits(try(utils::modifyList(list(X = tibble(a = 1:3)),
                                      list(X = tibble(a = 1:2))), silent = TRUE),
                "try-error")
ok(err, "modifyList errors on 3 -> 2 rows (the loud case)")
ok(nrow(merge_checkpoints(list(X = tibble(a = 1:3)), list(X = tibble(a = 1:2)))$X) == 2L,
   "flat replacement handles it")

cat("\n--- 5. union and precedence ---\n")
older <- list(A = tibble(k = "A", v = 1), B = tibble(k = "B", v = 1))
newer <- list(B = tibble(k = "B", v = 2), C = tibble(k = "C", v = 2))
mm <- merge_checkpoints(older, newer)
ok(length(mm) == 3L, "merged set is the union")
ok(mm$B$v == 2, "newer wins on overlap")
ok(mm$A$v == 1, "older survives where newer has nothing")

cat(sprintf("\n%s\n", strrep("=", 58)))
if (fail) { cat(sprintf("FAILED: %d assertion(s)\n", fail)); quit(status = 1) }
cat("Checkpoint merge contract holds.\n")
