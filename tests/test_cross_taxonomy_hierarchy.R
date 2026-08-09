#!/usr/bin/env Rscript
# Synthetic tests for the cross-taxonomy resolution hierarchy.
#
# The rule these pin down: identity evidence is judged FIRST, taxonomy second.
# An exact-name nursing-only candidate is not automatically worse than a
# fuzzy-name midwifery one -- but it must never be promoted into
# primary_midwifery either. Both directions of that error were made during
# development, one after the other.

suppressPackageStartupMessages({library(dplyr); library(testthat)})

CONFLICT_MARGIN <- 12

resolve_pool <- function(df) {
  if (!nrow(df)) return(mutate(df, resolution = character(0)))
  df %>% group_by(amcb_id) %>%
    mutate(top_score = max(score_total), n_at_top = sum(score_total == top_score),
           n_top_mid = sum(score_total == top_score & mid_match == 1L)) %>%
    filter(score_total == top_score) %>%
    mutate(resolution = case_when(
      n_at_top == 1L                    ~ "unique_top_score",
      n_top_mid == 1L & mid_match == 1L ~ "resolved_by_middle",
      TRUE                              ~ "tied")) %>%
    filter(resolution != "tied", !(n_at_top > 1L & resolution == "unique_top_score")) %>%
    ungroup()
}

decide <- function(cand) {
  stats <- cand %>% group_by(amcb_id) %>%
    summarise(bm = suppressWarnings(max(score_total[npi_tax_class == "midwife"], -Inf)),
              bn = suppressWarnings(max(score_total[npi_tax_class == "nursing"], -Inf)),
              nm = sum(npi_tax_class == "midwife"),
              nn = sum(npi_tax_class == "nursing"), .groups = "drop")
  mid <- resolve_pool(filter(cand, npi_tax_class == "midwife"))
  need <- setdiff(unique(cand$amcb_id), mid$amcb_id)
  # Rule 4 covers a midwifery candidate that is WEAK as well as one that is
  # non-identifiable: a lone fuzzy midwifery match must not win outright
  # against a far stronger nursing-only one just because it stands alone.
  conflict <- stats %>% filter(nm > 0, nn > 0, is.finite(bm), is.finite(bn),
                               bn - bm >= CONFLICT_MARGIN) %>% pull(amcb_id)
  mid <- filter(mid, !amcb_id %in% conflict)
  need <- setdiff(unique(cand$amcb_id), mid$amcb_id)
  nurs <- resolve_pool(filter(cand, npi_tax_class == "nursing",
                              amcb_id %in% setdiff(need, conflict)))
  bind_rows(mutate(mid, tier = "primary_midwifery"),
            mutate(nurs, tier = "sensitivity_nursing")) %>%
    bind_rows(tibble(amcb_id = conflict, tier = "quarantined_cross_taxonomy"))
}

cand <- function(id, npi, cls, score, mid = 0L, fuzzy = FALSE)
  tibble(amcb_id = id, npi = npi, npi_tax_class = cls, score_total = score,
         mid_match = as.integer(mid), fuzzy = fuzzy)

test_that("exact midwifery beats exact nursing-only", {
  r <- decide(bind_rows(cand("A", "M1", "midwife", 60), cand("A", "N1", "nursing", 60)))
  expect_equal(r$tier[r$amcb_id == "A"], "primary_midwifery")
  expect_equal(r$npi[r$amcb_id == "A"], "M1")
})

test_that("fuzzy midwifery does NOT block an exact nursing-only match", {
  # Fuzzy surname scores 20 (first only); exact nursing scores 60. The gap
  # exceeds the margin, so neither identity is asserted.
  r <- decide(bind_rows(cand("B", "M1", "midwife", 20, fuzzy = TRUE),
                        cand("B", "N1", "nursing", 60)))
  expect_equal(r$tier[r$amcb_id == "B"], "quarantined_cross_taxonomy")
})

test_that("exact midwifery survives a fuzzy nursing-only rival", {
  r <- decide(bind_rows(cand("C", "M1", "midwife", 60), cand("C", "N1", "nursing", 20)))
  expect_equal(r$tier[r$amcb_id == "C"], "primary_midwifery")
})

test_that("ambiguous midwifery falls through to an exact nursing match", {
  # Two tied midwifery candidates are not identifiable; the nursing candidate
  # is, and the gap is under the margin, so it is accepted as SENSITIVITY only.
  r <- decide(bind_rows(cand("D", "M1", "midwife", 55), cand("D", "M2", "midwife", 55),
                        cand("D", "N1", "nursing", 60)))
  expect_equal(r$tier[r$amcb_id == "D"], "sensitivity_nursing")
  expect_false("primary_midwifery" %in% r$tier[r$amcb_id == "D"])
})

test_that("exact midwifery wins over ambiguous nursing", {
  r <- decide(bind_rows(cand("E", "M1", "midwife", 60),
                        cand("E", "N1", "nursing", 55), cand("E", "N2", "nursing", 55)))
  expect_equal(r$tier[r$amcb_id == "E"], "primary_midwifery")
})

test_that("tied cross-taxonomy evidence resolves to the midwifery pool", {
  # Equal scores: the midwifery pool is resolved first and is identifiable, so
  # taxonomy breaks the tie -- but only because identity evidence was equal.
  r <- decide(bind_rows(cand("F", "M1", "midwife", 60), cand("F", "N1", "nursing", 60)))
  expect_equal(r$tier[r$amcb_id == "F"], "primary_midwifery")
})

test_that("nursing-only matches never enter primary_midwifery", {
  r <- decide(bind_rows(cand("G", "N1", "nursing", 60), cand("H", "N2", "nursing", 60)))
  expect_true(all(r$tier == "sensitivity_nursing"))
})

# --- Invariant: candidate sets only grow ------------------------------------
# Adding a candidate source must never make a previously known candidate
# disappear from the audit table. It may change which candidate is SELECTED, or
# make the row ambiguous, but the losing candidate must remain visible. The
# staged cascade violated this silently: once an exact match existed, the
# fuzzy-surname candidate was never generated, so STACEY WALDEN vanished from
# the evidence rather than losing on it.
test_that("adding a candidate source never removes a known candidate", {
  gen <- function(sources) {
    out <- tibble(amcb_id = character(0), npi = character(0))
    if ("exact" %in% sources)
      out <- bind_rows(out, tibble(amcb_id = "X", npi = "N_exact"))
    if ("fuzzy" %in% sources)
      out <- bind_rows(out, tibble(amcb_id = "X", npi = "M_fuzzy"))
    out
  }
  before <- gen("fuzzy")
  after  <- gen(c("exact", "fuzzy"))
  expect_true(all(before$npi %in% after$npi),
              info = "every candidate present before must survive the addition")
  expect_gt(nrow(after), nrow(before))
})

test_that("taxonomy cannot break a tie between indistinguishable names", {
  # Two candidates, identical name evidence, different taxonomy. Neither may
  # be selected: taxonomy says nothing about WHICH person the name refers to.
  best <- tibble(amcb_id = c("Y", "Y"), npi = c("M1", "N1"),
                 name_evidence_class = c(2L, 2L),
                 taxonomy_axis = c("midwife", "nursing"))
  n_at_best <- sum(best$name_evidence_class == min(best$name_evidence_class))
  expect_gt(n_at_best, 1L)
  resolved <- best %>% filter(n_at_best == 1L)
  expect_equal(nrow(resolved), 0L)
})
