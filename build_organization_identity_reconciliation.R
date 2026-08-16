#!/usr/bin/env Rscript
#' @title Identifier-based organization reconciliation, with a before/after audit
#'
#' @description
#' Until now two arms were said to name the same organization when their
#' normalised legal names matched. The PAC ID <-> NPI crosswalk makes identifier
#' comparison possible. This measures what that buys, and CHANGES NOTHING: the
#' resolver is not rerun, no affiliation is altered, no source name or date is
#' touched. Changing accepted affiliations in the step that measures the change
#' would leave nothing to compare against.
#'
#' @section The point is not a higher coverage percentage:
#' It is replacing one vague claim -- "these organization names look alike" --
#' with three distinguishable ones:
#'
#'   specific_npi   the same specific organization, by NPI
#'   pac_entity     the same corporate entity, site uncertain
#'   name_only      names agree, no identifier can confirm it
#'   unresolved     no identity established
#'
#' @section Chain PAC IDs cannot support a same-site claim:
#' ~95% of organization PAC IDs map to one NPI, but WALGREEN CO holds 9,166 NPIs
#' under one PAC ID. Two rows agreeing on a chain PAC ID agree on the
#' CORPORATION, not the location. Treating that as `specific_npi` would assert
#' co-location that the identifier does not carry, so it resolves to
#' `pac_entity` unless another identifier selects a specific NPI.
#'
#' @section The resolution hierarchy, identifiers before names:
#'   A  exact organization NPI on both sides            -> specific_npi
#'   B  exact PAC ID on both sides, PAC maps to one NPI -> specific_npi
#'   C  PAC ID bridged to a unique NPI                  -> specific_npi
#'   D  exact PAC ID, PAC is a multi-NPI entity         -> pac_entity
#'   E  normalised-name agreement only                  -> name_only
#'   F  none of the above                               -> unresolved
#'
#' A-D are identifier evidence. E is not, and is never reported as identifier
#' confirmation.
#'
#' @section SNAPSHOT-MATCHED, with ever- as a labelled fallback:
#' pac_npi_snapshot is the scientific source of truth. The PPEF series has two
#' genuine snapshots (2026-04, 2026-07), so most arm observations predate it;
#' where no snapshot matches, the ever-crosswalk is used and the row says so in
#' `bridge_source`. A pair that was ambiguous in ANY snapshot is not treated as
#' a durable identifier relation.
#'
#' @section The BEFORE state is READ, not recomputed:
#' It comes from artifacts/organization_affiliation_resolved.csv exactly as that
#' file recorded it. Recomputing it with today's code would compare the new
#' method against itself and the audit would be meaningless.
#'
#' Inputs : artifacts/organization_affiliation_resolved.csv (the frozen before)
#'          artifacts/pac_npi_snapshot.csv, artifacts/pac_npi_ever.csv
#'          the arm artifacts, for their NATIVE identifiers
#' Outputs: artifacts/organization_identity_pairings.csv          (gitignored)
#'          artifacts/organization_identity_transitions.csv       (tracked)
#'          artifacts/organization_identity_coverage.csv          (tracked)
#'          artifacts/organization_identity_conflicts.csv         (tracked)
#'
#' @family organization-linkage
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tidyr); library(cli)
})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "org_names.R"))

OUT_PAIR <- "artifacts/organization_identity_pairings.csv"
OUT_TRA  <- "artifacts/organization_identity_transitions.csv"
OUT_COV  <- "artifacts/organization_identity_coverage.csv"
OUT_CON  <- "artifacts/organization_identity_conflicts.csv"

rd <- function(p) read_csv(p, col_types = cols(.default = "c"), progress = FALSE)
need <- function(p, why) {
  if (!file.exists(p))
    stop(sprintf("%s not found.\n  %s\n  Refusing to report a reconciliation that did not happen.",
                 p, why), call. = FALSE)
  invisible(p)
}
need("artifacts/pac_npi_ever.csv", "Run build_pac_id_npi_crosswalk.R first.")
need("artifacts/organization_affiliation_resolved.csv",
     "Run build_organization_affiliation_resolver.R first; it is the frozen BEFORE state.")

# --- the bridge --------------------------------------------------------------
ever <- rd("artifacts/pac_npi_ever.csv")
# Durable relation = unique AND never ambiguous in any snapshot.
ever_ok <- ever %>%
  filter(pac_npi_resolution == "unique",
         !(ever_ambiguous %in% c("TRUE", "true"))) %>%
  distinct(pac_id, .keep_all = TRUE) %>%
  select(pac_id, ever_npi = npi, ever_name = organization_name)
# Multi-NPI corporate entities: knowable as an entity, not as a site.
chain_pacs <- ever %>%
  filter(pac_npi_resolution != "unique") %>% distinct(pac_id) %>% pull(pac_id)
cli::cli_alert_info("bridge: {format(nrow(ever_ok), big.mark = ',')} durable PAC->NPI; {format(length(chain_pacs), big.mark = ',')} multi-NPI entities")

bridge_snap <- if (file.exists("artifacts/pac_npi_snapshot.csv")) {
  rd("artifacts/pac_npi_snapshot.csv") %>%
    filter(pac_npi_resolution == "unique") %>%
    transmute(join_snapshot = substr(snapshot_date, 1, 7), pac_id, snap_npi = npi) %>%
    distinct(join_snapshot, pac_id, .keep_all = TRUE)
} else NULL

# --- canonical organization-evidence table -----------------------------------
# One row per (midwife, source, source organization). The RAW source name is
# never overwritten; org_key is an additional column, not a replacement.
cli::cli_h2("Canonical organization evidence")
SRC_ID_TYPE <- c(pecos_reassignment = "pac", care_compare_group = "pac",
                 nppes_org_colocation = "npi", open_payments_org = "npi",
                 facility_affiliation = "ccn", hospital_affiliation = "ccn")
ev <- list()
arm_add <- function(nm, d) {
  if (is.null(d) || !nrow(d)) return(invisible())
  ev[[nm]] <<- d %>% mutate(source = nm, source_id_type = unname(SRC_ID_TYPE[nm]))
  cli::cli_alert_success("{nm}: {format(nrow(d), big.mark = ',')} evidence rows")
}
if (file.exists("artifacts/midwife_reassignment_spells.csv"))
  arm_add("pecos_reassignment", rd("artifacts/midwife_reassignment_spells.csv") %>%
        transmute(midwife_npi, source_organization_id = org_pac_id,
                  organization_name_raw = organization_name,
                  source_snapshot_date = last_seen_vintage) %>%
        filter(!is.na(source_organization_id), nzchar(source_organization_id)))
if (file.exists("artifacts/midwife_organization_panel.csv"))
  arm_add("care_compare_group", rd("artifacts/midwife_organization_panel.csv") %>%
        filter(has_group %in% c("TRUE", "true")) %>%
        transmute(midwife_npi, source_organization_id = org_pac_id,
                  organization_name_raw = organization_name,
                  source_snapshot_date = vintage) %>%
        filter(!is.na(source_organization_id), nzchar(source_organization_id)) %>% distinct())
coloc <- NULL
if (file.exists("artifacts/nppes_colocation_2025.csv"))
  coloc <- rd("artifacts/nppes_colocation_2025.csv") %>%
    transmute(midwife_npi = npi, source_organization_id = org_npi,
              organization_name_raw = organization_name,
              source_snapshot_date = nppes_vintage)
if (file.exists("artifacts/midwife_org_person.csv")) {
  o <- rd("artifacts/midwife_org_person.csv") %>%
    transmute(midwife_npi = npi, source_organization_id = org_npi,
              organization_name_raw = organization_name,
              source_snapshot_date = NA_character_)
  coloc <- if (is.null(coloc)) o else bind_rows(coloc, o %>% filter(!midwife_npi %in% coloc$midwife_npi))
}
if (!is.null(coloc)) arm_add("nppes_org_colocation",
                         coloc %>% filter(!is.na(source_organization_id),
                                          nzchar(source_organization_id)))
if (file.exists("artifacts/dac_facility_affiliations.csv"))
  arm_add("facility_affiliation", rd("artifacts/dac_facility_affiliations.csv") %>%
        transmute(midwife_npi = npi, source_organization_id = ccn,
                  organization_name_raw = facility_name,
                  source_snapshot_date = NA_character_) %>%
        filter(!is.na(source_organization_id), nzchar(source_organization_id)))
if (file.exists("artifacts/midwife_hospital_affiliations.csv"))
  arm_add("hospital_affiliation", rd("artifacts/midwife_hospital_affiliations.csv") %>%
        transmute(midwife_npi = npi, source_organization_id = cms_ccn,
                  organization_name_raw = hospital_name,
                  source_snapshot_date = NA_character_) %>%
        filter(!is.na(source_organization_id), nzchar(source_organization_id)))

evidence <- bind_rows(ev) %>%
  mutate(organization_name_normalized = norm_org(organization_name_raw)) %>%
  distinct(midwife_npi, source, source_id_type, source_organization_id,
           organization_name_raw, organization_name_normalized, source_snapshot_date)
N_EVIDENCE_IN <- nrow(evidence)
# Frozen immediately after construction; compared at the end. Nothing between
# here and there may rewrite a source name.
FROZEN_RAW_NAMES <- evidence$organization_name_raw
cli::cli_alert_info("evidence rows: {format(N_EVIDENCE_IN, big.mark = ',')}")

# --- resolve identifiers, hierarchy A-F --------------------------------------
cli::cli_h2("Identifier resolution")
evidence <- evidence %>%
  mutate(organization_pac_id = if_else(source_id_type == "pac",
                                       source_organization_id, NA_character_),
         direct_npi = if_else(source_id_type == "npi",
                              source_organization_id, NA_character_),
         join_snapshot = substr(source_snapshot_date, 1, 7))
if (!is.null(bridge_snap)) {
  evidence <- evidence %>%
    left_join(bridge_snap, by = c("organization_pac_id" = "pac_id", "join_snapshot"))
} else evidence$snap_npi <- NA_character_
evidence <- evidence %>%
  left_join(ever_ok, by = c("organization_pac_id" = "pac_id")) %>%
  mutate(
    is_chain_pac = !is.na(organization_pac_id) & organization_pac_id %in% chain_pacs,
    organization_npi = case_when(
      !is.na(direct_npi) ~ direct_npi,                       # A
      !is.na(snap_npi)   ~ snap_npi,                         # C, snapshot-matched
      !is.na(ever_npi)   ~ ever_npi,                         # C, ever fallback
      TRUE               ~ NA_character_),
    bridge_source = case_when(
      !is.na(direct_npi) ~ "native_npi",
      !is.na(snap_npi)   ~ "snapshot_matched",
      !is.na(ever_npi)   ~ "ever_crosswalk",
      is_chain_pac       ~ "multi_npi_entity",
      source_id_type == "ccn" ~ "unbridged_ccn",
      TRUE               ~ "unbridged"),
    organization_identity_level = case_when(
      !is.na(organization_npi) ~ "specific_npi",
      is_chain_pac             ~ "pac_entity",
      !is.na(organization_pac_id) ~ "pac_entity",
      TRUE                     ~ "name_only"))
print(as.data.frame(count(evidence, source, bridge_source)), row.names = FALSE)

# --- BEFORE, read from the frozen artifact -----------------------------------
cli::cli_h2("BEFORE (read, not recomputed)")
before <- rd("artifacts/organization_affiliation_resolved.csv")
before_pair <- before %>%
  transmute(midwife_npi = npi, org_key = norm_org(organization_name),
            before_class = affiliation_class,
            before_evidence_count = as.integer(affiliation_evidence_count))
print(as.data.frame(count(before_pair, before_class, sort = TRUE)), row.names = FALSE)

# --- cross-source pairings ---------------------------------------------------
cli::cli_h2("Cross-source pairings")
a <- evidence %>% select(midwife_npi, source_a = source, id_type_a = source_id_type,
                         pac_a = organization_pac_id, npi_a = organization_npi,
                         key_a = organization_name_normalized,
                         raw_a = organization_name_raw, lvl_a = organization_identity_level,
                         chain_a = is_chain_pac, bridge_a = bridge_source)
b <- evidence %>% select(midwife_npi, source_b = source, id_type_b = source_id_type,
                         pac_b = organization_pac_id, npi_b = organization_npi,
                         key_b = organization_name_normalized,
                         raw_b = organization_name_raw, lvl_b = organization_identity_level,
                         chain_b = is_chain_pac, bridge_b = bridge_source)
pair <- inner_join(a, b, by = "midwife_npi", relationship = "many-to-many") %>%
  filter(source_a < source_b)
cli::cli_alert_info("pairings: {format(nrow(pair), big.mark = ',')}")

pair <- pair %>% mutate(
  comparison_type = paste(pmin(id_type_a, id_type_b), pmax(id_type_a, id_type_b), sep = "-"),
  name_match = key_a == key_b,
  npi_match  = !is.na(npi_a) & !is.na(npi_b) & npi_a == npi_b,
  npi_conflict = !is.na(npi_a) & !is.na(npi_b) & npi_a != npi_b,
  pac_match  = !is.na(pac_a) & !is.na(pac_b) & pac_a == pac_b,
  chain_pair = chain_a | chain_b,

  # A pairing whose two sides carry different organization NPIs is an
  # identifier conflict. It is NOT reconciled by falling back to the name --
  # that is exactly the move this whole exercise exists to stop.
  after_class = case_when(
    npi_match & !chain_pair            ~ "specific_npi_confirmed",
    npi_match &  chain_pair            ~ "pac_entity_confirmed",
    pac_match &  chain_pair            ~ "pac_entity_confirmed",
    npi_conflict                       ~ "true_identifier_conflict",
    pac_match & !npi_conflict          ~ "pac_entity_confirmed",
    name_match                         ~ "name_only_agreement",
    TRUE                               ~ "unresolved"),
  after_identity_level = case_when(
    after_class == "specific_npi_confirmed"   ~ "specific_npi",
    after_class == "pac_entity_confirmed"     ~ "pac_entity",
    after_class == "name_only_agreement"      ~ "name_only",
    TRUE                                      ~ "unresolved"),
  # BEFORE, on the same unit: name identity was all that existed.
  before_class_pair = if_else(name_match, "cross_source_name_agreement",
                              "cross_source_disagreement"),
  # Identity and TIMING are separate claims, and the artifact must keep them
  # separate. A retrospective bridge can say "these two labels are the same CMS
  # organization identity"; it cannot equally say "that identifier was attached
  # to this source record at that historical date". With both PPEF snapshots in
  # 2026 and arm observations spanning 2021-2026, ~89% of newly reconciled
  # pairings rest on the retrospective form, so collapsing the two would
  # overstate the temporal claim for almost the whole gain.
  organization_identity_resolved = after_class %in%
    c("specific_npi_confirmed", "pac_entity_confirmed"),
  temporal_alignment = case_when(
    !organization_identity_resolved                                ~ NA_character_,
    bridge_a == "snapshot_matched" & bridge_b == "snapshot_matched" ~ "snapshot_matched",
    bridge_a == "native_npi"       & bridge_b == "native_npi"       ~ "native_identifier",
    bridge_a == "snapshot_matched" | bridge_b == "snapshot_matched" ~ "partial_snapshot_matched",
    TRUE                                                            ~ "retrospective_bridge"),
  transition = case_when(
    !name_match & after_class == "specific_npi_confirmed"
      ~ "identifier_resolved_name_disagreement",
    !name_match & after_class == "pac_entity_confirmed"
      ~ "pac_entity_resolved_name_disagreement",
    name_match  & after_class == "true_identifier_conflict"
      ~ "REFUTED_name_collision",
    name_match  & after_class %in% c("specific_npi_confirmed", "pac_entity_confirmed")
      ~ "identifier_confirmed_same_name",
    !name_match & after_class == "true_identifier_conflict"
      ~ "true_identifier_conflict",
    name_match  & after_class == "name_only_agreement"
      ~ "name_only_agreement",
    TRUE ~ "unresolved"))

cli::cli_h2("Transitions")
tra <- pair %>% count(comparison_type, before_class_pair, after_class, transition,
                      name = "n_pairings") %>%
  group_by(before_class_pair) %>%
  mutate(pct_of_before_class = round(100 * n_pairings / sum(n_pairings), 2)) %>%
  ungroup() %>% arrange(comparison_type, desc(n_pairings))
print(as.data.frame(tra %>% select(-comparison_type) %>%
                      group_by(before_class_pair, after_class) %>%
                      summarise(n = sum(n_pairings), .groups = "drop") %>%
                      group_by(before_class_pair) %>%
                      mutate(pct_of_before = round(100 * n / sum(n), 1)) %>% ungroup()),
      row.names = FALSE)

# --- identifier conflicts, quarantined ---------------------------------------
conf <- pair %>% filter(after_class == "true_identifier_conflict") %>%
  count(source_a, source_b, comparison_type, name = "n_pairings")
cli::cli_alert_warning("identifier conflicts: {format(sum(pair$after_class == 'true_identifier_conflict'), big.mark = ',')} pairings; these do NOT enter the confirmed set")
if (nrow(conf)) print(as.data.frame(conf), row.names = FALSE)
write_with_provenance(conf, OUT_CON, na = "", inputs = prov_inputs("artifacts/pac_npi_ever.csv"))

# --- CONSERVATION ------------------------------------------------------------
# The reconciliation changes interpretation, never source evidence.
cli::cli_h2("Conservation")
stopifnot(nrow(evidence) == N_EVIDENCE_IN)
in_ev <- n_distinct(evidence$midwife_npi)
in_pair <- n_distinct(pair$midwife_npi)
cli::cli_alert_success("evidence rows unchanged: {format(N_EVIDENCE_IN, big.mark = ',')}")
cli::cli_alert_success("midwives in evidence {format(in_ev, big.mark = ',')}; in pairings {format(in_pair, big.mark = ',')} (pairings need >=2 sources)")
# The guard is that WE did not lose a name, not that every source had one:
# some arms legitimately record a relationship with no organization name, and
# treating that as corruption halts a run over data that is simply sparse. An
# earlier version tested is.na() and stopped the whole reconciliation.
if (!identical(evidence$organization_name_raw, FROZEN_RAW_NAMES))
  stop("a raw source organization name was altered by the reconciliation",
       call. = FALSE)
cli::cli_alert_success("no raw source name or date was overwritten")

# --- per-midwife coverage, the paper table -----------------------------------
cli::cli_h2("Coverage by identity level")
LEVELS <- c("specific_npi", "pac_entity", "name_only", "unresolved")
per_mw <- evidence %>%
  group_by(midwife_npi) %>%
  summarise(best_identity_level = LEVELS[min(match(organization_identity_level, LEVELS))],
            n_specific_npi = n_distinct(organization_npi[!is.na(organization_npi)]),
            .groups = "drop")

cw <- Sys.glob("artifacts/amcb_npi_crosswalk_*panel*.csv")
cw <- cw[!grepl("\\.manifest\\.json$|\\.provenance\\.json$", cw)]
cw <- cw[order(file.mtime(cw), decreasing = TRUE)][1]
spine <- rd(cw) %>% filter(!is.na(npi), nzchar(npi)) %>%
  distinct(certification_number = amcb_id, midwife_npi = npi)
status <- if (file.exists("artifacts/cohort_membership_four_way.csv")) {
  rd("artifacts/cohort_membership_four_way.csv") %>%
    distinct(certification_number, .keep_all = TRUE) %>% select(certification_number, status)
} else tibble::tibble(certification_number = character(), status = character())

cov <- spine %>% left_join(status, by = "certification_number") %>%
  left_join(per_mw, by = "midwife_npi") %>%
  mutate(best_identity_level = coalesce(best_identity_level, "unresolved"))
active <- cov %>% filter(status == "ACTIVE")
cov_tab <- active %>% count(best_identity_level, name = "n_active_midwives") %>%
  mutate(pct = round(100 * n_active_midwives / nrow(active), 1)) %>%
  arrange(match(best_identity_level, LEVELS))
print(as.data.frame(cov_tab), row.names = FALSE)

# --- gain among the PREVIOUSLY UNRESOLVED only -------------------------------
# Improvements among already-covered midwives must not inflate this.
cli::cli_h2("Gain among the previously unresolved")
before_npis <- unique(before$npi)
unres_before <- active %>% filter(!midwife_npi %in% before_npis)
gained <- unres_before %>% filter(best_identity_level != "unresolved")
cli::cli_alert_info("ACTIVE unresolved BEFORE: {format(nrow(unres_before), big.mark = ',')}")
cli::cli_alert_info("of those, now have an organization identity: {format(nrow(gained), big.mark = ',')}")
if (nrow(gained)) print(as.data.frame(count(gained, best_identity_level)), row.names = FALSE)

write_with_provenance(pair, OUT_PAIR, na = "", inputs = prov_inputs("artifacts/pac_npi_ever.csv"))
write_with_provenance(tra, OUT_TRA, na = "", inputs = prov_inputs(OUT_PAIR))
write_with_provenance(
  bind_rows(cov_tab %>% mutate(cohort = "active_all"),
            count(gained, best_identity_level, name = "n_active_midwives") %>%
              mutate(pct = NA_real_, cohort = "active_unresolved_before")),
  OUT_COV, na = "", inputs = prov_inputs(OUT_PAIR))
cli::cli_alert_success("wrote {OUT_PAIR}, {OUT_TRA}, {OUT_COV}, {OUT_CON}")

# --- the five headline numbers -----------------------------------------------
cli::cli_h2("Headline")
nm_dis <- sum(pair$before_class_pair == "cross_source_disagreement")
p <- function(n, d) if (d > 0) sprintf("%.1f%%", 100 * n / d) else "-"
cat(sprintf("  1. ACTIVE unresolved before: %s; gained an organization: %s\n",
            format(nrow(unres_before), big.mark = ","), format(nrow(gained), big.mark = ",")))
cat(sprintf("  2. former name-disagreements now the SAME specific NPI: %s (%s)\n",
            format(sum(pair$transition == "identifier_resolved_name_disagreement"), big.mark = ","),
            p(sum(pair$transition == "identifier_resolved_name_disagreement"), nm_dis)))
cat(sprintf("  3. ... same PAC entity, different/unknown site: %s (%s)\n",
            format(sum(pair$transition == "pac_entity_resolved_name_disagreement"), big.mark = ","),
            p(sum(pair$transition == "pac_entity_resolved_name_disagreement"), nm_dis)))
cat(sprintf("  4. ... remaining TRUE identifier disagreements: %s (%s)\n",
            format(sum(pair$transition == "true_identifier_conflict"), big.mark = ","),
            p(sum(pair$transition == "true_identifier_conflict"), nm_dis)))
cat("  5. ACTIVE midwives by best identity level:\n")
for (i in seq_len(nrow(cov_tab)))
  cat(sprintf("       %-14s %8s  %5.1f%%\n", cov_tab$best_identity_level[i],
              format(cov_tab$n_active_midwives[i], big.mark = ","), cov_tab$pct[i]))
cat(sprintf("     name collisions REFUTED by identifier: %s\n",
            format(sum(pair$transition == "REFUTED_name_collision"), big.mark = ",")))

# --- 6. how much of this rests on an UNDATED bridge --------------------------
# With only two PPEF snapshots, both 2026, most arm observations predate the
# crosswalk entirely. A relation bridged by ever_crosswalk is evidence about
# ORGANIZATION IDENTITY but weaker evidence about affiliation AT A DATE: it
# assumes the PAC->NPI mapping held at a time we never observed. Reporting the
# split is the difference between "600 newly resolved" and "600 newly resolved,
# 580 of them on an assumption".
cli::cli_h2("Bridge provenance")
bridged <- evidence %>% filter(!is.na(organization_npi), !is.na(organization_pac_id))
bp <- bridged %>% count(bridge_source, name = "n_evidence_rows") %>%
  mutate(pct = round(100 * n_evidence_rows / sum(n_evidence_rows), 1))
print(as.data.frame(bp), row.names = FALSE)

resolved_pairs <- pair %>%
  filter(transition %in% c("identifier_resolved_name_disagreement",
                           "pac_entity_resolved_name_disagreement"))
rp <- resolved_pairs %>%
  mutate(bridge_pair = case_when(
    bridge_a == "snapshot_matched" & bridge_b == "snapshot_matched" ~ "both_snapshot_matched",
    bridge_a == "snapshot_matched" | bridge_b == "snapshot_matched" ~ "one_snapshot_matched",
    bridge_a == "native_npi" & bridge_b == "native_npi"             ~ "both_native_npi",
    TRUE                                                            ~ "relies_on_ever_crosswalk")) %>%
  count(bridge_pair, name = "n_pairings") %>%
  mutate(pct = round(100 * n_pairings / sum(n_pairings), 1))
cat("\n  of the pairings NEWLY reconciled by identifier:\n")
print(as.data.frame(rp), row.names = FALSE)

gained_prov <- evidence %>% filter(midwife_npi %in% gained$midwife_npi) %>%
  count(bridge_source, name = "n_evidence_rows") %>%
  mutate(pct = round(100 * n_evidence_rows / sum(n_evidence_rows), 1))
if (nrow(gained_prov)) {
  cat("\n  evidence behind the newly-resolved midwives:\n")
  print(as.data.frame(gained_prov), row.names = FALSE)
}
write_with_provenance(
  bind_rows(bp %>% mutate(scope = "all_bridged_evidence"),
            rp %>% rename(bridge_source = bridge_pair, n_evidence_rows = n_pairings) %>%
              mutate(scope = "newly_reconciled_pairings"),
            gained_prov %>% mutate(scope = "newly_resolved_midwives")),
  "artifacts/organization_identity_bridge_provenance.csv", na = "",
  inputs = prov_inputs(OUT_PAIR))
cli::cli_alert_success("wrote artifacts/organization_identity_bridge_provenance.csv")
