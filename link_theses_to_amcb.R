#!/usr/bin/env Rscript
# =============================================================================
# Link DNP/ETD authors at ACME schools to the AMCB roster -> training institution
# =============================================================================
#
# THE LINKAGE RUNS AMCB -> AUTHORS, not authors -> AMCB. Both universes are
# bounded: 22,309 certificants against the degree-work authors of the 50
# ACME-accredited programs. That is a far better record-linkage problem than
# searching the open literature for midwives.
#
# SPECIALTY IS NOT AN INCLUSION CRITERION. There is usually no midwifery
# collection; DNP projects sit in a university-wide DNP/ETD collection and the
# specialty is absent from Dublin Core. Measured at Seattle University: 209 DNP
# authors, only 7 mention midwifery in metadata, yet 24 match the AMCB roster.
# Requiring the word discards 97% of the collection and 19 of the 24 matches.
# midwifery_text is therefore CORROBORATION, never a filter.
#
# THE TEMPORAL WINDOW IS FITTED PER INSTITUTION, NOT GLOBALLY. The gap between
# a project year and AMCB certification year measures program TYPE:
#
#   Seattle University   median gap  0 yrs   entry-level DNP: certification and
#                                            capstone are the same event
#   Frontier Nursing U   median gap  4 yrs   post-professional DNP: practising
#                        p90        19 yrs   CNMs returning for a doctorate
#
# A single -1..+3 window fitted on Seattle drops 308 of Frontier's 555 real
# matches (55%) -- people certified in 1980 whose project is dated 2023. So the
# window is fitted from each institution's own matched distribution, and is
# recorded as an EVIDENCE TIER rather than applied as a filter. Nothing is
# deleted for being temporally discordant.
#
# EVIDENCE TIERS (see training_evidence_class):
#   1 collection_specific   collection is midwifery-specific; membership is the
#                           evidence (Frontier). Accept regardless of gap.
#   2 generic_concordant    generic DNP collection + gap inside the institution's
#                           fitted window, or midwifery text present.
#   3 generic_discordant    generic collection, name match only. Candidate.
#   4 ambiguous             >1 AMCB certificant matches the same project.
#
# Usage: Rscript link_theses_to_amcb.R
# Output: artifacts/amcb_training_institution.csv
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr); library(tidyr)})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)
source(file.path(root_dir, "R", "amcb_name_keys.R"))
source(file.path(root_dir, "R", "amcb_match_rules.R"))   # require_cols, assert_nonempty_selection

# Institutions whose degree-work authors are essentially all nurse-midwives, so
# a name match needs no corroborator. Measured, not assumed: Frontier's
# permutation-control false-positive proxy is 7%, against 54-84% at schools
# whose DNP collections span every nursing specialty.
SPECIALTY_PURE_INSTITUTIONS <- c("Frontier Nursing University")

# Collections excluded by review (2026-08-10). These carry FACULTY output,
# undergraduate work, posters, journals and alumni bulletins -- none of which is
# the author's own doctoral degree work, and a faculty publication says where
# someone WORKS, not where they trained. degree_text alone did not remove them:
# a faculty paper about a DNP program still matches the degree vocabulary.
#
# Compared case-insensitively on purpose: "College of Nursing and Health
# sciences" (lowercase s) is a distinct string from the "...Sciences" spelling
# in this list, and exact matching would silently keep it.
EXCLUDED_COLLECTIONS <- c(
  "Nurse Educator Theses", "Nursing Department", "Nursing Faculty Publications",
  "Nursing and Health Studies Faculty Book Gallery",
  "SANA: Self-Achievement through Nursing Art",
  "Marion Peckham Egan School of Nursing and Health Studies",
  "Student Publications and Presentations", "Nursing Faculty Scholarship",
  "Nursing, College of", "College of Nursing Faculty Research and Publications",
  "College of Nursing and Health Sciences",
  "Bachelor of Science in Nursing Senior Synthesis",
  "National Nursing Symposium on Antibiotic Resistance and Stewardship",
  "College of Nursing Faculty Papers & Presentations", "Nursing Alumni Bulletins",
  "Department of Nursing Posters", "Bachelor of Science in Nursing Honors Program",
  "Asian/Pacific Island Nursing Journal")

AUTHORS <- Sys.getenv("ACME_AUTHORS", "artifacts/acme_dnp_authors.csv")
ROSTER  <- "midwives.csv"
FROZEN  <- "artifacts/amcb_npi_linkage_FROZEN.csv"
OUT     <- Sys.getenv("TRAINING_OUT", "artifacts/amcb_training_institution.csv")
stopifnot(file.exists(AUTHORS), file.exists(ROSTER))

au <- read_csv(AUTHORS, show_col_types = FALSE)
require_cols(au, c("institution", "author_last", "author_first", "year",
                   "collection", "midwifery_text"), "author harvest")
# DEGREE WORKS ONLY. A faculty publication says where someone WORKS, not where
# they trained, and the general "College of Nursing" sets are mostly faculty
# output: of Marquette's 11,483 harvested records only 372 are degree works.
# Restricting here took the pooled false-positive proxy from 36% to 20%.
# NAMES ARE PARSED WITH humaniformat, ON BOTH SIDES, AND COMPARED AS TOKEN SETS.
# The previous split-on-first-comma plus take-first-token produced, verbatim:
#   "Wang, MSN, CRNP, Mary" -> given name "MSN,"   (credentials)
#   "Williams, W. Jon"      -> given name "W."     (initial-first; it is Jon)
#   "Bass, Dr. M. Dustin"   -> given name "Dr."    (title)
# 764 of 5,404 degree-work author strings contain a period, 54 have two or more
# commas, 119 have no comma at all. Switching to humaniformat + token sets
# found 128 additional certificants and lost NONE.
# degree_text IS RECOMPUTED HERE, NOT TRUSTED FROM THE HARVEST. The harvester's
# pattern was wrong in two ways that each silently discarded a real collection:
#
#   "thesis"   does not match "Theses"  -> Bethel University's
#              "Nurse-Midwifery Theses and Projects" (154 records) was dropped,
#              and that is a MIDWIFERY-SPECIFIC collection, i.e. tier-1 evidence.
#   "doctoral" does not match "Doctor of Nursing Practice" -> Seattle
#              University's "Doctor of Nursing Practice Projects" (409 records)
#              was dropped, which is why Seattle fell from 24 matches to 1.
#
# Stems, not whole words. perl = TRUE because \\b is not a word boundary in
# POSIX ERE -- the same trap that made an earlier producer-detector match
# nothing at all.
DEGREE_WORK_RX <- paste0(
  "thes|dissert|doctor|\\bDNP\\b|\\bETD\\b|capstone|",
  "scholarly project|doctoral project|culminating|graduate project")
au <- au %>%
  mutate(degree_text = grepl(DEGREE_WORK_RX, paste(collection, title),
                             ignore.case = TRUE, perl = TRUE)) %>%
  filter(degree_text,
         !tolower(trimws(collection)) %in% tolower(trimws(EXCLUDED_COLLECTIONS))) %>%
  mutate(project_year = suppressWarnings(as.integer(substr(year, 1, 4))),
         # TIER-1 PURITY IS AN INSTITUTION PROPERTY, NOT A COLLECTION NAME.
         # The first version tested only the collection name and returned ZERO
         # tier-1 rows -- because Frontier's collection is called "DNP
         # Projects", not "Nurse-Midwifery". Frontier's 7% false-positive rate
         # (against 54-84% elsewhere) comes from its STUDENT BODY being
         # essentially all nurse-midwives, which no collection name states.
         # Both routes to purity are now recognised.
         collection_specific = grepl("midwif|nurse[-[:space:]]?midwi", collection,
                                     ignore.case = TRUE) |
                               institution %in% SPECIALTY_PURE_INSTITUTIONS) %>%
  filter(!is.na(author_raw), nzchar(author_raw))
.pa <- amcb_parse_person(au$author_raw)
au$k_last <- .pa$last
au$given_tokens <- amcb_given_tokens(.pa$first, .pa$middle)
au <- au %>% filter(!is.na(k_last), nzchar(k_last), lengths(given_tokens) > 0)
assert_nonempty_selection(au$k_last, "harvested authors with usable parsed names")

am <- read_csv(ROSTER, show_col_types = FALSE) %>%
  mutate(cert_year = suppressWarnings(as.integer(sub("^.*/", "", certification_date))))
# The SAME parser on the roster side. Parsing only the external side and
# comparing against a naively split roster reintroduces the asymmetry that
# caused false matches in this project before.
.pm <- amcb_parse_person(paste0(am$last_name, ", ", am$first_name, " ",
                                ifelse(is.na(am$middle_name), "", am$middle_name)))
am$k_last <- .pm$last
am$given_tokens <- amcb_given_tokens(.pm$first, .pm$middle)
am <- am %>% filter(!is.na(k_last), nzchar(k_last), lengths(given_tokens) > 0)

# Explode given-name tokens: identity rests on a SHARED FULL TOKEN, not on
# position. "Williams, W. Jon" and "Jon W Williams" share JON; a positional
# rule scores them as different people. Initials are excluded from the token
# set upstream -- "W." is compatible with every W and identifies nobody.
# NAME RARITY: how many AMCB certificants share this exact (surname, first
# given token)? A match on a name held by one person in the roster is strong;
# a match on a name held by nine is not. This is the corroborator that replaced
# state agreement.
#
# WHY STATE AGREEMENT WAS THE WRONG TOOL. It bought precision by discarding
# anyone who trained in one state and practises in another -- which is a large
# and entirely legitimate share of the workforce, and irrelevant to the
# question being asked. The University of South Carolina had 215 degree works
# and 23 matches, NONE of which survived, purely because those graduates moved.
# Where someone practises now is not evidence about where they went to school.
.rarity <- am %>%
  mutate(.first_amcb = vapply(given_tokens, function(z) z[1], character(1))) %>%
  count(k_last, .first_amcb, name = "n_amcb_same_name")

link_on <- function(authors) {
  # Capture the FIRST given token before unnesting -- unnest_longer consumes
  # the list column, so it cannot be inspected afterwards.
  a <- authors %>%
    mutate(.aid = row_number(),
           .first_repo = vapply(given_tokens, function(z) z[1], character(1))) %>%
    tidyr::unnest_longer(given_tokens, values_to = ".tok")
  m <- am %>%
    mutate(.mid = row_number(),
           .first_amcb = vapply(given_tokens, function(z) z[1], character(1))) %>%
    tidyr::unnest_longer(given_tokens, values_to = ".tok")
  inner_join(m, a, by = c("k_last", ".tok"), relationship = "many-to-many") %>%
    # WHICH given name matched matters. "Casey, Lauren Marie" matched "Annette
    # Marie Casey" on MARIE alone, and "Morgan, Lisa Marie" matched both "Anne
    # Marie Morgan" and "Lisa Jean Morgan". A shared MIDDLE name is weak
    # evidence -- common middle names collide across unrelated people -- while a
    # shared FIRST given name is what actually identifies.
    mutate(tok_is_first_amcb = .tok == .first_amcb,
           tok_is_first_repo = .tok == .first_repo,
           given_match_position = dplyr::case_when(
             tok_is_first_amcb & tok_is_first_repo ~ "both_first",
             tok_is_first_amcb | tok_is_first_repo ~ "one_first",
             TRUE                                  ~ "both_middle")) %>%
    group_by(.mid, .aid) %>%
    slice_min(order_by = match(given_match_position,
                               c("both_first", "one_first", "both_middle")),
              n = 1, with_ties = FALSE) %>%
    ungroup() %>%
    left_join(.rarity, by = c("k_last", ".first_amcb")) %>%
    mutate(n_amcb_same_name = coalesce(n_amcb_same_name, 1L),
           name_is_unique_in_roster = n_amcb_same_name == 1L,
           gap = project_year - cert_year)
}
real <- link_on(au)

# --- permutation control -----------------------------------------------------
# Shuffling first names against surnames within the harvest estimates how many
# matches arise from name collision alone. Reported per institution, because
# collision risk scales with collection breadth: Frontier (all midwifery
# students) ran 9%, Seattle (all nursing specialties) ran 38%.
#
# A plain sample() is a permutation, not a DERANGEMENT: it has ~1 expected
# fixed point regardless of vector length (verified: ~62% chance of at least
# one, for n = 10, 30, or 100), so roughly six times in ten this "negative"
# control silently leaves at least one row's given_tokens matched back to its
# own true surname -- a real match hiding inside what is meant to be a clean
# null. For a small institution (Frontier-sized cohorts), one such
# contaminated row is a non-trivial share of that institution's reported
# permutation rate, understating how much of the real match rate is genuine
# signal rather than name collision. Rejection-sampled to a true derangement:
# P(zero fixed points) is ~37% per draw, so this terminates in a few tries.
# derange() is defined in R/lib/derangement.R -- the canonical home, so the
# cycle-30 test exercises this exact implementation rather than a copy.
source(file.path(root_dir, "R", "lib", "derangement.R"))
set.seed(20260810)
ctrl <- link_on(au %>% mutate(given_tokens = derange(given_tokens)))

# --- per-institution window --------------------------------------------------
# Fitted from the institution's own matched gaps: p10..p90 of the real matches,
# widened to at least -1..+3 so a school with few matches cannot produce an
# absurdly narrow window. Institutions with <5 matches fall back to the pooled
# window, and that fallback is recorded.
POOLED <- c(-1L, 3L)
win <- real %>%
  filter(!is.na(gap)) %>%
  group_by(institution) %>%
  summarise(n_matched = n_distinct(certification_number),
            lo = as.integer(floor(quantile(gap, .10, na.rm = TRUE))),
            hi = as.integer(ceiling(quantile(gap, .90, na.rm = TRUE))),
            median_gap = as.integer(median(gap, na.rm = TRUE)), .groups = "drop") %>%
  mutate(fitted = n_matched >= 5,
         lo = if_else(fitted, pmin(lo, POOLED[1]), POOLED[1]),
         hi = if_else(fitted, pmax(hi, POOLED[2]), POOLED[2]),
         # A wide right tail is the signature of a post-professional program;
         # a median near zero is entry-level. Reported, not acted on.
         program_type = case_when(!fitted ~ "unknown (few matches)",
                                  median_gap <= 1 ~ "entry-level DNP (gap ~ 0)",
                                  TRUE ~ "post-professional DNP"))

res <- real %>%
  left_join(win %>% select(institution, lo, hi, fitted, program_type), by = "institution") %>%
  mutate(lo = coalesce(lo, POOLED[1]), hi = coalesce(hi, POOLED[2]),
         temporally_concordant = !is.na(gap) & gap >= lo & gap <= hi)

# The crosswalk join must happen BEFORE tiering now, because state_agrees is a
# tier input rather than a decoration.
if (file.exists(FROZEN)) {
  .fz <- read_csv(FROZEN, col_types = cols(.default = "c")) %>%
    select(certification_number, npi, linkage_tier, nppes_state)
  res <- res %>% left_join(.fz, by = "certification_number") %>%
    mutate(state_agrees = !is.na(nppes_state) & !is.na(state) & nppes_state == state)
} else {
  res <- res %>% mutate(npi = NA_character_, linkage_tier = NA_character_,
                        nppes_state = NA_character_, state_agrees = FALSE)
}

# Ambiguity: one project matched by more than one certificant. At most one can
# be right, and which is unknowable from name alone.
# AMBIGUITY IS PER AUTHOR STRING, NOT PER PROJECT. Grouping by project treated
# a genuine multi-author DNP project as ambiguous: 37 groups had two
# certificants matching two DIFFERENT authors on the same paper, which is two
# real matches, not a collision. Only several certificants competing for the
# SAME author string is unresolvable.
res <- res %>%
  group_by(institution, repository_author_key = author_raw) %>%
  mutate(n_amcb_on_project = n_distinct(certification_number)) %>%
  ungroup() %>%
  # THE WINDOW IS NO LONGER A GATE. Fitting it per institution from the matched
  # gaps was CIRCULAR: those matches are up to 59% false, so the fitted p10-p90
  # widened to absurdity (-1..+38) until it accepted everything. Measured on
  # non-Frontier schools, a fixed window barely helped either (59% -> 33% FP).
  #
  # STATE AGREEMENT IS THE CORROBORATOR THAT WORKS. True matches agree on state
  # ~88% of the time (deconvolved) while name collisions agree 2% of the time --
  # a ~44x likelihood ratio. It takes non-Frontier precision from 59% FP to 3%.
  # midwifery_text is rarer but cleaner still (0% FP on 10 matches).
  #
  # The window remains a REPORTED field: the gap distribution diagnoses program
  # type (Frontier median 4, p90 19 = post-professional; Seattle median 0 =
  # entry-level), which is a finding in its own right. It just must not gatekeep.
  mutate(training_evidence_class = case_when(
    n_amcb_on_project > 1                          ~ 4L,
    # A shared MIDDLE name alone is not identification, whatever the collection.
    given_match_position == "both_middle"          ~ 3L,
    collection_specific                            ~ 1L,
    # Measured on non-Frontier schools: first-given-name match AND a name held
    # by exactly one certificant gives 207 people at 16% FP, against 34 people
    # at ~8% under the old state rule. Six times the yield, and it does not
    # penalise anyone for having moved.
    (given_match_position == "both_first" & name_is_unique_in_roster) |
      midwifery_text                               ~ 2L,
    TRUE                                           ~ 3L),
    training_evidence = recode(as.character(training_evidence_class),
      "1" = "collection_is_midwifery_specific",
      "2" = "generic_collection_unique_first_name_or_midwifery_text",
      "3" = "generic_collection_name_match_only",
      "4" = "ambiguous_multiple_certificants_on_one_project"))

out <- res %>%
  transmute(certification_number, amcb_name = paste(first_name, last_name), npi,
            linkage_tier, training_institution = institution, school_state = state,
            program_type, collection, repository_author = author_raw,
            project_title = title, project_year, cert_year, gap,
            window_lo = lo, window_hi = hi, window_fitted = fitted,
            temporally_concordant, midwifery_text, state_agrees,
            given_match_position, n_amcb_same_name, name_is_unique_in_roster,
            n_amcb_on_project, training_evidence_class, training_evidence,
            project_url = url) %>%
  arrange(training_evidence_class, training_institution, certification_number)
write_csv(out, OUT, na = "")

# --- report ------------------------------------------------------------------
cat("================ AMCB x ACME DNP AUTHORS ================\n")
cat(sprintf("harvested author-records : %s across %s institutions\n",
            format(nrow(au), big.mark = ","), n_distinct(au$institution)))
cat(sprintf("AMCB certificants matched: %s\n", format(n_distinct(out$certification_number), big.mark = ",")))
cat(sprintf("permutation control      : %s  (%.0f%% FP proxy)\n",
            format(n_distinct(ctrl$certification_number), big.mark = ","),
            100 * n_distinct(ctrl$certification_number) /
              max(n_distinct(real$certification_number), 1)))
cat("\n-- evidence class --\n")
print(as.data.frame(out %>% count(training_evidence_class, training_evidence)))
cat("\n-- by institution --\n")
print(as.data.frame(out %>% group_by(training_institution) %>%
  summarise(people = n_distinct(certification_number),
            program_type = first(program_type),
            window = sprintf("%+d..%+d", first(window_lo), first(window_hi)),
            median_gap = median(gap, na.rm = TRUE), .groups = "drop") %>%
  arrange(desc(people))))
cat(sprintf("\nwith an NPI: %s of %s\n",
            format(sum(!is.na(out$npi)), big.mark = ","),
            format(nrow(out), big.mark = ",")))
cat(sprintf("written: %s\n", OUT))
