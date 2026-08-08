#!/usr/bin/env Rscript
# =============================================================================
# Audit the 81 rows whose linked identity changed when 2018-2025 was added
# =============================================================================
#
# A row moving matched -> quarantined is the guard working: newer data revealed
# ambiguity the truncated panel hid. A row moving matched -> DIFFERENT NPI is a
# different claim -- it says the linked person is someone else. Those must be
# explained before the artifact is frozen.
#
# Nothing here changes a match. It only classifies why each identity moved.
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr); library(tidyr)})

# NPIs are identifiers, not numbers: read_csv infers double and then refuses to
# join against the panel's character column.
full  <- read_csv("artifacts/amcb_npi_matched.csv", show_col_types = FALSE) %>%
  mutate(npi = as.character(npi))
old   <- read_csv("artifacts/amcb_npi_matched_through2017.csv", show_col_types = FALSE) %>%
  mutate(npi = as.character(npi))
panel <- read_csv("midwife_panel.csv", col_types = cols(.default = "c")) %>%
  mutate(snapshot_year = as.integer(snapshot_year))

flips <- full %>%
  select(amcb_id = certification_number, last_name, first_name, middle_name, status,
         npi_new = npi, method_new = npi_match_method, res_new = npi_match_resolution,
         cand_new = n_candidates_pre_rank,
         city_new = nppes_city, state_new = nppes_state, year_new = nppes_location_year) %>%
  inner_join(old %>% select(amcb_id = certification_number, npi_old = npi,
                            method_old = npi_match_method, res_old = npi_match_resolution,
                            cand_old = n_candidates_pre_rank),
             by = "amcb_id") %>%
  filter(!is.na(npi_new), !is.na(npi_old), npi_new != npi_old)

cat(sprintf("identity flips to audit: %s\n\n", nrow(flips)))

# Per-NPI history from the panel: lifespan, every name spelling, taxonomy.
npi_hist <- panel %>%
  group_by(npi) %>%
  summarise(first_year = min(snapshot_year, na.rm = TRUE),
            last_year  = max(snapshot_year, na.rm = TRUE),
            n_surnames = n_distinct(last_name),
            names_seen = paste(sort(unique(paste(first_name, middle_name, last_name))),
                               collapse = " | "),
            surnames   = paste(sort(unique(last_name)), collapse = "|"),
            city       = last(practice_city[order(snapshot_year)]),
            state      = last(practice_state[order(snapshot_year)]),
            .groups = "drop")

aud <- flips %>%
  left_join(npi_hist %>% rename_with(~paste0(.x, "_o"), -npi), by = c("npi_old" = "npi")) %>%
  left_join(npi_hist %>% rename_with(~paste0(.x, "_n"), -npi), by = c("npi_new" = "npi")) %>%
  mutate(
    amcb_last_upper = toupper(gsub("[^A-Za-z]", "", last_name)),
    new_npi_is_newer   = !is.na(first_year_n) & first_year_n >= 2018,
    old_npi_absent_now = !is.na(last_year_o) & last_year_o <= 2017,
    new_has_namechange = !is.na(n_surnames_n) & n_surnames_n > 1,
    old_has_namechange = !is.na(n_surnames_o) & n_surnames_o > 1,
    same_name_both     = !is.na(surnames_o) & !is.na(surnames_n) &
                          surnames_o == surnames_n,
    method_changed     = method_old != method_new,
    reason = case_when(
      new_npi_is_newer                          ~ "newer_true_candidate",
      new_has_namechange | old_has_namechange   ~ "historical_name_change",
      method_old == "fuzzy_last_exact_first" |
        method_new == "fuzzy_last_exact_first"  ~ "fuzzy_stage_displacement",
      same_name_both                            ~ "duplicate_name_collision",
      TRUE                                      ~ "unexplained"))

cat("=== reason for identity change ===\n")
print(as.data.frame(count(aud, reason, sort = TRUE)))
cat(sprintf("\ntotal: %s (must equal %s)\n", nrow(aud), nrow(flips)))
stopifnot(nrow(aud) == nrow(flips), !any(is.na(aud$reason)))

cat("\n=== supporting detail ===\n")
cat(sprintf("new NPI first appears 2018+          : %s\n", sum(aud$new_npi_is_newer)))
cat(sprintf("old NPI last appears <=2017          : %s\n", sum(aud$old_npi_absent_now)))
cat(sprintf("either NPI has >1 surname on record  : %s\n",
            sum(aud$new_has_namechange | aud$old_has_namechange)))
cat(sprintf("both NPIs share identical surname    : %s\n", sum(aud$same_name_both, na.rm = TRUE)))
cat(sprintf("match method differed between runs   : %s\n", sum(aud$method_changed)))
cat(sprintf("candidate count 1 in both runs       : %s\n",
            sum(aud$cand_old == 1 & aud$cand_new == 1)))

cat("\n=== 20 representative rows ===\n")
show <- aud %>%
  transmute(amcb = paste(last_name, first_name, sep = ", "), status,
            npi_old, old_yrs = paste0(first_year_o, "-", last_year_o),
            old_names = substr(names_seen_o, 1, 34),
            npi_new, new_yrs = paste0(first_year_n, "-", last_year_n),
            new_names = substr(names_seen_n, 1, 34),
            new_loc = paste(city_new, state_new), reason)
print(head(as.data.frame(show), 20), right = FALSE)

write_csv(aud, "artifacts/identity_flip_audit.csv", na = "")
cat(sprintf("\naudit written: %s\n", normalizePath("artifacts/identity_flip_audit.csv")))
