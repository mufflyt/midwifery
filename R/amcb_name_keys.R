# =============================================================================
# AMCB name keys -- now a shim over the mysterynpi package
# =============================================================================
#
# WHAT HAPPENED HERE (2026-09-05). Everything this file used to define was
# extracted into the mysterynpi package -- the extraction's stated purpose was
# to stop this repository, isochrones and their siblings from each carrying a
# copy of the same rules. This file is the adoption: the amcb_* names survive
# so no call site changes, and each one now delegates to the package.
#
# WHY A PACKAGE BEATS THE source() THIS REPLACED. The old header said "a
# second copy of a name-normalisation rule is how two pipelines quietly
# disagree about who matched whom", and enforced it by source()-ing
# ~/isochrones -- a path that could move without any version changing (Cycle
# 4 was exactly that). A package pins a VERSION, and the behaviour this
# pipeline relies on is pinned twice more: mysterynpi's own CI proves the
# normalisation surface byte-identical to the isochrones originals
# (test-drop-in-parity), and tests/test_mysterynpi_contracts.R in THIS repo
# runs the package's assert_*_contract() suite so a breaking change upstream
# fails here, in CI, before it can touch a cohort.
#
# EQUIVALENCE, MEASURED ON THIS COHORT (2026-09-05). Old implementation vs
# mysterynpi over the 23,543 distinct name values in midwives.csv plus an
# adversarial battery: name keys, parenthetical stripping, blank_na, first
# initials, has-information, surname tokens and token table, middle tokens,
# split-first, noise stripping, given tokens (on the normalised inputs the
# old contract required) and middle agreement -- ALL IDENTICAL. One
# definitional difference exists and was measured to touch nothing:
# mysterynpi's NAME_NOISE adds FACOG/FACS/FRCS (physician credentials) to
# the credential list; zero roster values change under it.
#
# The historical rationale for each rule now lives in mysterynpi's own
# documentation, alongside the defects that motivated them (several of which
# were first paid for in this repository).
# =============================================================================

if (!requireNamespace("mysterynpi", quietly = TRUE)) {
  stop(paste0(
    "AMCB name keys are provided by the mysterynpi package, which is not ",
    "installed.\n",
    "  Fix: remotes::install_github(\"mufflyt/mysterynpi@v0.2.0\")\n",
    "       (public repository; no credentials needed)\n",
    "  Do NOT vendor a local copy -- name handling must have exactly one ",
    "definition across the pipelines that compare names."), call. = FALSE)
}
if (utils::packageVersion("mysterynpi") < "0.2.0") {
  stop(sprintf("mysterynpi %s installed; this pipeline pins >= 0.2.0.",
               utils::packageVersion("mysterynpi")), call. = FALSE)
}
# stringi is what performs the transliteration; mysterynpi::name_key refuses
# to run without it, so the old explicit guard is now enforced upstream.

amcb_strip_parenthetical  <- mysterynpi::strip_parenthetical
amcb_name_key             <- mysterynpi::name_key
amcb_has_name_information <- mysterynpi::has_name_information
amcb_blank_na             <- mysterynpi::blank_na
amcb_first_initial        <- mysterynpi::first_initial
amcb_surname_tokens       <- mysterynpi::surname_tokens
amcb_surname_token_table  <- mysterynpi::surname_token_table
amcb_middle_tokens        <- mysterynpi::middle_tokens
amcb_strip_name_noise     <- mysterynpi::strip_name_noise
amcb_given_tokens         <- mysterynpi::given_tokens
amcb_person_matches       <- mysterynpi::person_matches

AMCB_SURNAME_PARTICLES <- mysterynpi::SURNAME_PARTICLES
AMCB_MIN_SURNAME_TOKEN <- mysterynpi::MIN_SURNAME_TOKEN
AMCB_NAME_NOISE        <- mysterynpi::NAME_NOISE

#' Split the AMCB first_name field into given name and trailing middle tokens.
#' The package calls the second element middle_from_given; this cohort's call
#' sites say middle_from_first, and a rename across seven scripts buys nothing.
amcb_split_first <- function(first_name) {
  s <- mysterynpi::split_given(first_name)
  list(given = s$given, middle_from_first = s$middle_from_given)
}

#' Parse an author string into first / middle / last.
#'
#' CONTRACT DIFFERENCE, PRESERVED HERE: mysterynpi::parse_person() renders
#' absent parts as "" so has_name_information() is the only test a caller
#' needs; this repository's callers predate that and test is.na(). The shim
#' keeps this cohort's NA contract so no consumer changes meaning.
amcb_parse_person <- function(x) {
  out <- mysterynpi::parse_person(x)
  out[] <- lapply(out, function(v) { v[!nzchar(v)] <- NA_character_; v })
  out
}

coalesce_chr <- function(x) if (is.null(x)) "" else ifelse(is.na(x), "", x)
