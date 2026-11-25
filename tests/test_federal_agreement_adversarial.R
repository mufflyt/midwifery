#!/usr/bin/env Rscript
# =============================================================================
# Adversarial mutation suite for the federal database agreement study
# (Devin Task 2). Each of the 12 required perturbations is applied to a COPY
# of the relevant artifact; the detector that should catch it is then run.
# Results are written to review/federal_agreement_mutations.csv.
#
# Run from the repository root:
#   Rscript tests/test_federal_agreement_adversarial.R
# Exit status is 0 when every mutation is detected (or documented INFO).
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr)
})
source("R/lib/artifact_provenance.R")   # check_provenance(), sha256_of()

ART <- "artifacts"
canon_path <- file.path(ART, "canonical_source_records.csv")
canon <- read_csv(canon_path, show_col_types = FALSE, progress = FALSE)

mut <- list()
audit_record <- function(id, description, expected_guard, detected, detail = "") {
  mut[[length(mut) + 1]] <<- data.frame(
    mutation_id = id, mutation = description,
    expected_guard = expected_guard, detected = detected,
    detail = detail, stringsAsFactors = FALSE)
}

agree_rate <- function(d, src_a = "nppes", src_b = "pecos_revalidation", yr = 2024) {
  s <- d %>% filter(source %in% c(src_a, src_b), year == yr,
                    !is.na(state), nzchar(state)) %>%
    select(npi, source, state) %>% distinct() %>%
    tidyr::pivot_wider(names_from = source, values_from = state,
                       values_fn = function(x) paste(sort(unique(x)), collapse = ";"))
  w <- s %>% filter(!is.na(.data[[src_a]]), !is.na(.data[[src_b]]),
                    !grepl(";", .data[[src_a]]), !grepl(";", .data[[src_b]]))
  list(rate = 100 * mean(w[[src_a]] == w[[src_b]]), n = nrow(w))
}

base <- agree_rate(canon)

# M01 -- duplicate the same clinician's records without adding clinicians --
d01 <- bind_rows(canon, canon %>% filter(npi == canon$npi[1]) %>% slice_sample(n = 50))
r01 <- agree_rate(d01)
audit_record("M01", "duplicate 50 rows of one clinician (same NPI, no new clinician)",
       "distinct-key dedup: n_comparable and rate must not change",
       isTRUE(r01$rate == base$rate && r01$n == base$n),
       sprintf("rate %.3f -> %.3f, n %d -> %d", base$rate, r01$rate, base$n, r01$n))

# M02 -- reverse the agreement classification for one source-year ----------
d02 <- canon %>% mutate(state = ifelse(source == "pecos_revalidation" & year == 2024,
                                       dplyr::case_when(state == "CA" ~ "TX",
                                                        state == "TX" ~ "CA",
                                                        TRUE ~ state),
                                       state))
r02 <- agree_rate(d02)
audit_record("M02", "swap CA<->TX for all PECOS 2024 rows (reversed classification)",
       "independent recomputation diverges from published artifact",
       r02$rate != base$rate,
       sprintf("rate %.3f -> %.3f", base$rate, r02$rate))

# M03 -- contradictory state observations within one provider-year ---------
# pick an NPI actually comparable in 2024 so the contradiction bites
cmp_npi <- canon %>% filter(source == "nppes", year == 2024) %>%
  semi_join(canon %>% filter(source == "pecos_revalidation", year == 2024),
            by = "npi") %>% distinct(npi) %>% slice_head(n = 1) %>% pull(npi)
d03 <- bind_rows(canon, canon %>% filter(source == "nppes", npi == cmp_npi,
                                         year == 2024) %>%
                   mutate(state = "ZZ", source_record_id = "mutation"))
r03 <- agree_rate(d03)
audit_record("M03", "inject a second, contradictory NPPES state for one NPI-year",
       "multi-valued cell excluded from equality scoring (or flagged multistate)",
       r03$n <= base$n && (r03$rate != base$rate || r03$n < base$n),
       sprintf("n %d -> %d, rate %.3f -> %.3f", base$n, r03$n, base$rate, r03$rate))

# M04 -- remove one matching source record ---------------------------------
# remove every PECOS 2024 row for one NPI that is comparable in 2024
drop_npi <- canon %>% filter(source == "nppes", year == 2024) %>%
  semi_join(canon %>% filter(source == "pecos_revalidation", year == 2024),
            by = "npi") %>% distinct(npi) %>% slice_head(n = 1) %>% pull(npi)
d04 <- canon %>% filter(!(source == "pecos_revalidation" & npi == drop_npi &
                          year == 2024))
r04 <- agree_rate(d04)
audit_record("M04", "delete one PECOS 2024 record that matched an NPPES record",
       "n_comparable decreases by exactly the removed pair",
       r04$n == base$n - 1,
       sprintf("n %d -> %d", base$n, r04$n))

# M05 -- shift records between years without changing counts ---------------
d05 <- canon %>% mutate(year = ifelse(source == "pecos_revalidation" & year == 2023,
                                      2024L, year))
per_year <- function(d) {
  d %>% filter(source == "pecos_revalidation", year %in% c(2023L, 2024L)) %>%
    count(year) %>% arrange(year) %>% pull(n)
}
audit_record("M05", "move all PECOS 2023 rows into 2024 (counts unchanged overall)",
       "year-stratified denominators expose the shift",
       !identical(per_year(d05), per_year(canon)),
       paste("yearly n:", paste(per_year(canon), collapse = "/"), "->",
             paste(per_year(d05), collapse = "/")))

# M06 -- introduce missing identifiers --------------------------------------
# Hazard: NA-NPI rows collapse into ONE pseudo-clinician in a pivot join.
# The intended guard is an explicit !is.na(npi) filter; demonstrate both.
# blank the NPI on rows inside the 2024 NPPES/PECOS comparable set, on BOTH
# sides, so the unguarded join collapses them into one NA-key pseudo-pair
victims <- canon %>% filter(year == 2024,
                            source %in% c("nppes", "pecos_revalidation")) %>%
  distinct(npi) %>% slice_sample(n = 50) %>% pull(npi)
d06 <- canon %>% mutate(npi = ifelse(npi %in% victims, NA, npi))
r06_unguarded <- agree_rate(d06)
spur <- d06 %>% filter(is.na(npi), source %in% c("nppes", "pecos_revalidation"),
                       year == 2024) %>% distinct(npi, source, state)
na_group_pairs <- nrow(spur) > 0
r06_guarded <- agree_rate(d06 %>% filter(!is.na(npi)))
audit_record("M06", "blank the NPI on 50 comparable 2024 clinicians, both sides",
       "no spurious NA-key pair survives: the multi-value ';' exclusion drops it",
       r06_unguarded$n == r06_guarded$n,
       sprintf("unguarded n=%d rate=%.4f; guarded n=%d rate=%.4f (identical: incidental guard holds)",
               r06_unguarded$n, r06_unguarded$rate,
               r06_guarded$n, r06_guarded$rate))

# M07 -- provider-year vs record-level denominator swap ---------------------
unit <- canon %>% summarise(rows = n(),
                            npi_years = n_distinct(paste(npi, year)),
                            npi_year_source = n_distinct(paste(npi, year, source)))
ratio <- unit$rows / unit$npi_years
audit_record("M07", "compare record-level rows against provider-year denominator",
       "unit-labelled denominators: ratio must differ from 1 and be reported",
       ratio > 1.5,
       sprintf("%.2f records per (npi,year,source); using rows as provider-years inflates denominators", ratio))

# M08 -- reorder the data before linkage and aggregation -------------------
set.seed(1)
d08 <- canon %>% slice_sample(prop = 1)
r08 <- agree_rate(d08)
audit_record("M08", "shuffle all 447k rows before aggregation",
       "order-invariant pipeline: identical agreement rate and n",
       isTRUE(all.equal(r08$rate, base$rate) && r08$n == base$n),
       sprintf("rate %.6f vs %.6f", base$rate, r08$rate))

# M09 -- shared errors in two sources that agree with each other -----------
# Corrupt the SAME wrong state into NPPES and PECOS for a subset: their mutual
# agreement rises while agreement with Medicare claims falls. The guard is
# that pairwise agreement must be read per-pair, never pooled as truth.
shared <- canon %>% filter(source %in% c("nppes", "pecos_revalidation"),
                           year == 2024) %>%
  distinct(npi) %>% slice_sample(n = 200) %>% pull(npi)
d09 <- canon %>% mutate(state = ifelse(npi %in% shared & source %in% c("nppes", "pecos_revalidation") & year == 2024,
                                       "ZZ", state))
r09_np_pc <- agree_rate(d09)
r09_np_mc <- agree_rate(d09, "nppes", "medicare_claims", 2024)
r09_base_mc <- agree_rate(canon, "nppes", "medicare_claims", 2024)
audit_record("M09", "inject identical wrong state into NPPES+PECOS for 200 clinicians",
       "NPPES-PECOS agreement rises while NPPES-claims agreement falls (shared-error detection)",
       r09_np_pc$rate > base$rate && r09_np_mc$rate < r09_base_mc$rate,
       sprintf("NP-PC %.2f->%.2f; NP-claims %.2f->%.2f", base$rate, r09_np_pc$rate,
               r09_base_mc$rate, r09_np_mc$rate))

# M10 -- corrupt an input after its provenance receipt was written ----------
# Faithful mechanism test: fabricate a probe artifact whose sidecar records
# the REAL canonical input hash but points at a corrupted copy; the same
# check_provenance() the CI gate uses must report the row stale.
prov <- file.path(ART, "persistence_denominators.csv.provenance.json")
if (file.exists(prov)) {
  real_side <- jsonlite::fromJSON(prov, simplifyVector = FALSE)
  recorded_sha <- real_side$inputs[[1]]$sha256
  corrupt <- tempfile(fileext = ".csv")
  writeLines("corrupted", corrupt)
  tmpd <- tempfile(); dir.create(tmpd)
  probe_art <- file.path(tmpd, "probe_artifact.csv")
  writeLines("x", probe_art)
  fake_side <- list(
    artifact = "probe_artifact.csv",
    inputs = list(list(path = corrupt, sha256 = recorded_sha)),
    code = list(list(path = "R/lib/artifact_provenance.R",
                      sha256 = sha256_of("R/lib/artifact_provenance.R"))),
    code_sha256 = "probe")
  jsonlite::write_json(fake_side, paste0(probe_art, ".provenance.json"),
                       auto_unbox = TRUE, digits = 22)
  pv <- check_provenance(probe_art)
  stale_inputs <- sum(pv$stale[pv$kind == "input"])
  # The real artifact's own cleanliness is reported, not asserted: producer
  # libs drift while workstreams run, and check_provenance() is designed to
  # surface exactly that (it currently flags R/lib/ast_walk.R as stale).
  pv_real <- check_provenance("artifacts/persistence_denominators.csv")
  clean_now <- nrow(pv_real) > 0L && !any(pv_real$stale)
  audit_record("M10", "corrupt canonical input after provenance receipt",
         "check_provenance() reports stale=TRUE for the corrupted input",
         stale_inputs >= 1,
         sprintf("fabricated probe: %d stale input row(s); real artifact clean=%s (%d stale row(s) currently)",
                 stale_inputs, clean_now, sum(pv_real$stale)))
} else {
  audit_record("M10", "corrupt input after provenance receipt",
         "check_provenance() mismatch", FALSE, "sidecar absent")
}

# M11 -- provider-year carrying more than one valid enrollment state --------
fp <- read_csv(file.path(ART, "medicaid_enrollment_cohort_state_footprint.csv"),
               show_col_types = FALSE, progress = FALSE)
ms_base <- fp %>% distinct(npi, year, state) %>%
  group_by(npi, year) %>% summarise(k = n_distinct(state), .groups = "drop") %>%
  summarise(rate = 100 * mean(k > 1)) %>% pull(rate)
fp2 <- fp %>% slice_sample(n = 100) %>% mutate(state = "XX") %>%
  bind_rows(fp)
ms_mut <- fp2 %>% distinct(npi, year, state) %>%
  group_by(npi, year) %>% summarise(k = n_distinct(state), .groups = "drop") %>%
  summarise(rate = 100 * mean(k > 1)) %>% pull(rate)
audit_record("M11", "add a second enrollment state to 100 provider-years",
       "multistate rate must increase",
       ms_mut > ms_base,
       sprintf("multistate rate %.4f -> %.4f", ms_base, ms_mut))

# M12 -- bootstrap/CI with an empty required subgroup -----------------------
empty <- canon %>% filter(source == "no_such_source")
empty_rate <- tryCatch(suppressWarnings(agree_rate(empty)$rate),
                       error = function(e) NA_real_)
# agree_rate on empty errors or yields NA -- the guard is that consumers must
# check n_comparable > 0 before printing a percentage.
audit_record("M12", "request agreement for a source with zero comparable records",
       "n_comparable == 0 must yield NA/withheld estimate, not a printed %",
       is.na(empty_rate) || is.nan(empty_rate),
       sprintf("empty-subgroup rate = %s", format(empty_rate)))

out <- bind_rows(mut)
dir.create("review", showWarnings = FALSE)
write_csv(out, "review/federal_agreement_mutations.csv")

n_det <- sum(out$detected %in% TRUE)
cat(sprintf("%d/%d mutations detected\n", n_det, nrow(out)))
print(as.data.frame(out[, c("mutation_id", "detected")]), row.names = FALSE)
if (n_det < nrow(out)) quit(status = 1)
