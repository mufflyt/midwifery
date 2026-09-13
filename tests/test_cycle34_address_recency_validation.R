#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 34, revised 2026-09-13
# =============================================================================
# Target: validate_address_recency_pipeline.R.
#
# Cycle 34 (2026-08-30) fixed two defects here: a coverage count printed as a
# relocation count, and a case-study verdict hardcoded regardless of its
# evidence. The coverage fix stands and is still tested below (T34-4, T34-7).
#
# The verdict fix does not, because what it made "conditional on the
# evidence" was not evidence. The verdict read has_cpt_delivery_claim, which
# was "DAC primary specialty is CNM" relabelled as delivery attendance, about
# a midwife whose NPPES address fields had been overwritten by hand; and the
# summary table beside it carried typed-in "400" and "98.5%" that no code
# computes. All three were removed on 2026-09-13 (see the script header and
# docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md). The tests that pinned
# the case study and the CPT arithmetic went with them; in their place are
# checks that the production file cannot quietly grow them back.
#
# The script cannot run end-to-end (gitignored input), so its counting logic
# is replicated literally here, and its source is read for the static checks.
#
# Run: Rscript tests/test_cycle34_address_recency_validation.R
# =============================================================================

suppressPackageStartupMessages({ library(dplyr); library(stringr) })

root <- "."
if (!file.exists(file.path(root, "validate_address_recency_pipeline.R")) &&
    file.exists("../validate_address_recency_pipeline.R")) root <- ".."
PROD <- file.path(root, "validate_address_recency_pipeline.R")

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# Literal replicas of the production counting logic.
state_coverage_message <- function(v4) {
  state_known <- v4 %>% filter(!is.na(nppes_state))
  sprintf("1. NPPES State Coverage: %d midwives have a known current NPPES practice state (not a cross-state MOVE count -- no prior-state field exists to compare against).",
          n_distinct(state_known$npi))
}
summary_counts <- function(v4) {
  c(total = n_distinct(v4$npi),
    state_known = n_distinct(v4$npi[!is.na(v4$nppes_state)]))
}
retired_state_message <- function(n) sprintf("1. State Transition Audit: Identified %d midwives with cross-state practice moves.", n)

code_only <- local({
  ln <- readLines(PROD, warn = FALSE)
  ln[!grepl("^\\s*#", ln)]
})

cat("\n-- BVA --\n")

# T34-1. An empty input yields zero counts rather than an error.
{
  v4 <- tibble::tibble(npi = character(0), nppes_state = character(0))
  chk(identical(unname(summary_counts(v4)), c(0L, 0L)) &&
        grepl("Coverage: 0 midwives", state_coverage_message(v4)),
      "T34-1 an empty cohort yields 0 midwives, not an error")
}

# T34-2. Every nppes_state missing: coverage is 0 of N, not NA.
{
  v4 <- tibble::tibble(npi = c("1", "2"), nppes_state = c(NA_character_, NA_character_))
  chk(identical(unname(summary_counts(v4)), c(2L, 0L)),
      "T34-2 an entirely-NA nppes_state column gives coverage 0 of 2")
}

cat("\n-- SEMANTIC --\n")

# T34-4. The coverage message describes the quantity it computes (a coverage
# count), not one it cannot compute (a relocation count).
{
  v4 <- tibble::tibble(npi = c("1", "2", "3"), nppes_state = c("CO", NA, "TX"))
  msg <- state_coverage_message(v4)
  chk(grepl("known current NPPES practice state", msg) && !grepl("cross-state practice move", msg),
      "T34-4 the coverage message does not claim a cross-state MOVE count")
  chk(grepl("cross-state practice moves", retired_state_message(2L)),
      "T34-4b the retired message claimed 'cross-state practice moves' for the same count")
}

# T34-7. The printed count and the summary-table count come from one filter.
{
  v4 <- tibble::tibble(npi = c("1", "2", "3", "4"), nppes_state = c("CO", NA, "TX", "WA"))
  n_msg <- as.integer(str_match(state_coverage_message(v4), "Coverage: (\\d+) midwives")[, 2])
  chk(identical(n_msg, unname(summary_counts(v4)["state_known"])),
      sprintf("T34-7 message count (%d) equals summary count (%d)",
              n_msg, summary_counts(v4)["state_known"]))
}

# T34-11. Counts are of people. v4 has one row per midwife per attributed
# facility; a midwife with two facilities is one midwife.
{
  v4 <- tibble::tibble(npi = c("1", "1", "2"), nppes_state = c("WA", "WA", NA))
  chk(identical(unname(summary_counts(v4)), c(2L, 1L)),
      "T34-11 a duplicated NPI counts once in both the total and the coverage")
}

cat("\n-- ADVERSARIAL (static checks on the production file) --\n")

# T34-12. No value in the summary table may be a typed literal. Every Value
# entry must be computed with as.character(...). The retired table carried
# "400" and "98.5%" as bare strings.
{
  tb <- paste(code_only, collapse = "\n")
  block <- str_match(tb, "(?s)tribble\\((.*?)\\n\\)")[, 2]
  rows <- str_split(block, "\n")[[1]]
  rows <- rows[grepl("^\\s*\"", rows)]
  values <- str_trim(str_replace(rows, '^\\s*"[^"]*",\\s*"[^"]*",\\s*', ""))
  typed <- values[!grepl("^as\\.character\\(", values)]
  chk(length(rows) >= 1L && length(typed) == 0L,
      sprintf("T34-12 every summary Value is computed (%d rows; typed literals: %s)",
              length(rows), if (length(typed)) paste(typed, collapse = " | ") else "none"))
}

# T34-13. The script must not read the relabelled delivery flag or anything
# derived from it.
{
  hit <- grepl("has_cpt_delivery_claim|active_attending_status|refined_clinical_setting|cpt",
               code_only, ignore.case = TRUE)
  chk(!any(hit),
      sprintf("T34-13 no code line reads a CPT/delivery field (%d found)", sum(hit)))
}

# T34-14. No named-person case study. A filter on a surname in production code
# is how a hand-edited record was "validated" against itself.
{
  hit <- grepl("filter\\([^)]*last_name|str_detect\\([^)]*last_name", code_only)
  chk(!any(hit),
      sprintf("T34-14 no code line filters on an individual's surname (%d found)", sum(hit)))
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
