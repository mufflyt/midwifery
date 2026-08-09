#!/usr/bin/env Rscript
# =============================================================================
# Gate the freeze: verify the three linkage arms before anything is frozen
# =============================================================================
# Order matters -- each check assumes the previous one passed.
#   1 artifact separation (distinct files AND distinct hashes)
#   2 tier accounting (five tiers sum to the roster; nursing/fuzzy not primary)
#   3 transition audit vs the previous midwifery-only frozen linkage
#   4 geography completeness BY TIER, never pooled
#   5 identity changes enumerated for audit
# Freezing happens only from an explicitly named specification, never from
# "whichever arm ran last".
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr); library(digest)})

ART <- "artifacts"
arms <- list.files(ART, pattern = "^amcb_npi_linkage_panel-.*\\.csv$", full.names = TRUE)
stopifnot(length(arms) >= 2)

cat("=========== 1. ARTIFACT SEPARATION ===========\n")
info <- tibble(file = basename(arms),
               sha256 = vapply(arms, function(p) digest(file = p, algo = "sha256"),
                               character(1), USE.NAMES = FALSE),
               rows = vapply(arms, function(p) nrow(read_csv(p, show_col_types = FALSE)),
                             numeric(1), USE.NAMES = FALSE))
print(as.data.frame(info %>% mutate(sha256 = substr(sha256, 1, 16))))
cat(sprintf("distinct filenames: %s | distinct hashes: %s\n",
            n_distinct(info$file), n_distinct(info$sha256)))
stopifnot(n_distinct(info$file) == length(arms),
          n_distinct(info$sha256) == length(arms))
stopifnot(all(info$rows == 22309))
cat("PASS: every arm wrote its own artifact, all 22,309 rows\n")

PRIMARY_SPEC <- Sys.getenv("PRIMARY_SPEC",
  file.path(ART, "amcb_npi_linkage_panel-midwifery-plus-nursing_years-2007-2025.csv"))
stopifnot(file.exists(PRIMARY_SPEC))
cat(sprintf("\nselected specification: %s\n", basename(PRIMARY_SPEC)))
sel <- read_csv(PRIMARY_SPEC, show_col_types = FALSE) %>% mutate(npi = as.character(npi))

cat("\n=========== 2. TIER ACCOUNTING ===========\n")
tiers <- sel %>% count(linkage_tier) %>% mutate(pct = round(100 * n / nrow(sel), 1))
print(as.data.frame(tiers))
stopifnot(sum(tiers$n) == 22309)
prim <- sum(sel$linkage_tier == "primary_midwifery")
nurs <- sum(sel$linkage_tier == "sensitivity_nursing")
fuzz <- sum(sel$linkage_tier == "sensitivity_fuzzy")
# Primary must be midwifery-taxonomy, exact-name evidence only.
stopifnot(!any(sel$linkage_tier == "primary_midwifery" &
                 sel$npi_tax_class == "nursing", na.rm = TRUE),
          !any(sel$linkage_tier == "primary_midwifery" &
                 sel$npi_match_method == "fuzzy_last_exact_first", na.rm = TRUE))
cat(sprintf("primary_midwifery          : %s (%.1f%%)\n", format(prim, big.mark=","), 100*prim/22309))
cat(sprintf("+ sensitivity_nursing      : %s (%+.1f pp -> %.1f%%)\n", format(nurs, big.mark=","),
            100*nurs/22309, 100*(prim+nurs)/22309))
cat(sprintf("+ sensitivity_fuzzy        : %s (%+.1f pp -> %.1f%%)\n", format(fuzz, big.mark=","),
            100*fuzz/22309, 100*(prim+nurs+fuzz)/22309))
cat(sprintf("quarantined                : %s (%.1f%%), %s with candidates\n",
            format(sum(sel$linkage_tier=="quarantined"), big.mark=","),
            100*mean(sel$linkage_tier=="quarantined"),
            format(sum(sel$linkage_tier=="quarantined" & sel$has_candidate), big.mark=",")))
cat(sprintf("unmatched                  : %s (%.1f%%), %s WITH candidates\n",
            format(sum(sel$linkage_tier=="unmatched"), big.mark=","),
            100*mean(sel$linkage_tier=="unmatched"),
            format(sum(sel$linkage_tier=="unmatched" & sel$has_candidate), big.mark=",")))
cat("PASS: tiers mutually exclusive, sum to roster, primary uncontaminated\n")

cat("\n=========== 3. TRANSITION vs PREVIOUS FROZEN ===========\n")
prev <- read_csv(file.path(ART, "amcb_npi_linkage_FROZEN.csv"), show_col_types = FALSE) %>%
  mutate(npi = as.character(npi))
tier_of <- function(d) if ("linkage_tier" %in% names(d)) d$linkage_tier else
  case_when(!is.na(d$npi) & d$match_status == "sensitivity_fuzzy" ~ "sensitivity_fuzzy",
            !is.na(d$npi) ~ "primary_midwifery",
            grepl("^ambiguous", d$match_status) ~ "quarantined", TRUE ~ "unmatched")
cmp <- tibble(id = prev$certification_number, npi_a = prev$npi, npi_b = sel$npi,
              tier_a = tier_of(prev), tier_b = tier_of(sel)) %>%
  mutate(transition = case_when(
    !is.na(npi_a) & !is.na(npi_b) & npi_a == npi_b & tier_a == tier_b ~ "same NPI, same tier",
    !is.na(npi_a) & !is.na(npi_b) & npi_a == npi_b                    ~ "same NPI, different tier",
    !is.na(npi_a) & !is.na(npi_b)                                     ~ "different NPI",
    !is.na(npi_a) & is.na(npi_b)                                      ~ paste("matched ->", tier_b),
    is.na(npi_a) & !is.na(npi_b)                                      ~ paste(tier_a, "-> matched"),
    TRUE                                                              ~ paste(tier_a, "->", tier_b)))
print(as.data.frame(count(cmp, transition, sort = TRUE)))
stopifnot(nrow(cmp) == 22309)
cat(sprintf("total %s (must be 22,309)\n", format(nrow(cmp), big.mark = ",")))
diff_npi <- filter(cmp, transition == "different NPI")
cat(sprintf("NPIs changing identity: %s | rows changing tier only: %s\n",
            format(nrow(diff_npi), big.mark = ","),
            format(sum(cmp$transition == "same NPI, different tier"), big.mark = ",")))
write_csv(diff_npi, file.path(ART, "linkage_identity_changes.csv"), na = "")

cat("\n=========== 4. GEOGRAPHY BY EVIDENCE TIER ===========\n")
geo_f <- "midwives_geography_guarded.csv"
if (file.exists(geo_f)) {
  geo <- read_csv(geo_f, show_col_types = FALSE)
  # A geography artifact built from a DIFFERENT linkage says nothing about this
  # one's tiers. Refuse the comparison rather than report a stale percentage.
  sel_sha <- digest(file = PRIMARY_SPEC, algo = "sha256")
  geo_sha <- if ("source_linkage_sha256" %in% names(geo))
    unique(geo$source_linkage_sha256)[1] else NA_character_
  if (is.na(geo_sha) || !identical(geo_sha, sel_sha)) {
    cat(sprintf(paste0("REFUSED: %s was built from linkage %s\n",
                       "         but the specification under test is %s.\n",
                       "         Rerun Stage 3 against the selected spec; a stale\n",
                       "         geography percentage is not evidence about these tiers.\n"),
                geo_f, substr(coalesce(geo_sha, "<none recorded>"), 1, 16),
                substr(sel_sha, 1, 16)))
    geo <- NULL
  }
}
if (file.exists(geo_f) && !is.null(geo)) {
  g <- sel %>% left_join(geo %>% select(certification_number, county_exact, county_best),
                         by = "certification_number")
  by_tier <- g %>% filter(!is.na(npi)) %>% group_by(linkage_tier) %>%
    summarise(n = n(),
              pct_city_state = round(100 * mean(!is.na(nppes_state)), 1),
              pct_county_exact = round(100 * mean(!is.na(county_exact)), 1),
              pct_county_best = round(100 * mean(!is.na(county_best)), 1), .groups = "drop")
  print(as.data.frame(by_tier))
  cat("Geography is reported BY TIER; a pooled percentage would blend evidence\n")
  cat("standards and is deliberately not produced here.\n")
} else {
  cat(sprintf("SKIP: %s absent -- rerun Stage 3 against the selected spec first\n", geo_f))
}

cat("\n=========== 5. READY TO FREEZE? ===========\n")
cat(sprintf("identity changes needing audit: %s -> %s\n", nrow(diff_npi),
            file.path(ART, "linkage_identity_changes.csv")))
cat("Freeze only after those are explained, as with the earlier 81-row audit.\n")
