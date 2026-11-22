#!/usr/bin/env Rscript
# =============================================================================
# The price of reducing a multi-state provider to one state
# =============================================================================
# Two questions are asked of the same records, and they do not get the same
# answer:
#
#   A. Is a midwife enrolled in Medicaid in a state CMS's National Downloadable
#      Health directory lists an address for?        (set membership)
#   B. Is the state where she has the MOST Medicaid enrolment segments one of
#      the states NDH lists?                         (one reduced value)
#
# A is near-flat in the number of state programmes she is enrolled in. B falls
# away as that number grows, and the gap between them is not a measurement of
# worse data: it is the cost of a reduction the comparison imposes. Every
# cross-source comparison in this project that scores one state per provider
# per year is paying some version of it.
#
# WHY THIS SCRIPT EXISTS. The finding was published in
# docs/VIGNETTE_STATE_SOURCE_AUDIT_2026-11-04.md with no surviving artifact --
# the numbers reached the prose and the producing code did not reach the repo.
# This rebuilds it from two tracked inputs so the claim can be checked and
# re-run, which is the standard that vignette's own argument demands.
#
# NDH IS MULTI-VALUED TOO, and is treated as a set here rather than reduced to
# one state, because reducing BOTH sides would bake the same error into the
# instrument measuring it.
#
# Inputs : artifacts/medicaid_enrollment_cohort_state_footprint.csv
#          artifacts/cms_ndh_midwives.csv
# Output : artifacts/medicaid_vs_ndh_state_reduction.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tidyr)
})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "clean_state.R"))

FOOTPRINT <- "artifacts/medicaid_enrollment_cohort_state_footprint.csv"
NDH       <- "artifacts/cms_ndh_midwives.csv"
OUT       <- "artifacts/medicaid_vs_ndh_state_reduction.csv"

#' States named in an NDH address blob
#'
#' Addresses arrive pipe-separated ("... Milwaukee WI 53204 | ... CA 94501").
#' The state is the two-letter token before the trailing ZIP of each segment;
#' anchoring on the ZIP rather than on position keeps a street name like
#' "Oakland CA" from being read out of the middle of a line.
#'
#' @param x [character]: one provider's `ndh_addresses` cell.
#' @return [character] unique state codes, possibly empty.
ndh_states_of <- function(x) {
  if (is.na(x) || !nzchar(x)) return(character(0))
  parts <- str_trim(str_split(x, "\\|", simplify = TRUE))
  st <- str_match(parts, "\\b([A-Z]{2})\\s+\\d{5}(?:-\\d{4})?\\s*$")[, 2]
  st <- st[!is.na(st)]
  unique(st[!is.na(clean_state(st))])
}

#' The one state a reduction of the directory would pick
#'
#' CMS's directory lists several addresses for many providers. Taking the first
#' is what the originally published version of this analysis did, and it is
#' reproduced here deliberately: both definitions are reported side by side so
#' the published 2026-11-04 figures stay checkable against the rebuild instead
#' of being quietly replaced by it.
ndh_first_of <- function(x) {
  s <- ndh_states_of(x)
  if (length(s)) s[1] else NA_character_
}

stopifnot(file.exists(FOOTPRINT), file.exists(NDH))

fp <- read_csv(FOOTPRINT, show_col_types = FALSE, progress = FALSE)

# Her Medicaid state set, and the one state a reduction would pick: most
# enrolment segments, ties broken alphabetically so the choice is deterministic
# and reproducible rather than row-order dependent.
med <- fp %>%
  group_by(npi, state) %>%
  summarise(segs = sum(n_segments), .groups = "drop") %>%
  arrange(npi, desc(segs), state)

med_set <- med %>% group_by(npi) %>%
  summarise(states = list(state), k = n_distinct(state),
            largest = first(state), .groups = "drop")

ndh <- read_csv(NDH, show_col_types = FALSE, progress = FALSE) %>%
  filter(!is.na(ndh_addresses), nzchar(ndh_addresses)) %>%
  mutate(ndh_st  = lapply(ndh_addresses, ndh_states_of),
         ndh_one = vapply(ndh_addresses, ndh_first_of, character(1))) %>%
  filter(lengths(ndh_st) > 0) %>%
  select(npi, ndh_st, ndh_one)

cmp <- med_set %>%
  inner_join(ndh, by = "npi") %>%
  mutate(
    # A: does ANY state NDH lists appear anywhere in her Medicaid footprint
    enrolled_where_listed = mapply(function(a, b) any(b %in% a), states, ndh_st),
    # B: is the single state a reduction would pick one of NDH's
    largest_is_listed     = mapply(function(l, b) l %in% b, largest, ndh_st),
    # The originally published definition, kept so the two are comparable:
    # the directory reduced to its FIRST listed address rather than its set.
    enrolled_where_listed_firstonly = mapply(function(a, o) o %in% a, states, ndh_one),
    largest_is_listed_firstonly     = largest == ndh_one
  )

out <- cmp %>%
  mutate(band = ifelse(k >= 5, "5+", as.character(k))) %>%
  group_by(band) %>%
  summarise(n_midwives = n(),
            pct_enrolled_where_listed = 100 * mean(enrolled_where_listed),
            pct_largest_is_listed     = 100 * mean(largest_is_listed),
            pct_enrolled_where_listed_firstonly = 100 * mean(enrolled_where_listed_firstonly),
            pct_largest_is_listed_firstonly     = 100 * mean(largest_is_listed_firstonly),
            .groups = "drop") %>%
  mutate(share_of_comparable = 100 * n_midwives / sum(n_midwives),
         gap_points = pct_enrolled_where_listed - pct_largest_is_listed) %>%
  arrange(band)

overall <- cmp %>% summarise(band = "all",
  n_midwives = n(),
  pct_enrolled_where_listed = 100 * mean(enrolled_where_listed),
  pct_largest_is_listed     = 100 * mean(largest_is_listed),
  pct_enrolled_where_listed_firstonly = 100 * mean(enrolled_where_listed_firstonly),
  pct_largest_is_listed_firstonly     = 100 * mean(largest_is_listed_firstonly),
  share_of_comparable = 100,
  gap_points = 100 * (mean(enrolled_where_listed) - mean(largest_is_listed)))

out <- bind_rows(out, overall)
print(as.data.frame(out), row.names = FALSE, digits = 4)

# The whole point is that the two curves diverge; if they ever stop doing so
# the figure drawn from this is making a claim the data no longer supports.
stopifnot(nrow(out) >= 3,
          all(out$pct_enrolled_where_listed >= out$pct_largest_is_listed - 1e-9))

write_with_provenance(out, OUT, inputs = c(FOOTPRINT, NDH), na = "")
cat(sprintf("\nwrote %s (%d comparable midwives)\n", OUT, nrow(cmp)))
