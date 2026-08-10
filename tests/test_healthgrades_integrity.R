#!/usr/bin/env Rscript
# =============================================================================
# Adversarial integrity tests for the Healthgrades scrape
# =============================================================================
# Written on the assumption that the numbers are WRONG until they survive a
# test designed to break them. Every check below corresponds to a defect that
# was actually found in this pipeline on 2026-08-09, not a hypothetical one.
#
# Three axes:
#   1. NUMERICAL INTERNAL CONSISTENCY -- do the parts sum to the whole, and do
#      numerator and denominator describe the same population?
#   2. STATISTIC / CODE CORRECTNESS -- does the code compute the quantity its
#      name claims? (Counting rows where the claim is about people is the
#      canonical way to be precisely wrong.)
#   3. PROVENANCE -- can each reported number be regenerated from a file on
#      disk? A figure no longer reproducible must not be quoted.
#
# Exits non-zero on failure. Run: Rscript tests/test_healthgrades_integrity.R
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr)})

fails <- 0L
ok   <- function(m) cat(sprintf("  ok   %s\n", m))
bad  <- function(m) { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
chk  <- function(cond, m) if (isTRUE(cond)) ok(m) else bad(m)

LINK   <- "artifacts/amcb_npi_linkage_FROZEN.csv"
HITS   <- "healthgrades_midwives.csv"
ATTRS  <- "healthgrades_profile_attrs.csv"

if (!file.exists(LINK) || !file.exists(HITS)) {
  cat("SKIP: inputs absent\n"); quit(status = 0)
}

# The crawl rewrites HITS wholesale at each checkpoint. Reading it live races
# that write and can yield a truncated parse, which would look like data loss.
snap <- tempfile(fileext = ".csv"); invisible(file.copy(HITS, snap))
x    <- read_csv(snap, show_col_types = FALSE, progress = FALSE)
link <- read_csv(LINK, show_col_types = FALSE, progress = FALSE)

COHORT <- link %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  pull(certification_number) %>% unique()

# =============================================================================
cat("\n1. NUMERICAL INTERNAL CONSISTENCY\n")
# =============================================================================

# The crawl targets the FULL roster; the cohort is a 53% subset. Any coverage
# statistic that draws its numerator from the crawl and its denominator from
# the cohort mixes two populations and inflates the result -- it can exceed
# 100%. This is the defect that shipped in sweep_healthgrades_enrichment.R.
n_roster <- n_distinct(link$certification_number)
chk(length(COHORT) < n_roster,
    sprintf("cohort (%s) is a strict subset of the crawl target (%s) -- coverage
         must be computed on ONE of them, never across both",
            format(length(COHORT), big.mark = ","),
            format(n_roster, big.mark = ",")))

cohort_hit <- x %>% filter(hg_status == "ok", certification_number %in% COHORT) %>%
  pull(certification_number) %>% n_distinct()
chk(cohort_hit <= length(COHORT),
    sprintf("cohort members with a profile (%s) cannot exceed the cohort (%s)",
            format(cohort_hit, big.mark = ","), format(length(COHORT), big.mark = ",")))

# Status is a partition: every searched certificant lands in exactly one.
per_cert <- x %>% distinct(certification_number, hg_status) %>% count(certification_number)
chk(all(per_cert$n == 1),
    sprintf("each certificant holds exactly one status (%d hold more)",
            sum(per_cert$n > 1)))

if (file.exists("docs/table1_midwives.md")) {
  N <- length(COHORT)
  groups <- list(
    Certification = c(11794, 119), Sex = c(11829, 63, 13, 8),
    Rurality = c(10696, 816, 347, 54),
    YearsSinceEnum = c(2223, 2729, 2307, 2162, 2484, 8),
    YearsObserved = c(3095, 2746, 2173, 3899),
    ACOG = c(935, 971, 792, 1772, 1155, 1253, 662, 2112, 1015, 536, 670, 2, 38))
  for (g in names(groups)) {
    chk(sum(groups[[g]]) == N,
        sprintf("Table 1 %s sums to the cohort (%s vs %s)", g,
                format(sum(groups[[g]]), big.mark = ","), format(N, big.mark = ",")))
  }
}

# =============================================================================
cat("\n2. STATISTIC / CODE CORRECTNESS\n")
# =============================================================================

# A midwife occupies one ROW PER PRACTICE SITE. So counting rows per URL to
# detect "one profile claimed by several people" flags every multi-site
# midwife: 757 flagged where 131 were real. The unit of the claim is the
# person, so the unit of the count must be the person.
rowwise  <- x %>% filter(!is.na(hg_url)) %>% count(hg_url) %>% filter(n > 1) %>% nrow()
certwise <- x %>% filter(!is.na(hg_url)) %>% distinct(certification_number, hg_url) %>%
  count(hg_url) %>% filter(n > 1) %>% nrow()
chk(certwise <= rowwise,
    sprintf("row-wise duplicate count (%d) overstates person-wise (%d) by %d --
         any ambiguity check MUST distinct() on certification_number first",
            rowwise, certwise, rowwise - certwise))

# A rejected candidate KEEPS the hg_url it was rejected for. Selecting on
# !is.na(hg_url) therefore silently readmits rejected matches. Selection must
# be on hg_status == "ok".
url_any <- n_distinct(x$hg_url[!is.na(x$hg_url)])
url_ok  <- n_distinct(x$hg_url[x$hg_status == "ok"])
chk(url_ok < url_any,
    sprintf("non-ok rows carry URLs (%d urls on any row vs %d on ok rows) --
         !is.na(hg_url) is NOT a substitute for hg_status == 'ok'",
            url_any, url_ok))

# The real ambiguity, measured correctly. These profiles cannot be attributed
# to any one certificant and their attributes must not reach Table 1.
amb <- x %>% filter(hg_status == "ok", !is.na(hg_url)) %>%
  distinct(certification_number, hg_url) %>% add_count(hg_url) %>% filter(n > 1)
amb_cohort <- sum(unique(amb$certification_number) %in% COHORT)
cat(sprintf("  note %d shared profile(s), %d links, %d cohort members -- must be
         dropped before attributing attributes\n",
            n_distinct(amb$hg_url), nrow(amb), amb_cohort))

if (file.exists(ATTRS)) {
  a <- read_csv(ATTRS, show_col_types = FALSE, progress = FALSE)
  chk(!anyDuplicated(a$hg_url), "one enriched row per profile URL")
  # Joining attributes on a shared URL would fan out one person's demographics
  # onto several certificants -- fabricated data, not missing data.
  # Every extra row beyond one-per-certificant must be explained by a KNOWN
  # shared URL. An earlier version of this check read
  #   nrow(fan) == n_distinct(...) || amb_cohort > 0
  # which passes automatically whenever any ambiguity exists -- it could never
  # fail, and a test that cannot fail is worse than no test, because it reads
  # as coverage. The excess is now accounted for exactly.
  fan <- x %>% filter(hg_status == "ok") %>% distinct(certification_number, hg_url) %>%
    inner_join(a, by = "hg_url")
  excess <- nrow(fan) - n_distinct(fan$certification_number)
  explained <- fan %>% filter(hg_url %in% amb$hg_url) %>%
    { nrow(.) - n_distinct(.$certification_number) }
  chk(excess == explained,
      sprintf("every fanned-out join row traces to a known shared URL (excess %d, explained %d)",
              excess, explained))

  # After dropping shared URLs the join must be strictly one row per person.
  clean <- fan %>% filter(!hg_url %in% amb$hg_url)
  chk(nrow(clean) == n_distinct(clean$certification_number),
      sprintf("with shared URLs dropped, exactly one attribute row per certificant (%d rows, %d people)",
              nrow(clean), n_distinct(clean$certification_number)))
}

# =============================================================================
cat("\n3. PROVENANCE\n")
# =============================================================================

# The merged 5,963 came from a run over midwives_unmatched.csv -- selected for
# having FAILED NPI linkage, so they are harder to find on any site. Pooling
# them with fresh searches biases the hit rate downward. The pooled rate is
# not an estimate of anything.
prior_f <- "prior_run_checkpoint_20260809T191817.rds"
if (file.exists(prior_f)) {
  prior <- names(readRDS(prior_f))
  fr <- x %>% filter(!certification_number %in% prior)
  ol <- x %>% filter(certification_number %in% prior)
  rate <- function(d) {
    n <- n_distinct(d$certification_number)
    if (!n) return(NA_real_)
    100 * n_distinct(d$certification_number[d$hg_status == "ok"]) / n
  }
  r_fresh <- rate(fr); r_old <- rate(ol)
  cat(sprintf("  note fresh %.1f%% vs merged-in %.1f%% -- report the fresh rate\n",
              r_fresh, r_old))
  chk(!is.na(r_fresh) && !is.na(r_old) && r_fresh > r_old,
      "the merged subset really is harder to match, so pooling biases downward")
} else {
  bad(sprintf("%s absent -- the fresh-only hit rate cannot be regenerated and
         must not be quoted", prior_f))
}

chk(all(unique(x$certification_number) %in% link$certification_number),
    "every scraped certification_number traces back to the frozen linkage file")

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
