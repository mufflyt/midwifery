#!/usr/bin/env Rscript
# =============================================================================
# Denominator contracts: a rate's numerator must belong to its denominator
# =============================================================================
# ci_artifact_contracts.R checks arithmetic inside a file. ci_semantic_contracts.R
# checks that two files describe the same world. ci_science_contracts.R checks
# that the code does not claim more than the data supports. This file checks the
# one thing none of them does: that every published RATE divides a count by the
# group that count came from, over rows where the rate is defined at all.
#
# Every gate here is a defect that reached a supplemental table in this
# repository, found in review of the Green Journal rewrite (2026-11-21). They
# are static checks on tracked source plus arithmetic on committed artifacts --
# none needs the person-level data.
#
#   D1  A persistence rate is never pooled across the panel edge. At each
#       source's last observed year there is no t+1, so n_followed_source is 0
#       and n_lost_from_source == n_observed BY CONSTRUCTION, not by attrition.
#       Summing that row into a per-source total reported Medicaid attrition as
#       16.9% where the evaluable years say 0.8%.
#
#   D2  Registry visibility is undefined past the registry's last year. A
#       source-year whose t+1 falls outside NPPES scores every leaver as "not
#       in the registry", which is unobserved, not absent -- the SCI3 defect in
#       a denominator. PECOS ends in 2026 and so does NPPES, so Table S4
#       printed 16.4% for the "leavers still in the registry" share whose
#       evaluable value is 96.5%, contradicting its own caption.
#
#   D3  A percentage's numerator must belong to its denominator's group.
#       both_move_together_at_t1 is a sub-count of n_concordant_at_t -- one of
#       the three ways concordance breaks -- and was divided by
#       n_discordant_at_t. The open_payments row of Table S4 summed to 114.5%.
#
#   D4  A base-year label must be backed by the base-year count. n_discordant_at_t
#       pools every paired transition in a source's window; disc_base_n is the
#       base-year cohort. They differ by 18x for Medicaid, and the pooled count
#       was printed under a "Base year" column header.
#
#   D5  Every consumer of the canonical source record table honours
#       usable_for_trend. The producer marks left-censored Medicaid segments and
#       pre-SUPPORT-Act Open Payments years unusable; 37,923 of 447,008 rows.
#       A consumer that ignores the flag scores agreement on records the rest of
#       the manuscript excludes, and moved the Table S2 dose-response anchor by
#       5.3 points.
#
# Base R only. No network. Reads committed artifacts and tracked source.
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))

# Files that carry the analysis or a published display. Excludes tests/ so a
# gate does not police the fixtures written to prove the gate works -- and so
# that THIS file, which necessarily spells every forbidden expression out, does
# not fail itself. Three gates in this repository shipped self-tripping.
display_files <- function() {
  f <- c(ci_tracked("*.R"), ci_tracked("R/*.R"), ci_tracked("R/lib/*.R"),
         ci_tracked("manuscript/*.R"), ci_tracked("manuscript/R/*.R"),
         ci_tracked("manuscript/*.qmd"))
  unique(f[!grepl("^tests/", f)])
}

# A committed artifact as a numeric data frame, or NULL. The n_ columns are
# written with na = "" by write_with_provenance(), so an empty cell is NA and
# must stay NA -- coercing it to 0 is the defect D1 describes, performed by the
# checker instead of the code under test.
num_artifact <- function(rel) {
  d <- ci_read_head(rel, root = root)
  if (is.null(d) || !nrow(d)) return(NULL)
  for (cn in names(d)) {
    raw <- trimws(d[[cn]])
    v <- suppressWarnings(as.numeric(raw))
    # Numeric only when the parse fails exactly where the cell was blank. A
    # column of state abbreviations parses to all-NA with no blanks and stays
    # character; a count column with five empty cells becomes numeric with five
    # NAs, which is what it means.
    if (all(is.na(v) == !nzchar(raw))) d[[cn]] <- v
  }
  d
}

PERS <- "artifacts/persistence_denominators.csv"
LL   <- "artifacts/mrost_lead_lag.csv"
CANON <- "artifacts/canonical_source_records.csv"

# -----------------------------------------------------------------------------
ci_section("D1 a persistence rate is not pooled across the panel edge")

p <- num_artifact(PERS)
if (is.null(p)) {
  ci_fail("D1: %s is missing or empty. It is a tracked artifact, so absence is
       a regression, not a private-data skip.", PERS)
} else {
  need <- c("source", "year", "n_observed", "n_followed_source",
            "n_lost_from_source")
  if (!all(need %in% names(p))) {
    ci_fail("D1: %s lost column(s) %s. The gate cannot check a contract whose
       terms are gone; restore them or update this gate deliberately.",
       PERS, paste(setdiff(need, names(p)), collapse = ", "))
  } else {
    # The structural claim, asserted rather than assumed.
    #
    # TWO SHAPES ARE LEGAL AT THE EDGE and an earlier version of this check
    # accepted only one. A source's last year either reports the degeneracy
    # explicitly (0 followed, everyone "lost") or declines to report it at all
    # (NA). The second is the fixed form D2 asks the producer for, so a check
    # that demanded the first would have failed the moment anyone took D2's
    # advice -- a gate blocking its own remedy. What is NOT legal either way is
    # a degenerate row in the interior, because there the zero would be real.
    maxyr <- tapply(p$year, p$source, max)
    is_edge <- p$year == maxyr[p$source]
    declared <- !is.na(p$n_followed_source) & p$n_followed_source == 0 &
      !is.na(p$n_lost_from_source) & p$n_lost_from_source == p$n_observed
    withheld <- is.na(p$n_followed_source) | is.na(p$n_lost_from_source)
    bad_edge <- which(is_edge & !(declared | withheld))
    bad_mid <- which(!is_edge & declared)
    if (length(bad_edge) || length(bad_mid)) {
      ci_fail("D1: the panel edge is not the only row in %s without follow-up
       (%d edge row(s) report real follow-up, %d interior row(s) report none).
       The edge-exclusion rule below was derived from that shape; re-derive it
       before trusting any pooled rate from this artifact:\n%s",
       PERS, length(bad_edge), length(bad_mid),
       paste(sprintf("       %s %s", p$source[c(bad_edge, bad_mid)],
                     p$year[c(bad_edge, bad_mid)]), collapse = "\n"))
    } else {
      ci_ok("%d edge row(s) carry no follow-up (%d declared, %d withheld), %d interior row(s) all do",
            sum(is_edge), sum(is_edge & declared), sum(is_edge & withheld),
            sum(!is_edge))
    }
    cat(sprintf("  [CONTROL] D1 edge rows n=%d of %d\n", sum(is_edge), nrow(p)))

    # The code half. A file that pools these denominators must say which years
    # it pools. Naming the artifact and summing it is not enough -- the
    # restriction has to be visible, because a reader checking the table cannot
    # see an aggregation's year range from the table.
    POOL <- paste0("\\b(aggregate|tapply|rowsum|colSums|rowSums|",
                   "ave|xtabs)\\s*\\(|\\bsum\\s*\\(|group_by\\s*\\(")
    RESTRICT <- paste0("followable|registry_evaluable|evaluable|terminal|",
                       "panel_edge|last_year|max\\s*\\(\\s*[^)]*year|",
                       "year\\s*[<!]|year\\s*%in%|!is\\.na\\s*\\(\\s*pct_")
    off <- character(0)
    for (f in display_files()) {
      txt <- ci_code_lines(f, root = root)
      use <- grep("persistence_denominators|n_lost_from_source|n_followed_source",
                  txt)
      if (!length(use)) next
      # The producer cannot filter on a flag it is the one writing.
      if (any(grepl("write_[a-z_]*\\([^\\n]*persistence_denominators", txt,
                    perl = TRUE))) next
      # SCOPED TO THE BLOCK THAT USES THE ARTIFACT, not the whole file. The
      # first version of this check scanned whole files and passed vacuously on
      # manuscript/R/build_stats_catalog.R -- 1,500 lines, so somewhere in it a
      # `year <` or a `max(..., year)` belonging to an unrelated catalog entry
      # satisfied RESTRICT and the one block that actually pools these
      # denominators was never examined.
      span <- seq(max(1L, min(use) - 5L), min(length(txt), max(use) + 5L))
      blk <- txt[span]
      if (!any(grepl(POOL, blk, perl = TRUE))) next
      if (any(grepl(RESTRICT, blk, perl = TRUE))) next
      # Line numbers from the RAW file, not from the comment-stripped vector
      # the window was cut out of -- a reader given "lines 951-977" for a block
      # that lives at 1463 goes looking in the wrong place, and the first
      # version of this message did exactly that.
      raw <- tryCatch(readLines(file.path(root, f), warn = FALSE),
                      error = function(e) character(0))
      at <- grep("persistence_denominators|n_lost_from_source|n_followed_source",
                 raw)
      off <- c(off, if (length(at))
        sprintf("%s (lines %d-%d)", f, min(at), max(at)) else f)
    }
    if (length(off)) {
      ci_fail("D1: %d file(s) pool %s across every year without restricting to
       the years where follow-up exists:\n%s
       At each source's last year n_followed_source is 0 and
       n_lost_from_source == n_observed because there is no t+1, not because
       anyone left. Exclude the edge, or have the producer emit NA there.",
       length(off), PERS,
       paste(sprintf("       %s", off), collapse = "\n"))
    } else {
      ci_ok("every pooling consumer of %s restricts the year range", basename(PERS))
    }
  }
}

# -----------------------------------------------------------------------------
ci_section("D2 registry visibility is undefined past the registry's last year")

if (!is.null(p) && all(c("n_lost_source_but_in_nppes", "n_lost_from_source",
                         "source", "year") %in% names(p))) {
  # Hard arithmetic first: a conditional count cannot exceed the group it
  # conditions on.
  over <- which(p$n_lost_source_but_in_nppes > p$n_lost_from_source)
  if (length(over)) {
    ci_fail("D2: %d row(s) of %s count more registry-visible leavers than
       leavers:\n%s", length(over), PERS,
       paste(sprintf("       %s %s: %d of %d", p$source[over], p$year[over],
                     p$n_lost_source_but_in_nppes[over],
                     p$n_lost_from_source[over]), collapse = "\n"))
  } else {
    ci_ok("registry-visible leavers never exceed leavers (%d rows)", nrow(p))
  }

  # A source-year is evaluable for this rate only when t+1 is observed BOTH in
  # the source (so "left" means left) and in the registry (so "not in the
  # registry" means absent rather than unobserved).
  nppes_max <- suppressWarnings(max(p$year[p$source == "nppes"], na.rm = TRUE))
  if (!is.finite(nppes_max)) {
    ci_fail("D2: %s carries no nppes rows, so the registry's last year cannot be
       determined and registry visibility cannot be scored.", PERS)
  } else {
    maxyr <- tapply(p$year, p$source, max)
    evaluable <- p$year < maxyr[p$source] & p$year + 1L <= nppes_max
    srcs <- setdiff(unique(p$source), "nppes")
    straddle <- character(0)
    protected <- character(0)
    for (s in srcs) {
      i <- p$source == s
      j <- i & evaluable
      den <- sum(p$n_lost_from_source[j], na.rm = TRUE)
      if (!den) next
      true <- sum(p$n_lost_source_but_in_nppes[j], na.rm = TRUE) / den
      # na.rm IS OMITTED HERE ON PURPOSE. If the producer withholds the rate
      # where t+1 is unobservable, the naive pooled sum is NA and no consumer
      # can reach a wrong number by pooling -- which is the outcome this gate
      # is asking for, so NA is a pass, not an error to be swept up.
      naive <- sum(p$n_lost_source_but_in_nppes[i]) / sum(p$n_lost_from_source[i])
      if (is.na(naive)) {
        protected <- c(protected, s)
        cat(sprintf("  [CONTROL] D2 %-20s pooled=NA (withheld at the edge) evaluable=%.1f%% (n=%d evaluable leavers)\n",
                    s, 100 * true, den))
        next
      }
      cat(sprintf("  [CONTROL] D2 %-20s pooled=%.1f%% evaluable=%.1f%% (n=%d evaluable leavers)\n",
                  s, 100 * naive, 100 * true, den))
      # Not "the two differ" -- every edge row shifts a rate a little. The
      # failure is a difference big enough to change the finding a reader takes
      # away, which is what 16.4% vs 96.5% did to Table S4's caption.
      if (abs(true - naive) > 0.05) straddle <- c(straddle,
        sprintf("%s: pooled %.1f%% vs evaluable %.1f%%", s, 100 * naive, 100 * true))
    }
    if (length(protected))
      ci_ok("%d source(s) withhold the rate where t+1 is unobservable, so it cannot be pooled wrongly: %s",
            length(protected), paste(protected, collapse = ", "))
    if (length(straddle)) {
      ci_fail("D2: %d source(s) whose leaver-visibility share moves by more than
       5 points when the inevaluable rows are dropped:\n%s
       Those rows score an unobserved t+1 as a confirmed absence from the
       registry. %s should carry the rate as NA where t+1 is outside the
       source's or the registry's window, so no consumer can pool it.",
       length(straddle), paste(sprintf("       %s", straddle), collapse = "\n"),
       basename(PERS))
    } else {
      ci_ok("leaver-visibility is stable to dropping inevaluable rows (%d sources)",
            length(srcs))
    }
  }
} else if (!is.null(p)) {
  ci_fail("D2: %s lacks the leaver-visibility columns this gate scores.", PERS)
}

# -----------------------------------------------------------------------------
ci_section("D3 a percentage's numerator belongs to its denominator's group")

ll <- num_artifact(LL)
if (is.null(ll)) {
  ci_fail("D3: %s is missing or empty. It is a tracked artifact, so absence is
       a regression, not a private-data skip.", LL)
} else {
  conc_cols <- c("a_breaks_concordance_first", "b_breaks_concordance_first",
                 "both_move_together_at_t1", "n_concordant_at_t")
  disc_cols <- c("b_adopts_a_at_t1_n", "a_reverts_to_b_at_t1_n",
                 "n_discordant_at_t")
  if (!all(c(conc_cols, disc_cols) %in% names(ll))) {
    ci_fail("D3: %s lost column(s) %s.", LL,
            paste(setdiff(c(conc_cols, disc_cols), names(ll)), collapse = ", "))
  } else {
    # Group membership established from the data, so the static check below is
    # not an argument about naming. both_move_together_at_t1 fits inside the
    # concordant group and the adopt/revert counts fit inside the discordant
    # group; neither fits the other.
    parts <- ll$a_breaks_concordance_first + ll$b_breaks_concordance_first +
      ll$both_move_together_at_t1
    if (!all(parts <= ll$n_concordant_at_t)) {
      ci_fail("D3: the concordance-breaking counts do not fit inside
       n_concordant_at_t in %s, so this gate's premise is wrong; re-derive it.", LL)
    } else if (!all(ll$b_adopts_a_at_t1_n + ll$a_reverts_to_b_at_t1_n <=
                      ll$n_discordant_at_t)) {
      ci_fail("D3: the resolution counts do not fit inside n_discordant_at_t
       in %s, so this gate's premise is wrong; re-derive it.", LL)
    } else {
      ci_ok("both_move_together_at_t1 is a sub-count of n_concordant_at_t, not of n_discordant_at_t")
    }

    # A decomposition of one group cannot exceed the group. Recomputes what a
    # display would print and fails on the row that exceeds 100%.
    pct_cols <- c("b_adopts_a_at_t1_pct", "a_reverts_to_b_at_t1_pct",
                  "persistent_discordant_at_t1_pct")
    if (all(pct_cols %in% names(ll))) {
      legit <- rowSums(ll[, pct_cols], na.rm = TRUE)
      plus <- legit + 100 * ll$both_move_together_at_t1 / ll$n_discordant_at_t
      if (any(legit > 100 + 1e-6)) {
        ci_fail("D3: the discordance decomposition already exceeds 100%% in %s
       before anything is added to it. Rows: %s", LL,
       paste(ll$source_b[legit > 100 + 1e-6], collapse = ", "))
      } else {
        ci_ok("the three discordance shares sum to <= 100%% in all %d rows", nrow(ll))
      }
      cat(sprintf("  [CONTROL] D3 max decomposition %.1f%%, max if both_move_together is added %.1f%%\n",
                  max(legit), max(plus, na.rm = TRUE)))
    }

    # The code half. Dividing the concordant-group count by the discordant
    # denominator is the specific defect; it must not reappear in any display.
    BAD <- "both_move_together_at_t1\\s*(\\)|,)?\\s*/\\s*[^;]{0,80}?n_discordant_at_t"
    off <- character(0)
    for (f in display_files()) {
      txt <- ci_code_lines(f, root = root)
      # A THREE-LINE WINDOW, not the whole file. The division is split across
      # two lines in the qmd chunk, which is how it survived review, so a
      # line-by-line grep misses it -- but collapsing the entire file matched
      # build_lead_lag_decomposition.R, which merely carries both columns
      # through a transmute() eight lines apart and divides nothing. A gate with
      # a false positive gets switched off, and the real gates beside it go too.
      win <- if (length(txt) < 3) paste(txt, collapse = " ") else
        vapply(seq_len(length(txt) - 2L),
               function(i) paste(txt[i:(i + 2L)], collapse = " "), character(1))
      if (any(grepl(BAD, win, perl = TRUE))) off <- c(off, f)
    }
    if (length(off)) {
      ci_fail("D3: %d file(s) divide both_move_together_at_t1 by
       n_discordant_at_t:\n%s
       both_move_together_at_t1 counts provider-years that AGREED at t and
       moved together at t+1 -- a sub-count of n_concordant_at_t. Over the
       discordant denominator the open_payments row sums to 114.5%%. Report the
       residual as 100 - (adopts + reverts + persistent), or denominate
       concordance-breaking in n_concordant_at_t.",
       length(off), paste(sprintf("       %s", off), collapse = "\n"))
    } else {
      ci_ok("no display divides a concordant-group count by the discordant denominator")
    }
  }
}

# -----------------------------------------------------------------------------
ci_section("D4 a base-year label is backed by the base-year count")

if (!is.null(ll) && all(c("base_year", "disc_base_n", "n_discordant_at_t") %in%
                        names(ll))) {
  # The two are different quantities, which is what makes mixing them an error
  # rather than pedantry. Asserted so the gate cannot pass vacuously on an
  # artifact where they happen to coincide.
  ratio <- ll$n_discordant_at_t / ll$disc_base_n
  cat(sprintf("  [CONTROL] D4 n_discordant_at_t / disc_base_n ranges %.1fx to %.1fx\n",
              min(ratio, na.rm = TRUE), max(ratio, na.rm = TRUE)))
  if (!any(ratio > 1.5, na.rm = TRUE)) {
    ci_skip("D4: pooled and base-year discordance counts are within 1.5x everywhere; the mix-up this gate catches would not be visible here")
  }

  # A display that puts a READER-FACING base-year label next to a count taken
  # from the pooled column is telling the reader the pooled number is a
  # base-year number.
  #
  # The discriminator is the quoted display label, not the bare `base_year`
  # symbol. build_lead_lag_decomposition.R carries base_year and
  # n_discordant_at_t through one transmute() as two independent columns and
  # labels nothing; flagging it would be a false positive, and the rule being
  # enforced here is about what a table SAYS, not which columns a script
  # touches.
  LABEL <- "[`\"'][Bb]ase[ _][Yy]ear"
  off <- character(0)
  for (f in display_files()) {
    txt <- ci_code_lines(f, root = root)
    one <- paste(txt, collapse = " ")
    if (!grepl(LABEL, one, perl = TRUE)) next
    if (!grepl("n_discordant_at_t", one, fixed = TRUE)) next
    # disc_base_n present means the display reaches for the base-year count
    # where it means the base year; that is the fixed form, not the defect.
    if (grepl("disc_base_n", one, fixed = TRUE)) next
    off <- c(off, f)
  }
  if (length(off)) {
    ci_fail("D4: %d file(s) label a column `base_year` while counting with
       n_discordant_at_t:\n%s
       n_discordant_at_t pools every paired transition in the source's window
       (23,315 for Medicaid); disc_base_n is the base-year cohort (1,316).
       Either drop the base-year column and say the counts pool all years, or
       switch the row to disc_base_n with its _multi_ follow-up shares.",
       length(off), paste(sprintf("       %s", off), collapse = "\n"))
  } else {
    ci_ok("no display reports a pooled count under a base-year label")
  }
}

# -----------------------------------------------------------------------------
ci_section("D5 every consumer of the canonical records honours usable_for_trend")

# Vacuity control. A flag that is TRUE everywhere makes every consumer correct
# by accident, and a gate that cannot fail is worse than no gate.
cv <- ci_read_head(CANON, root = root)

# ABSENT-AND-GITIGNORED IS A SKIP; ABSENT-AND-TRACKED IS STILL A FAILURE.
# This branch used to call ci_fail() unconditionally, on the stated grounds
# that the canonical records are "a tracked artifact, so absence is a
# regression". They are not tracked -- .gitignore:320 excludes them -- so the
# branch fired on every runner and D5 could never pass in CI. That is the
# environment case DEBT D14's closing note separates from a live defect: a
# gate no one's work can turn green gets muted, and the four gates beside it
# get muted with it.
#
# The discrimination matters more than the skip. `git check-ignore` is asked
# whether this particular path is ignored, exactly as ci_require_files() in
# tests/ci_report.R does, so deleting a TRACKED input still fails here and
# only the known-private one is forgiven. The skip is declared in
# tests/skip_budget.tsv, so gaining or losing it is itself a failure.
canon_ignored <- identical(as.integer(suppressWarnings(system2(
  "git", c("-C", root, "check-ignore", "-q", CANON),
  stdout = FALSE, stderr = FALSE))), 0L)

if (is.null(cv) && !file.exists(file.path(root, CANON)) && canon_ignored) {
  ci_skip("D5: %s absent (gitignored; expected on CI and a fresh checkout) -- the vacuity control below needs it, so D5 asserts locally only",
          CANON)
} else if (is.null(cv) || !"usable_for_trend" %in% names(cv)) {
  ci_fail("D5: %s is missing while tracked, or carries no usable_for_trend
       column. The producer writes that column, and a tracked input that has
       gone missing is a regression rather than a private-data skip.", CANON)
} else {
  n_false <- sum(cv$usable_for_trend != "TRUE")
  cat(sprintf("  [CONTROL] D5 unusable rows n=%d of %d\n", n_false, nrow(cv)))
  if (!n_false) {
    ci_skip("D5: no row is marked unusable, so honouring the flag is unobservable; the gate below cannot fail")
  }

  # KNOWN, AWAITING A DECISION -- not forgiven.
  #
  # build_state_variation_agreement.R predates this gate and scores
  # per-registry-state agreement without the filter. It is baselined rather
  # than rewritten here because changing which records enter a published
  # stratification is the author's call, not a test's. The baseline can only
  # shrink: a new consumer fails this gate, and fixing the baselined one
  # requires deleting its line.
  # DELETED 2026-11-21. build_state_variation_agreement.R now reads
  # `filter(usable_for_trend == "TRUE", ...)` at its head, which is what DEBT
  # D14 item 5 asked for, so this gate's own instruction on a baselined
  # consumer that starts honouring the flag applies: remove its line. An empty
  # list makes the gate STRICTER -- any consumer that skips the flag now fails
  # outright, with no forgiven entry to hide behind. Re-adding a name is a
  # decision to argue for in DEBT, not a convenience.
  UFT_BASELINE <- character(0)

  off <- character(0); known <- character(0)
  for (f in display_files()) {
    txt <- ci_code_lines(f, root = root)
    if (!any(grepl("canonical_source_records", txt, fixed = TRUE))) next
    # The producer itself writes the flag; it cannot filter on it.
    if (basename(f) == "build_canonical_source_records.R") next
    # A consumer that never reads `state` is not scoring agreement and the
    # eligibility flag may legitimately not apply to it.
    if (!any(grepl("\\bstate\\b", txt))) next
    if (any(grepl("usable_for_trend", txt, fixed = TRUE))) next
    if (f %in% UFT_BASELINE) known <- c(known, f) else off <- c(off, f)
  }
  tracked <- intersect(UFT_BASELINE, display_files())
  stale <- setdiff(tracked, known)
  if (length(stale)) {
    ci_fail("D5: %d baselined consumer(s) now honour the flag: %s. Remove them
       from UFT_BASELINE so the baseline keeps shrinking.",
       length(stale), paste(stale, collapse = ", "))
  }
  if (length(known)) {
    ci_skip("D5: %d known consumer(s) awaiting a policy decision:", length(known))
    for (k in known) cat(sprintf("       %s\n", k))
  }
  if (length(off)) {
    ci_fail("D5: %d consumer(s) of %s score practice state without honouring
       usable_for_trend:\n%s
       %d of %d rows are marked unusable -- left-censored Medicaid enrollment
       segments and pre-2021 Open Payments years, whose state attribution the
       producer does not stand behind. compare_all_sources_mysteryroster.R and
       build_f2_f3_uncertainty_denominators.R both filter; a consumer that does
       not is scoring a different cohort from the rest of the manuscript.",
       length(off), CANON,
       paste(sprintf("       %s", off), collapse = "\n"), n_false, nrow(cv))
  } else {
    ci_ok("every state-scoring consumer of %s honours the flag", basename(CANON))
  }
}

ci_finish()
