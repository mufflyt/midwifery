#!/usr/bin/env Rscript
#' @title One organization-affiliation table from every arm, Medicare or not
#'
#' @description
#' The endpoint, per docs/DECISIONS_CONTRACT.md, is not "who employs this
#' CNM/CM?" but:
#'
#'   What practice organizations is this CNM/CM affiliated with, and how strong
#'   is the evidence that each affiliation is current?
#'
#' This produces that table: one row per (midwife, organization), carrying each
#' arm as a SEPARATE column, a class describing which evidence supports it, and
#' a separate class describing how current it is.
#'
#' @section Why this exists as a second layer:
#' PECOS sees 68.7% of the resolved cohort and only 47% of LAPSED/RETIRED
#' certificants, but the missingness is dominated by certification status, not
#' by practice type. Among ACTIVE midwives PECOS misses 19.4%. Those are not
#' unreachable: the NPPES co-location arm is built from NPPES registration and
#' owes nothing to Medicare enrollment, so it can see people PECOS cannot.
#'
#' @section The organization key problem, stated rather than hidden:
#' The arms do not share an organization identifier. PECOS and Care Compare use
#' a PAC ID, NPPES co-location uses a Type-2 NPI, the hospital arms use a CCN,
#' and no public crosswalk joins all three. So cross-arm agreement is
#' established on the NORMALISED NAME (R/lib/org_names.R), and every identifier
#' each arm supplied is carried on the row.
#'
#' That is a real limitation and it runs in one direction: two arms naming the
#' same organization differently will NOT be merged, so `multi_source_confirmed`
#' is an UNDERCOUNT and `affiliation_evidence_count` is a lower bound. It does
#' not run the other way -- distinct organizations are not merged, because
#' norm_org() strips only corporate suffixes and never stems or fuzzy-matches.
#' An undercount of corroboration is the safe direction for this error.
#'
#' @section Nothing here is an employer:
#' Per the ruling, these are affiliations with evidence attached. A reassignment
#' on file is a billing relationship; a shared address is co-location; neither
#' is employment. No column is named employer and no class asserts one.
#'
#' Inputs : the arm artifacts listed in ARMS below, all optional -- an absent
#'          arm is scored NA (not consulted), never FALSE (looked, found nothing)
#' Outputs: artifacts/organization_affiliation_resolved.csv  (person-level, gitignored)
#'          artifacts/organization_affiliation_summary.csv   (tracked, suppressed)
#'          artifacts/organization_affiliation_unresolved.csv(tracked, suppressed)
#'
#' @family organization-linkage
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tidyr); library(stringr); library(cli)
})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "org_names.R"))
source(file.path("R", "lib", "organization_affiliation_status.R"))

OUT     <- "artifacts/organization_affiliation_resolved.csv"
OUT_SUM <- "artifacts/organization_affiliation_summary.csv"
OUT_UNR <- "artifacts/organization_affiliation_unresolved.csv"

rd <- function(p) read_csv(p, col_types = cols(.default = "c"), progress = FALSE)

# --- spine -------------------------------------------------------------------
cw <- Sys.glob("artifacts/amcb_npi_crosswalk_*panel*.csv")
cw <- cw[!grepl("\\.manifest\\.json$|\\.provenance\\.json$", cw)]
if (!length(cw)) stop("no AMCB->NPI crosswalk in artifacts/", call. = FALSE)
cw <- cw[order(file.mtime(cw), decreasing = TRUE)][1]
spine <- rd(cw) %>% filter(!is.na(npi), nzchar(npi)) %>%
  distinct(certification_number = amcb_id, npi)
cli::cli_alert_info("spine: {format(nrow(spine), big.mark = ',')} resolved midwives")

# --- each arm, reduced to a common shape -------------------------------------
# npi | org_id | org_id_type | organization_name | first_evidence | last_evidence
collect <- list()
arm_note <- function(arm, d) {
  if (is.null(d) || !nrow(d)) { cli::cli_alert_warning("{arm}: no rows"); return(invisible()) }
  d$arm <- arm
  collect[[arm]] <<- d
  cli::cli_alert_success("{arm}: {format(nrow(d), big.mark = ',')} pairs, {format(dplyr::n_distinct(d$npi), big.mark = ',')} midwives")
}
have <- function(p) file.exists(p)

cli::cli_h2("Arms")

# PECOS reassignment -- carries real dates, from the spell table.
if (have("artifacts/midwife_reassignment_spells.csv")) {
  arm_note("pecos_reassignment", rd("artifacts/midwife_reassignment_spells.csv") %>%
    transmute(npi = midwife_npi, org_id = org_pac_id, org_id_type = "pac_id",
              organization_name, first_evidence = first_seen_vintage,
              last_evidence = last_seen_vintage) %>%
    filter(!is.na(npi), nzchar(npi)))
}

# Care Compare -- dated by vintage; collapse to the observed span.
if (have("artifacts/midwife_organization_panel.csv")) {
  arm_note("care_compare_group", rd("artifacts/midwife_organization_panel.csv") %>%
    filter(has_group %in% c("TRUE", "true")) %>%
    group_by(npi = midwife_npi, org_id = org_pac_id, organization_name) %>%
    summarise(first_evidence = min(vintage), last_evidence = max(vintage),
              .groups = "drop") %>%
    mutate(org_id_type = "pac_id") %>%
    filter(!is.na(npi), nzchar(npi)))
}

# NPPES co-location -- the non-Medicare arm, and the only one independent of
# Medicare enrollment. Undated: NPPES publishes a registration state, not a
# history, so first/last are left NA rather than stamped with the file's
# vintage, which would read as an observation window.
#
# TWO VINTAGES, ONE ARM. The 2025-11 build and the older build are the SAME
# METHOD run on different cuts, not two independent sources. Counting them as
# two arms would let one method corroborate itself and push pairs into
# multi_source_confirmed on no new evidence at all. So they are unioned into a
# single arm, the NEWER vintage taking precedence per the standing preference,
# and the older one contributing only midwives the newer cut does not resolve
# (organizations close and move; 1,053 midwives are resolved by the old cut and
# not the new).
coloc <- NULL
if (have("artifacts/nppes_colocation_2025.csv")) {
  coloc <- rd("artifacts/nppes_colocation_2025.csv") %>%
    transmute(npi, org_id = org_npi, org_id_type = "npi_type2",
              organization_name, colocation_vintage = nppes_vintage)
}
if (have("artifacts/midwife_org_person.csv")) {
  older <- rd("artifacts/midwife_org_person.csv") %>%
    transmute(npi, org_id = org_npi, org_id_type = "npi_type2",
              organization_name, colocation_vintage = "pre_2025")
  coloc <- if (is.null(coloc)) older
           else bind_rows(coloc, older %>% filter(!npi %in% coloc$npi))
}
if (!is.null(coloc)) {
  arm_note("nppes_org_colocation", coloc %>%
    mutate(first_evidence = NA_character_, last_evidence = NA_character_) %>%
    select(-colocation_vintage) %>%
    filter(!is.na(npi), nzchar(npi)))
}

# Facility / hospital arms -- CCN-identified, undated.
if (have("artifacts/dac_facility_affiliations.csv")) {
  arm_note("facility_affiliation", rd("artifacts/dac_facility_affiliations.csv") %>%
    transmute(npi, org_id = ccn, org_id_type = "ccn",
              organization_name = facility_name,
              first_evidence = NA_character_, last_evidence = NA_character_) %>%
    filter(!is.na(npi), nzchar(npi)))
}
if (have("artifacts/midwife_hospital_affiliations.csv")) {
  arm_note("hospital_affiliation", rd("artifacts/midwife_hospital_affiliations.csv") %>%
    transmute(npi, org_id = cms_ccn, org_id_type = "ccn",
              organization_name = hospital_name,
              first_evidence = NA_character_, last_evidence = NA_character_) %>%
    filter(!is.na(npi), nzchar(npi)))
}

# Birth-centre arms. PARTIAL BY CONSTRUCTION: these registries cover accredited
# or listed centres only, so absence from them is not evidence of anything.
bc <- list(
  c("artifacts/cabc_matched_midwives_final.csv", "matched_cabc_birth_center"),
  c("artifacts/aabc_matched_birth_center_midwives.csv", "matched_facility_text"),
  c("artifacts/freestanding_birth_center_midwives_expanded.csv", "taxonomy_description"))
bc_rows <- lapply(bc, function(x) {
  if (!have(x[1])) return(NULL)
  d <- rd(x[1]); if (!x[2] %in% names(d)) return(NULL)
  tibble::tibble(npi = d$npi, org_id = NA_character_, org_id_type = "none",
                 organization_name = d[[x[2]]],
                 first_evidence = NA_character_, last_evidence = NA_character_)
})
bc_rows <- bind_rows(bc_rows)
if (nrow(bc_rows)) arm_note("birth_center_registry",
                        bc_rows %>% filter(!is.na(npi), nzchar(npi),
                                           !is.na(organization_name),
                                           nzchar(organization_name)))

if (have("artifacts/cohort_midwives_open_payments_type2_organizations.csv")) {
  arm_note("open_payments_org",
       rd("artifacts/cohort_midwives_open_payments_type2_organizations.csv") %>%
         transmute(npi = midwife_npi, org_id = type2_organization_npi,
                   org_id_type = "npi_type2",
                   organization_name = type2_organization_name,
                   first_evidence = NA_character_, last_evidence = NA_character_) %>%
         filter(!is.na(npi), nzchar(npi)))
}

ARMS_SEEN <- names(collect)
if (!length(ARMS_SEEN)) {
  stop("no arm artifact could be read. Refusing to write an empty resolver, ",
       "which would read as 'no midwife has any organization'.", call. = FALSE)
}

# --- one row per (midwife, organization) -------------------------------------
cli::cli_h2("Resolve")
all_rows <- bind_rows(collect) %>%
  semi_join(spine, by = "npi") %>%
  mutate(org_key = norm_org(organization_name)) %>%
  # A row with no usable organization name cannot be compared across arms and
  # cannot be reported. Counted and dropped, never silently.
  filter(nzchar(org_key))
cli::cli_alert_info("arm rows on cohort: {format(nrow(all_rows), big.mark = ',')}")

pair <- all_rows %>%
  group_by(npi, org_key) %>%
  summarise(
    # The longest recorded spelling is the most informative label; the choice
    # is arbitrary among ties, so break it deterministically.
    organization_name = organization_name[order(-nchar(organization_name),
                                                organization_name)][1],
    org_ids = paste(sort(unique(na.omit(org_id[nzchar(org_id)]))), collapse = "|"),
    org_id_types = paste(sort(unique(org_id_type[org_id_type != "none"])), collapse = "|"),
    first_evidence_date = if (all(is.na(first_evidence))) NA_character_
                          else min(first_evidence, na.rm = TRUE),
    last_evidence_date  = if (all(is.na(last_evidence))) NA_character_
                          else max(last_evidence,  na.rm = TRUE),
    arms = paste(sort(unique(arm)), collapse = "|"),
    affiliation_evidence_count = n_distinct(arm),
    .groups = "drop")

for (a in ARMS_SEEN) pair[[a]] <- str_detect(pair$arms, fixed(a))

# --- affiliation_class: WHICH evidence supports this pair --------------------
# Ordered most to least informative. Deliberately NOT a currentness statement:
# that is the separate column below, because "how many sources" and "how
# current" are different questions and one column cannot answer both.
arm_flag <- function(nm) if (nm %in% names(pair)) pair[[nm]] else rep(FALSE, nrow(pair))
p_pecos <- arm_flag("pecos_reassignment"); p_cc <- arm_flag("care_compare_group")
p_nppes <- arm_flag("nppes_org_colocation")
p_fac   <- arm_flag("facility_affiliation") | arm_flag("hospital_affiliation")
p_bc    <- arm_flag("birth_center_registry"); p_op <- arm_flag("open_payments_org")

pair <- pair %>% mutate(
  affiliation_class = case_when(
    affiliation_evidence_count >= 2L ~ "multi_source_confirmed",
    p_cc                             ~ "carecompare_current_group",
    p_pecos                          ~ "pecos_reassignment_on_file",
    p_nppes                          ~ "nppes_org_colocation_only",
    p_fac                            ~ "facility_only",
    p_bc                             ~ "birth_center_registry_only",
    p_op                             ~ "open_payments_only",
    TRUE                             ~ "unresolved"),
  # WHICH LAYER carried this pair. The point of the exercise: a pair resolved
  # only by non-Medicare evidence is one PECOS could never have produced.
  evidence_layer = case_when(
    (p_pecos | p_cc) & (p_nppes | p_fac | p_bc) ~ "both_layers",
    p_pecos | p_cc                              ~ "medicare_only",
    TRUE                                        ~ "non_medicare_only"),
  # Currentness reuses the ruling's own classifier rather than inventing a
  # second ladder. nppes here is co-location, which is what that argument means.
  currentness_class = classify_affiliation_status(
    pecos = p_pecos, care_compare = p_cc, nppes = p_nppes | p_fac))

cli::cli_alert_success("pairs: {format(nrow(pair), big.mark = ',')}; midwives with >=1 organization: {format(n_distinct(pair$npi), big.mark = ',')}")
cat("\n"); print(as.data.frame(count(pair, affiliation_class, sort = TRUE)), row.names = FALSE)
cat("\n"); print(as.data.frame(count(pair, evidence_layer, sort = TRUE)), row.names = FALSE)
cat("\n"); print(as.data.frame(count(pair, currentness_class, sort = TRUE)), row.names = FALSE)

out <- pair %>%
  left_join(spine, by = "npi") %>%
  select(certification_number, npi, organization_name, org_ids, org_id_types,
         all_of(ARMS_SEEN), first_evidence_date, last_evidence_date,
         affiliation_evidence_count, affiliation_class, evidence_layer,
         currentness_class) %>%
  arrange(certification_number, desc(affiliation_evidence_count), organization_name)

write_with_provenance(out, OUT, na = "",
  inputs = prov_inputs(c(cw, unlist(lapply(ARMS_SEEN, function(a) NULL)))))
cli::cli_alert_success("wrote {OUT}")

# --- what the non-Medicare layer actually bought -----------------------------
cli::cli_h2("What the non-Medicare layer adds")
med_npi <- unique(pair$npi[pair$evidence_layer %in% c("medicare_only", "both_layers")])
non_only <- setdiff(unique(pair$npi), med_npi)
cli::cli_alert_info("midwives resolvable ONLY by non-Medicare evidence: {format(length(non_only), big.mark = ',')}")

unres <- spine %>% filter(!npi %in% pair$npi)
cli::cli_alert_warning("midwives with NO organization from ANY arm: {format(nrow(unres), big.mark = ',')}")

# --- tracked summaries -------------------------------------------------------
suppress <- function(d, col = "n_midwives") {
  d[[col]] <- as.integer(d[[col]])
  d$suppressed <- d[[col]] < 11L
  d[[col]] <- ifelse(d$suppressed, NA_integer_, d[[col]])
  d
}
summ <- out %>%
  distinct(npi, affiliation_class, evidence_layer, currentness_class) %>%
  count(affiliation_class, evidence_layer, currentness_class, name = "n_midwives") %>%
  suppress() %>% arrange(affiliation_class, evidence_layer, currentness_class)
write_with_provenance(summ, OUT_SUM, na = "", inputs = prov_inputs(OUT))
cli::cli_alert_success("wrote {OUT_SUM} (cells under 11 suppressed)")

# The unresolved group, described only in aggregate -- it is the work list, and
# the person-level version stays out of the repo.
geo <- if (have("artifacts/amcb_npi_geography.csv")) {
  rd("artifacts/amcb_npi_geography.csv") %>% distinct(npi, .keep_all = TRUE) %>%
    select(npi, practice_state, taxonomy_description)
} else tibble::tibble(npi = character(), practice_state = character(),
                      taxonomy_description = character())
unr_summ <- unres %>% left_join(geo, by = "npi") %>%
  count(practice_state, taxonomy_description, name = "n_midwives") %>%
  suppress() %>% arrange(desc(n_midwives), practice_state)
write_with_provenance(unr_summ, OUT_UNR, na = "", inputs = prov_inputs(cw))
cli::cli_alert_success("wrote {OUT_UNR} (cells under 11 suppressed)")
