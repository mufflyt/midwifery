#!/usr/bin/env Rscript
# =============================================================================
# AMCB -> NPPES linkage: gates against the failures that RECURRED
# =============================================================================
# Each gate here corresponds to a defect that happened more than once, or that
# produced a committed artifact. Tests pin behaviour; gates pin the PATTERN, so
# a seventh copy of a known-bad idiom fails before it ships.
#
#   G1  every column of a committed artifact must be producible by the
#       committed script that generates it        (caught nothing until a8552fa)
#   G2  no new hand-rolled name normaliser        (the defect appeared 6 times)
#   G3  "rival candidate" counts must exclude self (the NPI x variant unit, 3x)
#   G4  a selector matching nothing must FAIL      (bit me twice in one session)
#
# Run: Rscript tests/test_amcb_gates.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path(root, "R", "amcb_match_rules.R"))
source(file.path(root, "R", "amcb_cohort_membership.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# =============================================================================
cat("\n-- G1: committed artifacts must be reproducible from committed source --\n")
# =============================================================================
# a8552fa published a crosswalk carrying nppes_matched_last, nppes_matched_first
# and nppes_name_changed_since_match while the match_amcb_to_npi.R in that same
# commit produced none of them. Nothing detected it; I found it by hand, later,
# while doing something else.
#
# A column is "producible" if it appears literally in the generating script, OR
# it is passed through from a declared upstream input. The roster passthrough is
# real -- certification, status and friends are never named in the matcher --
# so it must be allowed or the gate is pure noise.
{
  passthrough <- function(paths) {
    unique(unlist(lapply(paths[file.exists(paths)], function(p)
      names(read_csv(p, n_max = 0, show_col_types = FALSE, progress = FALSE)))))
  }
  ART <- list(
    list(csv = Sys.glob("artifacts/amcb_npi_crosswalk_*_panel-*.csv"),
         src = "match_amcb_to_npi.R", inputs = "midwives.csv"),
    list(csv = "artifacts/amcb_npi_geography.csv",
         src = "enrich_amcb_crosswalk_geography.R", inputs = character(0)),
    list(csv = "artifacts/amcb_class5_review_census.csv",
         src = "draw_class5_review_census.R",
         inputs = Sys.glob("artifacts/amcb_npi_crosswalk_c5guard_*.csv")),
    list(csv = "artifacts/amcb_class5_corroboration.csv",
         src = "corroborate_class5_matches.R",
         inputs = "artifacts/amcb_class5_review_census.csv"),
    list(csv = Sys.glob("artifacts/amcb_crosswalk_review_sample_*.csv"),
         src = "audit_amcb_crosswalk.R",
         inputs = Sys.glob("artifacts/amcb_npi_crosswalk_c5guard_*.csv")))

  checked <- 0L
  for (a in ART) {
    a$csv <- a$csv[!grepl("\\.manifest\\.json$", a$csv)]
    a$csv <- a$csv[file.exists(a$csv)]
    if (!length(a$csv) || !file.exists(a$src)) next
    src <- paste(readLines(a$src, warn = FALSE), collapse = "\n")
    ok_extra <- passthrough(a$inputs)
    for (csv in a$csv) {
      cols <- names(read_csv(csv, n_max = 0, show_col_types = FALSE, progress = FALSE))
      unexplained <- cols[!vapply(cols, function(cc)
        grepl(cc, src, fixed = TRUE) || cc %in% ok_extra, logical(1))]
      checked <- checked + 1L
      chk(length(unexplained) == 0L,
          sprintf("G1 %s: every column producible by %s%s", basename(csv), a$src,
                  if (length(unexplained))
                    paste0(" [UNEXPLAINED: ", paste(unexplained, collapse = ", "), "]")
                  else ""))
    }
  }
  chk(checked > 0L, sprintf("G1 gate actually examined artifacts [%d]", checked))

  # NEGATIVE CONTROLS. A gate that has never been observed to fail is
  # decoration. Both of these must be caught.
  explains <- function(cols, src, extra = character(0)) {
    cols[!vapply(cols, function(cc)
      grepl(cc, src, fixed = TRUE) || cc %in% extra, logical(1))]
  }
  # (a) synthetic: a column no script produces.
  chk(length(explains(c("npi", "invented_column_xyz"), "x <- npi")) == 1L,
      "G1 negative control: an unproducible column is detected")

  # (b) historical: a8552fa published a crosswalk carrying three columns its
  # own committed matcher could not produce. This gate must fail that commit.
  hist_ok <- tryCatch({
    src_old <- paste(system2("git", c("show", "a8552fa:match_amcb_to_npi.R"),
                             stdout = TRUE, stderr = FALSE), collapse = "\n")
    hdr <- system2("git", c("show",
      "a8552fa:artifacts/amcb_npi_crosswalk_translit_panel-midwifery-plus-nursing_years-2007-2025.csv"),
      stdout = TRUE, stderr = FALSE)[1]
    cols_old <- strsplit(hdr, ",", fixed = TRUE)[[1]]
    bad <- explains(cols_old, src_old, passthrough("midwives.csv"))
    length(bad) == 3L && all(c("nppes_matched_last", "nppes_matched_first",
                               "nppes_name_changed_since_match") %in% bad)
  }, error = function(e) NA)
  if (is.na(hist_ok)) {
    cat("  skip G1 historical negative control (commit a8552fa unreachable)\n")
  } else {
    chk(hist_ok, "G1 negative control: would have failed a8552fa (3 columns)")
  }
}

# =============================================================================
cat("\n-- G2: no new hand-rolled name normaliser --\n")
# =============================================================================
# toupper(trimws(...)) is correct about whitespace and silently wrong about
# Unicode. It was written independently in SIX functions across two repos, and
# BUG FIX #7 fixing one of them in January did not stop the next five. Tests on
# the canonical normaliser cannot prevent a seventh copy; only a gate on the
# PATTERN can. Scoped to AMCB-owned files so it cannot fail for another
# session's code and get switched off.
{
  owned <- c(Sys.glob("*amcb*.R"), Sys.glob("R/amcb_*.R"),
             "match_amcb_to_npi.R", "audit_amcb_crosswalk.R",
             "enrich_amcb_crosswalk_geography.R", "draw_class5_review_census.R",
             "corroborate_class5_matches.R")
  owned <- unique(owned[file.exists(owned)])
  assert_nonempty_selection(owned, "G2 file selection")

  BAD <- c("toupper\\s*\\(\\s*trimws", "str_to_upper\\s*\\(\\s*str_squish",
           "str_squish\\s*\\(\\s*str_to_upper", "toupper\\s*\\(\\s*str_trim")
  hits <- unlist(lapply(owned, function(f) {
    ln <- readLines(f, warn = FALSE)
    ln <- ln[!grepl("^\\s*#", ln)]                    # comments may cite it
    i <- which(Reduce(`|`, lapply(BAD, function(p) grepl(p, ln))))
    if (length(i)) sprintf("%s:%s", f, ln[i]) else NULL
  }))
  chk(length(hits) == 0L,
      sprintf("G2 no toupper(trimws())-style normaliser in %d AMCB files%s",
              length(owned),
              if (length(hits)) paste0(" [", paste(hits, collapse = " | "), "]") else ""))

  # The gate must be able to FAIL. A pattern check that cannot fire is decoration.
  probe <- 'x <- toupper(trimws(name))'
  chk(any(vapply(BAD, function(p) grepl(p, probe), logical(1))),
      "G2 gate demonstrably fires on a known-bad line")
  chk(!any(vapply(BAD, function(p) grepl(p, "k <- amcb_name_key(name)"), logical(1))),
      "G2 gate does not fire on the canonical call")
}

# =============================================================================
cat("\n-- G3: a rival candidate must be a different PERSON --\n")
# =============================================================================
{
  matched <- data.frame(amcb_id = c("A1", "A2", "A3"),
                        npi = c("111", "222", "333"), stringsAsFactors = FALSE)

  # A1: its own NPI appears as vetoed (a second name variant) plus one real
  # rival -> exactly 1. This is the case that cost two false demotions.
  # A2: ONLY its own variant was vetoed -> 0. Flagging it would demote a sound
  # match on no evidence.
  # A3: two genuinely different people -> 2.
  vetoed <- data.frame(
    amcb_id   = c("A1", "A1", "A2", "A3", "A3"),
    vetoed_npi = c("111", "999", "222", "444", "555"),
    stringsAsFactors = FALSE)
  got <- count_rival_npis(vetoed, matched)
  chk(identical(got$amcb_id, c("A1", "A2", "A3")) &&
        identical(got$n_rival_npis, c(1L, 0L, 2L)),
      sprintf("G3 self-variant excluded, real rivals counted [%s]",
              paste(sprintf("%s=%d", got$amcb_id, got$n_rival_npis), collapse = " ")))

  # An unmatched person has no self to exclude: every vetoed candidate is a rival.
  got2 <- count_rival_npis(data.frame(amcb_id = "A9", vetoed_npi = c("1", "2"),
                                      stringsAsFactors = FALSE),
                           data.frame(amcb_id = "A9", npi = NA_character_,
                                      stringsAsFactors = FALSE))
  chk(identical(got2$n_rival_npis, 2L), "G3 unmatched person: all vetoed are rivals")

  # Duplicate variant rows must not inflate the count.
  got3 <- count_rival_npis(data.frame(amcb_id = c("A1", "A1"),
                                      vetoed_npi = c("999", "999"),
                                      stringsAsFactors = FALSE),
                           matched[1, ])
  chk(identical(got3$n_rival_npis, 1L), "G3 duplicate variant rows counted once")

  # Empty input is 0 rows, not an error and not a fabricated row.
  chk(nrow(count_rival_npis(
        data.frame(amcb_id = character(0), vetoed_npi = character(0)),
        matched)) == 0L, "G3 empty veto set yields no rows")

  # A non-bijective `matched` is a contract violation upstream, not something
  # to average over.
  chk(inherits(try(count_rival_npis(
        data.frame(amcb_id = "A1", vetoed_npi = "9", stringsAsFactors = FALSE),
        data.frame(amcb_id = c("A1", "A1"), npi = c("1", "2"),
                   stringsAsFactors = FALSE)), silent = TRUE), "try-error"),
      "G3 refuses a matched table with duplicate amcb_id")
}

# =============================================================================
cat("\n-- G4: absent keys and empty selections must fail, not pass --\n")
# =============================================================================
{
  df <- data.frame(a = 1:3, b = letters[1:3])
  chk(inherits(try(require_cols(df, "amcb_id"), silent = TRUE), "try-error"),
      "G4 require_cols() errors on an absent join key")
  chk(!inherits(try(require_cols(df, c("a", "b")), silent = TRUE), "try-error"),
      "G4 require_cols() passes when the columns exist")
  chk(inherits(try(assert_nonempty_selection(character(0), "probe"), silent = TRUE),
               "try-error"),
      "G4 an empty selection errors instead of reporting clean")
  chk(!inherits(try(assert_nonempty_selection("x", "probe"), silent = TRUE),
                "try-error"), "G4 a non-empty selection passes")

  # The concrete failure: %in% against a column that does not exist returns 0
  # and reads as a clean result. require_cols() is what turns that into a stop.
  co <- data.frame(review_order = 1:3)
  vacuous <- sum(df$a %in% co$amcb_id)
  chk(vacuous == 0L && inherits(try(require_cols(co, "amcb_id"), silent = TRUE),
                                "try-error"),
      "G4 the vacuous-join pattern is caught by require_cols()")
}

# =============================================================================
cat("\n-- invariants the artifacts must satisfy --\n")
# =============================================================================
{
  xw <- Sys.glob("artifacts/amcb_npi_crosswalk_c5guard_*.csv")
  xw <- xw[!grepl("manifest", xw)]
  if (length(xw) == 1) {
    x <- read_csv(xw, col_types = cols(.default = "c"), progress = FALSE)
    ec <- suppressWarnings(as.numeric(x$name_evidence_class))
    chk(sum(table(x$linkage_tier)) == nrow(x), "tiers partition every row")
    chk(!any(x$linkage_tier == "primary_midwifery" & ec %in% c(4, 5), na.rm = TRUE),
        "primary_midwifery never holds class 4 or 5 evidence")
    chk(!any(x$linkage_tier == "quarantined" & !is.na(x$npi)),
        "no quarantined row retains an NPI")
    m <- x %>% filter(!is.na(npi)) %>% count(npi) %>% filter(n > 1)
    chk(nrow(m) == 0L, "one NPI, one person (bijection holds)")
  } else {
    chk(FALSE, "current crosswalk present and unique")
  }
}

# =============================================================================
cat("\n-- G5: crosswalk inclusion does NOT imply cohort eligibility --\n")
# =============================================================================
# Membership was inferred downstream as filter(!is.na(npi)). Harmless while
# every strategy produced comparable evidence; not harmless once a deliberately
# WEAK strategy was added. Class 5 contributed 156 candidates, and under the
# inferred rule all 156 would have become full cohort members -- 96% of the
# proposed growth from the weakest, entirely unreviewed tier.
{
  chk(is.character(COHORT_MEMBERSHIP_TIERS) && length(COHORT_MEMBERSHIP_TIERS) > 0,
      sprintf("G5 membership tiers are declared, not inferred [%s]",
              paste(COHORT_MEMBERSHIP_TIERS, collapse = ", ")))
  chk(!"sensitivity_name_component" %in% COHORT_MEMBERSHIP_TIERS,
      "G5 class-5 (surname component) is NOT cohort-eligible")
  chk(!any(c("quarantined", "unmatched") %in% COHORT_MEMBERSHIP_TIERS),
      "G5 quarantined and unmatched are NOT cohort-eligible")

  # Having an NPI is necessary and NOT sufficient. This is the whole rule.
  chk(isTRUE(is_cohort_member("1234567893", "primary_midwifery")) &&
        isFALSE(is_cohort_member("1234567893", "sensitivity_name_component")) &&
        isFALSE(is_cohort_member(NA_character_, "primary_midwifery")) &&
        isFALSE(is_cohort_member("", "primary_midwifery")),
      "G5 membership requires BOTH an NPI and an allowlisted tier")

  # NEGATIVE CONTROL: if someone adds class 5 back, the guard must notice.
  chk(sum(is_cohort_member(c("1", "2"), c("primary_midwifery", "sensitivity_name_component"),
                           allowed = c("primary_midwifery", "sensitivity_name_component"))) == 2L,
      "G5 negative control: widening the allowlist demonstrably changes membership")

  # Applied to the real crosswalk: the 156 must be candidates, not members.
  xw <- Sys.glob("artifacts/amcb_npi_crosswalk_c5guard_*.csv")
  xw <- xw[!grepl("manifest", xw)]
  if (length(xw) == 1) {
    x <- read_csv(xw, col_types = cols(.default = "c"), progress = FALSE)
    s5 <- cohort_membership_summary(x)
    chk(s5$n_members == 16898 && s5$n_with_npi == 17054 &&
          s5$n_candidates_not_members == 156,
        sprintf("G5 crosswalk: %s with an NPI, %s members, %s candidates held out",
                format(s5$n_with_npi, big.mark = ","),
                format(s5$n_members, big.mark = ","),
                format(s5$n_candidates_not_members, big.mark = ",")))
    chk(sum(is_cohort_member(x$npi, x$linkage_tier) &
              x$linkage_tier == "sensitivity_name_component") == 0L,
        "G5 no class-5 row is counted as a cohort member")
  } else {
    chk(FALSE, "G5 current crosswalk present")
  }
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
