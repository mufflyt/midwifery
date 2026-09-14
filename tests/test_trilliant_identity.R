#!/usr/bin/env Rscript
# =============================================================================
# Trilliant as a second identity source: R/lib/trilliant_identity.R
# =============================================================================
# The ways this goes wrong quietly: taxonomy breaks a tie the resolver refuses
# to break, and nothing shows it; a candidate whose surname simply differs is
# proposed because everything else agrees; an NPI another certificant holds is
# proposed again; a pool where every candidate is contradicted is reported as
# "no candidate"; a spelling variant of one middle name counts as two people;
# an unknown evidence level scores zero instead of stopping. Fixtures are
# synthetic (invented names and NPIs), not source data.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "credential_compatibility.R"))
source(file.path(root, "R", "lib", "trilliant_identity.R"))

fails <- 0L
chk <- function(ok, label) {
  cat(sprintf("  %-4s %s\n", if (isTRUE(ok)) "ok" else "FAIL", label))
  if (!isTRUE(ok)) fails <<- fails + 1L
}

cat("\n-- PROFESSION --\n")
chk(identical(trl_taxonomy_class(c("367A00000X", "176B00000X", "363LW0102X", "367500000X", "367H00000X",
                                   "207V00000X", "163W00000X", NA)),
              c("midwife", "midwife", "nursing", "nursing", "other", "physician", "nursing", NA)),
    "T1 taxonomy classes; a nurse anesthetist is nursing, an anesthesiologist assistant is not")
chk(identical(trl_credential_class(c("CNM", "APRN CNM", "RN", "MD", "PA-C", NA)),
              c("midwife", "midwife", "nursing", "physician", "other", NA)),
    "T2 credential classes come from classify_credentials(), renamed")
p <- trl_profession(c("physician", "nursing", "nursing", NA), c("midwife", "nursing", NA, NA),
                    c(NA, "midwife|nursing", NA, NA))
chk(identical(p$profession_class, c("midwife", "midwife", "nursing", "unknown")) &&
      identical(p$profession_mixed, c(TRUE, FALSE, FALSE, FALSE)),
    "T3 midwifery from any source wins and a physician taxonomy beside it is flagged mixed")

cat("\n-- GRADUATION YEAR --\n")
chk(identical(trl_grad_year_band(c(2010, 2013, 2003, 2021, NA, 1999), c(2010, 2010, 2010, 2010, 2010, NA)),
              c("within_1", "within_3", "within_10", "beyond_10", "unknown", "unknown")),
    "T4 bands by |graduation - certification|; either year missing is unknown, not a match")

cat("\n-- NAME EVIDENCE --\n")
np <- tibble::tibble(
  amcb_last   = c("SMITH", "JONES", "GARCIA", "OKAFOR", "SMITH", "SMITH", "SMITH", "SMITH", "SMITH", "SMITH", "SMITH"),
  amcb_given  = c("JANE", "JANE", "MARIA", "ADA", "JANE", "KATHERINE", "JANE", "JANE", "JANE", "JANE", "JANE"),
  amcb_middle = c("ANN", "", "", "", "", "", "ANN", "ANN", "", "", ""),
  trl_last    = c("SMITH", "SMITH JONES", "LOPEZ", "BELL", "SMYTH", "SMITH", "SMITH", "SMITH", "SMITH", "WU", "SMITH"),
  trl_given   = c("JANE", "JANE", "MARIA", "ADA", "JANE", "KATHY", "JANE", "JANE", "J", "JANE", "JOAN"),
  trl_middle  = c("A", "", "GARCIA", "", "", "", "ANNE", "BETH", "", "", ""),
  nppes_other_last = c("", "", "", "OKAFOR", "", "", "", "", "", "", ""),
  last_edit_distance = c(0L, 6L, 5L, 6L, 1L, 0L, 0L, 0L, 0L, 5L, 0L))
ne <- trl_name_evidence(np)
chk(identical(ne$surname_evidence, c("exact", "component", "component", "alias_nppes", "edit_1_2", "exact",
                                     "exact", "exact", "exact", "different", "exact")),
    "T5 surname: exact, shared component, maiden name carried as a middle name, NPPES alias, edit distance, different")
chk(identical(ne$given_evidence[c(1, 6, 9, 11)], c("exact", "nickname", "initial", "conflict")),
    "T6 given name: exact, nickname, initial only, and a different given name with the same initial")
chk(identical(ne$middle_evidence[c(1, 2, 7, 8)], c("corroborates", "uninformative", "initial_only", "conflicts")),
    "T7 middle: initial agreement corroborates; ANN/ANNE is initial_only, not a contradiction; ANN/BETH conflicts")
chk(inherits(try(trl_name_evidence(np[, 1:6]), silent = TRUE), "try-error"),
    "T8 a missing input column stops rather than scoring blanks")
gv <- trl_name_evidence(tibble::tibble(
  amcb_last = "DOE", trl_last = "DOE", nppes_other_last = "", last_edit_distance = 0L,
  amcb_given  = c("ROSEANNE", "ANNA-MARIA", "MARYJO", "KATHRYN", "MEILING", "KERRY", "JENNIFER"),
  amcb_middle = c("", "", "", "", "", "", ""),
  trl_given   = c("ROSE", "ANNA", "MARY", "KATHRIN", "GRACE", "TERRY", "JESSICA"),
  trl_middle  = c("ANNE", "MARIA", "", "", "MEILING", "", "")))
chk(identical(gv$given_evidence, c("compound", "compound", "compound", "spelling_variant", "given_in_middle",
                                   "conflict", "conflict")),
    "T8b fused, split and prefixed given names, one-edit variants of long names and a given name kept as a middle are not conflicts; KERRY/TERRY (one edit, too short) and JENNIFER/JESSICA are")

cat("\n-- SCORES --\n")
base_ev <- function(...) {
  d <- tibble::tibble(surname_evidence = "exact", given_evidence = "exact", middle_evidence = "uninformative",
                      profession_class = "midwife", grad_year_band = "unknown", trl_sex = "F")
  mods <- list(...)
  for (m in names(mods)) d[[m]] <- mods[[m]]
  d
}
s <- trl_score_pairs(dplyr::bind_rows(
  base_ev(middle_evidence = "corroborates", grad_year_band = "within_1"),
  base_ev(profession_class = "physician"),
  base_ev(trl_sex = "M"),
  base_ev(grad_year_band = "beyond_10")))
chk(identical(s$score_full, c(17, 2, 11, 9)) && identical(s$score_identity_only, c(12, 7, 6, 4)),
    "T9 full adds profession; identity_only never does")
chk(identical(s$contradiction_count, c(0L, 1L, 0L, 1L)),
    "T10 a physician record and a graduation year >10 years off are contradictions; MALE is only a penalty")
chk(identical(s$corroborated_identity, c(TRUE, FALSE, FALSE, FALSE)) &&
      identical(s$corroborated_full, c(TRUE, FALSE, TRUE, TRUE)),
    "T11 corroboration: graduation year for identity_only; graduation year or midwifery for full")
chk(inherits(try(trl_score_pairs(base_ev(grad_year_band = "close")), silent = TRUE), "try-error"),
    "T12 an unknown evidence level stops; it never scores zero")

cat("\n-- DECISIONS --\n")
candidate_row <- function(amcb_id, npi, ..., held = FALSE) {
  d <- base_ev(...)
  d$amcb_id <- amcb_id; d$npi <- npi; d$npi_held_by_other_certificant <- held
  d
}
pool <- dplyr::bind_rows(
  candidate_row("A", "1000000001", grad_year_band = "within_1"),                         # A: clear winner
  candidate_row("A", "1000000002", profession_class = "nursing"),
  candidate_row("B", "1000000003"), candidate_row("B", "1000000004"),                             # B: two CNMs, nothing else
  candidate_row("C", "1000000005", profession_class = "physician"),                      # C: only contradicted
  candidate_row("C", "1000000006", profession_class = "other"),
  candidate_row("D", "1000000007", surname_evidence = "different", middle_evidence = "corroborates",
       grad_year_band = "within_1"),                                            # D: surname changed, no alias
  candidate_row("E", "1000000008", grad_year_band = "within_1", held = TRUE),            # E: NPI held by another
  candidate_row("F", "1000000009"), candidate_row("F", "1000000010", profession_class = "nursing")) # F: taxonomy separates
sc <- trl_score_pairs(pool)
dec <- function(v) {
  d <- trl_decide(trl_rank_candidates(sc, v), v)
  stats::setNames(d$decision, d$amcb_id)
}
full <- dec("full"); ident <- dec("identity_only")
chk(identical(unname(full[c("A", "B", "C", "D", "E", "F")]),
              c("ACCEPT", "REVIEW", "UNRESOLVED", "REVIEW", "REVIEW", "ACCEPT")),
    "T13 full: clear winner accepted; tie, changed surname and held NPI reviewed; all-contradicted unresolved")
chk(identical(unname(ident["F"]), "REVIEW") && identical(unname(full["F"]), "ACCEPT"),
    "T14 a pool that only taxonomy separates is ACCEPT under full and REVIEW (tied) under identity_only")
dd <- trl_decide(trl_rank_candidates(sc, "full"), "full")
chk(isTRUE(dd$emptied[dd$amcb_id == "C"]) &&
      identical(dd$decision_reason[dd$amcb_id == "C"], "unresolved:every_candidate_contradicted"),
    "T15 an emptied pool is reported as emptied, not as no candidate (DECISIONS_CONTRACT D17)")
chk(grepl("surname_changed_unexplained", dd$decision_reason[dd$amcb_id == "D"]) &&
      grepl("npi_held_by_other_certificant", dd$decision_reason[dd$amcb_id == "E"]) &&
      grepl("tied_top", dd$decision_reason[dd$amcb_id == "B"]),
    "T16 every REVIEW names the rule that stopped it")
chk(is.na(dd$best_npi[dd$amcb_id == "B"]) && identical(dd$tied_npis[dd$amcb_id == "B"], "1000000003|1000000004"),
    "T17 a tie names no best NPI; the tied NPIs are listed instead of one chosen by row order")
chk(is.na(dd$margin[dd$amcb_id == "E"]) && identical(dd$decision_reason[dd$amcb_id == "A"], "accept:unique_top;margin=7"),
    "T18 an unopposed candidate has no margin; an opposed one records it")

cat("\n-- WHERE A CONTRADICTION COMES FROM --\n")
src <- trl_contradiction_source(contra_given = c(TRUE, TRUE, TRUE, FALSE, FALSE),
                                contra_middle = c(FALSE, FALSE, FALSE, FALSE, FALSE),
                                contra_profession = c(FALSE, FALSE, TRUE, FALSE, FALSE),
                                contra_grad_year = c(FALSE, FALSE, FALSE, TRUE, FALSE),
                                trl_name_equals_nppes = c(TRUE, FALSE, TRUE, TRUE, NA))
chk(identical(src, c("name_rule", "directory_name", "directory_fields", "directory_fields", "none")),
    "T18b a name conflict on the very name NPPES carries is the matcher's rule, not the directory's evidence")

cat("\n-- OUTCOMES AND STRATA --\n")
chk(identical(trl_stratum(c("primary_midwifery", "primary_midwifery", "sensitivity_nursing", "quarantined", "unmatched"),
                          c("1", "3", "2", NA, NA), c("1000000001", "1000000002", "1000000003", NA, "")),
              c("1a_existing_high_confidence", "1b_existing_other", "1b_existing_other", "2_ambiguous", "3_unmatched")),
    "T19 strata from tier, evidence class and whether an NPI is held")
o <- trl_outcome(stratum = c("1a_existing_high_confidence", "1a_existing_high_confidence", "1b_existing_other",
                             "1a_existing_high_confidence", "1b_existing_other", "2_ambiguous", "3_unmatched",
                             "3_unmatched"),
                 incumbent_found = c(TRUE, TRUE, TRUE, FALSE, TRUE, FALSE, FALSE, FALSE),
                 incumbent_confirms = c(TRUE, FALSE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE),
                 incumbent_contra_source = c("none", "directory_fields", "none", NA, "name_rule", NA, NA, NA),
                 displaced = c(FALSE, FALSE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE),
                 decision = c("ACCEPT", "UNRESOLVED", "ACCEPT", "UNRESOLVED", "UNRESOLVED", "ACCEPT", "REVIEW",
                              "UNRESOLVED"))
chk(identical(o, c("confirms", "contradicts", "contradicts", "no_useful_evidence", "name_rule_conflict",
                   "chooses_between_competing", "plausible_new_npi", "no_useful_evidence")),
    "T20 displacement outranks confirmation; a name-rule conflict is reported apart; an absent incumbent is no evidence")

cat(sprintf("\n%s\n", if (fails) sprintf("%d FAILED", fails) else "all passed"))
quit(status = if (fails) 1L else 0L)
