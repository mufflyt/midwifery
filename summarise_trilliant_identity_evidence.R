#!/usr/bin/env Rscript
# =============================================================================
# The numbers behind docs/TECHNICAL_APPENDIX_TRILLIANT_IDENTITY_EXPERIMENT.md
# =============================================================================
# experiment_trilliant_identity_linkage.R writes its outcome counts. The
# appendix also quotes breakdowns of WHY: how strongly graduation year separates
# likely matches from likely non-matches, which way a discordant year points,
# where a contradiction came from, and what the accepted recoveries are made of.
# Those were first computed in throwaway scripts; this makes every one of them
# reproducible from committed code, as one aggregate table.
#
#   Rscript summarise_trilliant_identity_evidence.R [--sha8 dbcc76f4]
#
# Inputs : artifacts/trilliant_identity_candidates_<sha8>.parquet   (person-level)
#          artifacts/trilliant_identity_decisions_<sha8>.csv        (person-level)
#          both written by experiment_trilliant_identity_linkage.R; default is
#          the newest pair on disk.
# Output : artifacts/trilliant_identity_evidence_<sha8>.csv         (aggregate, tracked)
#          columns section, population, level, n, denominator, pct, value.
#          `value` holds a ratio where one is the point (likelihood ratios);
#          otherwise NA. No row names a person or an NPI.
# =============================================================================
suppressPackageStartupMessages({
  library(duckplyr); library(dplyr); library(readr); library(tidyr); library(tibble)
})
# See experiment_trilliant_identity_linkage.R: duckplyr must not drive joins on
# ordinary data frames.
invisible(duckplyr::methods_restore())
source(file.path("R", "lib", "artifact_provenance.R"))   # write_with_provenance()

args <- commandArgs(trailingOnly = TRUE)
i <- match("--sha8", args)
SHA8 <- if (!is.na(i) && i < length(args)) args[[i + 1L]] else {
  hits <- Sys.glob(file.path("artifacts", "trilliant_identity_candidates_*.parquet"))
  if (!length(hits)) stop("no trilliant_identity_candidates_*.parquet; run experiment_trilliant_identity_linkage.R",
                          call. = FALSE)
  newest <- hits[which.max(file.mtime(hits))]
  sub("^trilliant_identity_candidates_([0-9a-f]{8})\\.parquet$", "\\1", basename(newest))
}
CAND <- file.path("artifacts", sprintf("trilliant_identity_candidates_%s.parquet", SHA8))
DEC <- file.path("artifacts", sprintf("trilliant_identity_decisions_%s.csv", SHA8))
OUT <- file.path("artifacts", sprintf("trilliant_identity_evidence_%s.csv", SHA8))
for (f in c(CAND, DEC)) if (!file.exists(f)) stop("missing ", f, call. = FALSE)

cand <- read_parquet_duckdb(CAND) |> collect()
dec <- read_csv(DEC, col_types = cols(.default = "c"), progress = FALSE)
inc <- cand |> filter(is_incumbent)
evidence_row <- function(section, population, level, n, denominator, value = NA_real_)
  tibble(section, population, level, n = as.integer(n), denominator = as.integer(denominator),
         pct = round(100 * n / denominator, 2), value = value)

# ---- A. graduation year as evidence: likely matches vs likely non-matches -------
# Likely matches: incumbents in the primary tier. Likely non-matches: every other
# candidate of a certificant who has an incumbent. Both limited to pairs with a
# known graduation year. The ratio is P(band | match) / P(band | non-match).
bands <- c("within_1", "within_3", "within_10", "beyond_10")
m <- inc |> filter(linkage_tier == "primary_midwifery", grad_year_band %in% bands)
u <- cand |> filter(!is_incumbent, !is.na(incumbent_npi), grad_year_band %in% bands)
lr <- bind_rows(lapply(bands, function(b) {
  pm <- mean(m$grad_year_band == b); pu <- mean(u$grad_year_band == b)
  bind_rows(evidence_row("A_grad_year_likelihood", "likely matches (primary-tier incumbents)", b, sum(m$grad_year_band == b), nrow(m)),
            evidence_row("A_grad_year_likelihood", "likely non-matches (other candidates)", b, sum(u$grad_year_band == b), nrow(u)),
            evidence_row("A_grad_year_likelihood", "likelihood ratio", b, NA, NA, value = round(pm / pu, 3)))
}))

# ---- B. which way a discordant graduation year points ------------------------
direction_rows <- function(d, population) {
  x <- d |> filter(grad_year_band == "beyond_10")
  bind_rows(evidence_row("B_grad_year_direction", population, "graduated >10 years before certifying", sum(x$grad_year_diff < -10), nrow(x)),
            evidence_row("B_grad_year_direction", population, "graduated >10 years after certifying", sum(x$grad_year_diff > 10), nrow(x)),
            evidence_row("B_grad_year_direction", population, "graduated >20 years after certifying", sum(x$grad_year_diff > 20), nrow(x)),
            evidence_row("B_grad_year_direction", population, "graduated >30 years after certifying", sum(x$grad_year_diff > 30), nrow(x)))
}
dirs <- bind_rows(direction_rows(filter(inc, stratum == "1a_existing_high_confidence"), "1a high-confidence incumbents"),
                  direction_rows(filter(inc, linkage_tier == "sensitivity_nursing"), "nursing-tier incumbents"),
                  direction_rows(filter(inc, linkage_tier == "sensitivity_fuzzy"), "fuzzy-tier incumbents"))

# ---- C. incumbents the directory does not carry, by AMCB status -------------
absent <- dec |> filter(variant == "full", startsWith(stratum, "1")) |>
  group_by(stratum) |> mutate(denominator = n()) |> ungroup() |>
  filter(incumbent_found == "FALSE") |>
  count(stratum, status, denominator) |>
  transmute(section = "C_incumbent_absent_by_status", population = stratum, level = status, n, denominator,
            pct = round(100 * n / denominator, 2), value = NA_real_)

# ---- D. where each contradiction of an incumbent came from ------------------
src <- inc |> filter(contradiction_count > 0L) |>
  mutate(population = paste(stratum, linkage_tier, paste0("class ", name_evidence_class), sep = " / ")) |>
  group_by(population) |> mutate(denominator = n()) |> ungroup() |>
  count(population, level = contra_source, denominator) |>
  transmute(section = "D_contradiction_source", population, level, n, denominator,
            pct = round(100 * n / denominator, 2), value = NA_real_)
same_name <- inc |> filter(contra_given, name_evidence_class == "3")
same_name_row <- evidence_row("D_contradiction_source", "class-3 incumbents with a given-name conflict",
                     "directory carries the same name as NPPES", sum(same_name$trl_name_equals_nppes %in% TRUE),
                     nrow(same_name))

# ---- E. what the accepted recoveries are made of (full variant) -------------
accept_composition <- function(st) {
  a <- dec |> filter(variant == "full", stratum == st, decision == "ACCEPT") |>
    select(amcb_id, best_npi) |>
    inner_join(cand, by = c("amcb_id", best_npi = "npi"), relationship = "one-to-one")
  enum_year <- suppressWarnings(as.integer(substr(a$nppes_enumeration_date, 7, 10)))
  recent <- !a$nppes_found | (!is.na(enum_year) & enum_year >= 2025L)
  bind_rows(
    evidence_row("E_accept_composition", st, "ACCEPT total", nrow(a), nrow(a)),
    evidence_row("E_accept_composition", st, "surname and given name exact", sum(a$surname_evidence == "exact" & a$given_evidence == "exact"), nrow(a)),
    evidence_row("E_accept_composition", st, "graduation within 1 year of certification", sum(a$grad_year_band == "within_1"), nrow(a)),
    evidence_row("E_accept_composition", st, "NPI not in the NPPES bulk file", sum(!a$nppes_found), nrow(a)),
    evidence_row("E_accept_composition", st, "NPI enumerated 2025 or later", sum(a$nppes_found & enum_year >= 2025L, na.rm = TRUE), nrow(a)),
    evidence_row("E_accept_composition", st, "certified 2024 or later", sum(a$cert_year >= 2024L, na.rm = TRUE), nrow(a)),
    evidence_row("E_accept_composition", st, "profession mixed (midwifery plus a physician or other source)", sum(a$profession_mixed), nrow(a)),
    # The two explanations overlap, so their union is counted, and so is what
    # neither explains: an older NPI the freeze's name panel should have held.
    evidence_row("E_accept_composition", st, "recent NPI or mixed profession (union)", sum(recent | a$profession_mixed), nrow(a)),
    evidence_row("E_accept_composition", st, "neither: older NPI, midwifery specialty", sum(!recent & !a$profession_mixed & a$specialty_class %in% "midwife"), nrow(a)),
    evidence_row("E_accept_composition", st, "neither: older NPI, nursing specialty", sum(!recent & !a$profession_mixed & a$specialty_class %in% "nursing"), nrow(a)),
    evidence_row("E_accept_composition", st, "neither: older NPI, other or no specialty", sum(!recent & !a$profession_mixed & !(a$specialty_class %in% c("midwife", "nursing"))), nrow(a)))
}
comp <- bind_rows(accept_composition("2_ambiguous"), accept_composition("3_unmatched"))

# ---- F. ambiguous certificants: full against identity_only ------------------
cross <- dec |> filter(stratum == "2_ambiguous") |>
  select(amcb_id, variant, decision) |>
  pivot_wider(names_from = variant, values_from = decision) |>
  count(full, identity_only) |>
  transmute(section = "F_ambiguous_full_vs_identity_only", population = "2_ambiguous",
            level = paste0("full ", full, " / identity_only ", identity_only), n,
            denominator = sum(n), pct = round(100 * n / sum(n), 2), value = NA_real_)

out <- bind_rows(lr, dirs, absent, src, same_name_row, comp, cross) |>
  mutate(frozen_sha8 = SHA8)
if (anyNA(out$level)) stop("a row has no level; refusing to write an unlabelled count", call. = FALSE)
write_with_provenance(out, OUT, na = "")
cat("wrote", OUT, "(", nrow(out), "rows )\n")
