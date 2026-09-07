#!/usr/bin/env Rscript
# =============================================================================
# Truth-set infrastructure: every guard proven on synthetic data, both ways
# =============================================================================
# Each check in R/truth_set_checks.R must PASS clean data and FAIL each
# specific corruption. These are the killer tests for mutation catalogue
# entries T1-T12: hollow a guard and the matching negative control here
# goes green when it must go red.
#
# Run: Rscript tests/test_truth_set_infrastructure.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
source(file.path(root, "R", "truth_set_checks.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat("  ok:", m, "\n")
  else { fails <<- fails + 1L; cat("  FAIL:", m, "\n") }
}
guard_trips <- function(expr) inherits(try(expr, silent = TRUE), "try-error")
err_msg <- function(expr) {
  e <- try(expr, silent = TRUE)
  if (inherits(e, "try-error")) attr(e, "condition")$message else ""
}

# ---- synthetic clean world ---------------------------------------------------
inst <- data.frame(
  adjudication_id = c("ADJ-A1-1111111111", "ADJ-A2-2222222222",
                      "ADJ-A3-3333333333"),
  amcb_id = c("A1", "A2", "A3"), npi = c("1111111111", "2222222222",
                                         "3333333333"),
  workflow_state = c("complete", "complete", "resolved"),
  stringsAsFactors = FALSE)
manifest <- list(rows_instrument = 3L,
                 population_hash = population_hash(inst$adjudication_id))
prov <- data.frame(
  adjudication_id = c("ADJ-A1-1111111111", "ADJ-A2-2222222222",
                      "ADJ-A2-2222222222", "ADJ-A3-3333333333"),
  source_template = c("a", "a", "b", "b"),
  source_row_id = c("1", "2", "1", "2"),
  source_file_hash = "deadbeef", source_review_status = "unadjudicated",
  stringsAsFactors = FALSE)
EXP <- c(a = 2L, b = 2L)
reviews <- data.frame(
  adjudication_id = rep(inst$adjudication_id, each = 2),
  reviewer_id = rep(c("R1", "R2"), 3),
  verdict = c("match", "match", "nonmatch", "nonmatch", "match", "nonmatch"),
  evidence_source = "primary_person_source",
  locator = "cv page 2", reason = "same person, same practice",
  review_date = "2026-09-10", stringsAsFactors = FALSE)
resolution <- data.frame(
  adjudication_id = "ADJ-A3-3333333333", final_verdict = "match",
  resolution_method = "third_review", resolver = "R3",
  resolution_date = "2026-09-11",
  resolution_reason = "middle name on CV settles it",
  stringsAsFactors = FALSE)
evidence <- data.frame(
  evidence_id = c("EV1", "EV2"),
  source_class = c("primary_person_source", "institutional_profile"),
  source_url = c("https://example.org/cv", "https://university.edu/profile"),
  source_type = c("cv", "profile"), locator = c("p2", "faculty page"),
  notes = c("matches practice city", "title consistent"),
  retrieved_at = "2026-09-10", evidence_sha256 = c("aa", "bb"),
  stringsAsFactors = FALSE)
links <- data.frame(
  adjudication_id = c("ADJ-A1-1111111111", "ADJ-A3-3333333333"),
  evidence_id = c("EV1", "EV2"), stringsAsFactors = FALSE)
eligibility <- utils::read.csv(text = paste(
  "source_class,eligible,policy_note",
  "primary_person_source,TRUE,x", "institutional_profile,TRUE,x",
  "professional_directory,TRUE,x", "board_source,FALSE,prohibited",
  "secondary_source,TRUE,x", "other,FALSE,x", sep = "\n"),
  stringsAsFactors = FALSE)

cat("\n-- clean world passes every guard --\n")
chk(!guard_trips(check_population(inst, manifest)), "population clean")
chk(!guard_trips(check_provenance_roundtrip(prov, inst, EXP)), "provenance clean")
chk(!guard_trips(check_reviewer_export_blinded(inst)), "blinding clean")
chk(!guard_trips(check_board_contamination(reviews, resolution, evidence)),
    "contamination clean")
chk(!guard_trips(check_evidence(evidence, links, inst, eligibility)),
    "evidence clean")
chk(!guard_trips(check_completeness(inst, reviews, resolution)),
    "completeness clean")

cat("\n-- T1/T2: population corruption fails closed --\n")
chk(guard_trips(check_population(inst[-1, ], manifest)), "T1: dropped row caught")
dup <- rbind(inst, inst[1, ])
mdup <- list(rows_instrument = 4L,
             population_hash = population_hash(dup$adjudication_id))
chk(guard_trips(check_population(dup, mdup)), "T2: duplicate adj_id caught")
renamed <- inst; renamed$adjudication_id[1] <- "ADJ-A9-9999999999"
chk(guard_trips(check_population(renamed, manifest)),
    "population hash catches silent id swap")
# a drop RE-FROZEN by an attacker: hash matches the shrunken set, so only
# the count check can catch it -- and vice versa for the id swap above.
refrozen <- list(rows_instrument = 3L,
                 population_hash = population_hash(inst$adjudication_id[-1]))
chk(guard_trips(check_population(inst[-1, ], refrozen)),
    "T1: dropped row caught even when the hash was re-frozen")

cat("\n-- T3: provenance loss fails the round-trip --\n")
chk(guard_trips(check_provenance_roundtrip(prov[-2, ], inst, EXP)),
    "T3: one of the original rows lost")
orph <- prov; orph$adjudication_id[1] <- "ADJ-ZZ-0000000000"
chk(guard_trips(check_provenance_roundtrip(orph, inst, EXP)),
    "orphan provenance caught")

cat("\n-- T4 + leakage: blinding is schema AND value --\n")
leaky <- inst; leaky$npi_match_confidence <- "0.35"
chk(guard_trips(check_reviewer_export_blinded(leaky)), "T4: banned column caught")
leakv <- inst; leakv$notes <- c("", "matched by exact_last_first", "")
chk(guard_trips(check_reviewer_export_blinded(leakv)),
    "matcher vocabulary in free text caught")

cat("\n-- T9: board contamination canaries (all four) --\n")
c1 <- reviews; c1$reason[1] <- "clean CV, also Texas Medical Board says active"
chk(guard_trips(check_board_contamination(c1, resolution, evidence)),
    "canary 1: clean URL + board mention in notes")
c2 <- evidence; c2$notes[1] <- "secondary link goes to the state board"
chk(guard_trips(check_board_contamination(reviews, resolution, c2)),
    "canary 2: primary source + board-linked secondary evidence")
c3 <- reviews; c3$locator[2] <- "board profile p3"
chk(guard_trips(check_board_contamination(c3, resolution, evidence)),
    "canary 3: board mention hidden in locator")
c4 <- resolution; c4$resolution_reason <- "BON record settles it"
chk(guard_trips(check_board_contamination(reviews, c4, evidence)),
    "canary 4: board mention in resolution reason")

cat("\n-- T8/T11: evidence orphans and governed eligibility --\n")
orphE <- rbind(evidence,
               data.frame(evidence_id = "EV9",
                          source_class = "primary_person_source",
                          source_url = "https://x.org", source_type = "cv",
                          locator = "p1", notes = "n",
                          retrieved_at = "2026-09-10",
                          evidence_sha256 = "cc", stringsAsFactors = FALSE))
chk(guard_trips(check_evidence(orphE, links, inst, eligibility)),
    "T8: unlinked evidence row caught")
badL <- rbind(links, data.frame(adjudication_id = "ADJ-A1-1111111111",
                                evidence_id = "EVMISSING",
                                stringsAsFactors = FALSE))
chk(guard_trips(check_evidence(evidence, badL, inst, eligibility)),
    "link to missing evidence caught")
# T11 both directions: eligibility comes from the DECLARED class, never
# the URL. A board_source with a clean university URL must FAIL...
boardclean <- evidence
boardclean$source_class[2] <- "board_source"
chk(guard_trips(check_evidence(boardclean, links, inst, eligibility)),
    "T11: board_source with clean-looking URL still ineligible")
# ...and an eligible class whose URL merely CONTAINS an odd string passes
# the eligibility check (contamination is a separate guard).
oddurl <- evidence
oddurl$source_url[1] <- "https://example.org/aboardwalk-clinic-cv"
chk(!guard_trips(check_evidence(oddurl, links, inst, eligibility)),
    "T11 inverse: eligibility never inferred from URL text")
undecl <- evidence; undecl$source_class[1] <- "faculty_page"
chk(guard_trips(check_evidence(undecl, links, inst, eligibility)),
    "undeclared source class fails closed")

cat("\n-- T6/T7/T10: completeness, disagreement, immutability --\n")
partial <- inst; partial$workflow_state[2] <- "in_review"
chk(guard_trips(check_completeness(partial, reviews, resolution)),
    "T6: partial truth cannot unblind")
chk(guard_trips(check_completeness(inst, reviews, resolution[0, ])),
    "T7: unresolved disagreement caught (A3 split verdicts)")
ow <- reviews; ow$final_verdict <- "match"
chk(guard_trips(check_completeness(inst, ow, resolution)),
    "T10: final_verdict column on reviews = overwrite, refused")
noreason <- resolution; noreason$resolution_reason <- ""
chk(guard_trips(check_completeness(inst, reviews, noreason)),
    "resolution without reasoning refused")
anon <- reviews; anon$reviewer_id[3] <- ""
chk(guard_trips(check_completeness(inst, anon, resolution)),
    "missing reviewer identity refused")
badv <- reviews; badv$verdict[1] <- "probably"
chk(guard_trips(check_completeness(inst, badv, resolution)),
    "off-vocabulary verdict refused")

cat("\n-- T5/T12: custody --\n")
tdir <- tempfile(); dir.create(tdir)
writeLines("hello", file.path(tdir, "f1.csv"))
man <- list(files = list(f1 = list(file = file.path(tdir, "f1.csv"),
                                   sha256 = sha256_file(
                                     file.path(tdir, "f1.csv")))))
chk(!guard_trips(check_custody(man)), "custody clean")
writeLines("tampered", file.path(tdir, "f1.csv"))
chk(guard_trips(check_custody(man)), "T5/T12: hash mismatch refused")
chk(grepl("CUSTODY", err_msg(check_custody(man))), "custody names itself")

cat("\n-- the unblinding gate has no escape hatch --\n")
source(file.path(root, "analysis", "unblind_truth_set.R"))
chk(identical(names(formals(unblind_truth_set)), "truth_dir"),
    "no force=, no subset=, no partial= formal exists")

cat(sprintf("\n%s: %d failures\n", if (fails) "RED" else "GREEN", fails))
if (fails) quit(status = 1L)
