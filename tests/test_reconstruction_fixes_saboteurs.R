#!/usr/bin/env Rscript
# =============================================================================
# Saboteurs for the 2026-11-19 reconstruction fixes
# =============================================================================
# Five mechanisms landed together and each fails silently in a different way:
#
#   F1 OP linkage adjudication -- an A-pick inside B's candidate set is the
#      only case where the two implementations agree; ruling() must flip with
#      the address-universe flag and must never collapse an ambiguous set.
#   F2 CMS by-provider fingerprints -- the ONLY evidence a renamed CSV can
#      offer for its year. A poisoned manifest entry must be refuted, not
#      inherited; a well-formed manifest is a precondition for that.
#   F3 §11 reconstruction audit -- built over the canonical table; medicare's
#      two validation legs (warehouse release_id + CSV fingerprint) must
#      collapse to one row per year, not duplicate it.
#   F4 changelog honesty -- T-MSIS outputs now exist (warehouse rebuilt
#      2026-11-19); the changelog must record the run with evidence, not a
#      bare "done", and must not still list it as blocked. The fingerprint
#      upgrade must also be recorded as landed.
#   F5 DAC honesty -- the audit's dac series is real (physician_compare_
#      historical_midwives.csv, 14 years); the residual spec item is
#      finer-grained vintages, so no doc may claim dac coverage is missing.
#
# Each saboteur either mutates an input and checks the mechanism reports the
# mutation, or checks a guard that would hide the failure it introduces.
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr)})
.harness <- grep("--file=", commandArgs(), value = TRUE)
source(file.path(if (length(.harness)) dirname(sub("--file=", "", .harness[1]))
                 else "tests", "helper-saboteur.R"))
root <- test_repo_root()
source(file.path(root, "R", "lib", "source_year.R"))
SAB_PREFIX <- "F"

py_ruling <- function(row_fields) {
  py <- sprintf(
    paste0("import sys; sys.path.insert(0, %s)\n",
           "import adjudicate_op_linkage_450 as m\n",
           "v,c,why = m.ruling(%s)\n",
           "print(v, '|', c, '|', why)"),
    shQuote(root), row_fields)
  out <- system2("python3", c("-c", shQuote(py)), stdout = TRUE)
  parts <- strsplit(out[length(out)], " \\| ")[[1]]
  list(ruling = parts[1], canonical = parts[2], reason = parts[3])
}
mk_row <- function(a, b, flag, n) sprintf(paste0(
  "{'npi':'1','a_type2_npi':'%s','a_org_name':'','a_op_address':'',",
  "'op_addr_is_nppes_practice_addr':'%s','b_type2_npis':'%s',",
  "'b_org_names':'','b_evidence_keys':'','b_resolution_methods':'',",
  "'n_b_candidates':'%d'}"), a, flag, b, n)

# --- F1 adjudication ---------------------------------------------------------
sab(1, "an A-pick inside B's set rules agree -- flipping the universe flag cannot hide it")
r <- py_ruling(mk_row("100", "100;200", "True", 2))
chk(r$ruling == "agree" && r$canonical == "100",
    "F1a a pick inside the candidate set rules agree")

r <- py_ruling(mk_row("100", "200", "False", 1))
chk(r$ruling == "b_preferred_universe",
    "F1b an out-of-universe OP address rules b_preferred_universe")

# SABOTEUR: same inputs, universe flag flipped -- the ruling MUST move.
r <- py_ruling(mk_row("100", "200", "True", 1))
chk(r$ruling == "b_preferred_tenant" && r$canonical == "200",
    "F1c same address + single B candidate rules b_preferred_tenant")

r <- py_ruling(mk_row("100", "200;300", "True", 2))
chk(r$ruling == "ambiguous" && !nzchar(r$canonical),
    "F1d a multi-candidate set stays a set (no canonical collapse)")

# --- F2 fingerprints ---------------------------------------------------------
sab(2, "a poisoned fingerprint entry is refuted, never inherited")
tmp <- tempfile(fileext = ".csv")
writeLines("a,b\n1,2", tmp)
good <- digest::digest(file = tmp, algo = "sha256")
v <- assert_source_year(tmp, 2019L, fingerprint = good, strict = FALSE)
chk(v$status == "fingerprint", "F2a a matching sha256 validates as fingerprint")
# SABOTEUR: manifest says the 2019 file is this content but bytes differ.
v <- assert_source_year(tmp, 2019L,
                        fingerprint = paste0("0", substring(good, 2)),
                        strict = FALSE)
chk(v$status == "refuted", "F2b a mismatched recorded hash is refuted")

man <- read_csv(file.path(root, "config/cms_by_provider_fingerprints.csv"),
                col_types = cols(.default = "c"), progress = FALSE)
chk(all(grepl("^[0-9a-f]{64}$", man$sha256)) &&
      !anyDuplicated(paste(man$filename, man$year)),
    "F2c manifest is well-formed: 64-hex sha256, unique (filename, year)")

# --- F3 §11 audit -------------------------------------------------------------
sab(3, "medicare's two validation legs collapse to one audit row per year")
sb <- file.path(tempdir(), "audit_sab")
dir.create(sb, showWarnings = FALSE, recursive = TRUE)
write_csv(tibble::tibble(
  amcb_id = "A1", npi = c("1","1","2","2","3"), source = "medicaid_enrollment",
  source_record_id = NA, year = c(2020,2021,2020,2021,2021),
  state = c("NM","NM","CO","CO","CO"), evidence_type = "administrative",
  snapshot_date = NA, effective_date = NA, vintage = "T",
  usable_for_trend = c(FALSE,TRUE,FALSE,TRUE,TRUE), source_hash = NA,
  reconstruction_version = "t"),
  file.path(sb, "records.csv"))
write_csv(tibble::tibble(program_year = 2021, status = "in_file_date",
                         confidence = "high", observed_years = 2021,
                         detail = "t"),
          file.path(sb, "op_val.csv"))
write_csv(tibble::tibble(
  year = c(2020, 2020, 2021, 2021),
  source = c("medicare_part_b_2020", "part_d_by_provider_2020.csv",
             "medicare_part_b_2021", "part_d_by_provider_2021.csv"),
  status = c("release_id", "fingerprint", "release_id", "fingerprint"),
  confidence = "medium", observed_years = NA, detail = "t"),
  file.path(sb, "mc_val.csv"))
out_csv <- file.path(sb, "audit.csv")
env <- paste0("CANONICAL_RECORDS_CSV=", file.path(sb, "records.csv"),
              " OP_YEAR_VALIDATION_CSV=", file.path(sb, "op_val.csv"),
              " MC_YEAR_VALIDATION_CSV=", file.path(sb, "mc_val.csv"),
              " RECONSTRUCTION_AUDIT_CSV=", out_csv)
system2("Rscript", file.path(root, "build_longitudinal_reconstruction_audit.R"),
        env = env, stdout = FALSE, stderr = FALSE)
aud <- read_csv(out_csv, col_types = cols(.default = "c"), progress = FALSE)
chk(nrow(aud) == 2 && !anyDuplicated(paste(aud$source, aud$year)),
    "F3a two source-years in, two audit rows out (medicare legs collapsed)")
chk(identical(sort(aud$n_npis), c("2", "3")),
    "F3b per-year n_npis counted independently")

# --- F4 changelog honesty ------------------------------------------------------
sab(4, "the changelog cannot claim outputs that do not exist")
cl <- paste(readLines(file.path(root, "docs",
                                "longitudinal-reconstruction-changelog.md"),
                      warn = FALSE), collapse = "\n")
chk(grepl("fingerprint", cl, fixed = TRUE),
    "F4a changelog records the fingerprint fix as landed")
# T-MSIS is DONE as of 2026-11-19: the changelog must carry the run's
# evidence (row count), the blocked list must not still contain it, and
# the artifacts must exist on disk -- a doc claim without a file is the
# failure this saboteur guards.
chk(grepl("238,015,729", cl, fixed = TRUE) &&
      !grepl("extraction outputs pending", cl, fixed = TRUE) &&
      file.exists(file.path(root, "artifacts",
                            "tmsis_medicaid_spending_cohort_by_year.csv")) &&
      file.exists(file.path(root, "artifacts",
                            "medicaid_billing_by_state.csv")) &&
      file.exists(file.path(root, "artifacts",
                            "medicaid_billing_year_trend.csv")),
    "F4b changelog records the T-MSIS run with evidence and the files exist")

# --- F5 DAC honesty -------------------------------------------------------------
sab(5, "no doc may claim the 14-year DAC series is missing")
mx <- paste(readLines(file.path(root, "docs", "spec-completion-matrix.md"),
                      warn = FALSE), collapse = "\n")
chk(!grepl("DAC[^|\n]*(missing|absent)", mx, ignore.case = TRUE) &&
      grepl("physician_compare_historical", cl, fixed = TRUE),
    "F5 DAC residual item is vintages, not coverage")

saboteur_report("5 fixes")
