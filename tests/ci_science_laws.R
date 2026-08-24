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
#   L2  POPULATION IS CONSERVED. linkage_completeness_by_status.csv reported four
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
if (length(off)) {
  ci_fail("L2: %d accounting identity violation(s):\n%s\n       People are inside a denominator and outside every column beside it.",
          length(off), paste(sprintf("       %s", off), collapse = "\n"))
} else {
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
        ci_law_exercised("L3", nrow(comp))
        ci_ok("no cohort group is placed entirely in a single real geography")
      }
    }
  }
}

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
    ci_law_exercised("L4", n_pairs)
    ci_ok("access is monotone in the travel-time band across %d pair(s)", n_pairs)
  }

  # The same law on area, read straight off the surfaces when they are present.
  a30 <- file.path(root, "artifacts", "maps", "midwifery_isochrone_union_30min.rds")
  a60 <- file.path(root, "artifacts", "maps", "midwifery_isochrone_union_60min.rds")
  if (file.exists(a30) && file.exists(a60)) {
    s30 <- readRDS(a30); s60 <- readRDS(a60)
    if (s30$area_km2 > s60$area_km2) {
      ci_fail("L4: the 30-minute surface (%s km2) is LARGER than the 60-minute surface (%s km2).",
              format(round(s30$area_km2), big.mark = ","),
              format(round(s60$area_km2), big.mark = ","))
    } else {
      ci_ok("the 30-minute surface is contained in area by the 60-minute surface")
    }
  } else {
    ci_skip("L4: dissolved surfaces are gitignored and absent; area check skipped")
  }
}

# -----------------------------------------------------------------------------
ci_section("L5 every routed provider participates in the union")

vt <- suppressWarnings(ci_read_head("artifacts/osmde_validation_table.csv", -1L, root = root))
a30 <- file.path(root, "artifacts", "maps", "midwifery_isochrone_union_30min.rds")
if (is.null(vt) || !file.exists(a30)) {
  { ci_law_skipped("L5", "input absent"); ci_skip("L5: validation table or dissolved surface absent; skipped") }
} else {
  routed <- law_num(vt$observed[vt$check == "locations successfully retrieved"])
  if (!length(routed) || is.na(routed)) {
    ci_skip("L5: the validation table does not report retrieved locations")
  } else {
    off <- character(0)
    for (b in c(30, 60)) {
      f <- file.path(root, "artifacts", "maps",
                     sprintf("midwifery_isochrone_union_%dmin.rds", b))
      if (!file.exists(f)) next
      u <- readRDS(f)
      # The union also dissolves canonical and recovered origins, so it may hold
      # MORE than the osm.de set -- but never fewer, which is the stale case.
      if (u$n_origins_dissolved < routed) {
        off <- c(off, sprintf("%d-min union holds %s origins against %s routed (%.0f%%)",
                              b, format(u$n_origins_dissolved, big.mark = ","),
                              format(routed, big.mark = ","),
                              100 * u$n_origins_dissolved / routed))
      }
    }
    if (length(off)) {
      ci_fail("L5: %d surface(s) cover fewer origins than were routed:\n%s\n       A union built before the routing finished understates access while\n       looking complete. Rebuild with build_midwifery_isochrone_map.R.",
              length(off), paste(sprintf("       %s", off), collapse = "\n"))
    } else {
      ci_law_exercised("L5", routed)
      ci_ok("every dissolved surface covers at least the %s routed locations",
            format(routed, big.mark = ","))
    }
  }
}

ci_finish()
