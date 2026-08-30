#!/usr/bin/env Rscript
# =============================================================================
# Does ci_science_laws.R actually detect anything?
# =============================================================================
# A law that cannot be violated in a test is not a law, it is a sentence. This
# plants one defect per law in a scratch repository and asserts each is caught
# BY NAME -- exit status alone would let L2 take credit for what only L1 saw.
#
# The mutations are the ones that actually happened, shrunk to fixtures:
#
#   L1  a cohort silently off by one, and a whole superseded vintage
#   L2  a disposition column dropped, so the parts no longer reach the whole;
#       and a share that exceeds its own denominator -- the real 150% defect,
#       which breaks no addition and so is invisible to the sum rule
#   L3  the crosswalk guard removed; the ZCTA filter removed; and the
#       newly-resolved group placed back in remote-rural Alaska
#   L4  a 30-minute figure raised above its own 60-minute figure, and the two
#       surfaces swapped
#   L5  a union built from half the routed origins
#
# Near-misses are pinned too, because a law that fires on a legitimate case gets
# an exemption written for it and then it protects nothing.
#
# Reports N/N so a partial regression is visible as a number, not as a wall of
# ok lines someone skims.
# =============================================================================

root <- normalizePath(".")
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- normalizePath("..")

GATE   <- file.path(root, "tests", "ci_science_laws.R")
REPORT <- file.path(root, "tests", "ci_report.R")
local({
  e <- new.env(); sys.source(REPORT, envir = e)
  e$ci_law_evidence_header("tests/test_science_laws_detect.R")
})
LIB    <- file.path(root, "R", "lib", "zip_county_crosswalk.R")
# L12 compares the artifacts against the value the manuscript renders, so the
# catalog has to exist in the scratch repository too. Copied rather than
# stubbed: a stub would prove the comparison runs, not that the real assembler
# agrees with the real artifacts.
CATALOG <- file.path(root, "manuscript", "R", "build_stats_catalog.R")
stopifnot(file.exists(GATE), file.exists(REPORT), file.exists(LIB),
          file.exists(CATALOG))

caught <- 0L; planted <- 0L; allowed <- 0L; near <- 0L
failures <- character(0)
chk <- function(ok, m) { if (isTRUE(ok)) cat(sprintf("  ok   %s\n", m))
  else { failures <<- c(failures, m); cat(sprintf("  FAIL %s\n", m)) } }

# --- a scratch repository that satisfies every law ---------------------------
law_scaffold <- function(dir) {
  for (d in c("tests", "artifacts/maps", "R/lib", "data", "manuscript/R"))
    dir.create(file.path(dir, d), recursive = TRUE, showWarnings = FALSE)
  file.copy(GATE,    file.path(dir, "tests", "ci_science_laws.R"))
  file.copy(REPORT,  file.path(dir, "tests", "ci_report.R"))
  file.copy(LIB,     file.path(dir, "R", "lib", "zip_county_crosswalk.R"))
  file.copy(CATALOG, file.path(dir, "manuscript", "R", "build_stats_catalog.R"))

  # L1: a registered cohort
  writeLines(c("stage,cohort_n,n", "1,16892,100"),
             file.path(dir, "artifacts", "stage_progression_like_for_like.csv"))
  # L2: dispositions that sum to n
  # Carries every disposition the manuscript catalog reads, because L12 builds
  # that catalog here. A two-column fixture satisfied L2 and crashed the
  # catalog on a missing subscript, which took the whole gate down and made
  # every law in the file look broken at once.
  writeLines(c("status,n,matched,matched_nursing_taxonomy,ambiguous,unmatched,candidate_class5_held_out_of_cohort,pct_matched",
               "ACTIVE,100,70,10,5,10,5,70.0",
               "LAPSED,40,20,4,2,12,2,50.0",
               "DECEASED,10,0,1,1,7,1,0.0"),
             file.path(dir, "artifacts", "linkage_completeness_by_status.csv"))
  # L3: a ZCTA file with blank ZCTAs, and a composition table that says Unknown
  writeLines(c("GEOID_ZCTA5_20|GEOID_COUNTY_20|AREALAND_PART",
               "01001|01001|100", "|02290|500", "01002|01003|200"),
             file.path(dir, "data", "zcta_county_2020.txt"))
  # ALSO L12's fixture, and DERIVED to agree with the bounds table below: 75 of
  # the 90 with known rurality are metropolitan, so both artifacts must say
  # 83.33%. The first version of this scaffold gave them unrelated numbers, and
  # L12 -- whose entire subject is two artifacts disagreeing -- failed on the
  # clean scaffold before any defect was planted.
  writeLines(c("group,level,n,N,pct",
               "1_retained,Metro (RUCC 1-3),75,110,68.18181818181819",
               "1_retained,\"Nonmetro, adjacent (4-6)\",10,110,9.090909090909092",
               "1_retained,\"Nonmetro, remote (7-9)\",5,110,4.545454545454546",
               "1_retained,Unknown,20,110,18.181818181818183",
               "2_newly_npi_resolved,Unknown,40,40,100"),
             file.path(dir, "artifacts", "composition_rucc_cat.csv"))
  # L4: monotone access
  writeLines(c("rurality,band_minutes,women_with_access,women_total,pct_women_with_access",
               "Metro (RUCC 1-3),30,80,100,80.0",
               "Metro (RUCC 1-3),60,95,100,95.0"),
             file.path(dir, "artifacts", "full_cohort_access_by_band_rucc.csv"))
  # L11: bounds DERIVED from the completeness fixture above -- 150 certificants,
  # 90 matched, so 60 unlinked and every interval exactly 40 points wide.
  # Deliberately not a second completeness table: the first version of this
  # wrote its own, silently replaced L2's fixture with a single row, and broke
  # every law in the scaffold at once.
  # Full precision, not 83.3: L12 compares two independent computations of the
  # same quantity at 1e-6, and a rounded fixture would fail it for being rounded
  # rather than for being wrong.
  writeLines(c("rurality,n_linked_in_cat,n_linked,n_roster,observed_pct,manski_lower_pct,manski_upper_pct,zip_lower_pct,zip_upper_pct",
               "Metro,75,90,150,83.33333333333333,50,90,60,88",
               "Rural,15,90,150,16.666666666666668,10,50,8,40"),
             file.path(dir, "artifacts", "linkage_selection_bounds.csv"))

  # L13: a clean ledger -- every variable covers every group, and missingness is
  # even rather than concentrated. Two variables and six cells clears the
  # non-vacuity floor.
  writeLines(c("variable,group,group_n,n_observed,n_missing,pct_missing,top_level_pct",
               "rucc_cat,1_retained,100,98,2,2.0,80",
               "rucc_cat,2_newly_npi_resolved,50,49,1,2.0,80",
               "rucc_cat,4_removed,40,39,1,2.5,80",
               "certification,1_retained,100,100,0,0.0,99.1",
               "certification,2_newly_npi_resolved,50,50,0,0.0,98.8",
               "certification,4_removed,40,40,0,0.0,99.5"),
             file.path(dir, "artifacts", "composition_missingness_ledger.csv"))

  # L5: routed count, and surfaces that cover it
  writeLines(c("check,expected,observed,gates,pass,status",
               "locations successfully retrieved,900,900,yes,TRUE,PASS"),
             file.path(dir, "artifacts", "osmde_validation_table.csv"))
  saveRDS(data.frame(band_minutes = 30L, n_origins_dissolved = 1000L, area_km2 = 500),
          file.path(dir, "artifacts", "maps", "midwifery_isochrone_union_30min.rds"))
  saveRDS(data.frame(band_minutes = 60L, n_origins_dissolved = 1000L, area_km2 = 900),
          file.path(dir, "artifacts", "maps", "midwifery_isochrone_union_60min.rds"))

  system2("git", c("-C", shQuote(dir), "init", "-q"), stdout = FALSE, stderr = FALSE)
  system2("git", c("-C", shQuote(dir), "add", "-A", "-f"), stdout = FALSE, stderr = FALSE)
}

# L4 and L5 read scalars from a tracked manifest rather than from 30 MB of
# geometry, so the scaffold needs one. It is DERIVED from whatever surfaces the
# scratch repo currently holds, and regenerated AFTER the edits are applied --
# so a mutation that plants a short union still reaches the law, instead of
# tripping the drift guard and failing for the wrong reason. That distinction is
# the point: drift and a broken law are different defects.
law_write_manifest <- function(dir) {
  fs <- list.files(file.path(dir, "artifacts", "maps"),
                   pattern = "^midwifery_isochrone_union_[0-9]+min[.]rds$",
                   full.names = TRUE)
  if (!length(fs)) return(invisible(NULL))
  rows <- lapply(fs, function(f) {
    u <- readRDS(f)
    data.frame(band_minutes = as.numeric(u$band_minutes),
               n_origins_dissolved = as.numeric(u$n_origins_dissolved),
               area_km2 = as.numeric(u$area_km2),
               water_removed_km2 = if (!is.null(u$water_removed_km2))
                 as.numeric(u$water_removed_km2) else 0,
               source_file = basename(f),
               source_bytes = as.numeric(file.size(f)),
               source_md5 = unname(tools::md5sum(f)),
               stringsAsFactors = FALSE)
  })
  d <- do.call(rbind, rows)
  utils::write.csv(d[order(d$band_minutes), , drop = FALSE],
                   file.path(dir, "artifacts", "isochrone_union_manifest.csv"),
                   row.names = FALSE)
  invisible(d)
}

# The cd is load-bearing: the gate resolves its root as getwd(), and
# system2("Rscript", <path>) would leave it at the caller's, so every plant
# would silently run against the real repository.
law_run <- function(dir) {
  out <- suppressWarnings(system2("sh",
    c("-c", shQuote(sprintf("cd %s && Rscript tests/ci_science_laws.R 2>&1", shQuote(dir)))),
    stdout = TRUE, stderr = TRUE))
  st <- attr(out, "status")
  list(text = paste(out, collapse = "\n"), failed = !is.null(st) && st != 0L)
}

law_with <- function(edits) {
  dir <- file.path(tempdir(), paste0("law_", as.integer(stats::runif(1) * 1e9)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  law_scaffold(dir)
  for (nm in names(edits)) {
    tgt <- file.path(dir, nm)
    dir.create(dirname(tgt), recursive = TRUE, showWarnings = FALSE)
    if (is.function(edits[[nm]])) edits[[nm]](tgt) else writeLines(edits[[nm]], tgt)
  }
  # Regenerate UNLESS the mutation supplied a manifest of its own -- otherwise a
  # planted manifest would be silently overwritten by a correct one and the
  # defect would test nothing.
  if (!"artifacts/isochrone_union_manifest.csv" %in% names(edits))
    law_write_manifest(dir)
  system2("git", c("-C", shQuote(dir), "add", "-A", "-f"), stdout = FALSE, stderr = FALSE)
  law_run(dir)
}

kills <- function(label, code, edits) {
  planted <<- planted + 1L
  r <- law_with(edits)
  hit <- r$failed && grepl(sprintf("%s:", code), r$text, fixed = TRUE)
  if (hit) caught <<- caught + 1L
  # Evidence for tests/ci_law_coverage.R: which law, which defect, and whether
  # the law killed it. A law with no DETECTED line has no positive control.
  cat(sprintf("[MUTATION] %s %s %s\n", code,
              gsub("[^A-Za-z0-9]+", "-", label), if (hit) "DETECTED" else "SURVIVED"))
  chk(hit, sprintf("%s  %s", code, label))
  if (!r$failed) cat("       the gate passed; the mutation survived\n")
  else if (!hit) cat(sprintf("       failed, but not as %s -- another law took the hit\n", code))
}

survives <- function(label, edits) {
  near <<- near + 1L
  r <- law_with(edits)
  if (!r$failed) allowed <<- allowed + 1L
  chk(!r$failed, sprintf("near miss  %s", label))
  if (r$failed) for (l in grep("^FAIL", strsplit(r$text, "\n")[[1]], value = TRUE))
    cat("       ", l, "\n")
}

# -----------------------------------------------------------------------------
cat("\n-- the clean scaffold satisfies every law --\n")
local({
  dir <- file.path(tempdir(), paste0("law_clean_", as.integer(stats::runif(1) * 1e9)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  law_scaffold(dir); law_write_manifest(dir); r <- law_run(dir)
  chk(!r$failed, "an unperturbed scaffold produces no failures")
  if (r$failed) cat(r$text, "\n")
})

cat("\n-- planted defects, one or more per law --\n")

kills("a cohort silently off by one", "L1",
  list("artifacts/stage_progression_like_for_like.csv" = c("stage,cohort_n,n", "1,16891,100")))
kills("a superseded cohort vintage returns", "L1",
  list("artifacts/stage_progression_like_for_like.csv" = c("stage,cohort_n,n", "1,17538,100")))

kills("a disposition column dropped, parts no longer reach the whole", "L2",
  list("artifacts/linkage_completeness_by_status.csv" = c(
    "status,n,matched,pct_matched", "ACTIVE,100,70,70.0", "LAPSED,50,20,40.0")))
kills("ten percent of unmatched records vanish", "L2",
  list("artifacts/linkage_completeness_by_status.csv" = c(
    "status,n,matched,unmatched,pct_matched", "ACTIVE,100,70,27,70.0", "LAPSED,50,20,30,40.0")))

# THE REAL DEFECT, REPRODUCED. This is the artifact that
# resolve_amcb_by_state_license() actually emitted when its deterministic
# matches were taken from the whole external license universe while the
# denominator was the roster it was asked about: a two-person study frame
# reporting 8 people with a state license and 3 of 2 resolved. Nothing here
# fails an addition, which is why the parts-sum rule alone never saw it.
kills("a roster restriction removed, so a study frame resolves more people than it holds", "L2",
  list("artifacts/amcb_license_resolution_summary.csv" = c(
    "metric,n,pct_of_amcb",
    "amcb_roster,2,100",
    "amcb_with_state_license,8,400",
    "deterministically_resolved,3,150",
    "license_quarantine_rows,5,250")))
kills("a single share creeps just past its denominator", "L2",
  list("artifacts/amcb_license_resolution_summary.csv" = c(
    "metric,n,pct_of_amcb",
    "amcb_roster,16892,100",
    "deterministically_resolved,16893,100.006")))

# The two crosswalk fixtures are GREPPED by the gate, never sourced, so they
# carry no package-qualified calls. That is deliberate: the nightly asserts
# statically that the science files reach nothing outside base R, and a `::`
# inside a string literal is indistinguishable from a call to a grep. The one
# file that legitimately needs such a literal -- ci_science_contracts.R, whose
# SCI2 pattern must match a namespaced call in the sources it polices -- is excluded
# there by name and with a reason. A test fixture does not need the exemption.
kills("the crosswalk loses its NA-key assertion", "L3",
  list("R/lib/zip_county_crosswalk.R" = c(
    "zcta_county_parts <- function(path) {",
    "  d <- read_the_file(path)",
    "  d[!is.na(d$GEOID_ZCTA5_20), ]",
    "}")))
kills("the crosswalk stops filtering ZCTA-less rows", "L3",
  list("R/lib/zip_county_crosswalk.R" = c(
    "zcta_county_parts <- function(path) {",
    "  assert_no_na_key(read_the_file(path), 'zip5', 'x')",
    "}")))
kills("the ZIP-less group is placed back in remote-rural Alaska", "L3",
  list("artifacts/composition_rucc_cat.csv" = c(
    "group,level,n,N,pct",
    "1_retained,Metro (RUCC 1-3),75,110,68.18181818181819",
    "1_retained,\"Nonmetro, adjacent (4-6)\",10,110,9.090909090909092",
    "1_retained,\"Nonmetro, remote (7-9)\",5,110,4.545454545454546",
    "1_retained,Unknown,20,110,18.181818181818183",
    "2_newly_npi_resolved,\"Nonmetro, remote (7-9)\",40,40,100")))

kills("thirty-minute access exceeds sixty-minute access", "L4",
  list("artifacts/full_cohort_access_by_band_rucc.csv" = c(
    "rurality,band_minutes,women_with_access,women_total,pct_women_with_access",
    "Metro (RUCC 1-3),30,95,100,95.0",
    "Metro (RUCC 1-3),60,80,100,80.0")))
kills("the two surfaces are swapped", "L4",
  list("artifacts/maps/midwifery_isochrone_union_30min.rds" = function(p)
    saveRDS(data.frame(band_minutes = 30L, n_origins_dissolved = 1000L, area_km2 = 900), p),
       "artifacts/maps/midwifery_isochrone_union_60min.rds" = function(p)
    saveRDS(data.frame(band_minutes = 60L, n_origins_dissolved = 1000L, area_km2 = 500), p)))

kills("a union built from half the routed origins", "L5",
  list("artifacts/maps/midwifery_isochrone_union_30min.rds" = function(p)
    saveRDS(data.frame(band_minutes = 30L, n_origins_dissolved = 450L, area_km2 = 500), p)))

# THE MANIFEST'S OWN FAILURE MODE. Moving L4 and L5 onto a tracked summary of an
# untracked artifact bought enforcement on every runner and introduced one way
# to be wrong that did not exist before: the summary can drift from the surface
# it describes, and a drifted summary asserts a number nobody can check. It is
# guarded wherever the surface is present, and that guard is planted here.
local({
  r <- law_with(list("artifacts/isochrone_union_manifest.csv" = c(
    "\"band_minutes\",\"n_origins_dissolved\",\"area_km2\",\"water_removed_km2\",\"source_file\",\"source_bytes\",\"source_md5\"",
    "30,777,500,0,\"midwifery_isochrone_union_30min.rds\",1,\"deadbeefdeadbeefdeadbeefdeadbeef\"",
    "60,1000,900,0,\"midwifery_isochrone_union_60min.rds\",1,\"deadbeefdeadbeefdeadbeefdeadbeef\"")))
  chk(r$failed && grepl("manifest disagrees with the surfaces", r$text),
      "the union manifest describing a surface that is no longer there")
  # NOT counted as a law mutation. It is a defect in the gate's own evidence
  # rather than a violation of a registered law, and putting an unregistered
  # code into the [MUTATION] stream would corrupt the coverage scoreboard.
})

kills("bounds narrower than the missingness allows", "L11",
  list("artifacts/linkage_selection_bounds.csv" = c(
    "rurality,n_linked_in_cat,n_linked,n_roster,observed_pct,manski_lower_pct,manski_upper_pct",
    "Metro,75,90,150,83.3,70,90",
    "Rural,15,90,150,16.7,10,50")))
kills("a point estimate outside its own interval", "L11",
  list("artifacts/linkage_selection_bounds.csv" = c(
    "rurality,n_linked_in_cat,n_linked,n_roster,observed_pct,manski_lower_pct,manski_upper_pct",
    "Metro,75,90,150,95.0,50,90",
    "Rural,15,90,150,16.7,10,50")))
kills("bounds describing a different roster than the completeness table", "L11",
  list("artifacts/linkage_selection_bounds.csv" = c(
    "rurality,n_linked_in_cat,n_linked,n_roster,observed_pct,manski_lower_pct,manski_upper_pct",
    "Metro,50,120,200,41.7,25,65",
    "Rural,10,120,200,8.3,5,45")))

# L12. THE THREE NUMBERS THAT ACTUALLY SHIPPED, shrunk to fixtures. Each of
# these is a locally defensible artifact that disagrees with another one, which
# is the only way this defect ever appears -- nobody writes an artifact they
# know to be wrong.
kills("the metropolitan share counts the unknown-rurality members in its denominator", "L12",
  list("artifacts/linkage_selection_bounds.csv" = c(
    "rurality,n_linked_in_cat,n_linked,n_roster,observed_pct,manski_lower_pct,manski_upper_pct",
    # 75/110 rather than 75/90: the 86.5% defect exactly, an estimate diluted by
    # the people whose rurality is the thing that is missing.
    "Metro,75,90,150,68.18181818181819,50,90",
    "Rural,15,90,150,16.666666666666668,10,50")))
kills("the bounds are anchored on a different cohort than the composition", "L12",
  list("artifacts/composition_rucc_cat.csv" = c(
    "group,level,n,N,pct",
    # 78 metropolitan of 93 known -- the 160-person cohort drift, which moves
    # the share by half a point and breaks no other law in the file.
    "1_retained,Metro (RUCC 1-3),78,113,69.02654867256638",
    "1_retained,\"Nonmetro, adjacent (4-6)\",10,113,8.849557522123893",
    "1_retained,\"Nonmetro, remote (7-9)\",5,113,4.424778761061947",
    "1_retained,Unknown,20,113,17.699115044247787",
    "2_newly_npi_resolved,Unknown,40,40,100")))
kills("a percentage that no longer recomputes from the counts beside it", "L12",
  list("artifacts/linkage_selection_bounds.csv" = c(
    "rurality,n_linked_in_cat,n_linked,n_roster,observed_pct,manski_lower_pct,manski_upper_pct",
    # The counts still reconcile with the composition; only the percentage was
    # edited. A hand-corrected artifact looks exactly like this.
    "Metro,75,90,150,89.34122871946707,50,90",
    "Rural,15,90,150,16.666666666666668,10,50")))
kills("a group whose cells no longer sum to the N printed on its rows", "L12",
  list("artifacts/composition_rucc_cat.csv" = c(
    "group,level,n,N,pct",
    "1_retained,Metro (RUCC 1-3),75,110,68.18181818181819",
    "1_retained,\"Nonmetro, adjacent (4-6)\",10,110,9.090909090909092",
    "1_retained,\"Nonmetro, remote (7-9)\",5,110,4.545454545454546",
    "1_retained,Unknown,20,110,18.181818181818183",
    "2_newly_npi_resolved,Unknown,40,50,80")))

# L13. THE TWO SHAPES THAT ACTUALLY SHIPPED.
kills("a variable missing for a whole group and present for the rest", "L13",
  list("artifacts/composition_missingness_ledger.csv" = c(
    "variable,group,group_n,n_observed,n_missing,pct_missing,top_level_pct",
    # rurality as it really was: 100% missing for the newly-resolved group,
    # 3.2% for the retained one. Twelve laws ran green over this.
    "rucc_cat,1_retained,100,97,3,3.2,80",
    "rucc_cat,2_newly_npi_resolved,50,0,50,100.0,100",
    "rucc_cat,4_removed,40,39,1,2.5,80",
    "certification,1_retained,100,100,0,0.0,99.1",
    "certification,2_newly_npi_resolved,50,50,0,0.0,98.8",
    "certification,4_removed,40,40,0,0.0,99.5")))
kills("a group that vanished from a variable rather than being reported missing", "L13",
  list("artifacts/composition_missingness_ledger.csv" = c(
    "variable,group,group_n,n_observed,n_missing,pct_missing,top_level_pct",
    # practice_state as it really was: the group is simply not there.
    "practice_state,1_retained,100,100,0,0.0,8.8",
    "practice_state,4_removed,40,40,0,0.0,8.4",
    "certification,1_retained,100,100,0,0.0,99.1",
    "certification,2_newly_npi_resolved,50,50,0,0.0,98.8",
    "certification,4_removed,40,40,0,0.0,99.5")))

cat("\n-- near misses that must stay green --\n")

survives("a union holding MORE origins than were routed (canonical + recovered)",
  list("artifacts/maps/midwifery_isochrone_union_30min.rds" = function(p)
    saveRDS(data.frame(band_minutes = 30L, n_origins_dissolved = 1600L, area_km2 = 500), p)))
survives("the other registered cohort, 11,920",
  list("artifacts/stage_progression_like_for_like.csv" = c("stage,cohort_n,n", "1,11920,100")))
survives("equal access at two bands (a saturated stratum)",
  list("artifacts/full_cohort_access_by_band_rucc.csv" = c(
    "rurality,band_minutes,women_with_access,women_total,pct_women_with_access",
    "Metro (RUCC 1-3),30,100,100,100.0",
    "Metro (RUCC 1-3),60,100,100,100.0")))
survives("a level that is legitimately dominant in every group (99% CNM)",
  list("artifacts/composition_missingness_ledger.csv" = c(
    "variable,group,group_n,n_observed,n_missing,pct_missing,top_level_pct",
    "certification,1_retained,100,100,0,0.0,99.1",
    "certification,2_newly_npi_resolved,50,50,0,0.0,98.8",
    "certification,4_removed,40,40,0,0.0,99.5",
    "rucc_cat,1_retained,100,98,2,2.0,80",
    "rucc_cat,2_newly_npi_resolved,50,49,1,2.0,80",
    "rucc_cat,4_removed,40,39,1,2.5,80")))
survives("a group legitimately entirely Unknown",
  list("artifacts/composition_rucc_cat.csv" = c(
    "group,level,n,N,pct",
    "1_retained,Metro (RUCC 1-3),75,110,68.18181818181819",
    "1_retained,\"Nonmetro, adjacent (4-6)\",10,110,9.090909090909092",
    "1_retained,\"Nonmetro, remote (7-9)\",5,110,4.545454545454546",
    "1_retained,Unknown,20,110,18.181818181818183",
    "2_newly_npi_resolved,Unknown,40,40,100")))

# -----------------------------------------------------------------------------
cat(sprintf("\n%d/%d scientific mutations detected; %d/%d near misses allowed\n",
            caught, planted, allowed, near))
if (length(failures)) {
  cat(sprintf("\nFAILED (%d)\n", length(failures)))
  for (f in failures) cat(sprintf("  - %s\n", f))
  quit(status = 1)
}
cat("PASS (0 failures)\n")
