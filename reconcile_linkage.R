#!/usr/bin/env Rscript
# =============================================================================
# Reconcile the A/B linkage runs and freeze the linkage artifact
# =============================================================================
#
# Three things this settles before the artifact is trusted:
#
#  1. A/B accounting. The net gain (+6,041) and the count of newly matched rows
#     (6,120) can only differ if some rows that matched under the truncated
#     panel changed or lost their match once 2018-2025 candidates appeared.
#     That is the identifiability guard working, and it must be shown, not
#     absorbed into a net figure. A full row-level transition matrix is
#     produced and required to reconcile to 22,309.
#
#  2. A mutually exclusive resolution variable. The previous breakdown mixed
#     resolution categories with a diagnostic flag: "exact first+last with >1
#     candidate NPI" is a SUBSET of the middle-resolved rows, and the 66
#     last-name + first-initial matches were omitted entirely, so the
#     categories summed to 15,640 rather than 15,706.
#
#  3. Fuzzy-surname matches demoted to sensitivity. With no city, state, phone
#     or date of birth on the AMCB side, a Levenshtein surname match rests on
#     materially weaker evidence than an exact one. Excluding the 168 costs
#     0.8 percentage points of yield and buys a clean primary definition.
#
# Output: artifacts/amcb_npi_linkage_FROZEN.csv
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr); library(tidyr)})

full <- read_csv("artifacts/amcb_npi_matched.csv", show_col_types = FALSE)
old  <- read_csv("artifacts/amcb_npi_matched_through2017.csv", show_col_types = FALSE)
stopifnot(nrow(full) == 22309, nrow(old) == 22309)

# --- 1. Transition matrix -----------------------------------------------------
state_of <- function(d) case_when(
  d$npi_match_status == "matched"                  ~ "matched",
  grepl("^ambiguous", d$npi_match_status)          ~ "quarantined",
  TRUE                                             ~ "unmatched")

cmp <- tibble(amcb_id = full$certification_number,
              before = state_of(old), after = state_of(full),
              npi_before = old$npi, npi_after = full$npi) %>%
  mutate(transition = case_when(
    before == "matched" & after == "matched" & npi_before == npi_after ~ "matched -> same NPI",
    before == "matched" & after == "matched" & npi_before != npi_after ~ "matched -> different NPI",
    before == "matched" & after == "quarantined"   ~ "matched -> quarantined",
    before == "matched" & after == "unmatched"     ~ "matched -> unmatched",
    before == "quarantined" & after == "matched"   ~ "quarantined -> matched",
    before == "unmatched" & after == "matched"     ~ "unmatched -> matched",
    before == "quarantined" & after == "quarantined" ~ "quarantined -> quarantined",
    before == "unmatched" & after == "unmatched"   ~ "unmatched -> unmatched",
    TRUE ~ paste(before, "->", after)))

cat("=== A/B transition matrix (through-2017 -> 2007-2025) ===\n")
tm <- count(cmp, transition, sort = TRUE)
print(as.data.frame(tm))
cat(sprintf("\ntotal rows                : %s (must equal 22,309)\n",
            format(sum(tm$n), big.mark = ",")))
gained <- sum(cmp$after == "matched") - sum(cmp$before == "matched")
newly  <- sum(cmp$before != "matched" & cmp$after == "matched")
lost   <- sum(cmp$before == "matched" & cmp$after != "matched")
changed<- sum(cmp$transition == "matched -> different NPI")
cat(sprintf("newly matched             : %s\n", format(newly, big.mark = ",")))
cat(sprintf("lost their match          : %s\n", format(lost, big.mark = ",")))
cat(sprintf("net gain                  : %s  (%s newly - %s lost)\n",
            format(gained, big.mark = ","), format(newly, big.mark = ","),
            format(lost, big.mark = ",")))
cat(sprintf("matched but NPI changed   : %s (net-neutral)\n", format(changed, big.mark = ",")))
stopifnot(sum(tm$n) == 22309, gained == newly - lost)

reclass <- cmp %>% filter(transition %in% c("matched -> different NPI",
                                            "matched -> quarantined",
                                            "matched -> unmatched"))
if (nrow(reclass)) {
  cat("\n=== rows whose resolution changed when 2018-2025 was added ===\n")
  det <- reclass %>%
    left_join(select(full, amcb_id = certification_number, last_name, first_name,
                     status, n_candidates_pre_rank_after = n_candidates_pre_rank,
                     status_after = npi_match_status), by = "amcb_id") %>%
    left_join(select(old, amcb_id = certification_number,
                     n_candidates_pre_rank_before = n_candidates_pre_rank),
              by = "amcb_id")
  print(det %>% count(transition, status_after) %>% as.data.frame())
  cat("\ncandidate counts before vs after (median):\n")
  print(det %>% group_by(transition) %>%
          summarise(median_before = median(n_candidates_pre_rank_before, na.rm = TRUE),
                    median_after  = median(n_candidates_pre_rank_after, na.rm = TRUE),
                    .groups = "drop") %>% as.data.frame())
  cat("\nsample:\n")
  print(det %>% select(amcb_id, last_name, first_name, transition,
                       n_candidates_pre_rank_before, n_candidates_pre_rank_after) %>%
          head(15) %>% as.data.frame())
}

# --- 2. Mutually exclusive resolution ----------------------------------------
frozen <- full %>%
  mutate(
    match_resolution = case_when(
      is.na(npi)                                              ~ NA_character_,
      npi_match_method == "fuzzy_last_exact_first"            ~ "fuzzy_surname",
      npi_match_method == "exact_last_first_initial"          ~ "last_plus_first_initial",
      npi_match_resolution == "resolved_by_middle"            ~ "exact_name_tie_broken_by_middle",
      TRUE                                                    ~ "exact_name_unique"),
    # Diagnostic, deliberately NOT a resolution category: it overlaps with
    # exact_name_tie_broken_by_middle and describes the candidate set, not how
    # the row was decided.
    exact_first_last_multiple_candidates =
      !is.na(npi) & npi_match_method == "exact_last_first" & n_candidates_pre_rank > 1,
    # 3. Fuzzy surname is evidentially weaker with no location to corroborate it.
    match_status = case_when(
      is.na(npi)                             ~ npi_match_status,
      match_resolution == "fuzzy_surname"    ~ "sensitivity_fuzzy",
      TRUE                                   ~ "primary"))

cat("\n=== mutually exclusive match_resolution ===\n")
res <- frozen %>% filter(!is.na(npi)) %>% count(match_resolution, sort = TRUE)
print(as.data.frame(res))
cat(sprintf("sum                       : %s (must equal %s accepted)\n",
            format(sum(res$n), big.mark = ","),
            format(sum(!is.na(frozen$npi)), big.mark = ",")))
stopifnot(sum(res$n) == sum(!is.na(frozen$npi)))
cat(sprintf("diagnostic overlap: exact first+last with >1 candidate NPI: %s\n",
            format(sum(frozen$exact_first_last_multiple_candidates), big.mark = ",")))

n <- nrow(frozen)
prim <- sum(frozen$match_status == "primary")
sens <- sum(frozen$match_status == "sensitivity_fuzzy")
cat(sprintf("\nprimary linkage           : %s (%.1f%%)\n", format(prim, big.mark = ","), 100*prim/n))
cat(sprintf("+ sensitivity (fuzzy)     : %s (%.1f%%)\n",
            format(prim + sens, big.mark = ","), 100*(prim+sens)/n))

# --- Linkage completeness is NOT random --------------------------------------
cat("\n=== linkage completeness by AMCB status (primary only) ===\n")
by_status <- frozen %>%
  group_by(status) %>%
  summarise(n = n(), primary = sum(match_status == "primary"),
            pct_primary = round(100 * mean(match_status == "primary"), 1),
            .groups = "drop") %>%
  arrange(desc(n))
print(as.data.frame(by_status))
cat(sprintf("\nrange: %.1f%% (%s) to %.1f%% (%s) -- linkage is strongly\n",
            min(by_status$pct_primary), by_status$status[which.min(by_status$pct_primary)],
            max(by_status$pct_primary), by_status$status[which.max(by_status$pct_primary)]))
cat("associated with certification status, so the linked subset is NOT a\n")
cat("representative sample of the roster. Any geographic analysis must report\n")
cat("completeness by status rather than treating the linked rows as a random 70%.\n")

write_csv(frozen, "artifacts/amcb_npi_linkage_FROZEN.csv", na = "")
cat(sprintf("\nfrozen artifact           : %s\n",
            normalizePath("artifacts/amcb_npi_linkage_FROZEN.csv")))
cat(sprintf("columns                   : %s\n", ncol(frozen)))
