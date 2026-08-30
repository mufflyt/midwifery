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
#   G6  middle names compare as token SETS, and absence is never a conflict
#                                                  (position-1 cost 82 rows)
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
skips <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# An artifact that is absent is not an artifact that is WRONG. The crosswalk is
# person-level and gitignored, so on a runner these assertions have nothing to
# read -- chk(FALSE) there reports a defect that has not been demonstrated, and
# a permanently red test is one nobody reads.
#
# Skips are COUNTED and printed in the final line so this cannot decay into a
# vacuous pass: a run that skipped everything says so out loud.
skip <- function(m) {
  skips <<- skips + 1L
  cat(sprintf("  --   SKIP %s\n", m))
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
  # This is an anti-vacuous check and it is RIGHT to fail when the gate looked
  # at nothing -- that is how a gate quietly stops gating. But on a runner the
  # artifacts are gitignored, so "examined 0" is expected rather than alarming.
  # Distinguish the two: absent inputs skip, a present-but-unexamined artifact
  # still fails.
  if (checked > 0L) {
    chk(TRUE, sprintf("G1 gate actually examined artifacts [%d]", checked))
  } else if (length(Sys.glob("artifacts/amcb_npi_crosswalk_*.csv")) ||
             file.exists("artifacts/amcb_npi_geography.csv")) {
    chk(FALSE, "G1 gate examined 0 artifacts although artifacts are present")
  } else {
    skip("G1 artifact reproducibility: no committed artifacts to examine")
  }

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
  # A shallow clone (actions/checkout defaults to depth 1) does not contain
  # a8552fa. system2() returns character(0) for a missing object rather than
  # erroring, so this read as a FAILED negative control instead of an
  # unreachable one. Treat empty output as unreachable; the nightly checks out
  # full history so it actually runs there.
  hist_ok <- tryCatch({
    raw_old <- system2("git", c("show", "a8552fa:match_amcb_to_npi.R"),
                       stdout = TRUE, stderr = FALSE)
    if (!length(raw_old)) stop("a8552fa unreachable (shallow clone)")
    src_old <- paste(raw_old, collapse = "\n")
    hdr <- system2("git", c("show",
      "a8552fa:artifacts/amcb_npi_crosswalk_translit_panel-midwifery-plus-nursing_years-2007-2025.csv"),
      stdout = TRUE, stderr = FALSE)[1]
    if (is.na(hdr) || !nzchar(hdr)) stop("a8552fa artifact unreachable")
    cols_old <- strsplit(hdr, ",", fixed = TRUE)[[1]]
    bad <- explains(cols_old, src_old, passthrough("midwives.csv"))
    length(bad) == 3L && all(c("nppes_matched_last", "nppes_matched_first",
                               "nppes_name_changed_since_match") %in% bad)
  }, error = function(e) NA)
  # The control compares a8552fa's artifact columns against that commit's
  # matcher, ALLOWING roster passthrough. Without midwives.csv the passthrough
  # set is empty, every roster column reads as unexplained, and `bad` exceeds
  # the expected 3 -- the control fails for want of an allowlist rather than
  # because the gate stopped working. midwives.csv is gitignored, so that is
  # the runner's normal state.
  if (!file.exists("midwives.csv")) {
    skip("G1 historical negative control (midwives.csv absent; passthrough allowlist unavailable)")
  } else if (is.na(hist_ok)) {
    skip("G1 historical negative control (commit a8552fa unreachable in a shallow clone)")
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
cat("\n-- G8: a contested NPI is awarded on evidence, never on sort order --\n")
# =============================================================================
# Restoring any award rule reopens the defect the upstream resolver removed:
# whoever sorts first takes the NPI. The whole point of strict_dominance is
# that it MUST refuse the tie. If it ever awards the class-2/class-2 pair
# below, 37 real certificants get an identity decided by their certification
# number, and nothing downstream would show it.
{
  q <- data.frame(
    enthealth_id     = c("A", "B", "C", "D", "E", "F"),
    npi              = c("1000000004", "1000000004",   # separable
                         "1000000012", "1000000012",   # exact tie
                         "1000000020", "1000000038"),  # not contested
    resolution_status = c(rep("ambiguous_contested_npi", 4),
                          "ambiguous_tied_evidence", "ambiguous_tied_evidence"),
    method_priority  = 99L,
    score_total_adj  = c(4L, 3L, 3L, 3L, 4L, 4L),
    confidence_score = c(1.0, 0.9, 0.9, 0.9, 1.0, 1.0),
    stringsAsFactors = FALSE)

  sd <- amcb_award_contested(q, "strict_dominance")
  chk(nrow(sd) == 1L && sd$enthealth_id == "A",
      sprintf("G8 strict_dominance awards only the separable NPI [%d row(s)]",
              nrow(sd)))
  chk(!"1000000012" %in% sd$npi,
      "G8 strict_dominance REFUSES the exact tie -- no identity on sort order")
  chk(nrow(amcb_award_contested(q, "quarantine_all")) == 0L,
      "G8 quarantine_all awards nothing")
  gd <- amcb_award_contested(q, "greedy")
  chk(nrow(gd) == 2L,
      sprintf("G8 greedy awards the tie too -- the behaviour being priced [%d]",
              nrow(gd)))
  chk(!any(duplicated(sd$enthealth_id)) && !any(duplicated(sd$npi)),
      "G8 no person wins two NPIs and no NPI goes to two people")
  chk(nrow(amcb_award_contested(q[q$resolution_status == "ambiguous_tied_evidence", ],
                                "strict_dominance")) == 0L,
      "G8 tied-evidence rows are not contested rows and are never awarded")
  chk(inherits(try(amcb_award_contested(q, "whatever"), silent = TRUE), "try-error"),
      "G8 an unknown rule name errors rather than silently quarantining")
}

# =============================================================================
cat("\n-- G7: an imported function is pinned by BEHAVIOUR, not by exists() --\n")
# =============================================================================
# match_amcb_to_npi.R imported five functions from isochrones and checked them
# with exists(). Between the frozen linkage and 2026-08-30 the canonical
# rank_one_to_one() changed its default id_col AND began requiring a lookup
# table the ENT script does not export. exists() was TRUE throughout and two
# fifteen-minute runs died. Worse than the loud failure: a caller carrying a
# column named by the NEW default gets no error and silently enforces the
# bijection over the wrong identifier.
#
# The stand-ins below are the point of the gate. An assertion that only the real
# function can pass is indistinguishable from one that always passes.
{
  ok <- function(f) tryCatch({amcb_assert_rank_one_to_one(f); TRUE},
                             error = function(e) FALSE)

  greedy <- function(candidates, id_col = "enthealth_id") {
    d <- candidates[order(-candidates$score_total), ]
    d <- d[!duplicated(d$npi), ]
    d[!duplicated(d[[id_col]]), ]
  }
  first_row  <- function(candidates, id_col = "enthealth_id")
    candidates[!duplicated(candidates[[id_col]]), ]
  passthrough <- function(candidates, id_col = "enthealth_id") candidates

  chk(!ok(greedy),
      "G7 rejects a resolver that awards a contested NPI to the top scorer")
  chk(!ok(first_row),
      "G7 rejects a resolver that ignores evidence within one person")
  chk(!ok(passthrough),
      "G7 rejects a resolver returning more than one row per identifier")
  chk(inherits(try(amcb_assert_rank_one_to_one(function(...) stop("boom")),
                   silent = TRUE), "try-error"),
      "G7 an erroring resolver fails the contract rather than passing silently")

  if (exists("rank_one_to_one", mode = "function")) {
    chk(ok(NULL), "G7 the imported rank_one_to_one() satisfies the contract")
  } else {
    skip("G7 live contract: rank_one_to_one() not sourced (isochrones absent)")
  }
}

# =============================================================================
cat("\n-- G6: middle names compare as TOKEN SETS, never by position --\n")
# =============================================================================
# The veto on a middle-name conflict is the strongest single rule in the
# linkage: it deletes candidates agreeing on BOTH whole names. Comparing
# position 1 only, it scored a maiden surname held in a different slot as a
# disagreement and deleted 82 rows' only exact-name candidate. Both halves are
# pinned here -- what must now corroborate, and what must STILL conflict, since
# a fix that stops vetoing anything is not a fix.
{
  source(file.path(root, "R", "amcb_name_keys.R"))
  agree <- function(a, b) amcb_middle_agreement(amcb_middle_tokens(a),
                                                amcb_middle_tokens(b))

  # -- must corroborate: the same evidence, recorded in a different slot ------
  chk(agree("A REINHARD", "REINHARD") == "corroborates",
      "G6 whole token shared out of position corroborates (Reinhard/Rye)")
  chk(agree("BETH HARVEY", "H") == "corroborates",
      "G6 initial abbreviating a NON-FIRST token corroborates (Harvey/Capista)")
  chk(agree("M", "ANN MARIE") == "corroborates",
      "G6 initial matches the second of two middle names")
  chk(agree("JANE", "J") == "corroborates",
      "G6 the old position-1 behaviour is preserved where it was right")

  # -- must STILL conflict: the veto has to keep doing its job ----------------
  chk(agree("JANE", "DENISE") == "conflicts",
      "G6 two full middle names sharing no token still conflict")
  chk(agree("MARILYN", "F") == "conflicts",
      "G6 an initial that abbreviates no token still conflicts")
  chk(agree("WORKMAN", "G") == "conflicts",
      "G6 maiden surname against an unrelated initial still conflicts")
  chk(agree("JANE", "JOAN") == "conflicts",
      "G6 a shared first LETTER is not a shared token when neither is initial")

  # -- concatenated initials are initials, not a name ------------------------
  # Found by auditing the 27 identity flips the first version of this rule
  # caused. "VL" is two characters, so it was scored as a full NAME token,
  # matched nothing in {VELMA, LAURITZEN}, and -- neither side then holding a
  # single letter -- never reached the initial test. The candidate was vetoed
  # and a nursing record took the match from a midwifery one.
  chk(agree("VL", "VELMA LAURITZEN") == "corroborates",
      "G6 a concatenated-initials token matches the names it abbreviates")
  chk(agree("MJ", "MARY JANE") == "corroborates", "G6 two initials, two names")
  chk(agree("CJ", "CAROL JEAN") == "corroborates", "G6 and again, unordered input")
  chk(agree("VL", "LAURITZEN VELMA") == "conflicts",
      "G6 the mapping is ORDER-PRESERVING, not a bag of letters")

  # -- NO edit-distance tolerance anywhere on this axis -------------------
  # A one-edit tolerance was added and removed the same day. It was worth 22
  # roster records and it admitted pairs that are genuinely different given
  # names. These assertions exist so it cannot come back by accident: every
  # one of them was "uninformative" under that rule.
  chk(agree("JULIA", "JULIE") == "conflicts",
      "G6 one edit apart is a CONFLICT -- no fuzzy middle matching")
  chk(agree("LYN", "LYNN") == "conflicts", "G6 LYN/LYNN conflicts")
  chk(agree("ELISABETH", "ELIZABETH") == "conflicts",
      "G6 a spelling variant is still a conflict, however plausible")
  chk(agree("KRISTINA", "KRISHNA") == "conflicts",
      "G6 two edits on a long token conflicts")
  chk(agree("JANE", "JOAN") == "conflicts", "G6 and short tokens too")
  chk(agree("LEIGH", "LYNN") == "conflicts",
      "G6 genuinely different middle names still conflict")
  chk(!exists("near_spelling"),
      "G6 the edit-distance helper is gone, not merely unreferenced")

  # -- absence is never evidence of difference (the 2026-08-08 defect) --------
  chk(agree("", "MARIE") == "uninformative" &&
        agree("MARIE", "") == "uninformative" &&
        agree(NA_character_, "MARIE") == "uninformative",
      "G6 a missing middle name is uninformative, never a conflict")
  chk(agree("", "") == "uninformative",
      "G6 two absences do not agree with each other")

  # -- vectorised, and order-preserving --------------------------------------
  v <- agree(c("A REINHARD", "JANE", ""), c("REINHARD", "DENISE", "MARIE"))
  chk(identical(v, c("corroborates", "conflicts", "uninformative")),
      "G6 vectorises elementwise without reordering")
  chk(inherits(try(amcb_middle_agreement(list("A"), list("A", "B")),
                   silent = TRUE), "try-error"),
      "G6 refuses mismatched input lengths rather than recycling")
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
    skip("crosswalk invariants: artifacts/amcb_npi_crosswalk_*.csv absent (person-level, gitignored)")
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
  chk("sensitivity_unknown_taxonomy" %in% COHORT_MEMBERSHIP_TIERS,
      "G5 unknown taxonomy remains cohort-eligible but not primary")
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
    skip("G5 crosswalk membership: artifacts/amcb_npi_crosswalk_*.csv absent (person-level, gitignored)")
  }
}

cat(sprintf("\n%s (%d failures, %d skipped)\n",
            if (fails == 0L) "PASS" else "FAIL", fails, skips))
if (skips > 0L) cat(sprintf(paste0(
  "  NOTE %d assertion group(s) skipped for absent person-level artifacts.\n",
  "       They run for real only on a machine that has them.\n"), skips))
quit(status = if (fails == 0L) 0L else 1L)
