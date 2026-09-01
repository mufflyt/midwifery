#!/usr/bin/env Rscript
#' @title Case gallery: what the matcher did to each name, and why
#'
#' @description
#' Every existing linkage artifact reports the linkage as a statistic -- a rate,
#' a stratum count, a bound. None of them lets a reader check the matching by
#' eye. This draws a stratified, seeded sample of real certificants and prints,
#' for each one, the AMCB side, the NPPES side, the rule that fired, and the
#' candidate arithmetic that rule was applied to -- so a co-author can adjudicate
#' individual decisions rather than agree with a percentage.
#'
#' The strata are the decisions, not the outcomes. Each one names what a reviewer
#' should be looking for, including the three that published something a reader
#' cannot currently tell apart from the truth:
#'   - uniqueness manufactured by the middle-name veto (published `matched`, no flag)
#'   - a sole candidate vetoed away (published as "no candidate", which reads as
#'     absence from the registry)
#'   - an NPPES record renamed since the match was made
#'
#' OUTPUT IS PERSON-LEVEL. It carries names, certification numbers and NPIs, and
#' is written only into qa/, which is gitignored. Do not commit it, publish it,
#' or paste it into an issue. Use --redact for a shareable copy.
#'
#' Usage:
#'   Rscript build_linkage_case_gallery.R
#'   Rscript build_linkage_case_gallery.R --n=8 --seed=20260902
#'   Rscript build_linkage_case_gallery.R --redact
#'   Rscript build_linkage_case_gallery.R --crosswalk=artifacts/other_FROZEN.csv
#'
#' Output: qa/linkage_case_gallery.html   review sheet, one card per case
#'         qa/linkage_case_gallery.csv    same cases, for annotation
#'
#' @family linkage
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path("R", "lib", "artifact_provenance.R"))

# ---- arguments -------------------------------------------------------------
# Function names are gal_*-prefixed throughout: ci_hygiene H4 forbids one
# top-level function name being defined in two tracked files, and short names
# like `arg` or `esc` are exactly the ones a second script would also want.
gal_arg <- function(key, default) {
  hit <- grep(paste0("^--", key, "="), commandArgs(TRUE), value = TRUE)
  if (!length(hit)) return(default)
  sub(paste0("^--", key, "="), "", hit[1])
}
gal_flag <- function(key) paste0("--", key) %in% commandArgs(TRUE)

CROSSWALK <- gal_arg("crosswalk", file.path("artifacts", "amcb_npi_linkage_FROZEN.csv"))
PER_STRATUM <- as.integer(gal_arg("n", "6"))
SEED <- as.integer(gal_arg("seed", "20260902"))
REDACT <- gal_flag("redact")
OUTDIR <- gal_arg("outdir", "qa")

if (!identical(OUTDIR, "qa") && !gal_flag("allow-unsafe-outdir")) {
  stop("Refusing to write person-level output outside qa/, which is gitignored.\n",
       "  qa/ is the only directory this script writes to by default. If you have\n",
       "  a reason to put it elsewhere, pass --allow-unsafe-outdir and make sure\n",
       "  the destination is ignored by git.", call. = FALSE)
}
dir.create(OUTDIR, showWarnings = FALSE, recursive = TRUE)

if (!file.exists(CROSSWALK)) {
  stop("Frozen crosswalk not found at ", CROSSWALK, "\n",
       "  It is person-level and gitignored, so a fresh clone does not have it.\n",
       "  Rebuild it with match_amcb_to_npi.R, or point --crosswalk= at your copy.",
       call. = FALSE)
}

x <- read_csv(CROSSWALK, show_col_types = FALSE, guess_max = 50000)
message(sprintf("Read %s rows from %s", format(nrow(x), big.mark = ","), CROSSWALK))

gal_has <- function(...) all(c(...) %in% names(x))
gal_num <- function(v) suppressWarnings(as.numeric(v))
gal_true <- function(v) !is.na(v) & (v %in% c(TRUE, "TRUE", "true", "1"))

# ---- strata ----------------------------------------------------------------
# Each stratum is a decision the resolver made, paired with the question a
# reviewer is being asked to answer about it. `check` is the whole point of the
# document: a card with no question attached is just a data dump.
STRATA <- list(
  list(key = "c1", kind = "success",
       label = "Class 1 - exact name with a corroborating middle name",
       check = "Are these the same person? This is the strongest evidence the linkage has (confidence 1.00). If a class-1 match is wrong, nothing downstream can catch it.",
       filter = ~ name_evidence_class == 1 & npi_match_status == "matched"),

  list(key = "c2", kind = "success",
       label = "Class 2 - exact first and last, no useful middle information",
       check = "Same person, on first and last name alone? Note what is NOT here: no middle name, no date of birth. Ask whether the name is common enough that you would want more.",
       filter = ~ name_evidence_class == 2 & npi_match_status == "matched"),

  list(key = "c3", kind = "success",
       label = "Class 3 - surname plus FIRST INITIAL ONLY, given names differ",
       check = "This is the rule most likely to be wrong. It means 'same surname, same first letter, different given name' - not a nickname dictionary. Would you accept this pairing? Class 3 generates 76% of all candidate pairs.",
       filter = ~ name_evidence_class == 3 & npi_match_status == "matched"),

  list(key = "c4", kind = "success",
       label = "Class 4 - surname within edit distance 2, exact given name",
       check = "Is the surname difference a spelling variant of one person, or two different people? Look for transliteration, hyphenation and married-name patterns.",
       filter = ~ name_evidence_class == 4 & npi_match_status == "matched"),

  list(key = "nursing", kind = "success",
       label = "Found under NURSING taxonomy, deliberately not promoted",
       check = "The match is accepted but held out of the primary cohort because the NPI carries a nursing rather than a midwifery taxonomy. This gap is the whole difference between 78.4% and 84.6%. Is holding these out the right call?",
       filter = ~ npi_match_status == "matched_nursing_taxonomy"),

  list(key = "tied", kind = "failure",
       label = "TIED at the best class - quarantined, not broken",
       check = "Two or more candidates sit at the same strongest class, so the record resolves to nobody. Look at n_at_best_class. Is there evidence here a human could break the tie on, that the resolver is not using?",
       filter = ~ gal_num(n_at_best_class) > 1),

  list(key = "nocand", kind = "failure",
       label = "NO CANDIDATE - nothing in the registry to consider",
       check = "No plausible candidate was generated at all. Check the certification date: certifying before NPPES began enumerating in 2006 is a registry boundary, not a matching failure. Anything recent here needs an explanation.",
       filter = ~ gal_true(has_candidate) == FALSE & npi_match_status != "matched"),

  list(key = "contested", kind = "failure",
       label = "CONTESTED - one provider record claimed by two certificants",
       check = "The one-to-one constraint found two certificants resolving onto the same NPI. Which one is right, or is the NPPES record itself a duplicate?",
       filter = ~ grepl("contested", npi_match_status)),

  list(key = "c5held", kind = "failure",
       label = "Class 5 - surname component only, held out by the guard",
       check = "A shared surname fragment is the weakest evidence the pipeline generates, and these are deliberately excluded from the cohort. Is the exclusion right for these particular records?",
       filter = ~ name_evidence_class == 5 | gal_true(npi_demoted_absence_c5)),

  list(key = "manufactured", kind = "danger",
       label = "UNIQUENESS MANUFACTURED - resolved only because every rival was vetoed",
       check = "READ THESE CLOSELY. This record resolved to exactly one candidate ONLY because the middle-initial rule deleted all the others. It was published as `matched` with no flag on it. If the veto was wrong, this is a confident match to the wrong person.",
       filter = ~ gal_true(resolved_by_absence_c5)),

  list(key = "vetoed_away", kind = "danger",
       label = "SOLE CANDIDATE VETOED AWAY - published as if absent from the registry",
       check = "A middle-initial conflict deleted this record's only candidate, so it was published as 'no candidate'. A reader cannot tell that apart from someone who is genuinely not in NPPES. Was the middle-name disagreement real, or a data artifact?",
       filter = ~ gal_num(n_mid_vetoed_c5) > 0 & npi_match_status != "matched"),

  list(key = "renamed", kind = "danger",
       label = "NPPES RECORD RENAMED since the match was made",
       check = "The provider record this certificant matched to now carries a different name in NPPES. Marriage, correction, or a reused NPI? The match may still be right, but it no longer reproduces from the current registry.",
       filter = ~ gal_true(nppes_name_changed_since_match))
)

# ---- sample ----------------------------------------------------------------
set.seed(SEED)
gal_pick <- function(s) {
  got <- tryCatch(filter(x, !!rlang::f_rhs(s$filter)), error = function(e) NULL)
  if (is.null(got)) {
    message(sprintf("  %-14s SKIPPED - crosswalk lacks a column this stratum needs", s$key))
    return(NULL)
  }
  n_avail <- nrow(got)
  if (!n_avail) {
    message(sprintf("  %-14s 0 available", s$key))
    return(NULL)
  }
  out <- slice_sample(got, n = min(PER_STRATUM, n_avail))
  message(sprintf("  %-14s %d sampled of %s available", s$key, nrow(out),
                  format(n_avail, big.mark = ",")))
  mutate(out, .stratum = s$key, .stratum_n = n_avail)
}

message("Sampling:")
picked <- Filter(Negate(is.null), lapply(STRATA, gal_pick))
if (!length(picked)) stop("No strata produced any cases. Is this the right crosswalk?", call. = FALSE)
cases <- bind_rows(picked)

# ---- redaction -------------------------------------------------------------
# Redaction is a one-way hash of the identifying columns, keyed by the seed, so
# two cards for the same person still line up while no name survives.
if (REDACT) {
  gal_hash <- function(v) ifelse(is.na(v) | !nzchar(as.character(v)), NA_character_,
                                 substr(vapply(paste0(SEED, "|", v), digest::digest,
                                               character(1), algo = "sha256"), 1, 10))
  for (cc in intersect(c("last_name", "first_name", "middle_name", "amcb_name_original",
                         "normalized_last_name", "normalized_first_name",
                         "normalized_middle_name", "nppes_first_name", "nppes_middle_name",
                         "nppes_last_name", "nppes_matched_first", "nppes_matched_last",
                         "nppes_practice_address", "npi", "certification_number",
                         "amcb_id", "customer_id", "amcb_customer_id",
                         "class5_candidate_npi"), names(cases))) {
    cases[[cc]] <- gal_hash(cases[[cc]])
  }
  message("Redacted: identifying columns replaced with seed-keyed hashes.")
}

# ---- render ----------------------------------------------------------------
gal_esc <- function(v) {
  v <- ifelse(is.na(v), "", as.character(v))
  v <- gsub("&", "&amp;", v, fixed = TRUE)
  v <- gsub("<", "&lt;", v, fixed = TRUE)
  gsub(">", "&gt;", v, fixed = TRUE)
}
gal_get <- function(r, cc) if (cc %in% names(r)) gal_esc(r[[cc]][1]) else ""
gal_blank <- function(v) if (!nzchar(v)) "<span class=na>not recorded</span>" else v

gal_row <- function(lab, val) sprintf("<tr><th>%s</th><td>%s</td></tr>", lab, gal_blank(val))

gal_card <- function(r, i) {
  amcb <- paste0(
    gal_row("Name as printed", gal_get(r, "amcb_name_original")),
    gal_row("Last, first, middle", paste(gal_get(r, "last_name"), gal_get(r, "first_name"),
                                         gal_get(r, "middle_name"), sep = " | ")),
    gal_row("Certification", paste(gal_get(r, "certification"), gal_get(r, "certification_number"))),
    gal_row("Status", gal_get(r, "status")),
    gal_row("Certified", gal_get(r, "certification_date")))
  nppes <- paste0(
    gal_row("Matched name", paste(gal_get(r, "nppes_last_name"), gal_get(r, "nppes_first_name"),
                                  gal_get(r, "nppes_middle_name"), sep = " | ")),
    gal_row("NPI", gal_get(r, "npi")),
    gal_row("Credential", gal_get(r, "nppes_credential")),
    gal_row("Practice", paste(gal_get(r, "nppes_city"), gal_get(r, "nppes_state"),
                              gal_get(r, "nppes_zip"))),
    gal_row("Snapshot year", gal_get(r, "nppes_location_year")))
  decision <- paste0(
    gal_row("Status", gal_get(r, "npi_match_status")),
    gal_row("Evidence class", paste(gal_get(r, "name_evidence_class"),
                                    "(best available:", gal_get(r, "best_evidence_class"), ")")),
    gal_row("Method", gal_get(r, "npi_match_method")),
    gal_row("Resolution", gal_get(r, "npi_match_resolution")),
    gal_row("Tier", gal_get(r, "linkage_tier")),
    gal_row("Confidence", gal_get(r, "npi_match_confidence")),
    gal_row("In cohort", gal_get(r, "cohort_member")))
  arith <- paste0(
    gal_row("Candidates before ranking", gal_get(r, "n_candidates_pre_rank")),
    gal_row("At the best class", gal_get(r, "n_at_best_class")),
    gal_row("Midwifery / nursing-only", paste(gal_get(r, "n_midwifery_candidates"), "/",
                                              gal_get(r, "n_nursing_only_candidates"))),
    gal_row("Deleted by middle-name veto", gal_get(r, "n_mid_vetoed_c5")),
    gal_row("Resolved by absence", gal_get(r, "resolved_by_absence_c5")),
    gal_row("Ambiguity flag", gal_get(r, "ambiguity_flag")),
    gal_row("Match reason", gal_get(r, "match_reason")))

  sprintf(
'<article class="case">
  <div class="case-h"><span class="idx">Case %d</span></div>
  <div class="grid">
    <section><h4>AMCB roster</h4><table>%s</table></section>
    <section><h4>NPPES record</h4><table>%s</table></section>
    <section><h4>What the matcher decided</h4><table>%s</table></section>
    <section><h4>Candidate arithmetic</h4><table>%s</table></section>
  </div>
  <div class="verdict"><b>Verdict</b>
    <label><input type="checkbox"> Agree</label>
    <label><input type="checkbox"> Disagree</label>
    <label><input type="checkbox"> Cannot tell</label>
    <span class="note">Notes:</span>
  </div>
</article>', i, amcb, nppes, decision, arith)
}

gal_section <- function(s) {
  rows <- filter(cases, .stratum == s$key)
  if (!nrow(rows)) return("")
  cards <- vapply(seq_len(nrow(rows)), function(i) gal_card(rows[i, ], i), character(1))
  sprintf(
'<section class="stratum %s">
  <h2>%s</h2>
  <p class="count">%s records in this stratum across the whole roster &middot; %d shown</p>
  <p class="check"><b>What to check:</b> %s</p>
  %s
</section>', s$kind, gal_esc(s$label),
    format(rows$.stratum_n[1], big.mark = ","), nrow(rows),
    gal_esc(s$check), paste(cards, collapse = "\n"))
}

CSS <- '
:root{--ink:#161f1d;--mut:#5c6b67;--line:#d6ddda;--paper:#fff;--sunk:#f1f3f2;
      --ok:#1d5a57;--bad:#9a3524;--warn:#8a6d1f}
*{box-sizing:border-box}
body{margin:0;background:var(--sunk);color:var(--ink);
     font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
.wrap{max-width:1100px;margin:0 auto;padding:32px 20px 80px}
h1{font-size:26px;margin:0 0 8px;letter-spacing:-.01em}
.sub{color:var(--mut);margin:0 0 6px;max-width:70ch}
.warn{background:#fdf3f1;border:1px solid var(--bad);color:var(--bad);
      padding:12px 14px;margin:20px 0;border-radius:3px;font-weight:600}
.run{font-family:ui-monospace,Menlo,monospace;font-size:11.5px;color:var(--mut);
     border-top:1px solid var(--line);margin-top:18px;padding-top:12px}
.stratum{margin:44px 0 0;padding-top:22px;border-top:2px solid var(--ink)}
.stratum h2{font-size:18px;margin:0 0 4px}
.stratum.success h2{color:var(--ok)}
.stratum.failure h2{color:var(--warn)}
.stratum.danger h2{color:var(--bad)}
.count{font-family:ui-monospace,Menlo,monospace;font-size:11.5px;color:var(--mut);margin:0 0 10px}
.check{background:var(--paper);border-left:3px solid var(--line);padding:10px 14px;
       margin:0 0 18px;max-width:78ch}
.case{background:var(--paper);border:1px solid var(--line);border-radius:3px;
      padding:14px 16px;margin:0 0 14px}
.case-h{margin-bottom:10px}
.idx{font-family:ui-monospace,Menlo,monospace;font-size:11px;letter-spacing:.08em;
     text-transform:uppercase;color:var(--mut)}
.grid{display:grid;gap:16px;grid-template-columns:1fr}
@media(min-width:820px){.grid{grid-template-columns:1fr 1fr}}
h4{margin:0 0 6px;font-size:11px;letter-spacing:.07em;text-transform:uppercase;color:var(--mut)}
table{border-collapse:collapse;width:100%}
th,td{text-align:left;padding:3px 0;vertical-align:top;font-size:13px}
th{font-weight:400;color:var(--mut);width:44%;padding-right:10px}
td{font-family:ui-monospace,Menlo,monospace;font-size:12.5px;word-break:break-word}
.na{color:var(--mut);font-style:italic;font-family:inherit}
.verdict{margin-top:12px;padding-top:10px;border-top:1px dashed var(--line);
         display:flex;gap:16px;align-items:center;flex-wrap:wrap;font-size:13px}
.verdict label{color:var(--mut)}
.note{color:var(--mut);flex:1;border-bottom:1px solid var(--line);min-width:180px}
@media print{body{background:#fff}.case{break-inside:avoid}}
'

html <- sprintf(
'<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AMCB to NPPES linkage - case gallery</title><style>%s</style></head><body><div class="wrap">
<h1>AMCB to NPPES linkage: case gallery</h1>
<p class="sub">A stratified sample of real matching decisions, so the linkage can be
checked by eye rather than agreed with as a percentage. Strata are the decisions the
resolver made, ordered from strongest evidence to the three cases where the published
artifact cannot be told apart from the truth.</p>
<div class="warn">%s</div>
%s
<p class="run">crosswalk: %s &middot; sha256: %s &middot; rows: %s<br>
seed: %d &middot; per stratum: %d &middot; generated: %s &middot; redacted: %s<br>
regenerate: Rscript build_linkage_case_gallery.R --seed=%d --n=%d%s</p>
</div></body></html>',
  CSS,
  if (REDACT) "REDACTED COPY. Names and identifiers are seed-keyed hashes. Still treat as sensitive: the strata themselves say something about each record."
  else "PERSON-LEVEL. Real names, certification numbers and NPIs. qa/ is gitignored - do not commit this file, publish it, or paste it into an issue. Use --redact for a shareable copy.",
  paste(vapply(STRATA, gal_section, character(1)), collapse = "\n"),
  gal_esc(CROSSWALK), substr(sha256_of(CROSSWALK), 1, 16),
  format(nrow(x), big.mark = ","), SEED, PER_STRATUM,
  format(Sys.time(), "%Y-%m-%d %H:%M"), if (REDACT) "yes" else "no",
  SEED, PER_STRATUM, if (REDACT) " --redact" else "")

html_path <- file.path(OUTDIR, "linkage_case_gallery.html")
writeLines(html, html_path)

csv_path <- file.path(OUTDIR, "linkage_case_gallery.csv")
keep <- intersect(c(".stratum", ".stratum_n", "certification_number", "amcb_name_original",
                    "last_name", "first_name", "middle_name", "status", "certification_date",
                    "npi", "nppes_last_name", "nppes_first_name", "nppes_middle_name",
                    "nppes_credential", "nppes_city", "nppes_state",
                    "npi_match_status", "name_evidence_class", "best_evidence_class",
                    "npi_match_method", "npi_match_resolution", "linkage_tier",
                    "npi_match_confidence", "cohort_member", "n_candidates_pre_rank",
                    "n_at_best_class", "n_midwifery_candidates", "n_nursing_only_candidates",
                    "n_mid_vetoed_c5", "resolved_by_absence_c5", "ambiguity_flag",
                    "match_reason"), names(cases))
out <- cases[, keep, drop = FALSE]
out$reviewer_verdict <- NA_character_
out$reviewer_notes <- NA_character_
write_with_provenance(out, csv_path, inputs = CROSSWALK)

message(sprintf("\nWrote %d cases across %d strata:\n  %s\n  %s",
                nrow(cases), length(unique(cases$.stratum)), html_path, csv_path))
message("Both are person-level unless --redact was passed. qa/ is gitignored; keep them there.")
