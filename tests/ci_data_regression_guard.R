# =============================================================================
# Data regression guard: PUBLIC vs PRIVATE-OK, adapted from mufflyt/isochrones
# =============================================================================
# ci_artifact_contracts.R asks whether a published table is internally
# coherent (blocks sum to the cohort, a suppressed cell is not a zero). This
# file asks a different question: does the DATA COMMITTED TO THE REPO still
# say what it said, and do two independently-generated artifacts that claim
# the same fact still agree with each other. A join that fans out, a filter
# that flips, or a rebuild that silently drops a disposition can leave every
# existing gate green while the numbers a reader actually cites have moved.
#
# PUBLIC vs PRIVATE-OK, exactly the ~/isochrones distinction
# (test-data-regression-daily-guard.R, 2026-08-27/28), because the failure it
# guards against is real and specific:
#
#   PUBLIC       committed to the repo, must always be present on ANY
#                checkout that has this file. A skip on a PUBLIC input is
#                itself the regression -- ci_fail(), never ci_skip() -- the
#                same file that was there yesterday going missing today is
#                exactly the silent-loss failure mode this guard exists to
#                catch, and "the file was absent so the check quietly didn't
#                run" must not read as green.
#   PRIVATE-OK   gitignored by design (person-level: certification numbers,
#                names, NPIs). Genuinely absent on CI and on a fresh
#                checkout; present only on a machine that has run the real
#                pipeline. A skip here is the correct, expected outcome.
#
# Every check states what would have to break in the code or the data for it
# to fire, so a future reader can tell "this artifact was legitimately
# regenerated, update the pin" from "something is actually wrong."
#
# Base R + a JSON reader already used elsewhere in this suite. Runs in
# seconds; no network, no gitignored input required to exercise the PUBLIC
# checks.
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."

source(file.path(root, "tests", "ci_report.R"))

p <- function(...) file.path(root, ...)

read_json <- function(path) {
  tryCatch(jsonlite::fromJSON(path, simplifyVector = TRUE),
           error = function(e) NULL)
}

# -----------------------------------------------------------------------------
ci_section("D1 linkage_manifest.json: dispositions sum to the frozen roster total")

# PUBLIC. Frozen 2026-08-23; this is a point-in-time record of one linkage
# run, not something re-derived on every render, so exact equality is
# correct here -- a mismatch means the manifest itself was hand-edited or
# regenerated without updating total_rows, either of which is worth knowing
# about immediately rather than at publication time.
lm_path <- p("artifacts", "linkage_manifest.json")
if (!file.exists(lm_path)) {
  ci_fail("D1: %s is committed and absent -- PUBLIC artifact went missing", lm_path)
} else {
  lm <- read_json(lm_path)
  if (is.null(lm) || is.null(lm$linkage$dispositions) || is.null(lm$linkage$total_rows)) {
    ci_fail("D1: linkage_manifest.json parsed but is missing linkage$dispositions or linkage$total_rows")
  } else {
    disp <- unlist(lm$linkage$dispositions)
    s <- sum(disp)
    if (s != lm$linkage$total_rows) {
      ci_fail("D1: dispositions sum to %s but total_rows is %s -- a disposition was added, dropped, or double-counted",
              format(s, big.mark = ","), format(lm$linkage$total_rows, big.mark = ","))
    } else {
      ci_ok("dispositions sum to total_rows = %s across %d categories",
            format(s, big.mark = ","), length(disp))
    }
  }
}

# -----------------------------------------------------------------------------
ci_section("D2 two independently-generated artifacts agree on the same dispositions")

# PUBLIC, cross-artifact. linkage_manifest.json is written once at freeze
# time by the linkage script; linkage_completeness_by_status.csv is written
# by a different downstream step that re-derives the same seven counts
# broken out by certification status. If a rebuild of one moves without the
# other, they are describing two different linkages under one shared name --
# the exact class of silent divergence three disagreeing linkage figures
# once caused in this repo's own prose (see docs/ADVERSARIAL_LOOP_LEDGER.md,
# manuscript/R/build_stats_catalog.R's header).
lc_path <- p("artifacts", "linkage_completeness_by_status.csv")
if (!file.exists(lm_path) || !file.exists(lc_path)) {
  ci_fail("D2: linkage_manifest.json and/or linkage_completeness_by_status.csv is committed and absent")
} else {
  lc <- ci_read_head(sub("^\\./", "", lc_path), root = root)
  lm <- read_json(lm_path)
  disp_cols <- c("ambiguous_contested_npi", "ambiguous_tied_names",
                 "ambiguous_unruled_out_component",
                 "candidate_class5_held_out_of_cohort",
                 "matched", "matched_nursing_taxonomy", "unmatched")
  missing_cols <- setdiff(disp_cols, names(lc))
  if (is.null(lc) || length(missing_cols)) {
    ci_fail("D2: linkage_completeness_by_status.csv missing column(s): %s",
            paste(missing_cols, collapse = ", "))
  } else {
    lc_sums <- vapply(disp_cols, function(cc) sum(as.numeric(lc[[cc]])), numeric(1))
    lm_disp <- unlist(lm$linkage$dispositions)[disp_cols]
    diffs <- lc_sums - lm_disp
    off <- disp_cols[diffs != 0]
    if (length(off)) {
      ci_fail("D2: %d disposition(s) disagree between the two artifacts: %s",
              length(off), paste(sprintf("%s (status-file %s vs manifest %s)",
                                        off, lc_sums[off], lm_disp[off]), collapse = "; "))
    } else {
      ci_ok("all %d dispositions agree exactly between linkage_manifest.json and linkage_completeness_by_status.csv",
            length(disp_cols))
    }
  }
}

# -----------------------------------------------------------------------------
ci_section("D3 the FROZEN crosswalk's own manifest agrees with the linkage manifest")

# PUBLIC, cross-artifact, and a tolerance band rather than exact equality:
# a refreeze can legitimately add a handful of newly-resolved NPIs (this
# repo's own history: 16,892 -> 16,898 on 2026-08-10), so artifact_rows is
# allowed to drift within a band, but class5_candidates_held_out is a count
# of a specific, named disposition and must match the linkage manifest's
# own count of the same thing exactly -- these are not two different
# numbers that happen to be close, they are the same fact recorded twice.
frozen_manifest_path <- p("artifacts", "amcb_npi_linkage_FROZEN.csv.manifest.json")
if (!file.exists(frozen_manifest_path)) {
  ci_fail("D3: %s is committed and absent -- PUBLIC artifact went missing", frozen_manifest_path)
} else if (!file.exists(lm_path)) {
  ci_fail("D3: linkage_manifest.json is committed and absent")
} else {
  fm <- read_json(frozen_manifest_path)
  lm <- read_json(lm_path)
  if (is.null(fm$class5_candidates_held_out) ||
        is.null(lm$linkage$dispositions$candidate_class5_held_out_of_cohort)) {
    ci_fail("D3: expected key missing from one of the two manifests")
  } else if (fm$class5_candidates_held_out != lm$linkage$dispositions$candidate_class5_held_out_of_cohort) {
    ci_fail("D3: class5_candidates_held_out is %s in the FROZEN manifest but %s in linkage_manifest.json",
            fm$class5_candidates_held_out, lm$linkage$dispositions$candidate_class5_held_out_of_cohort)
  } else {
    ci_ok("class5_candidates_held_out = %s agrees between both manifests", fm$class5_candidates_held_out)
    if (!is.null(fm$artifact_rows)) {
      if (fm$artifact_rows < 20000L || fm$artifact_rows > 25000L) {
        ci_fail("D3: FROZEN manifest artifact_rows = %s is outside the plausible band (20,000-25,000) around the 22,309-row AMCB roster",
                format(fm$artifact_rows, big.mark = ","))
      } else {
        ci_ok("artifact_rows = %s within the plausible band", format(fm$artifact_rows, big.mark = ","))
      }
    }
  }
}

# -----------------------------------------------------------------------------
ci_section("D4 composition tables: every group's rows sum to its own N")

# PUBLIC. Generalized across every composition_*.csv this repo publishes --
# each is a group/level/n/N/pct breakdown, and a code change that drops a
# level, double-counts a row, or divides by the wrong denominator shows up
# here as n not summing to N or pct not summing to 100, regardless of which
# composition file it happens to be.
comp_files <- ci_tracked("artifacts/composition_*.csv")
if (length(comp_files) == 0) {
  ci_fail("D4: no artifacts/composition_*.csv tracked -- expected at least composition_rucc_cat.csv and composition_status.csv")
} else {
  bad <- character(0)
  checked <- 0L
  for (f in comp_files) {
    d <- ci_read_head(f, root = root)
    if (is.null(d) || !all(c("group", "level", "n", "N", "pct") %in% names(d))) next
    checked <- checked + 1L
    n <- as.numeric(d$n); Nn <- as.numeric(d$N); pct <- as.numeric(d$pct)
    for (g in unique(d$group)) {
      idx <- d$group == g
      n_sum <- sum(n[idx], na.rm = TRUE)
      N_g <- unique(Nn[idx])
      if (length(N_g) != 1L || n_sum != N_g) {
        bad <- c(bad, sprintf("%s group '%s': n sums to %s, N is %s",
                              basename(f), g, n_sum, paste(N_g, collapse = "/")))
      }
      pct_sum <- sum(pct[idx], na.rm = TRUE)
      if (abs(pct_sum - 100) > 0.1) {
        bad <- c(bad, sprintf("%s group '%s': pct sums to %.2f, not 100", basename(f), g, pct_sum))
      }
    }
  }
  if (checked == 0L) {
    ci_fail("D4: none of the %d composition_*.csv file(s) have the expected group/level/n/N/pct schema", length(comp_files))
  } else if (length(bad)) {
    ci_fail("D4: %d group(s) fail to reconcile across %d composition file(s):\n       %s",
            length(bad), checked, paste(bad, collapse = "\n       "))
  } else {
    ci_ok("every group in %d composition file(s) sums to its own N and closes to 100%%", checked)
  }
}

# -----------------------------------------------------------------------------
ci_section("D5 selection-bias bounds are internally ordered")

# PUBLIC. A Manski worst-case bound is only meaningful if lower <= observed
# <= upper; a code change that swaps a min/max, flips a filter, or divides
# by the wrong denominator can produce a numerically valid but logically
# inverted bound that no schema check would catch. This is a genuine
# data-quality invariant, not a fixed value, so it survives legitimate
# regeneration drift the way an exact pin would not.
bounds_path <- p("artifacts", "linkage_selection_bounds.csv")
if (!file.exists(bounds_path)) {
  ci_fail("D5: %s is committed and absent -- PUBLIC artifact went missing", bounds_path)
} else {
  b <- ci_read_head(sub("^\\./", "", "artifacts/linkage_selection_bounds.csv"), root = root)
  pairs <- list(
    c("manski_lower_pct", "observed_pct", "manski_upper_pct"),
    c("zip_lower_pct", "zip_observed_pct", "zip_upper_pct"),
    c("active_lower_pct", "active_observed_pct", "active_upper_pct")
  )
  bad <- character(0)
  for (trip in pairs) {
    if (!all(trip %in% names(b))) next
    lo <- as.numeric(b[[trip[1]]]); mid <- as.numeric(b[[trip[2]]]); hi <- as.numeric(b[[trip[3]]])
    ok <- is.na(mid) | (lo <= mid + 1e-9 & mid <= hi + 1e-9)
    if (!all(ok)) {
      bad <- c(bad, sprintf("%s: %d row(s) with lower > observed or observed > upper",
                            trip[2], sum(!ok)))
    }
  }
  if (length(bad)) {
    ci_fail("D5: %d bound triple(s) are not internally ordered: %s", length(bad), paste(bad, collapse = "; "))
  } else {
    ci_ok("every Manski bound triple present is ordered lower <= observed <= upper, for every row")
  }
}

# -----------------------------------------------------------------------------
ci_section("D6 README's headline roster count matches the linkage manifest")

# PUBLIC, doc-vs-data drift. README.md states "22,309 certificants" in prose
# at several points; linkage_manifest.json's total_rows is the number those
# claims are actually about. A regeneration that moves the real count
# without anyone updating the prose is exactly the kind of drift a reader
# has no way to detect by eye.
readme_path <- p("README.md")
if (!file.exists(readme_path) || !file.exists(lm_path)) {
  ci_fail("D6: README.md and/or linkage_manifest.json is committed and absent")
} else {
  readme <- readLines(readme_path, warn = FALSE)
  cited <- unique(regmatches(readme, regexpr("22,309", readme, fixed = TRUE)))
  lm <- read_json(lm_path)
  if (length(cited) == 0L) {
    ci_fail("D6: README.md no longer cites the roster count at all -- expected \"22,309\" to appear")
  } else if (as.numeric(gsub(",", "", cited[[1]])) != lm$linkage$total_rows) {
    ci_fail("D6: README.md cites %s but linkage_manifest.json's total_rows is %s",
            cited[[1]], format(lm$linkage$total_rows, big.mark = ","))
  } else {
    ci_ok("README.md's cited roster count (%s) matches linkage_manifest.json", cited[[1]])
  }
}

# -----------------------------------------------------------------------------
ci_section("D7 retired cohort count stays pinned and distinct from the current one")

# PUBLIC, the isochrones "retired cells" pattern. INPUT_FINGERPRINT.json
# freezes the cohort size (16,892) at the geography-guard step on
# 2026-08-08; amcb_npi_linkage_FROZEN.csv.manifest.json records a LATER
# refreeze the same week that added six members (16,898, see that file's
# own net_membership_change). Both numbers are real and both are correctly
# committed -- the failure this guards against is someone years from now
# reading one out of context and treating it as interchangeable with the
# other, or a future edit silently making them equal (which would mean one
# of the two frozen records was overwritten rather than superseded in
# place, per docs/TECHNICAL_APPENDIX_REPRODUCIBILITY.md).
fingerprint_path <- p("artifacts", "frozen_cohort", "INPUT_FINGERPRINT.json")
if (!file.exists(fingerprint_path)) {
  ci_fail("D7: %s is committed and absent -- PUBLIC artifact went missing", fingerprint_path)
} else if (!file.exists(frozen_manifest_path)) {
  ci_fail("D7: amcb_npi_linkage_FROZEN.csv.manifest.json is committed and absent")
} else {
  fp <- read_json(fingerprint_path)
  fm <- read_json(frozen_manifest_path)
  if (is.null(fp$rows) || is.null(fm$cohort_members)) {
    ci_fail("D7: expected 'rows' or 'cohort_members' key missing")
  } else if (fp$rows != 16892L) {
    ci_fail("D7: INPUT_FINGERPRINT.json's frozen rows moved from 16,892 to %s -- if this is a deliberate new freeze, update this pin and say so in the commit message",
            format(fp$rows, big.mark = ","))
  } else if (isTRUE(all.equal(fp$rows, fm$cohort_members))) {
    ci_fail("D7: the two frozen cohort counts (%s) have become identical -- one point-in-time record may have overwritten the other instead of coexisting",
            format(fp$rows, big.mark = ","))
  } else {
    ci_ok("retired count 16,892 (geography-guard freeze) stays pinned and distinct from %s (later refreeze)",
          format(fm$cohort_members, big.mark = ","))
  }
}

# -----------------------------------------------------------------------------
ci_section("D8 FROZEN linkage crosswalk (PRIVATE-OK): certification numbers unique, NPIs well-formed")

# PRIVATE-OK. Person-level, blanket-gitignored (.gitignore line ~334);
# genuinely absent on CI and on a fresh checkout, present only on a machine
# that has run the real linkage pipeline. A skip here is expected, not a
# failure -- unlike every PUBLIC section above.
frozen_xwalk_path <- p("artifacts", "amcb_npi_linkage_FROZEN.csv")
if (!file.exists(frozen_xwalk_path)) {
  ci_skip("amcb_npi_linkage_FROZEN.csv absent (PRIVATE-OK: person-level, gitignored; expected on CI and a fresh checkout)")
} else {
  x <- ci_read_head(sub("^\\./", "", "artifacts/amcb_npi_linkage_FROZEN.csv"), root = root)
  if (is.null(x) || !all(c("certification_number", "npi") %in% names(x))) {
    ci_fail("D8: amcb_npi_linkage_FROZEN.csv is present but missing certification_number or npi")
  } else {
    dup <- sum(duplicated(x$certification_number))
    npi <- x$npi[!is.na(x$npi) & nzchar(trimws(x$npi))]
    bad_npi <- sum(!grepl("^[0-9]{10}$", npi))
    if (dup > 0L) {
      ci_fail("D8: %d duplicated certification_number(s) in amcb_npi_linkage_FROZEN.csv", dup)
    } else if (bad_npi > 0L) {
      ci_fail("D8: %d non-10-digit npi value(s) among %d assigned", bad_npi, length(npi))
    } else {
      ci_ok("certification_number unique across %d rows; all %d assigned NPIs are 10-digit",
            nrow(x), length(npi))
    }
  }
}

# -----------------------------------------------------------------------------
ci_section("D9 analytic cohort (PRIVATE-OK): row count plausible, no duplicate certificants")

# PRIVATE-OK, same reasoning as D8: gitignored (.gitignore's
# /artifacts/frozen_cohort/analytic_cohort.csv line), genuinely absent
# unless the real pipeline has run here.
cohort_path <- p("artifacts", "frozen_cohort", "analytic_cohort.csv")
if (!file.exists(cohort_path)) {
  ci_skip("frozen_cohort/analytic_cohort.csv absent (PRIVATE-OK: person-level, gitignored; expected on CI and a fresh checkout)")
} else {
  d <- ci_read_head(sub("^\\./", "", "artifacts/frozen_cohort/analytic_cohort.csv"), root = root)
  if (is.null(d) || !("certification_number" %in% names(d))) {
    ci_fail("D9: analytic_cohort.csv is present but missing certification_number")
  } else {
    n <- nrow(d)
    dup <- sum(duplicated(d$certification_number))
    if (n < 10000L || n > 25000L) {
      ci_fail("D9: analytic_cohort.csv has %s rows, outside the plausible band (10,000-25,000)", format(n, big.mark = ","))
    } else if (dup > 0L) {
      ci_fail("D9: %d duplicated certification_number(s) in analytic_cohort.csv", dup)
    } else {
      ci_ok("%s rows, no duplicate certification_number", format(n, big.mark = ","))
    }
  }
}

# -----------------------------------------------------------------------------
ci_section("D10 provenance sidecars: schema stays well-formed on a sample")

# PUBLIC. write_with_provenance()'s own JSON contract (artifact, written_utc,
# inputs[].{path,sha256}) -- a change to that function that drops a field or
# writes a malformed hash would otherwise only surface the next time someone
# happens to open a sidecar by eye. Sampled, not exhaustive (this repo tracks
# 97+ sidecars and growing): a fixed, capped sample keeps this section fast
# while still exercising real, currently-committed files every run.
sidecars <- ci_tracked("artifacts/*.provenance.json")
if (length(sidecars) == 0) {
  ci_fail("D10: no artifacts/*.provenance.json tracked -- expected at least one")
} else {
  sample_n <- min(20L, length(sidecars))
  sample_files <- sidecars[seq_len(sample_n)]
  bad <- character(0)
  for (f in sample_files) {
    m <- read_json(p(f))
    if (is.null(m)) {
      bad <- c(bad, sprintf("%s: not valid JSON", f))
      next
    }
    need <- c("artifact", "written_utc", "inputs")
    missing <- setdiff(need, names(m))
    if (length(missing)) {
      bad <- c(bad, sprintf("%s: missing key(s) %s", f, paste(missing, collapse = ",")))
      next
    }
    if (length(m$inputs)) {
      hashes <- if (is.data.frame(m$inputs)) m$inputs$sha256 else vapply(m$inputs, function(i) i$sha256, character(1))
      malformed <- hashes[!grepl("^[0-9a-f]{64}$", hashes)]
      if (length(malformed)) {
        bad <- c(bad, sprintf("%s: %d input(s) with a non-64-hex-char sha256", f, length(malformed)))
      }
    }
  }
  if (length(bad)) {
    ci_fail("D10: %d of %d sampled sidecar(s) fail the write_with_provenance() schema:\n       %s",
            length(bad), sample_n, paste(bad, collapse = "\n       "))
  } else {
    ci_ok("%d of %d tracked provenance sidecars sampled: all well-formed JSON with valid sha256 input hashes",
          sample_n, length(sidecars))
  }
}

ci_finish()
