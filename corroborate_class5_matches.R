#!/usr/bin/env Rscript
# =============================================================================
# Class-5 corroboration: does the DROPPED surname component appear anywhere in
# the matched NPI's own NPPES record?
# =============================================================================
#
# THE IDEA. A class-5 match joins "CECELIA BROWN MELIN" (AMCB) to "CECELIA
# BROWN" (NPPES) on the token BROWN, discarding MELIN. The reviewer's question
# is whether these are one person or two Cecelia Browns. That question usually
# has an OBJECTIVE answer sitting in the panel: if any historical name variant
# of that NPI -- any snapshot's surname, middle name or first name, 2007-2025 --
# contains MELIN, then the registry itself records the same compound the roster
# does, and the match is corroborated by evidence outside the join that made it.
#
# This converts most of the review from judgement into a lookup. It cannot
# CONFIRM a non-match: absence of the dropped component means the registry
# never recorded it, which is exactly what happens when a name is genuinely
# dropped. So the output is three-valued -- corroborated / not corroborated /
# nothing to corroborate -- and only the first is decisive.
#
# Run: Rscript corroborate_class5_matches.R
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb)
})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)
source(file.path(root_dir, "R", "amcb_name_keys.R"))

CENSUS <- Sys.getenv("CLASS5_CENSUS", "artifacts/amcb_class5_review_census.csv")
PANEL  <- Sys.getenv("MIDWIFE_PANEL", "midwife_panel.csv")
OUT    <- Sys.getenv("CORROB_OUT", "artifacts/amcb_class5_corroboration.csv")
stopifnot(file.exists(CENSUS), file.exists(PANEL))

cen <- read_csv(CENSUS, col_types = cols(.default = "c"))
cat(sprintf("class-5 rows: %s\n", format(nrow(cen), big.mark = ",")))

# --- Every recorded name string for each matched NPI --------------------------
con <- dbConnect(duckdb::duckdb()); on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
npis <- unique(cen$npi)
vars <- dbGetQuery(con, sprintf(
  "SELECT DISTINCT npi, last_name, middle_name, first_name
     FROM read_csv_auto('%s', all_varchar = TRUE, sample_size = 1000,
                        normalize_names = TRUE)
    WHERE npi IN ('%s')", PANEL, paste(npis, collapse = "','")))
cat(sprintf("distinct name variants for those NPIs: %s\n",
            format(nrow(vars), big.mark = ",")))

# One searchable blob of every name string the registry ever held for an NPI.
blob <- vars %>%
  mutate(across(c(last_name, middle_name, first_name), ~ coalesce(amcb_name_key(.x), ""))) %>%
  group_by(npi) %>%
  summarise(all_names = paste(unique(c(last_name, middle_name, first_name)), collapse = " "),
            n_variants = n(), .groups = "drop")

# --- The component that the join DISCARDED ------------------------------------
dropped_for <- function(amcb_last, nppes_last, shared) {
  sh <- strsplit(shared, "|", fixed = TRUE)[[1]]
  all_t <- unique(c(amcb_surname_tokens(amcb_last), amcb_surname_tokens(nppes_last)))
  setdiff(all_t, sh)
}

res <- cen %>% left_join(blob, by = "npi")
dropped <- lapply(seq_len(nrow(res)), function(i)
  dropped_for(res$normalized_last_name[i], res$nppes_matched_last[i], res$shared_token[i]))

res$dropped_component <- vapply(dropped, function(d)
  if (!length(d)) NA_character_ else paste(d, collapse = "|"), character(1))

res$corroborated <- vapply(seq_along(dropped), function(i) {
  d <- dropped[[i]]
  if (!length(d)) return(NA)                       # nothing was dropped
  nm <- res$all_names[i]
  if (is.na(nm) || !nzchar(nm)) return(FALSE)
  any(vapply(d, function(t) grepl(t, nm, fixed = TRUE), logical(1)))
}, logical(1))

res <- res %>%
  mutate(corroboration = case_when(
    is.na(corroborated) ~ "nothing_dropped",
    corroborated        ~ "CORROBORATED",
    TRUE                ~ "not_corroborated"))

write_csv(res %>% select(review_order, risk_band, shared_token, shared_token_npi_count,
                         dropped_component, corroboration, n_variants,
                         amcb_name_original, normalized_last_name,
                         npi, nppes_matched_last, nppes_last_name, nppes_middle_name,
                         nppes_state, npi_tax_class, candidate_count),
          OUT, na = "")

cat(sprintf("\n============ class-5 corroboration: %s ============\n", OUT))
cat("\nDoes the dropped surname component appear in the NPI's own NPPES record?\n")
print(as.data.frame(count(res, corroboration, sort = TRUE)))
cat("\nby risk band:\n")
print(as.data.frame(res %>% count(risk_band, corroboration) %>%
                      tidyr::pivot_wider(names_from = corroboration, values_from = n,
                                         values_fill = 0)))
cat("\n---- highest-risk rows, with corroboration ----\n")
print(as.data.frame(res %>% arrange(desc(as.numeric(shared_token_npi_count))) %>%
  slice_head(n = 15) %>%
  transmute(ord = review_order, tok = shared_token,
            n_npi = shared_token_npi_count, dropped = dropped_component,
            corrob = corroboration, amcb = amcb_name_original,
            nppes_now = nppes_last_name, st = nppes_state)), right = FALSE)
