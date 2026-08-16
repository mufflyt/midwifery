#!/usr/bin/env Rscript
# =============================================================================
# A publication label is not an observation date
# =============================================================================
# CMS republishes byte-identical content under a later month. 2024-03 and
# 2024-08 share an sha256. If both are treated as observations, a relationship
# that ended in April 2024 reads as on file through August -- five months of
# continuity nobody observed, in a panel whose entire purpose is to avoid
# asserting exactly that.
#
# This enforces three things:
#
#   V  the tracked manifest is internally coherent: one content hash may carry
#      many labels, but exactly one of them is retained, and it is the earliest.
#   P  the panel builder actually drops republished labels -- detection that is
#      recorded but not applied is worse than none, because it reads as handled.
#   S  spell duration advances only on distinct content.
#
# Hermetic. Reads the tracked manifest and the panel builder's source. No raw
# snapshot, no warehouse, no network -- so it runs in CI where the 21 GB
# external volume is not mounted.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({ library(dplyr); library(readr) })

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

MAN <- "artifacts/revalidation_vintage_manifest.csv"

# =============================================================================
cat("\n-- V: the manifest is coherent --\n")
# =============================================================================
if (!file.exists(MAN)) {
  # Not a skip. The manifest is tracked; if it is gone, the invariant below is
  # unenforceable and the panel could silently regain five phantom months.
  cat(sprintf("  FAIL V0 %s is missing; run build_revalidation_vintage_manifest.R\n", MAN))
  fails <- fails + 1L
} else {
  m <- read_csv(MAN, col_types = cols(.default = "c"), progress = FALSE) |>
    mutate(is_republication = .data$is_republication %in% c("TRUE", "true"),
           use_for_panel    = .data$use_for_panel %in% c("TRUE", "true"))

  chk(nrow(m) > 0L, sprintf("V1 the manifest has %d labels", nrow(m)))
  chk(all(grepl("^[0-9]{4}-[0-9]{2}$", m$vintage)),
      "V2 every label is a YYYY-MM vintage")
  chk(!any(duplicated(m$vintage)), "V3 no label appears twice")
  chk(all(nchar(m$sha256) == 64L), "V4 every label carries a full sha256")

  # The load-bearing one: one content hash, exactly one retained label.
  per_hash <- m |> group_by(.data$sha256) |>
    summarise(n_labels = dplyr::n(), n_kept = sum(.data$use_for_panel),
              earliest = min(.data$vintage),
              kept_label = paste(.data$vintage[.data$use_for_panel], collapse = ","),
              .groups = "drop")
  chk(all(per_hash$n_kept == 1L),
      sprintf("V5 each of %d distinct contents retains exactly one label",
              nrow(per_hash)))
  # And the retained one is the EARLIER label -- when that content was current.
  chk(all(per_hash$kept_label == per_hash$earliest),
      "V6 the retained label is the earliest one carrying that content")

  ndup <- sum(m$is_republication)
  chk(identical(sum(!m$use_for_panel), ndup),
      "V7 republished and not-used-for-panel are the same set")
  cat(sprintf("       %d labels, %d distinct contents, %d republication(s)\n",
              nrow(m), nrow(per_hash), ndup))

  # The known case. If CMS ever un-publishes it this should be revisited
  # deliberately, not discovered by a number quietly changing.
  if (all(c("2024-03", "2024-08") %in% m$vintage)) {
    h <- m$sha256[match(c("2024-03", "2024-08"), m$vintage)]
    chk(identical(h[1], h[2]),
        "V8 the known 2024-03 / 2024-08 republication is still recorded")
    chk(isTRUE(m$use_for_panel[m$vintage == "2024-03"]) &&
        isFALSE(m$use_for_panel[m$vintage == "2024-08"]),
        "V9 and 2024-03 is the one kept")
  }
}

# =============================================================================
cat("\n-- P: the panel builder applies it --\n")
# =============================================================================
# Detection that is recorded but not acted on is worse than none: it reads as
# handled. These assert the drop actually happens in the builder.
{
  f <- "build_reassignment_panel.R"
  chk(file.exists(f), "P1 the panel builder exists")
  if (file.exists(f)) {
    ln <- readLines(f, warn = FALSE)
    code <- paste(ln[!grepl("^\\s*#", ln)], collapse = "\n")

    chk(grepl("setdiff\\s*\\(\\s*vint", code),
        "P2 the builder removes vintages from the list it panels over")
    # The vintage list must be narrowed BEFORE the panel query runs, not after.
    i_drop  <- regexpr("setdiff\\s*\\(\\s*vint", code)
    i_query <- regexpr("JOIN", code)
    chk(i_drop > 0 && i_query > 0 && i_drop < i_query,
        "P3 vintages are dropped before the panel query, not after")
    # Detection must be on content, never on a hardcoded month.
    chk(!grepl('"2024-08"', code, fixed = TRUE) &&
        !grepl("'2024-08'", code, fixed = TRUE),
        "P4 no hardcoded month: detection is by content, so the next one is caught")
    chk(grepl("length\\(vint\\)\\s*<\\s*2", code),
        "P5 the builder refuses to build a panel from fewer than two vintages")
  }
}

# =============================================================================
cat("\n-- S: spells advance only on distinct content --\n")
# =============================================================================
{
  f <- "build_reassignment_panel.R"
  if (file.exists(f)) {
    ln <- readLines(f, warn = FALSE)
    code <- paste(ln[!grepl("^\\s*#", ln)], collapse = "\n")
    # Spells must be indexed against the FILTERED vintage vector, so a dropped
    # label cannot contribute a snapshot to any spell's length.
    chk(grepl("vidx\\s*<-\\s*setNames\\(seq_along\\(vint\\)", code),
        "S1 spell indices come from the filtered vintage vector")
    chk(grepl("n_snapshots_seen", code),
        "S2 spells report how many snapshots they rest on")
    # No calendar arithmetic on labels: months CMS never published are not
    # breaks, and republished months are not observations.
    chk(!grepl("as\\.Date\\(paste0\\(.*vintage", code),
        "S3 spell length is snapshot-counted, not computed from label dates")
  }
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
