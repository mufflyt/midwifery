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

# Gitignored row-level inputs; a fresh checkout or worktree cannot hold them.
# MIDWIFERY_TEST_DATA_DIR supplies them explicitly. Unset, these stay
# repo-relative and the SKIP below behaves exactly as before.
source(file.path("tests", "helper-external-data.R"))
LINK   <- mw_data_path("artifacts/amcb_npi_linkage_FROZEN.csv")
HITS   <- mw_data_path("healthgrades_midwives.csv")
ATTRS  <- mw_data_path("healthgrades_profile_attrs.csv")
invisible(mw_data_report(c("artifacts/amcb_npi_linkage_FROZEN.csv",
                           "healthgrades_midwives.csv",
                           "healthgrades_profile_attrs.csv")))

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

# Table 1 group sums, READ FROM THE ARTIFACT. These were hardcoded constants
# typed into this test, so they summed to the cohort no matter what the table
# actually contained -- and they still named YearsSinceEnum, YearsObserved and
# the ACOG military/territory row after those blocks were removed from Table 1.
# A test that checks its own arithmetic is not checking the table.
#
# Registry-derived categories must sum to the cohort. Healthgrades-derived ones
# must not, and are excluded by name rather than by assuming which is which.
if (file.exists(mw_data_path("artifacts/table1_midwives.csv"))) {
  t1 <- read_csv(mw_data_path("artifacts/table1_midwives.csv"), show_col_types = FALSE, progress = FALSE)
  N  <- length(COHORT)
  hg_cats <- c("Language (Healthgrades floor)", "Accepts new patients",
               "Offers telehealth", "Cohort")
  # ACOG is legitimately SHORT. The military/territory row was removed from the
  # table body on request, so that block covers N minus those addresses. The
  # shortfall is read from the header note rather than hardcoded, so the test
  # fails if the note and the block ever disagree -- which is the actual risk
  # once a fact lives in prose instead of a row.
  # TWO DRIFTS FIXED 2026-08-16, and the data was innocent of both.
  #
  # 1. The pattern was the literal "ACOG district percentages exclude". The note
  #    now reads "...percentages LIKEWISE exclude 38 midwives". One inserted
  #    word made grep() return NA, acog_excl NA, and the comparison NA -- so
  #    the assertion had stopped checking anything while still being red.
  #    Anchoring on "ACOG district" plus "exclude" survives that kind of edit.
  #
  # 2. The expectation was N - acog_excl. That encoded an older Table 1 in
  #    which the excluded midwives were dropped from the block. They are now
  #    carried as their own row -- "Overseas-military or US-territory address
  #    (no ACOG district) | 38" -- precisely so the block still sums to the
  #    cohort, which the note also states. So the block sums to N, and 11,882
  #    was the wrong target.
  #
  # Both facts are still checked, just the right way round: the note's number
  # must match the row that carries it, and every block must sum to N.
  t1md <- readLines("docs/table1_midwives.md", warn = FALSE)
  note <- grep("ACOG district.*exclude", t1md, value = TRUE)[1]
  chk(!is.na(note) && nzchar(note),
      "Table 1 note about ACOG-district exclusions is still present")
  acog_excl <- suppressWarnings(as.integer(gsub(",", "",
    sub(".*exclude ([0-9,]+) midwi.*", "\\1", note))))
  chk(!is.na(acog_excl),
      sprintf("the excluded count parses out of the note [%s]", acog_excl))

  reg <- t1 %>% filter(!category %in% hg_cats, !is.na(n))

  # PROSE AGAINST DATA: the number the note claims is excluded must equal the
  # row that carries those people. This is the check the old grep was reaching
  # for, and the one that actually catches the note and the block disagreeing.
  excl_row <- reg$n[reg$category == "ACOG district" &
                      grepl("no ACOG district|Overseas", reg$characteristic)]
  chk(length(excl_row) == 1L && !is.na(acog_excl) && excl_row == acog_excl,
      sprintf("the note's %s excluded matches the row carrying them (%s)",
              format(acog_excl, big.mark = ","),
              if (length(excl_row) == 1L) format(excl_row, big.mark = ",") else "no such row"))

  for (g in unique(reg$category)) {
    tot <- sum(reg$n[reg$category == g])
    chk(tot == N,
        sprintf("Table 1 '%s' sums to the cohort (%s vs %s)", g,
                format(tot, big.mark = ","), format(N, big.mark = ",")))
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

# Collisions must be detected across the FULL roster and only THEN intersected
# with the cohort. Filtering to the cohort first hides any profile shared
# between a cohort member and a non-cohort certificant: the URL looks unshared
# and that midwife is wrongly treated as attributable. Live in
# build_table1_midwives.R for one run, where it reported 2 exclusions
# instead of 14 -- an error that removes a safeguard rather than adding noise.
detect_then_scope <- x %>% filter(hg_status == "ok", !is.na(hg_url)) %>%
  distinct(certification_number, hg_url) %>% add_count(hg_url) %>% filter(n > 1) %>%
  pull(certification_number) %>% unique() %>% intersect(COHORT) %>% length()
scope_then_detect <- x %>%
  filter(hg_status == "ok", !is.na(hg_url), certification_number %in% COHORT) %>%
  distinct(certification_number, hg_url) %>% add_count(hg_url) %>% filter(n > 1) %>%
  pull(certification_number) %>% unique() %>% length()
chk(detect_then_scope >= scope_then_detect,
    sprintf("collision detection precedes cohort scoping (%d found vs %d if scoped first)",
            detect_then_scope, scope_then_detect))

if (file.exists(mw_data_path("docs/table1_midwives.md"))) {
  t1txt <- readLines("docs/table1_midwives.md")
  # The count used to sit in a "Excluded: profile shared with another
  # certificant" row. That block was removed from the table body on request and
  # the number now lives in the header note, which is where a reader meets the
  # denominator. Parsed from there so the check follows the figure instead of
  # being dropped with the row -- the row moving is not the same as the
  # exclusion going unverified.
  note <- grep("share a Healthgrades profile", t1txt, value = TRUE)[1]
  claimed <- suppressWarnings(as.integer(gsub(",", "",
    sub(".*denominator of \\*\\*[0-9,]+\\*\\*: ([0-9,]+) midwi.*", "\\1", note))))

  # VINTAGE, NOT TOLERANCE. The crawl is still running, so the number the live
  # data implies rises every few minutes and Table 1 is stale by construction
  # the moment it is written. Asserting against live data would make this test
  # permanently red, which teaches everyone to ignore a red suite -- the
  # expensive failure mode.
  #
  # So the STRICT assertion is internal consistency: Table 1 must agree with
  # the vintage stamp recorded when it was built. Drift against the live crawl
  # is reported as drift. If the stamp is missing, fall back to the strict
  # live comparison rather than skipping the check.
  prov_f <- mw_data_path("artifacts/table1_provenance.csv")
  if (file.exists(prov_f)) {
    prov <- read_csv(prov_f, show_col_types = FALSE, progress = FALSE)
    chk(!is.na(claimed) && claimed == prov$hg_ambiguous_cohort[1],
        sprintf("Table 1 agrees with its own vintage stamp (%s vs %s)",
                claimed, prov$hg_ambiguous_cohort[1]))
    if (!is.na(claimed) && claimed != detect_then_scope) {
      cat(sprintf(paste0("  note Table 1 is STALE: built at %s over %s certificants ",
                         "(%d excluded); the crawl has since reached %s (%d). ",
                         "Rebuild when the crawl finishes.\n"),
                  prov$built_at[1], format(prov$scrape_certificants[1], big.mark = ","),
                  claimed, format(n_distinct(x$certification_number), big.mark = ","),
                  detect_then_scope))
    }
  } else {
    chk(!is.na(claimed) && claimed == detect_then_scope,
        sprintf("Table 1 reports the same exclusion count the data implies (%s vs %d)",
                claimed, detect_then_scope))
  }
}

# =============================================================================
cat("\n3. PROVENANCE\n")
# =============================================================================

# The merged 5,963 came from a run over midwives_unmatched.csv -- selected for
# having FAILED NPI linkage, so they are harder to find on any site. Pooling
# them with fresh searches biases the hit rate downward. The pooled rate is
# not an estimate of anything.
prior_f <- mw_data_path("prior_run_checkpoint_20260809T191817.rds")
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
