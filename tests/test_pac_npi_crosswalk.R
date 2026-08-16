#!/usr/bin/env Rscript
# =============================================================================
# The PAC ID <-> NPI bridge must be an IDENTIFIER relation, not a name match
# =============================================================================
# This crosswalk exists to replace normalised-name agreement with identifier
# agreement. If any relation in it were created by comparing organization
# names, it would smuggle the ambiguity it was built to remove into every
# downstream join -- and it would do so invisibly, because the output looks
# identical either way.
#
# Contracts PAC1-PAC12, in the order they were specified:
#
#   PAC1  pac_id never parsed numerically
#   PAC2  npi is exactly 10 digits
#   PAC3  enrlmt_id non-missing for every PPEF relation
#   PAC4  additional NPIs attach only through ENRLMT_ID
#   PAC5  NO name matching creates a PAC<->NPI relation
#   PAC6  duplicate exact relations collapse deterministically
#   PAC7  snapshot provenance recorded
#   PAC8  identical CMS republications detected by hash
#   PAC9  cardinality distribution reported
#   PAC10 every arm PAC ID classified mapped / ambiguous / genuinely absent
#   PAC11 a receiving PAC ID agrees with its direct ENROLLMENT NPI
#   PAC12 joining the crosswalk cannot silently multiply midwife rows
#
# Hermetic where it can be: PAC1-PAC10 read the builder's source and the
# tracked summaries. PAC11-PAC12 need the built crosswalk and SKIP LOUDLY when
# the external volume is absent, rather than passing vacuously.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({ library(dplyr); library(readr) })

fails <- 0L; skips <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
pac_skip <- function(m) { skips <<- skips + 1L; cat(sprintf("  SKIP %s\n", m)) }

BUILDER <- "build_pac_id_npi_crosswalk.R"
src  <- if (file.exists(BUILDER)) paste(readLines(BUILDER, warn = FALSE), collapse = "\n") else ""
code <- if (file.exists(BUILDER)) {
  ln <- readLines(BUILDER, warn = FALSE); paste(ln[!grepl("^\\s*#", ln)], collapse = "\n")
} else ""
rd <- function(p) read_csv(p, col_types = cols(.default = "c"), progress = FALSE)

cat("\n-- PAC1-PAC3: identifiers are text, and traceable --\n")
{
  chk(nzchar(code), "PAC0 the builder exists")
  # all_varchar keeps leading zeros; a numerically-parsed PAC ID stops joining.
  chk(grepl("all_varchar=TRUE", code, fixed = TRUE),
      "PAC1 every identifier column is read as text, never numeric")
  # LINE-BASED. In R's default engine "." matches a newline, so scanning the
  # whole file as one string made this fire on an as.integer() hundreds of lines
  # away from any mention of a PAC ID. Third time a checker in this repo has
  # been fooled by matching across its own file.
  code_lines <- if (file.exists(BUILDER)) {
    l <- readLines(BUILDER, warn = FALSE); l[!grepl("^\\s*#", l)]
  } else character(0)
  chk(!any(grepl("as\\.(numeric|integer)\\([^)]*pac", code_lines, ignore.case = TRUE)),
      "PAC1b no numeric coercion is applied to a PAC ID")
  chk(grepl('\\^\\[0-9\\]\\{10\\}\\$', code),
      "PAC2 an NPI must be exactly ten digits")
  chk(grepl("nzchar\\(\\.data\\$enrlmt_id\\)", code),
      "PAC3 a relation with no ENRLMT_ID is dropped, not kept")
}

cat("\n-- PAC4-PAC5: the relation comes from CMS, not from us --\n")
{
  # The load-bearing contract. A name comparison anywhere in the construction
  # path would rebuild the ambiguity this file removes.
  chk(!grepl("norm_org", code),
      "PAC5 norm_org() is not used anywhere in the builder")
  chk(!grepl("agrepl|adist|stringdist|fuzzy|jaro|levenshtein", code, ignore.case = TRUE),
      "PAC5b no fuzzy matcher is used to create a relation")
  chk(!grepl("join[^\\n]*by *= *[^\\n]*org_name", code),
      "PAC5c nothing is joined on an organization name")
  chk(grepl("npi_source", code),
      "PAC4 every NPI records which CMS relation supplied it")
  chk(grepl("ENROLLMENT", code, fixed = TRUE),
      "PAC4b and the enrollment-sourced ones say so")
  # ADDITIONAL_NPIS is not published. The gap must be named, not silently zero.
  chk(grepl("multiple_npi_flag", code),
      "PAC4c MULTIPLE_NPI_FLAG is carried, so the unpublished NPIs are countable")
  chk(grepl("incomplete_additional_npis_not_published", code),
      "PAC4d a flagged enrollment with one visible NPI is INCOMPLETE, not unique")
}

cat("\n-- PAC6-PAC8: determinism, provenance, republication --\n")
{
  chk(grepl("arrange\\(\\.data\\$snapshot_date, \\.data\\$pac_id, \\.data\\$npi", code),
      "PAC6 relations are sorted before collapsing, so output is order-independent")
  chk(grepl("snapshot_date", code) && grepl("snapshot_source", code),
      "PAC7 every relation carries its snapshot and its source")
  # The date must come from the FILE NAME. mtime is when we downloaded it.
  chk(grepl("PPEF_Enrollment_Extract_\\(\\[0-9\\.\\]\\+\\)", code) ||
      grepl("snap_of", code),
      "PAC7b the snapshot date is parsed from the CMS file name")
  chk(grepl("file\\.mtime\\(LEGACY\\)", code) == FALSE ||
      grepl("PPEF_LEGACY_DATE", code),
      "PAC7c an undated cut cannot be dated by its download time")
  chk(grepl("sha256", code) && grepl("is_republication", code),
      "PAC8 byte-identical republications are detected by hash")
  chk(grepl("use_for_panel", code),
      "PAC8b and excluded from the versioned series")
}

cat("\n-- PAC9: cardinality is measured, not assumed --\n")
{
  chk(grepl("n_npi_for_pac", code) && grepl("n_pac_for_npi", code),
      "PAC9 fan-out is computed in BOTH directions")
  chk(grepl("multi_location_entity", code),
      "PAC9b a PAC ID with several NPIs is labelled, not collapsed")
  # A one-to-one assumption anywhere would defeat the point.
  chk(!grepl("distinct\\(pac_id, \\.keep_all", code),
      "PAC9c the builder never reduces to one row per PAC ID")
  f <- "artifacts/pac_npi_cardinality.csv"
  if (file.exists(f)) {
    d <- rd(f)
    chk(all(c("direction", "entity_kind", "band", "n_ids") %in% names(d)),
        "PAC9d the cardinality report is stratified by direction and entity kind")
    chk(n_distinct(d$direction) == 2L,
        "PAC9e both directions are reported")
    chk(all(c("individual", "organization") %in% d$entity_kind),
        "PAC9f individuals and organizations are reported separately")
  } else pac_skip("PAC9d-f cardinality artifact absent (build not run)")
}

cat("\n-- PAC10: every arm PAC ID gets a verdict --\n")
{
  chk(grepl("mapped_unique", code) && grepl("mapped_ambiguous", code) &&
      grepl("absent_from_ppef", code),
      "PAC10 arm PAC IDs classify as mapped / ambiguous / genuinely absent")
  f <- "artifacts/pac_npi_arm_coverage.csv"
  if (file.exists(f)) {
    d <- rd(f)
    per_arm <- d %>% group_by(arm) %>% summarise(pct = sum(as.numeric(pct)), .groups = "drop")
    chk(all(abs(per_arm$pct - 100) < 1.5),
        sprintf("PAC10b each arm's classes account for ~100%% of its PAC IDs [%s]",
                paste(sprintf("%s=%.1f", per_arm$arm, per_arm$pct), collapse = ", ")))
  } else pac_skip("PAC10b arm coverage artifact absent (build not run)")
}

cat("\n-- PAC11-PAC12: the bridge behaves when joined --\n")
{
  ever <- "artifacts/pac_npi_ever.csv"
  if (!file.exists(ever)) {
    pac_skip("PAC11 crosswalk absent (needs PPEF_RAW_DIR); NOT passing vacuously")
    pac_skip("PAC12 crosswalk absent (needs PPEF_RAW_DIR); NOT passing vacuously")
  } else {
    x <- rd(ever)
    chk(all(grepl("^[0-9]{10}$", x$npi)), "PAC11a every NPI in the crosswalk is ten digits")
    chk(!any(duplicated(paste(x$pac_id, x$npi))),
        "PAC11b (pac_id, npi) is unique in the ever-crosswalk")
    chk(all(x$first_seen <= x$last_seen), "PAC11c first_seen never exceeds last_seen")
    chk(all(as.integer(x$n_snapshots_seen) >= 1L), "PAC11d every pair was seen at least once")

    # PAC12: the reason a one-to-many bridge is dangerous. Joining on a
    # multi-location PAC ID multiplies rows. Only the unique subset is safe,
    # and it must be provably one row per PAC ID.
    u <- x[x$pac_npi_resolution == "unique", ]
    chk(!any(duplicated(u$pac_id)),
        "PAC12 the 'unique' subset has exactly one NPI per PAC ID, so a join cannot multiply rows")
    amb <- x[x$pac_npi_resolution != "unique", ]
    chk(nrow(amb) == 0L || any(duplicated(amb$pac_id)) ||
        all(amb$pac_npi_resolution %in%
            c("incomplete_additional_npis_not_published", "npi_holds_multiple_pac_ids")),
        "PAC12b non-unique rows are genuinely fan-out or flagged-incomplete")
  }
}

cat(sprintf("\n%s (%d failures, %d skipped)\n",
            if (fails == 0L) "PASS" else "FAIL", fails, skips))
quit(status = if (fails == 0L) 0L else 1L)
