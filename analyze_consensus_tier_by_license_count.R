#!/usr/bin/env Rscript
# =============================================================================
# Does holding licences in several states predict cross-source disagreement?
# =============================================================================
# Every other analysis in the state-source audit can observe that sources
# disagree about a midwife's practice state, and none of them can say whether
# that is a data defect or a midwife who genuinely works in two places. The
# Open Payments Covered Recipient Profile Supplement carries
# Covered_Recipient_Profile_License_State_Code_1..5 -- which states CMS's own
# reporting says a provider is LICENSED in -- and that is independent of every
# practice-location source being compared. Crossing it against each midwife's
# consensus tier tests the ambiguity directly.
#
# WHY THIS SCRIPT EXISTS. The result was published in the 2026-11-04 vignette
# and its figure could not be redrawn: the per-NPI consensus tier was computed
# inside compare_all_sources_mysteryroster.R and discarded, and the licence
# extract was never committed. Both are now tracked artifacts, so this is a
# rebuild from data rather than a restatement of a published number.
#
# THIS IS AN ASSOCIATION, NOT AN ADJUDICATION. It cannot show that any one
# disagreement is genuine multi-state practice rather than a stale record; it
# shows that disagreement concentrates where multi-state licensure is present.
#
# Inputs : artifacts/mrost_consensus_tier_by_npi.csv
#          artifacts/cohort_midwives_open_payments_profile_supplement.csv
# Output : artifacts/consensus_tier_by_license_count.csv
# =============================================================================
suppressPackageStartupMessages({ library(dplyr); library(readr); library(tidyr) })
source(file.path("R", "lib", "artifact_provenance.R"))

TIERS <- "artifacts/mrost_consensus_tier_by_npi.csv"
LIC   <- "artifacts/cohort_midwives_open_payments_profile_supplement.csv"
OUT   <- "artifacts/consensus_tier_by_license_count.csv"

for (f in c(TIERS, LIC))
  if (!file.exists(f)) stop(sprintf("missing input: %s", f), call. = FALSE)

tiers <- read_csv(TIERS, show_col_types = FALSE, progress = FALSE) %>%
  transmute(npi = trimws(as.character(npi)), tier)
lic <- read_csv(LIC, show_col_types = FALSE, progress = FALSE) %>%
  transmute(npi = trimws(as.character(npi)), n_license_states) %>%
  filter(!is.na(n_license_states), n_license_states >= 1)

# The supplement is one row per NPI, and its producer says so after checking.
# ASSERTED rather than forced by keeping the first row: if CMS ever ships two
# profile rows for one provider, silently keeping whichever sorted first would
# pick a licence count at random and nothing downstream would show it.
dup <- lic %>% count(npi) %>% filter(n > 1)
if (nrow(dup))
  stop(sprintf(paste0("%s is not one row per NPI (%d duplicated). Decide how to ",
                      "combine their licence counts before using it here."),
               LIC, nrow(dup)), call. = FALSE)

j <- inner_join(tiers, lic, by = "npi") %>%
  mutate(lic_band = ifelse(n_license_states >= 2, "2+ licence states", "1 licence state"))

cat(sprintf("tiers %s | licence rows %s | joined %s midwives\n",
            format(nrow(tiers), big.mark = ","), format(nrow(lic), big.mark = ","),
            format(nrow(j), big.mark = ",")))

out <- j %>%
  count(lic_band, tier, name = "n") %>%
  group_by(lic_band) %>%
  mutate(n_in_band = sum(n), pct = 100 * n / n_in_band) %>%
  ungroup() %>%
  arrange(lic_band, tier)

tab <- table(j$lic_band, j$tier)
# chisq.test() warns, correctly, when any expected cell is below 5; a warning
# here means the test is not trustworthy and the p-value should not be
# printed as though it were, so it is surfaced rather than suppressed.
cs <- suppressWarnings(chisq.test(tab))
small <- sum(cs$expected < 5)
out$chisq        <- unname(cs$statistic)
out$chisq_df     <- unname(cs$parameter)
out$chisq_p      <- cs$p.value
# chisq_p UNDERFLOWS TO ZERO once the statistic passes about 1,400 on 2 df: the
# true value is smaller than the smallest positive double, so the column reads
# 0, which is not a p-value. log10 p is carried alongside so the magnitude
# survives the floor, and the prose must quote the bound, never the literal 0.
out$chisq_log10_p <- pchisq(cs$statistic, cs$parameter, lower.tail = FALSE,
                            log.p = TRUE) / log(10)
out$chisq_n      <- sum(tab)
out$expected_cells_under_5 <- small

print(as.data.frame(out), row.names = FALSE, digits = 4)
cat(sprintf("\nchi-square(%d, n=%s) = %.1f, %s%s\n",
            cs$parameter, format(sum(tab), big.mark = ","), cs$statistic,
            if (cs$p.value > 0) sprintf("p = %.3g", cs$p.value)
            else sprintf("log10(p) = %.1f (p underflows double)", out$chisq_log10_p[1]),
            if (small) sprintf("  [WARNING: %d expected cell(s) < 5]", small) else ""))

sp <- out %>% filter(tier == "split") %>% select(lic_band, pct)
if (nrow(sp) == 2)
  cat(sprintf("split rate: %s %.1f%% vs %s %.1f%%  (ratio %.1fx)\n",
              sp$lic_band[1], sp$pct[1], sp$lic_band[2], sp$pct[2],
              max(sp$pct) / max(min(sp$pct), 1e-9)))

stopifnot(nrow(out) >= 4, all(abs(tapply(out$pct, out$lic_band, sum) - 100) < 1e-6))
write_with_provenance(out, OUT, inputs = c(TIERS, LIC), na = "")
cat(sprintf("\nwrote %s\n", OUT))
