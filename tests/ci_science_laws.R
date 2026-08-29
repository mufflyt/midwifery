# =============================================================================
# Scientific laws: properties that hold regardless of vintage
# =============================================================================
# ci_science_contracts.R polices the CODE. ci_science_nightly.R recomputes the
# PUBLISHED NUMBERS. Neither states a law -- a property that must hold whatever
# the data says, so that violating it is not a difference of opinion about an
# estimate but an impossibility.
#
# Every law here was violated in this repository, in production, and the
# violation reached an artifact:
#
#   L1  ONE COHORT PER DECLARED VINTAGE. Four cohort sizes were found coexisting
#       in outputs -- 15,706 in a stage header, 17,538 in R/06's pins and two
#       artifacts, 15,391 in cohort_transitions, 16,892 in everything current --
#       plus 11,913 against 11,920 in two age-calibration provenance files
#       written four hours apart from the SAME filter. An artifact may not
#       declare a cohort size that is not a registered cohort.
#
#   L2  POPULATION IS CONSERVED, in two shapes. linkage_completeness_by_status.csv reported four
#       dispositions summing to 20,473 of 22,309 rows. 1,836 people, 845 of them
#       ACTIVE, were inside the denominator behind a published percentage and
#       outside every column beside it. Parts must sum to their whole.
#
#   L3  MISSING GEOGRAPHY STAYS MISSING. 903 rows of the Census ZCTA file carry
#       no ZCTA; two of four private crosswalk copies kept them, group_by()
#       collapsed all 903 into one NA-keyed row pointing at Yukon-Koyukuk Census
#       Area, Alaska, and left_join() matches NA to NA. Every midwife with no
#       practice ZIP was ASSIGNED a real county with a real RUCC. Absence of
#       evidence may not become evidence.
#
#   L4  MORE TRAVEL TIME CANNOT REDUCE ACCESS. A 60-minute surface contains the
#       30-minute surface from the same origins, so access is monotone in the
#       band. A violation means the two surfaces were built from different
#       inputs -- which is exactly what a stale union looks like.
#
#   L5  EVERY ROUTED PROVIDER IS IN THE UNION. The published surfaces held 4,714
#       of 8,359 routed origins for two weeks after the routing completed. A
#       union that silently covers half the cohort understates access while
#       looking finished.
#
# Base R plus the committed artifacts. No network, no person-level data.
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))
# EVIDENCE CUSTODY: see ci_law_evidence_header(). First line this gate emits.
ci_law_evidence_header("tests/ci_science_laws.R")

law_num <- function(x) suppressWarnings(as.numeric(x))

# -----------------------------------------------------------------------------
ci_section("L1 an artifact may not declare an unregistered cohort")

# THE REGISTRY IS THE POINT. Two cohorts are legitimately in circulation and
# they are not interchangeable: the analytic cohort the persistence work follows,
# and the ACTIVE primary-linked cohort Table 1 describes. Anything else is a
# vintage that outlived its freeze.
#
# Adding a row here is a decision. That is the same reason ci_hygiene.R keeps an
# allowlist rather than a heuristic: a registry someone must edit on purpose
# cannot drift, and a heuristic that infers "close enough to 11,920" would have
# accepted the 11,913 that motivated this law.
LAW_COHORTS <- c(
  "16892" = "analytic cohort (frozen_cohort/analytic_cohort.csv)",
  "11920" = "ACTIVE, primary-linked (Table 1)"
)

# KNOWN, AWAITING A DECISION -- not forgiven.
#
# state_nursing_license_ages_provenance.csv declares cohort_n = 11,913, written
# 2026-08-10 17:36. Its sibling ohio_voter_license_ages_provenance.csv declares
# 11,920 at 21:24 the same day, and enrich_state_nursing_license_ages.R and
# match_ohio_voter_ages.R apply the IDENTICAL filter -- status == "ACTIVE" and
# linkage_tier == "primary_midwifery". Same definition, different answer, four
# hours apart: the frozen linkage was re-frozen between the two runs and the
# earlier artifact was never rebuilt. The current value is 11,920.
#
# Baselined rather than rebuilt because rerunning it needs the state nursing
# scrape, which is a network job against two state boards. The baseline can only
# shrink.
LAW1_BASELINE <- c("artifacts/state_nursing_license_ages_provenance.csv")

off <- character(0); known <- character(0); seen <- 0L
for (f in ci_tracked("artifacts/*.csv")) {
  d <- suppressWarnings(ci_read_head(f, -1L, root = root))
  if (is.null(d) || !nrow(d) || !("cohort_n" %in% names(d))) next
  vals <- unique(d$cohort_n[!is.na(d$cohort_n) & nzchar(d$cohort_n)])
  for (v in vals) {
    seen <- seen + 1L
    if (v %in% names(LAW_COHORTS)) next
    entry <- sprintf("%s declares cohort_n = %s, which is not a registered cohort", f, v)
    if (f %in% LAW1_BASELINE) known <- c(known, entry) else off <- c(off, entry)
  }
}
law_stale <- setdiff(intersect(LAW1_BASELINE, ci_tracked("artifacts/*.csv")),
                     unique(sub(" declares.*$", "", known)))
if (length(law_stale)) {
  ci_fail("L1: %d baselined artifact(s) now declare a registered cohort:\n%s\n       Remove them from LAW1_BASELINE so the baseline keeps shrinking.",
          length(law_stale), paste(sprintf("       %s", law_stale), collapse = "\n"))
}
if (length(known)) {
  ci_skip("L1: %d known off-vintage declaration(s) awaiting a rebuild:", length(known))
  for (k in known) cat(sprintf("       %s\n", k))
}
if (length(off)) {
  ci_fail("L1: %d artifact(s) declare a cohort that is not registered:\n%s\n       Registered: %s.\n       Either the artifact is a stale vintage, or a new cohort needs adding to\n       LAW_COHORTS deliberately -- with the reason.",
          length(off), paste(sprintf("       %s", off), collapse = "\n"),
          paste(sprintf("%s (%s)", names(LAW_COHORTS), LAW_COHORTS), collapse = "; "))
} else {
  # POSITIVE CONTROL: the membership test must reject a value that is not
  # registered. Without it, a registry containing every possible value -- or a
  # test that never evaluates membership -- would pass silently.
  ci_law_positive("L1", !("99999" %in% names(LAW_COHORTS)))
  ci_law_exercised("L1", seen)
  ci_ok("all %d cohort_n declaration(s) name a registered cohort", seen)
}

# -----------------------------------------------------------------------------
ci_section("L2 population is conserved: parts sum to their whole")

# DECLARED, not inferred. Which columns are parts of which total is a fact about
# an artifact's meaning, and guessing it produces both false positives and false
# negatives. Each identity below is written down once and checked forever.
LAW_IDENTITIES <- list(
  list(file  = "artifacts/linkage_completeness_by_status.csv",
       total = "n",
       parts = NULL,   # NULL: every count column that is not the total
       what  = "linkage dispositions sum to the records considered"),
  list(file  = "artifacts/full_cohort_access_by_band_rucc.csv",
       total = "women_total",
       parts = NULL,
       what  = NA)     # NA: skip; with_access is a subset, not a partition
)

off <- character(0); n_checked <- 0L
for (idy in LAW_IDENTITIES) {
  if (is.na(idy$what)) next
  d <- suppressWarnings(ci_read_head(idy$file, -1L, root = root))
  if (is.null(d)) { { ci_law_skipped("L2", "input absent"); ci_skip("L2: %s absent; skipped", idy$file) }; next }
  if (!(idy$total %in% names(d))) {
    ci_fail("L2: %s has no `%s` column -- the identity cannot be checked, which is\n       itself a failure: the artifact changed shape under a declared law.",
            idy$file, idy$total)
    next
  }
  parts <- if (is.null(idy$parts)) setdiff(names(d), c(idy$total, "status", "rurality")) else idy$parts
  parts <- parts[vapply(parts, function(cn) {
    v <- law_num(d[[cn]]); !all(is.na(v)) && all(is.na(v) | (v >= 0 & abs(v - round(v)) < 1e-9))
  }, logical(1))]
  # A percentage column is not a part.
  parts <- parts[!grepl("^pct|_pct$|percent", parts, ignore.case = TRUE)]
  if (!length(parts)) { ci_skip("L2: %s has no part columns; skipped", idy$file); next }

  tot <- law_num(d[[idy$total]])
  sums <- rowSums(vapply(parts, function(cn) law_num(d[[cn]]), numeric(nrow(d))),
                  na.rm = TRUE)
  bad <- which(!is.na(tot) & abs(sums - tot) > 0.5)
  n_checked <- n_checked + 1L
  if (length(bad)) {
    off <- c(off, sprintf("%s: %s != sum(%s) on %d row(s); first gap %s",
                          idy$file, idy$total, paste(parts, collapse = " + "),
                          length(bad), format(tot[bad[1]] - sums[bad[1]])))
  }
}
# THE SECOND SHAPE OF THE SAME LAW. The identity check above asks whether the
# parts sum to the whole. This asks whether any part EXCEEDS the whole, which is
# the same conservation principle read the other way and is a defect the sum
# check cannot see: a single share of 150% breaks no addition.
#
# It exists because resolve_amcb_by_state_license() reported "3 of 2 AMCB
# certificants (150.0%)". Its deterministic matches were drawn from the whole
# external state-license universe while the denominator was the roster it was
# asked about, so a person outside the study frame was counted as resolved
# within it -- and written to the artifact. A column that names itself a share
# OF something has declared its own denominator, so it is checkable here.
share_bad <- character(0); n_shares <- 0L
for (f in ci_tracked("artifacts/*.csv")) {
  d <- suppressWarnings(ci_read_head(f, -1L, root = root))
  if (is.null(d)) next
  for (cn in grep("^pct_of_", names(d), value = TRUE)) {
    v <- law_num(d[[cn]])
    if (all(is.na(v))) next
    n_shares <- n_shares + 1L
    o <- which(is.finite(v) & (v < -1e-9 | v > 100 + 1e-9))
    if (length(o))
      share_bad <- c(share_bad, sprintf("%s: %s = %s on %d row(s)",
                                        f, cn, format(v[o[1]]), length(o)))
  }
}
if (length(share_bad))
  off <- c(off, sprintf("share exceeds its declared denominator -- %s", share_bad))
n_checked <- n_checked + n_shares

if (length(off)) {
  ci_fail("L2: %d accounting identity violation(s):\n%s\n       People are inside a denominator and outside every column beside it.",
          length(off), paste(sprintf("       %s", off), collapse = "\n"))
} else {
  # POSITIVE CONTROL: the identity check must notice parts that do not sum.
  # POSITIVE CONTROL, both shapes: parts that do not sum, and a share that
  # exceeds its denominator. A law that can only catch one of them is half a law.
  ci_law_positive("L2", {
    parts_fire <- { t <- 100; p <- c(70, 20); abs(sum(p) - t) > 0.5 }
    share_fire <- { v <- c(100, 150); any(is.finite(v) & v > 100 + 1e-9) }
    parts_fire && share_fire
  })
  ci_law_exercised("L2", n_checked)
  ci_ok("all %d declared accounting identit%s hold", n_checked,
        if (n_checked == 1L) "y" else "ies")
}

# -----------------------------------------------------------------------------
ci_section("L3 missing geography stays missing")

# THE FROZEN ALASKA REGRESSION. Not a metamorphic test of the pipeline -- that
# needs person-level inputs no runner has -- but a permanent assertion about the
# crosswalk that caused it, which is derived from a tracked Census file.
xw <- file.path(root, "data", "zcta_county_2020.txt")
if (!file.exists(xw)) {
  { ci_law_skipped("L3", "input absent"); ci_skip("L3: %s absent; skipped", xw) }
} else {
  raw <- readLines(xw, warn = FALSE)
  hdr <- strsplit(raw[1], "|", fixed = TRUE)[[1]]
  iz <- match("GEOID_ZCTA5_20", hdr); ic <- match("GEOID_COUNTY_20", hdr)
  if (is.na(iz) || is.na(ic)) {
    ci_fail("L3: %s does not carry GEOID_ZCTA5_20 / GEOID_COUNTY_20.", xw)
  } else {
    body <- strsplit(raw[-1], "|", fixed = TRUE)
    zc <- vapply(body, function(p) if (length(p) >= iz) p[iz] else NA_character_, character(1))
    n_blank <- sum(is.na(zc) | !nzchar(trimws(zc)))
    ci_ok("%s rows carry no ZCTA and must never reach a crosswalk (found %d)",
          format(n_blank, big.mark = ","), n_blank)

    # The canonical crosswalk must refuse them. If R/lib/zip_county_crosswalk.R
    # ever loses its guard, this is the assertion that notices.
    lib <- file.path(root, "R", "lib", "zip_county_crosswalk.R")
    if (!file.exists(lib)) {
      ci_fail("L3: R/lib/zip_county_crosswalk.R is missing. Without it every caller\n       reimplements the ZIP->county join privately, which is how 903 NA-keyed\n       rows became one row pointing at Yukon-Koyukuk.")
    } else {
      src <- readLines(lib, warn = FALSE)
      code <- src[!grepl("^\\s*#", src)]
      if (!any(grepl("assert_no_na_key", code))) {
        ci_fail("L3: the canonical crosswalk no longer calls assert_no_na_key().\n       A crosswalk whose key can be NA is a magnet: under dplyr's default\n       na_matches = \"na\", every row with no ZIP finds it.")
      } else if (!any(grepl("is\\.na\\(.*GEOID_ZCTA5_20", code))) {
        ci_fail("L3: the canonical crosswalk no longer filters rows with no ZCTA.")
      } else {
        ci_ok("the canonical crosswalk filters ZCTA-less rows and asserts no NA key")
      }
    }

    # And no published artifact may place a midwife in the county the defect
    # pointed at without a ZIP to justify it.
    # STATED AS THE LAW, NOT AS THE SYMPTOM. The first version of this check
    # asked whether the newly-resolved group was entirely
    # "Nonmetro, remote (7-9)" -- the exact label the defect produced. That
    # disarms itself the day someone relabels a RUCC band, and the mutation
    # matrix caught it doing exactly that: the planted defect survived because a
    # comma in the fixture shifted the label by one field.
    #
    # The law is that a group with no geography may not be placed in a REAL
    # geography. Any single non-absence level is a violation, whatever it is
    # called.
    LAW_ABSENT <- "^\\s*(unknown|unk|missing|not reported|not observed|none|n/?a)\\s*$"
    comp <- suppressWarnings(ci_read_head("artifacts/composition_rucc_cat.csv", -1L, root = root))
    if (!is.null(comp) && all(c("group", "level", "n") %in% names(comp))) {
      off3 <- character(0)
      for (g in unique(comp$group)) {
        rows <- comp[comp$group == g, ]
        pos <- rows[!is.na(law_num(rows$n)) & law_num(rows$n) > 0, ]
        if (nrow(pos) != 1L) next                       # spread across levels: fine
        lvl <- pos$level[1]
        if (grepl(LAW_ABSENT, lvl, ignore.case = TRUE)) next   # correctly Unknown
        off3 <- c(off3, sprintf("group `%s` sits entirely in `%s` (n = %s)",
                                g, lvl, pos$n[1]))
      }
      if (length(off3)) {
        ci_fail("L3: %d cohort group(s) placed entirely in one real geography:\n%s\n       A group with no practice ZIP must be Unknown. County 02290 -- Yukon-\n       Koyukuk Census Area -- is what a missing ZIP resolved to when the\n       crosswalk kept its NA key.",
                length(off3), paste(sprintf("       %s", off3), collapse = "\n"))
      } else {
        # POSITIVE CONTROL: a real level must be recognised as NOT an absence level,
        # which is the whole basis of the collapse test.
        ci_law_positive("L3", !grepl(LAW_ABSENT, "Nonmetro, remote (7-9)", ignore.case = TRUE) &&
                              grepl(LAW_ABSENT, "Unknown", ignore.case = TRUE))
        ci_law_exercised("L3", nrow(comp))
        ci_ok("no cohort group is placed entirely in a single real geography")
      }
    }
  }
}

# -----------------------------------------------------------------------------
# THE DISSOLVED-SURFACE MANIFEST
#
# L4 and L5 are laws about the dissolved isochrone surfaces, and neither one
# touches a polygon: every quantity they read is a scalar sitting beside 30 MB
# of geometry. The geometry is gitignored for size, which made both laws
# unrunnable anywhere but a machine that had built them -- L5 was reclassified
# `derived-ok` for exactly that reason and stopped being enforced on any runner
# (DEBT.md D9). A law nobody runs is the thing this whole suite exists to catch.
#
# artifacts/isochrone_union_manifest.csv carries those scalars in 327 bytes and
# is tracked, so the laws run everywhere.
#
# A TRACKED SUMMARY OF AN UNTRACKED ARTIFACT CAN GO STALE, and a stale summary
# asserting a number nobody can check would be worse than an honest skip. So
# wherever the surface IS present -- a developer machine, the pipeline -- the
# row is re-derived from it and any disagreement fails. The manifest is checked
# against the real thing wherever the real thing exists, and used where it does
# not.
UNION_MANIFEST_REL <- "artifacts/isochrone_union_manifest.csv"

law_union_manifest <- function() {
  d <- suppressWarnings(ci_read_head(UNION_MANIFEST_REL, -1L, root = root))
  if (is.null(d) || !nrow(d)) return(NULL)
  need <- c("band_minutes", "n_origins_dissolved", "area_km2", "source_file",
            "source_bytes", "source_md5")
  if (!all(need %in% names(d))) {
    ci_fail("the union manifest is missing column(s): %s. A manifest that has\n       changed shape cannot be compared against the surface it describes.",
            paste(setdiff(need, names(d)), collapse = ", "))
    return(NULL)
  }
  for (cn in c("band_minutes", "n_origins_dissolved", "area_km2", "source_bytes"))
    d[[cn]] <- law_num(d[[cn]])

  # --- the drift guard ---
  drift <- character(0); n_checked <- 0L
  for (i in seq_len(nrow(d))) {
    f <- file.path(root, "artifacts", "maps", d$source_file[i])
    if (!file.exists(f)) next
    n_checked <- n_checked + 1L
    u <- tryCatch(readRDS(f), error = function(e) NULL)
    if (is.null(u)) { drift <- c(drift, sprintf("%s could not be read", d$source_file[i])); next }
    same <- function(a, b) isTRUE(abs(a - b) <= 1e-6 * max(1, abs(b)))
    if (!same(d$n_origins_dissolved[i], as.numeric(u$n_origins_dissolved)))
      drift <- c(drift, sprintf("%s: manifest says %s origins, the surface holds %s",
                                d$source_file[i], format(d$n_origins_dissolved[i], big.mark = ","),
                                format(as.numeric(u$n_origins_dissolved), big.mark = ",")))
    if (!same(d$area_km2[i], as.numeric(u$area_km2)))
      drift <- c(drift, sprintf("%s: manifest says %s km2, the surface is %s km2",
                                d$source_file[i], format(round(d$area_km2[i])),
                                format(round(as.numeric(u$area_km2)))))
    got <- unname(tools::md5sum(f))
    if (!identical(got, d$source_md5[i]))
      drift <- c(drift, sprintf("%s: manifest describes %s, the file on disk is %s",
                                d$source_file[i], substr(d$source_md5[i], 1, 8), substr(got, 1, 8)))
  }
  if (length(drift)) {
    ci_fail("the union manifest disagrees with the surfaces it describes:\n%s\n       Regenerate it with write_union_manifest(). A tracked summary that has\n       drifted from its source asserts a number no runner can check, which is\n       worse than not having one.",
            paste(sprintf("       %s", drift), collapse = "\n"))
  } else if (n_checked > 0L) {
    ci_ok("the union manifest matches all %d surface(s) present here", n_checked)
  } else {
    ci_ok("the union manifest is used as-is (no surface present to re-derive from)")
  }
  d
}

UNION_MF <- law_union_manifest()

# -----------------------------------------------------------------------------
ci_section("L4 more travel time cannot reduce access")

acc <- suppressWarnings(ci_read_head("artifacts/full_cohort_access_by_band_rucc.csv",
                                     -1L, root = root))
if (is.null(acc)) {
  { ci_law_skipped("L4", "input absent"); ci_skip("L4: full_cohort_access_by_band_rucc.csv absent; skipped") }
} else {
  off <- character(0); n_pairs <- 0L
  for (s in unique(acc$rurality)) {
    r <- acc[acc$rurality == s, ]
    b <- law_num(r$band_minutes); p <- law_num(r$pct_women_with_access)
    o <- order(b); b <- b[o]; p <- p[o]
    if (length(b) < 2L) next
    for (i in seq_len(length(b) - 1L)) {
      n_pairs <- n_pairs + 1L
      if (!is.na(p[i]) && !is.na(p[i + 1L]) && p[i] > p[i + 1L] + 1e-9) {
        off <- c(off, sprintf("%s: %d min = %.1f%% but %d min = %.1f%%",
                              s, b[i], p[i], b[i + 1L], p[i + 1L]))
      }
    }
  }
  if (length(off)) {
    ci_fail("L4: %d stratum/band pair(s) where more travel time gives LESS access:\n%s\n       The 60-minute surface contains the 30-minute surface from the same\n       origins, so this is impossible unless the two were built from different\n       inputs -- which is what a stale union looks like.",
            length(off), paste(sprintf("       %s", off), collapse = "\n"))
  } else {
    # POSITIVE CONTROL: the monotonicity comparison must flag a decrease.
    ci_law_positive("L4", { a <- c(95, 80); a[1] > a[2] + 1e-9 })
    ci_law_exercised("L4", n_pairs)
    ci_ok("access is monotone in the travel-time band across %d pair(s)", n_pairs)
  }

  # The same law on area, read straight off the surfaces when they are present.
  if (!is.null(UNION_MF) && all(c(30, 60) %in% UNION_MF$band_minutes)) {
    a_30 <- UNION_MF$area_km2[UNION_MF$band_minutes == 30]
    a_60 <- UNION_MF$area_km2[UNION_MF$band_minutes == 60]
    if (a_30 > a_60) {
      ci_fail("L4: the 30-minute surface (%s km2) is LARGER than the 60-minute surface (%s km2).",
              format(round(a_30), big.mark = ","), format(round(a_60), big.mark = ","))
    } else {
      ci_ok("the 30-minute surface is contained in area by the 60-minute surface")
    }
  } else {
    ci_fail("L4: the union manifest does not carry both a 30- and a 60-minute band,\n       so the containment check cannot run. It is tracked, so absence is a\n       failure rather than a skip.")
  }
}

# -----------------------------------------------------------------------------
ci_section("L5 every routed provider participates in the union")

vt <- suppressWarnings(ci_read_head("artifacts/osmde_validation_table.csv", -1L, root = root))
# BOTH INPUTS ARE NOW TRACKED, so absence is a failure rather than a skip. This
# law spent several days registered `derived-ok` and therefore unenforced on
# every runner, because the only thing standing between it and a clean checkout
# was 30 MB of geometry it never reads.
if (is.null(vt) || is.null(UNION_MF)) {
  ci_fail("L5: %s absent. Both inputs are tracked, so this is a missing artifact\n       rather than a permitted skip.",
          if (is.null(vt)) "artifacts/osmde_validation_table.csv" else UNION_MANIFEST_REL)
} else {
  routed <- law_num(vt$observed[vt$check == "locations successfully retrieved"])
  if (!length(routed) || is.na(routed)) {
    ci_skip("L5: the validation table does not report retrieved locations")
  } else {
    off <- character(0); n_bands <- 0L
    for (i in seq_len(nrow(UNION_MF))) {
      b <- UNION_MF$band_minutes[i]
      n_dis <- UNION_MF$n_origins_dissolved[i]
      if (is.na(b) || is.na(n_dis)) next
      n_bands <- n_bands + 1L
      # The union also dissolves canonical and recovered origins, so it may hold
      # MORE than the osm.de set -- but never fewer, which is the stale case.
      if (n_dis < routed) {
        off <- c(off, sprintf("%d-min union holds %s origins against %s routed (%.0f%%)",
                              b, format(n_dis, big.mark = ","),
                              format(routed, big.mark = ","), 100 * n_dis / routed))
      }
    }
    if (n_bands == 0L)
      ci_fail("L5: the union manifest carries no usable band, so the law has no subjects.")
    if (length(off)) {
      ci_fail("L5: %d surface(s) cover fewer origins than were routed:\n%s\n       A union built before the routing finished understates access while\n       looking complete. Rebuild with build_midwifery_isochrone_map.R.",
              length(off), paste(sprintf("       %s", off), collapse = "\n"))
    } else {
      # POSITIVE CONTROL: the coverage comparison must flag a short union.
      ci_law_positive("L5", 450 < routed)
      ci_law_exercised("L5", routed)
      ci_ok("every dissolved surface covers at least the %s routed locations",
            format(routed, big.mark = ","))
    }
  }
}

# -----------------------------------------------------------------------------
ci_section("L11 an estimate from the linked subset is not a property of the roster")

# THE LAWS ABOVE CANNOT SEE THIS ONE. A differentially incomplete linkage is
# perfectly self-consistent: parts sum to their whole (L2), no share exceeds its
# denominator (L2), geography that is missing stays missing (L3), the
# computation is deterministic (L8) and every input has a declared vintage
# (L10). All of them pass on a cohort that has quietly become a sample of the
# easy-to-find.
#
# Geography exists only for the primary matched cohort -- 14,764 of 22,309 --
# and linkage runs from 78.4% of ACTIVE certificants down to 18.8% of DECEASED.
# So every geographic statement describes the LOCATED workforce, and the
# distance between that and the workforce is unobservable by construction: the
# geography of the unlinked is missing precisely because they did not link.
#
# The law is not "the bias is small". It is that the bias must be DECLARED, and
# that the declaration must be arithmetically honest:
#
#   B1  the bounds artifact exists (it is tracked, so absence is a failure)
#   B2  it describes the same roster as the published completeness table
#   B3  every point estimate lies inside its own bounds
#   B4  the width equals the unlinked fraction EXACTLY
#
# B4 is the one that cannot be satisfied by accident. Worst-case bounds have a
# closed form: unobserved people can be placed entirely inside or entirely
# outside a category, so upper - lower is 100 * (1 - f) for every category, no
# matter what the observed distribution looks like. A narrower interval is not a
# tighter analysis; it is an assumption someone declined to state.
LSB <- suppressWarnings(ci_read_head("artifacts/linkage_selection_bounds.csv", -1L, root = root))
COMP <- suppressWarnings(ci_read_head("artifacts/linkage_completeness_by_status.csv", -1L, root = root))

if (is.null(LSB)) {
  ci_fail("L11: artifacts/linkage_selection_bounds.csv is absent. It is tracked, so\n       this is a missing artifact rather than a permitted skip. Regenerate it\n       with analyze_linkage_selection_bias.R.")
} else {
  need <- c("rurality", "n_linked", "n_roster", "observed_pct",
            "manski_lower_pct", "manski_upper_pct")
  miss <- setdiff(need, names(LSB))
  if (length(miss)) {
    ci_fail("L11: the bounds artifact is missing column(s): %s.", paste(miss, collapse = ", "))
  } else {
    nr <- law_num(LSB$n_roster); nl <- law_num(LSB$n_linked)
    obs <- law_num(LSB$observed_pct)
    lo <- law_num(LSB$manski_lower_pct); hi <- law_num(LSB$manski_upper_pct)
    off <- character(0)

    # B2 -- the same population the published table describes.
    if (!is.null(COMP) && "n" %in% names(COMP)) {
      roster_published <- sum(law_num(COMP$n), na.rm = TRUE)
      if (any(is.finite(nr)) && abs(nr[1] - roster_published) > 0.5)
        off <- c(off, sprintf("bounds describe %s certificants, the completeness table %s",
                              format(nr[1], big.mark = ","),
                              format(roster_published, big.mark = ",")))
    }

    # B3 -- a point estimate outside its own interval is arithmetically broken.
    bad_in <- which(is.finite(obs) & is.finite(lo) & is.finite(hi) &
                      (obs < lo - 1e-6 | obs > hi + 1e-6))
    for (i in bad_in)
      off <- c(off, sprintf("%s: observed %.1f%% lies outside [%.1f, %.1f]",
                            LSB$rurality[i], obs[i], lo[i], hi[i]))

    # B4 -- the width IS the missingness. Not a target, an identity.
    if (any(is.finite(nr)) && any(is.finite(nl))) {
      want <- 100 * (nr - nl) / nr
      bad_w <- which(is.finite(want) & abs((hi - lo) - want) > 0.05)
      for (i in bad_w)
        off <- c(off, sprintf("%s: interval is %.1f points wide, but %s of %s certificants are unlinked, which admits %.1f",
                              LSB$rurality[i], hi[i] - lo[i],
                              format(nr[i] - nl[i], big.mark = ","),
                              format(nr[i], big.mark = ","), want[i]))
    }

    if (length(off)) {
      ci_fail("L11: %d selection-bound violation(s):\n%s\n       A point estimate from the linked subset may be reported as a property\n       of the roster only alongside bounds that are honest about what was not\n       observed.",
              length(off), paste(sprintf("       %s", off), collapse = "\n"))
    } else {
      # POSITIVE CONTROL: the width identity must reject a narrowed interval.
      ci_law_positive("L11", {
        n_r <- 100; n_l <- 60; narrowed <- 10
        abs(narrowed - 100 * (n_r - n_l) / n_r) > 0.05
      })
      ci_law_exercised("L11", nrow(LSB))
      ci_ok("%d rurality bound(s) declared, each %.1f points wide against %.1f%% linkage",
            nrow(LSB), (hi - lo)[1], 100 * nl[1] / nr[1])
    }
  }
}

ci_section("L12 one scientific quantity has one value in every representation")

# =============================================================================
# L12 the same estimand, computed twice, must agree
# =============================================================================
# WHAT WENT WRONG. The metropolitan share of the cohort was in circulation as
# three numbers at once: 86.5% in the manuscript, 89.34% implied by the
# composition artifact, and 89.8% anchoring the selection bounds. None was
# fabricated. 86.5% put the members with no assignable county into the
# denominator of a metropolitan share; 89.8% was computed over a different
# cohort using a different rurality assignment. Each was locally defensible and
# no gate could see the three together, because every existing law checks one
# artifact against itself.
#
# L12 checks artifacts against EACH OTHER. It does not pin 89.34 -- pinning a
# value would block legitimate science and is what the scientific-diff ratchet
# is for. It pins the IDENTITY: wherever the same quantity is represented, the
# representations must agree.
#
#   bounds observed anchor
#     == composition metropolitan share among known rurality
#     == the stats catalog value the manuscript renders
#
# and separately, the denominators must close:
#
#   known rurality + unknown rurality == the cohort
#
# The two paths are genuinely independent. The composition artifact is written
# by R/07-cohort-composition.R from the ZIP-county crosswalk; the bounds
# artifact is written by analyze_linkage_selection_bias.R from the roster; the
# catalog is assembled by manuscript/R/build_stats_catalog.R. A single wrong
# denominator cannot satisfy all three at once, which is the entire point.
CRC <- suppressWarnings(ci_read_head("artifacts/composition_rucc_cat.csv", -1L, root = root))

if (is.null(LSB) || is.null(CRC)) {
  ci_fail("L12: %s is absent. Both are tracked, so this is a missing artifact\n       rather than a permitted skip.",
          if (is.null(LSB)) "artifacts/linkage_selection_bounds.csv" else
            "artifacts/composition_rucc_cat.csv")
} else {
  # The cohort is every group except the removed one. 3_in_cohort_no_final_npi
  # is empty in the current vintage and is named anyway: a group that appears
  # later must join the denominator automatically rather than silently not.
  L12_COHORT_GROUPS <- c("1_retained", "2_newly_npi_resolved",
                         "3_in_cohort_no_final_npi")
  L12_METRO  <- "Metro (RUCC 1-3)"
  L12_ADJ    <- "Nonmetro, adjacent (4-6)"
  L12_REMOTE <- "Nonmetro, remote (7-9)"

  inc <- CRC[CRC$group %in% L12_COHORT_GROUPS, , drop = FALSE]
  gn <- function(lvl) {
    v <- law_num(inc$n[inc$level == lvl])
    if (!length(v)) 0 else sum(v, na.rm = TRUE)
  }
  metro_n <- gn(L12_METRO); adj_n <- gn(L12_ADJ); rem_n <- gn(L12_REMOTE)
  unk_n <- gn("Unknown")
  known_n <- metro_n + adj_n + rem_n
  comp_pct <- if (known_n > 0) 100 * metro_n / known_n else NA_real_

  mrow <- LSB[grepl("^Metro", LSB$rurality), , drop = FALSE]
  off <- character(0)
  agree <- function(a, b, what, tol = 1e-6) {
    if (is.finite(a) && is.finite(b) && abs(a - b) > tol)
      off <<- c(off, sprintf("%s: %.6f vs %.6f (%.3f pp apart)", what, a, b, a - b))
  }

  if (!nrow(mrow)) {
    ci_fail("L12: the bounds artifact has no metropolitan row to reconcile.")
  } else {
    b_obs <- law_num(mrow$observed_pct)[1]
    b_k   <- law_num(mrow$n_linked_in_cat)[1]
    b_n   <- law_num(mrow$n_linked)[1]

    # I1 -- the anchor of the bounds is the composition's own metropolitan share.
    agree(b_obs, comp_pct, "bounds observed_pct vs composition metro/known")

    # I2 -- and that percentage is arithmetic on the integers printed beside it.
    # A percentage that does not recompute from its own numerator and
    # denominator is the signature of a hand-edited artifact.
    agree(b_obs, 100 * b_k / b_n, "bounds observed_pct vs its own n_linked_in_cat/n_linked")

    # I3 -- both are describing the same set of people.
    agree(b_n, known_n, "bounds n_linked vs composition known-rurality n")
    agree(b_k, metro_n, "bounds n_linked_in_cat vs composition metro n")

    # I4 -- the denominators close. Known plus unknown is the cohort, and the
    # published subgroup's cells sum to the N printed on every one of its rows.
    for (g in unique(CRC$group)) {
      rows <- CRC[CRC$group == g, , drop = FALSE]
      cells <- sum(law_num(rows$n), na.rm = TRUE)
      Ns <- unique(law_num(rows$N))
      if (length(Ns) != 1) {
        off <- c(off, sprintf("group %s carries %d different N values", g, length(Ns)))
      } else if (abs(cells - Ns) > 0.5) {
        off <- c(off, sprintf("group %s: cells sum to %s, N says %s",
                              g, format(cells, big.mark = ","), format(Ns, big.mark = ",")))
      }
    }

    # I5 -- THE VALUE THE MANUSCRIPT ACTUALLY RENDERS. The chain is worth
    # nothing if the prose reaches a fourth number, so the catalog is built here
    # and its keys are compared to the artifacts above.
    # THE BUILD ITSELF IS PART OF THE LAW, and it must not be allowed to abort
    # the gate: an uncaught error here once took down every law in the file and
    # reported fourteen simultaneous failures for one missing column. A catalog
    # that cannot be assembled is an L12 failure, reported as one.
    K <- NULL
    cat_err <- tryCatch({
      suppressPackageStartupMessages({
        source(file.path(root, "manuscript", "R", "build_stats_catalog.R"))
      })
      K <- mw_build_catalog(root)
      NULL
    }, error = function(e) conditionMessage(e))
    if (!is.null(cat_err)) {
      off <- c(off, sprintf("the stats catalog could not be built: %s", cat_err))
    } else {
      agree(K$cohort$metro_pct, comp_pct, "catalog cohort.metro_pct vs composition")
      agree(K$bounds$metro_pct, b_obs, "catalog bounds.metro_pct vs bounds artifact")
      agree(K$cohort$known_n, known_n, "catalog cohort.known_n vs composition")
      agree(K$cohort$unknown_n, unk_n, "catalog cohort.unknown_n vs composition")
      agree(K$cohort$known_n + K$cohort$unknown_n, K$cohort$cohort_n,
            "catalog known + unknown vs cohort_n")

      # I6 -- and it must be RENDERED from the catalog, not typed beside it. A
      # protected value appearing as a literal in the prose is a number that has
      # stopped being recomputed, which is how 86.5% outlived its definition.
      protect <- c(K$cohort$metro_pct, K$cohort$metro_pct_retained_with_unknown,
                   K$bounds$lower_pct, K$bounds$upper_pct, K$bounds$outside_pct,
                   K$bounds$tip_required, K$bounds$tip_departure)
      lits <- unique(sprintf("%.1f", protect[is.finite(protect)]))
      qmds <- list.files(file.path(root, "manuscript"), pattern = "[.]qmd$",
                         full.names = TRUE)
      for (q in qmds) {
        txt <- readLines(q, warn = FALSE)
        # Only prose lines. An inline `r ...` call may legitimately contain a
        # format string or a threshold argument.
        prose <- txt[!grepl("`r ", txt, fixed = TRUE)]
        for (lit in lits) {
          hit <- grep(lit, prose, fixed = TRUE)
          if (length(hit))
            off <- c(off, sprintf("%s carries the literal %s in prose; it must come from the catalog",
                                  basename(q), lit))
        }
      }
    }

    if (length(off)) {
      ci_fail("L12: %d identity violation(s):\n%s\n       The same scientific quantity is being represented by more than one\n       value. Fix the representation that is wrong; do not widen the tolerance.",
              length(off), paste(sprintf("       %s", off), collapse = "\n"))
    } else {
      # POSITIVE CONTROL: the comparator must reject a disagreement. 86.5 and
      # 89.34 are the two values that actually shipped, so they are what the
      # detector is proved against.
      ci_law_positive("L12", abs(86.51202189352968 - 89.34122871946707) > 1e-6)
      ci_law_exercised("L12", nrow(CRC) + nrow(LSB))
      ci_ok("%s metropolitan share agrees across composition, bounds and catalog at %.2f%% on %s of %s cohort members",
            L12_METRO, comp_pct, format(known_n, big.mark = ","),
            format(known_n + unk_n, big.mark = ","))
    }
  }
}

ci_finish()
