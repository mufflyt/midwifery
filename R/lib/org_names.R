# =============================================================================
# Organization legal names, normalised for equivalence testing
# =============================================================================
# Arms identify organizations by DIFFERENT keys: PECOS and Care Compare use a
# PAC ID, NPPES co-location uses a Type-2 NPI, the hospital arms use a CCN.
# There is no public crosswalk joining all three, so when two arms are asked
# whether they name the SAME organization, the only thing they share is the
# name. That makes this function load-bearing rather than cosmetic.
#
# It is deliberately conservative. It strips corporate suffixes and punctuation
# so "MERCY CLINIC, LLC" and "MERCY CLINIC INC" compare equal; it does NOT
# stem, fuzzy-match or drop distinguishing words. "FAIRVIEW CLINICS" and
# "FAIRVIEW HEALTH SERVICES" remain different organizations, because they are.
#
# Promoted here from classify_residual_disagreements.R when the affiliation
# resolver became a second caller. Per CLAUDE.md, a helper with two callers
# belongs in R/lib and is defined exactly once -- duplicate definitions have
# silently broken this codebase before, and tests/ci_hygiene.R H4 fails on a
# new one.
# =============================================================================

#' Normalize an organization legal name for equivalence testing
#'
#' @param x [vector]: organization name as recorded.
#' @return [character] upper-case key, "" where empty. Never NA, so that a
#'   missing name groups with other missing names rather than silently
#'   dropping out of a join.
norm_org <- function(x) {
  y <- toupper(stringr::str_trim(replace(as.character(x), is.na(as.character(x)), "")))
  # Apostrophes are DELETED, not turned into a space. Turning them into a space
  # splits every possessive, so "ST MARY'S HOSPITAL" keyed as "ST MARY S
  # HOSPITAL" and never matched "ST MARYS HOSPITAL" -- two spellings of one
  # organization, recorded differently by two arms, counted as a disagreement.
  # Curly apostrophes are included: NPPES and Care Compare do not agree on which
  # they use.
  y <- stringr::str_replace_all(y, "['’ʼ`]", "")
  y <- stringr::str_replace_all(y, "[^A-Z0-9 ]", " ")
  y <- stringr::str_replace_all(
    y, "\\b(INC|LLC|PC|PA|LLP|CORP|CORPORATION|COMPANY|CO|THE|OF|AND)\\b", " ")
  stringr::str_trim(stringr::str_replace_all(y, "\\s+", " "))
}
