#!/usr/bin/env Rscript
# =============================================================================
# Three-arm linkage audit: separate the NPPES vintage effect from the logic change
# =============================================================================
# Comparing the frozen cohort straight to a 2026 rerun would confound TWO
# changes and report their sum as one number:
#
#   A  baseline      the frozen cohort -- old matcher, 2007-2025 panel.
#                    16,898 members across evidence classes 1-4.
#   B  logic only    CURRENT matcher, 2026 panel CAPPED at 2025
#                    (PANEL_YEAR_MAX=2025). Same input rows as A -- the 2026
#                    panel's 2007-2025 prefix is byte-identical to the old
#                    panel, verified by sha256 at promotion -- so B differs
#                    from A only by matcher logic, chiefly commit d6e4e8f
#                    retiring class-4 (Levenshtein) matching.
#   C  logic+vintage CURRENT matcher, full 2007-2026 panel.
#
#   A -> B  the logic change alone
#   B -> C  the NPPES vintage alone
#   A -> C  the combined effect, which is what a naive before/after would show
#
# WHY B IS NECESSARY AND NOT PEDANTRY. Class 4 was deleted by explicit decision
# on 2026-10-22, after the freeze. The frozen cohort's 323 class-4 members were
# admitted under a rule that no longer exists. Without arm B, that deletion and
# a year of fresh NPPES evidence arrive as a single membership delta, and
# whichever direction it points would be read as the vintage's doing.
#
# NO ARM IS CALLED AN IMPROVEMENT HERE. This script reports deltas and leaves
# interpretation to a reader who can see which arm moved what.
#
# Output: artifacts/linkage_arms_3way_audit.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(digest); library(tidyr)
})
source(file.path("R", "lib", "artifact_provenance.R"))  # write_with_provenance()

ART <- Sys.getenv("ARMS_ART_DIR", "artifacts")
BASE_ART <- Sys.getenv("BASELINE_ART_DIR", ART)

arms <- list(
  A_baseline_frozen     = file.path(BASE_ART, "amcb_npi_linkage_FROZEN.csv"),
  B_logic_only_thru2025 = file.path(ART, "amcb_npi_linkage_panel-midwifery-plus-nursing_years-through-2025.csv"),
  C_logic_plus_vintage  = file.path(ART, "amcb_npi_linkage_panel-midwifery-plus-nursing_years-2007-2026.csv"))

present <- vapply(arms, file.exists, logical(1))
if (!all(present))
  cat(sprintf("NOTE: %d/%d arms present; missing: %s\n", sum(present), length(arms),
              paste(names(arms)[!present], collapse = ", ")))
arms <- arms[present]
if (!length(arms)) stop("no arm artifacts found.", call. = FALSE)

MEMBER_CLASSES <- c("1", "2", "3", "4")

describe <- function(label, path) {
  d <- read_csv(path, col_types = cols(.default = "c"), progress = FALSE)
  cls <- trimws(ifelse(is.na(d$name_evidence_class), "", d$name_evidence_class))
  npi <- trimws(ifelse(is.na(d$npi), "", d$npi))
  c5  <- if ("class5_candidate_npi" %in% names(d))
           trimws(ifelse(is.na(d$class5_candidate_npi), "", d$class5_candidate_npi)) else rep("", nrow(d))
  # Membership is recomputed by the SAME rule for every arm, so the comparison
  # is of linkage evidence and not of whichever arm happened to carry a
  # cohort_member column. The frozen arm already holds class-5 npis blanked, so
  # the rule lands identically on all three.
  member <- cls %in% MEMBER_CLASSES & nzchar(npi)
  tibble(
    arm = label,
    artifact = basename(path),
    sha256 = digest(file = path, algo = "sha256"),
    certificants = nrow(d),
    linked_identities = sum(nzchar(npi)),
    distinct_npis = n_distinct(npi[nzchar(npi)]),
    members_by_rule = sum(member),
    class1 = sum(cls == "1"), class2 = sum(cls == "2"), class3 = sum(cls == "3"),
    class4 = sum(cls == "4"), class5 = sum(cls == "5"),
    no_class = sum(!nzchar(cls)),
    class5_candidates_preserved = sum(nzchar(c5)),
    abstention_rate_pct = round(100 * mean(!nzchar(npi)), 2),
    match_rate_pct = round(100 * mean(nzchar(npi)), 2))
}

tab <- bind_rows(Map(describe, names(arms), arms))
cat("\n=== THREE-ARM AUDIT ===\n")
print(as.data.frame(tab %>% select(-sha256, -artifact)), row.names = FALSE)
cat("\nartifact hashes:\n")
for (i in seq_len(nrow(tab)))
  cat(sprintf("  %-24s %s\n    %s\n", tab$arm[i], substr(tab$sha256[i], 1, 32), tab$artifact[i]))

# --- deltas, attributed ------------------------------------------------------
delta <- function(from, to, what) {
  if (!all(c(from, to) %in% tab$arm)) return(NULL)
  a <- tab[tab$arm == from, ]; b <- tab[tab$arm == to, ]
  tibble(comparison = sprintf("%s -> %s", from, to), attributes_to = what,
         d_linked = b$linked_identities - a$linked_identities,
         d_members = b$members_by_rule - a$members_by_rule,
         d_class4 = b$class4 - a$class4,
         d_class5 = b$class5 - a$class5,
         d_no_class = b$no_class - a$no_class)
}
d <- bind_rows(
  delta("A_baseline_frozen", "B_logic_only_thru2025", "matcher logic (class-4 retirement)"),
  delta("B_logic_only_thru2025", "C_logic_plus_vintage", "NPPES vintage (2025-11-09 -> 2026-08-09)"),
  delta("A_baseline_frozen", "C_logic_plus_vintage", "BOTH (what a naive before/after shows)"))
if (nrow(d)) { cat("\n=== DELTAS, ATTRIBUTED ===\n"); print(as.data.frame(d), row.names = FALSE) }

# --- per-certificant movement between arms -----------------------------------
if (all(c("A_baseline_frozen", "C_logic_plus_vintage") %in% tab$arm)) {
  rd <- function(p) read_csv(p, col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(certification_number,
              npi = trimws(ifelse(is.na(npi), "", npi)),
              cls = trimws(ifelse(is.na(name_evidence_class), "", name_evidence_class)))
  A <- rd(arms[["A_baseline_frozen"]]); C <- rd(arms[["C_logic_plus_vintage"]])
  j <- full_join(A, C, by = "certification_number", suffix = c("_A", "_C"))
  mv <- j %>% mutate(movement = case_when(
    npi_A == npi_C                        ~ "same npi",
    !nzchar(npi_A) & nzchar(npi_C)        ~ "gained an npi",
    nzchar(npi_A) & !nzchar(npi_C)        ~ "lost its npi",
    TRUE                                  ~ "REASSIGNED to a different npi")) %>%
    count(movement, name = "n") %>% arrange(desc(n))
  cat("\n=== per-certificant movement, baseline -> current ===\n")
  print(as.data.frame(mv), row.names = FALSE)
  cat("\nNOTE: 'REASSIGNED' is the row to read first. A gain or loss follows from\n")
  cat("the rule change; a reassignment means the same person now resolves to a\n")
  cat("DIFFERENT identity, which no rule change explains on its own.\n")
}

# Two tables, two files. Cross-joining the per-arm rows onto the per-comparison
# rows would emit arms x comparisons rows of nonsense -- they are different
# units of observation and belong apart.
# Inputs are whichever arms were PRESENT, not the three this script knows
# about: it reports a partial run rather than failing, so the sidecar has to
# say which arms the numbers actually came from.
write_with_provenance(tab, "artifacts/linkage_arms_3way_audit.csv",
                      inputs = unlist(arms, use.names = FALSE), na = "")
cat("\nwrote artifacts/linkage_arms_3way_audit.csv (one row per arm)\n")
if (nrow(d)) {
  write_with_provenance(d, "artifacts/linkage_arms_3way_deltas.csv",
                        inputs = unlist(arms, use.names = FALSE), na = "")
  cat("wrote artifacts/linkage_arms_3way_deltas.csv (one row per comparison)\n")
}
