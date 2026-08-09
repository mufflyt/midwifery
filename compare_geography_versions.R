#!/usr/bin/env Rscript
# =============================================================================
# Frozen vs enhanced geography -- the frozen artifact is never modified
# =============================================================================
# The 1,624-address geocode is a completeness ENHANCEMENT. It is published as a
# separate version with its own manifest and SHA so the frozen artifact remains
# the reference point and any change is attributable.
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(digest); library(jsonlite)})

FRO_LINK <- "artifacts/amcb_npi_linkage_FROZEN.csv"
FRO_GEO  <- "artifacts/midwives_geography_FROZEN.csv"
ENH_GEO  <- "midwives_geography_enhanced.csv"
stopifnot(file.exists(FRO_GEO), file.exists(ENH_GEO))

link <- read_csv(FRO_LINK, show_col_types=FALSE) %>% select(certification_number, linkage_tier)
fro  <- read_csv(FRO_GEO, show_col_types=FALSE)
enh  <- read_csv(ENH_GEO, show_col_types=FALSE)

cat("=== VALIDATION GATE ===\n")
link_sha <- digest(file=FRO_LINK, algo="sha256")
cat(sprintf("frozen linkage SHA matches in enhanced run: %s\n",
            identical(link_sha, unique(enh$source_linkage_sha256)[1])))
stopifnot(identical(link_sha, unique(enh$source_linkage_sha256)[1]))

cmp <- link %>%
  left_join(fro %>% select(certification_number, ex_f=county_exact, be_f=county_best), by="certification_number") %>%
  left_join(enh %>% select(certification_number, ex_e=county_exact, be_e=county_best), by="certification_number")

leak <- cmp %>% filter(linkage_tier %in% c("quarantined","unmatched"), !is.na(be_e))
cat(sprintf("geography on quarantined/unmatched rows   : %s (must be 0)\n", nrow(leak)))
stopifnot(nrow(leak)==0)

cat("\n=== FROZEN vs ENHANCED, BY TIER ===\n")
tab <- cmp %>% filter(linkage_tier %in% c("primary_midwifery","sensitivity_nursing","sensitivity_fuzzy")) %>%
  group_by(linkage_tier) %>%
  summarise(n=n(),
            exact_frozen=sum(!is.na(ex_f)), exact_enh=sum(!is.na(ex_e)),
            best_frozen=sum(!is.na(be_f)),  best_enh=sum(!is.na(be_e)), .groups="drop") %>%
  mutate(exact_gain=exact_enh-exact_frozen,
         exact_pp=round(100*(exact_enh-exact_frozen)/n,1),
         best_gain=best_enh-best_frozen,
         best_pp=round(100*(best_enh-best_frozen)/n,1),
         pct_exact_frozen=round(100*exact_frozen/n,1), pct_exact_enh=round(100*exact_enh/n,1),
         pct_best_frozen=round(100*best_frozen/n,1),  pct_best_enh=round(100*best_enh/n,1))
print(as.data.frame(tab %>% select(linkage_tier, n, pct_exact_frozen, pct_exact_enh, exact_gain, exact_pp)))
cat("\n"); print(as.data.frame(tab %>% select(linkage_tier, pct_best_frozen, pct_best_enh, best_gain, best_pp)))

cat("\n=== NEW CONFLICTS / DISCORDANCES ===\n")
cat(sprintf("cross-state conflicts (enhanced): %s\n", sum(enh$geo_source=="invariant_failure", na.rm=TRUE)))
cat(sprintf("  frozen                        : %s\n", sum(fro$geo_source=="invariant_failure", na.rm=TRUE)))
cat(sprintf("still ungeocoded (no coordinate): %s rows\n",
            sum(is.na(enh$county_exact) & !is.na(enh$county_best))))

m <- list(version="geography_enhanced", based_on_frozen_linkage_sha256=link_sha,
          frozen_geography_sha256=digest(file=FRO_GEO, algo="sha256"),
          enhanced_geography_sha256=digest(file=ENH_GEO, algo="sha256"),
          generated_utc=format(Sys.time(), tz="UTC", usetz=TRUE),
          by_tier=tab,
          note="Completeness enhancement from geocoding 1,624 previously uncached addresses. Does NOT supersede the frozen geography artifact.")
write_json(m, "artifacts/geography_enhanced_manifest.json", auto_unbox=TRUE, pretty=TRUE)
cat("\nmanifest: artifacts/geography_enhanced_manifest.json\n")
