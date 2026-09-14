# Training institution: the one place this repo resolves where a midwife trained.
#
# WHY THIS FILE EXISTS. Three products need the same answer -- Table 1, the
# leaflet map popups, and the education-history artifact -- and the resolution
# is not a lookup. It coalesces four sources with different coverage, different
# provenance and different meanings, and it keeps INITIAL midwifery education
# separate from a LATER doctorate. A second copy of that logic in a caller is
# how this codebase has silently broken before, so callers get these functions
# and never re-derive them.
#
# THE SOURCES ARE NOT INTERCHANGEABLE. CMS DAC maps every clinician through a
# MEDICAL-school code list, so it can only ever name a university that has a
# medical school. Frontier Nursing University -- the largest US nurse-midwifery
# programme -- CANNOT appear in it at any coverage level. Healthgrades is
# self-reported and reaches people DAC never enrolled. University repositories
# name a school structurally: the institution is which repository holds the
# thesis, not a string parsed from an affiliation. Order is registry, then
# profile, then repository, so self-report never overrides a federal file. The
# Trilliant provider directory comes last: it carries DAC's own strings for
# people the current DAC file no longer holds, and is only a backup.
#
# THE TWO VARIABLES ARE NOT ONE. 43% of repository links are doctorates earned
# after certification (median gap 7 years; 280 of them Frontier). Reporting
# those as where someone trained is false for the majority of Frontier rows.
# `midwifery_program` and `later_doctoral_institution` stay separate columns and
# separate display lines, and no caller may coalesce them.
# See docs/TECHNICAL_APPENDIX_OAI_TRAINING_INSTITUTION.md.

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

#' Normalise an institution string for comparison and pooling
#'
#' Not for display. Uppercases, resolves the escaped ampersands that appear in
#' DAC's export, strips punctuation and drops a leading "The" so that
#' "The Ohio State University" and "Ohio State University" pool together.
#' Returns NA for empty input rather than "".
training_norm_school <- function(x) {
  y <- toupper(str_squish(as.character(x)))
  y <- str_replace_all(y, "\\\\U0026|\\\\u0026|&AMP;", "AND")
  y <- str_replace_all(y, "[^A-Z0-9 ]", " ")
  y <- str_squish(str_replace(y, "^THE ", ""))
  ifelse(is.na(x) | !nzchar(y), NA_character_, y)
}

#' Strip a trailing medical-school unit from a CMS school name
#'
#' CMS maps every clinician through a MEDICAL-school code list, so a CNM's
#' nursing programme arrives as "<University> SCHOOL OF MEDICINE". Verbatim it
#' reads as a midwife with an MD. This keeps the institution and drops the unit.
#' Used by extract_dac_cnm_education.R (DAC) and enrich_trilliant_demographics.R
#' (the Trilliant directory, whose school strings are DAC's, character for
#' character), so both sources clean to the same value.
strip_med_suffix <- function(x) {
  # Ordered longest-first so a shorter pattern cannot truncate a longer one --
  # "COLLEGE OF MEDICINE" must be consumed before "COLLEGE OF MED" can leave a
  # trailing "INE". Every pattern anchors to end-of-string, so only a TRAILING
  # academic unit is removed and a leading one (Medical University of South
  # Carolina, Medical College of Wisconsin) is left intact by the guard below.
  #
  # Derived from the 72 distinct strings CMS actually uses for CNMs, not from
  # imagination: they include five DENTAL schools and a college of physicians
  # and surgeons, which is CMS taxonomy noise rather than midwifery training.
  pats <- c(
    "SCHOOL OF MEDICINE AND DENTISTRY", "COLLEGE OF PHYSICIANS AND SURGEONS",
    "SCHOOL OF OSTEOPATHIC MEDICINE",   "COLLEGE OF OSTEOPATHIC MEDICINE",
    "COLLEGE OF MEDICINE AND SURGERY",  "SCHOOL OF DENTAL MEDICINE",
    "SCHOOL OF DENTAL MED",             "COLLEGE OF DENTISTRY",
    "SCHOOL OF MEDICINE",               "COLLEGE OF MEDICINE",
    "MEDICAL DEPARTMENT",               "MEDICAL BRANCH",
    "MEDICAL SCHOOL",                   "MEDICAL COLLEGE",
    "MEDICAL CENTER",                   "MEDICAL UNIVERSITY",
    "COLLEGE OF MED", "SCHOOL OF MED", "SCH OF MED", "MED CTR", "MED SCH")
  # `^(.+?)` requires at least one character BEFORE the pattern, so a phrase
  # that opens the institution's name is never treated as a suffix. Without it,
  # "MEDICAL UNIVERSITY OF SOUTH CAROLINA COLLEGE OF MEDICINE" matched
  # "MEDICAL UNIVERSITY" at position 0, consumed the whole string, and the
  # empty-guard handed back the original -- the one name in 72 that came out
  # uncleaned. With it, only "COLLEGE OF MEDICINE" is stripped and the
  # institution survives.
  # "UN OF" is CMS's abbreviation in "STATE UN OF NY".
  inst <- regex("\\b(UNIVERSITY|UNIV|UN OF|COLLEGE|INSTITUTE)\\b", ignore_case = TRUE)
  y <- x
  # A NAMED SCHOOL OF A UNIVERSITY. When the medical unit is followed by "at",
  # "of" or a comma and then a university, the university is the institution and
  # the words before the unit are the school's own name: "BRODY SCHOOL OF
  # MEDICINE AT EAST CAROLINA UNIVERSITY", "PERELMAN SCHOOL OF MED AT THE
  # UNIVERSITY OF PENNSYLVANIA", "JEFFERSON MEDICAL COLLEGE OF THOMAS JEFFERSON
  # UNIVERSITY". Keeping the head, as the strip below does, reported BRODY,
  # PERELMAN and JEFFERSON as if they were universities.
  for (p in pats) {
    tail <- str_match(y, regex(paste0("^.+?\\s*[,-]?\\s*", p,
                                      "(?:\\s*,\\s*|\\s+(?:AT|OF)\\s+(?:THE\\s+)?)(.+)$"),
                               ignore_case = TRUE))[, 2]
    use <- !is.na(tail) & str_detect(tail, inst)
    y[use] <- tail[use]
  }
  # THE UNIT ITSELF. Each strip is accepted only if what is left still names an
  # institution. A strip that leaves no institution word means the medical
  # phrase WAS the institution's name, so that step is refused and the name
  # before it kept: OHIO MEDICAL UNIVERSITY, BAYLOR COLLEGE OF MEDICINE, ALBANY
  # MEDICAL COLLEGE and PHILADELPHIA COLLEGE OF OSTEOPATHIC MEDICINE are
  # institutions, not "OHIO", "BAYLOR", "ALBANY" and "PHILADELPHIA" -- which is
  # what the previous version returned, despite a comment saying it did not.
  # Refusing one step does not refuse the rest: MEHARRY MEDICAL COLLEGE SCHOOL
  # OF MEDICINE loses "SCHOOL OF MEDICINE" and keeps "MEHARRY MEDICAL COLLEGE".
  trim <- function(v)
    # Trailing connective left behind by a strip ("... AT THE", "... SYSTEM,").
    str_squish(str_replace(v, regex("[ ,\\-]+(AT|OF|THE|AND|SYSTEM|HSC)?[ ,\\-]*$", ignore_case = TRUE), ""))
  for (p in pats) {
    cand <- trim(str_replace(y, regex(paste0("^(.+?)\\s*[,-]?\\s*", p, "\\b.*$"),
                                      ignore_case = TRUE), "\\1"))
    ok <- !is.na(cand) & cand != y & nzchar(cand) & str_detect(cand, inst)
    y[ok] <- cand[ok]
  }
  ifelse(is.na(x), NA_character_, y)
}

#' Read the institution sources, keyed for joining
#'
#' Each returns NULL when its file is absent, so a caller running against a
#' partial checkout degrades to fewer sources rather than failing. DAC is keyed
#' by NPI (the only key it shares with anything); the other two by AMCB
#' certification number.
training_source_dac <- function(path = "artifacts/dac_cnm_education.csv") {
  if (!file.exists(path)) return(NULL)
  read_csv(path, show_col_types = FALSE, progress = FALSE) %>%
    mutate(npi = as.character(NPI)) %>%
    # Which duplicate row wins is a scientific choice, so state it: prefer a
    # row that names a real school over one DAC could not code, then sort by
    # the school string so the survivor does not depend on file order.
    arrange(npi, is.na(med_sch_clean) | med_sch_clean == "OTHER", med_sch_clean) %>%
    distinct(npi, .keep_all = TRUE) %>%
    # "OTHER" is DAC's placeholder for a school it could not code -- 4,171
    # values. It is not an institution and is dropped, not counted.
    transmute(npi, dac_school = ifelse(!is.na(med_sch_clean) &
                                         med_sch_clean != "OTHER",
                                       med_sch_clean, NA_character_))
}

training_source_healthgrades <- function(
    link_path  = "healthgrades_midwives.csv",
    attrs_path = "healthgrades_profile_attrs.csv",
    eligible   = NULL) {
  if (!file.exists(link_path) || !file.exists(attrs_path)) return(NULL)
  lk <- read_csv(link_path, show_col_types = FALSE, progress = FALSE) %>%
    filter(hg_status == "ok", !is.na(hg_url))
  # A profile URL shared by two certificants cannot be attributed to either;
  # copying one person's school onto another is worse than leaving it blank.
  if (!is.null(eligible)) lk <- filter(lk, certification_number %in% eligible)
  lk %>%
    distinct(certification_number, hg_url) %>%
    # healthgrades_profile_attrs.csv is one row per hg_url (8,231 of 8,231).
    # The distinct() below guards the LEFT side -- one certificant holding two
    # profile URLs -- not fan-out from the right.
    left_join(read_csv(attrs_path, show_col_types = FALSE, progress = FALSE) %>%
                select(hg_url, hg_education_name), by = "hg_url",
              relationship = "many-to-one") %>%
    # A certificant with two profile URLs: prefer the one that actually carries
    # a school, then the lexically first URL for determinism.
    arrange(certification_number, is.na(hg_education_name), hg_url) %>%
    distinct(certification_number, .keep_all = TRUE) %>%
    select(certification_number, hg_school = hg_education_name)
}

training_source_repository <- function(
    path = "artifacts/amcb_education_history.csv") {
  if (!file.exists(path)) return(NULL)
  read_csv(path, show_col_types = FALSE, progress = FALSE) %>%
    # Prefer the row naming a midwifery program over a blank one, then sort by
    # the program so the survivor does not depend on row order.
    arrange(certification_number, !nzchar(coalesce(midwifery_program, "")),
            midwifery_program) %>%
    distinct(certification_number, .keep_all = TRUE) %>%
    transmute(certification_number,
              rep_school = ifelse(nzchar(coalesce(midwifery_program, "")),
                                  midwifery_program, NA_character_),
              rep_doctoral = ifelse(nzchar(coalesce(later_doctoral_institution, "")),
                                    later_doctoral_institution, NA_character_),
              rep_doctoral_year = later_doctoral_year,
              rep_evidence_class = training_evidence_class)
}

#' The Trilliant provider directory's school, keyed by certification number
#'
#' Built by enrich_trilliant_demographics.R and already cleaned by
#' strip_med_suffix(). It is CMS DAC's medical-school string (it agreed with DAC
#' on every midwife both named, 2026-09-13), so it reaches people the current
#' DAC file no longer carries -- and shares DAC's blind spot for schools without
#' a medical school. Last in the order: a backup, never an override.
training_source_trilliant <- function(path = "artifacts/trilliant_demographics.csv") {
  if (!file.exists(path)) return(NULL)
  t <- read_csv(path, col_types = cols(.default = "c"), progress = FALSE) %>%
    select(certification_number, trl_school = trl_school_clean)
  if (anyDuplicated(t$certification_number))
    stop(path, " repeats a certification number; rebuild it.", call. = FALSE)
  t
}

#' Attach resolved education columns to a cohort
#'
#' Requires `certification_number` and `npi`. Adds:
#'   training_institution        display-cased initial midwifery school, or NA
#'   training_institution_source which source named it, for the reader
#'   later_doctoral_institution  a doctorate earned after certification, or NA
#'   later_doctoral_year
#'
#' `title_case` must be the canonical mysterymaps helper -- it keeps small words
#' lower inside a name ("... of New York at Stony Brook"), handles Mc/Mac and
#' leaves mixed-case input alone. A local re-case drifts from it.
training_attach <- function(coh, title_case, eligible = NULL, verbose = TRUE,
                            trilliant_path = "artifacts/trilliant_demographics.csv") {
  stopifnot(is.function(title_case))
  miss <- setdiff(c("certification_number", "npi"), names(coh))
  if (length(miss))
    stop("training_attach() needs column(s): ", paste(miss, collapse = ", "),
         call. = FALSE)

  coh <- mutate(coh, npi = as.character(npi))
  d <- training_source_dac()
  h <- training_source_healthgrades(eligible = eligible)
  r <- training_source_repository()
  t <- training_source_trilliant(trilliant_path)
  if (!is.null(d)) coh <- left_join(coh, d, by = "npi", relationship = "one-to-one")
  if (!is.null(h)) coh <- left_join(coh, h, by = "certification_number",
                                    relationship = "one-to-one")
  if (!is.null(r)) coh <- left_join(coh, r, by = "certification_number",
                                    relationship = "one-to-one")
  if (!is.null(t)) coh <- left_join(coh, t, by = "certification_number",
                                    relationship = "one-to-one")
  for (v in c("dac_school", "hg_school", "rep_school", "rep_doctoral", "trl_school")) {
    if (!v %in% names(coh)) coh[[v]] <- NA_character_
  }
  if (!"rep_doctoral_year" %in% names(coh)) coh$rep_doctoral_year <- NA

  dn <- training_norm_school(coh$dac_school)
  hn <- training_norm_school(coh$hg_school)
  rn <- training_norm_school(coh$rep_school)
  tn <- training_norm_school(coh$trl_school)
  coh$training_institution_source <- case_when(
    !is.na(dn) ~ "CMS Doctors and Clinicians",
    !is.na(hn) ~ "Healthgrades profile",
    !is.na(rn) ~ "university repository (thesis or DNP project)",
    !is.na(tn) ~ "Trilliant provider directory",
    TRUE       ~ NA_character_)
  coh$training_institution        <- title_case(coalesce(dn, hn, rn, tn))
  coh$later_doctoral_institution  <- title_case(training_norm_school(coh$rep_doctoral))
  coh$later_doctoral_year         <- coh$rep_doctoral_year

  if (verbose) {
    n <- nrow(coh)
    cat(sprintf("training institution: %s of %s (%.1f%%) [DAC %s, Healthgrades %s, repository %s, Trilliant %s]\n",
                sum(!is.na(coh$training_institution)), n,
                100 * mean(!is.na(coh$training_institution)),
                sum(!is.na(dn)), sum(is.na(dn) & !is.na(hn)),
                sum(is.na(dn) & is.na(hn) & !is.na(rn)),
                sum(is.na(dn) & is.na(hn) & is.na(rn) & !is.na(tn))))
    cat(sprintf("later doctorate (NOT training): %s\n",
                sum(!is.na(coh$later_doctoral_institution))))
  }
  select(coh, -any_of(c("dac_school", "hg_school", "rep_school", "rep_doctoral",
                        "rep_doctoral_year", "trl_school")))
}
