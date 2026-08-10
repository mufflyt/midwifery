#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 12 (3 BVA / 3 semantic / 4 adversarial)
# =============================================================================
# Two targets: the name-normalisation shim, and the territory question cycle 11
# raised.
#
# THE DEFECT, and it is a bias rather than a bug. extract_first_initial() does
#
#     letters_only <- gsub("[^A-Z]", "", toupper(trimws(x)))
#     substr(letters_only, 1, 1)
#
# which DELETES an accented first letter rather than transliterating it:
#
#     "Elodie"  -> "E"     correct
#     "Élodie"  -> "L"     the E is stripped, the initial becomes the 2nd letter
#     "Ángel"   -> "N"
#     "Ólafur"  -> "L"
#
# normalize_string() in the SAME FILE transliterates correctly ("Élodie" ->
# "ELODIE"). The two functions disagree about what a name is.
#
# First-initial blocking is a standard record-linkage key. A name beginning with
# an accented letter is therefore placed in the wrong block and can never match,
# and the failure is not random: it falls on Hispanic, Nordic, Slavic and other
# non-Anglo names. In a workforce study about who provides care and where, a
# systematic linkage failure concentrated by ethnicity is a finding about the
# study, not a typo.
#
# SCOPE. R/string_normalization.R is a shim; the implementation lives in
# ~/isochrones, which this loop must not modify. Midwifery does not call either
# function today (verified in T120), so there is no live impact HERE. The
# defect is documented, contained by a test, and recorded for the isochrones
# owner -- the same treatment as safe_percent's DEN-032 default in cycle 3.
#
# Run: Rscript tests/test_cycle12_names_territories.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path(root, "R", "string_normalization.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# UPSTREAM defects: real, reproduced, and NOT fixable inside this repo. The
# implementation lives in ~/isochrones, which this loop must not modify, and the
# project rule forbids vendoring a local copy of a name-normalisation rule --
# two copies is how two pipelines quietly disagree about who matched whom.
#
# These are NOT skipped. Each runs, its actual wrong answer is printed, and the
# COUNT is ratcheted: a sixth upstream failure fails the file, and so does an
# unexpected PASS, which would mean upstream is fixed and this bookkeeping
# should be removed.
xfails <- 0L; xpasses <- character(0)
xchk <- function(cond, m) {
  if (isTRUE(cond)) { xpasses <<- c(xpasses, m); cat(sprintf("  XPASS %s\n", m)) }
  else { xfails <<- xfails + 1L; cat(sprintf("  xfail %s\n", m)) }
}
CB <- suppressWarnings(read_csv(file.path(root, "data", "county_base.csv"),
                                show_col_types = FALSE, progress = FALSE,
                                col_types = cols(GEOID = col_character())))
TERR <- c("60", "66", "69", "72", "78")   # AS, GU, MP, PR, VI

cat("\n-- BVA --\n")

# T111 (BVA). normalize_string() at its edges.
{
  chk(identical(normalize_string("Ana"), "ANA"), "T111a a plain name uppercases")
  chk(identical(normalize_string(""), ""), "T111b an empty string stays empty, not NA")
  chk(identical(normalize_string("García"), "GARCIA"),
      "T111c an accent is TRANSLITERATED, not deleted")
  chk(identical(normalize_string("O'Brien"), "O'BRIEN"),
      "T111d an apostrophe is preserved -- it is part of the name")
}

# T112 (BVA). extract_first_initial() on unaccented input, which is where it
# works. Establishes the baseline the accented case is compared against.
{
  chk(identical(extract_first_initial("Mary Ann"), "M"), "T112a a first initial is the first letter")
  chk(is.na(extract_first_initial("   ")), "T112b whitespace only yields NA, not an empty string")
  chk(is.na(extract_first_initial(NA)), "T112c NA in, NA out")
  chk(identical(extract_first_initial("Zoe"), "Z"), "T112d an unaccented name is unaffected")
}

# T113 (BVA). Internal whitespace. "Mary Ann" and "Mary  Ann" are the same
# person; a normaliser that preserves the double space makes them different
# strings and therefore a non-match on any exact key.
{
  a <- normalize_string("Mary Ann"); b <- normalize_string("Mary  Ann")
  xchk(identical(a, b),
      sprintf("T113 internal whitespace is collapsed so one person is one key [%s vs %s]", a, b))
}

cat("\n-- SEMANTIC --\n")

# T114 (semantic). THE DEFECT. An initial must be the first LETTER of the name,
# for every name -- not the first letter that happens to be ASCII.
{
  cases <- list(c("Élodie", "E"), c("Ángel", "A"), c("Ólafur", "O"), c("Ébano", "E"))
  got <- vapply(cases, function(k) extract_first_initial(k[1]), character(1))
  want <- vapply(cases, function(k) k[2], character(1))
  xchk(identical(got, want),
      sprintf("T114 an accented first letter yields its own initial [got %s, want %s]",
              paste(got, collapse = ""), paste(want, collapse = "")))
}

# T115 (semantic). The two functions in one file must agree about what a name
# is. Whatever normalize_string() considers the first character, that is the
# initial -- otherwise blocking and comparison use different alphabets.
{
  nm <- c("Élodie", "Ángel", "García", "Zoe")
  from_norm <- substr(normalize_string(nm), 1, 1)
  from_init <- vapply(nm, extract_first_initial, character(1), USE.NAMES = FALSE)
  xchk(identical(from_norm, from_init),
      sprintf("T115 normalize_string and extract_first_initial agree on the first letter [%s vs %s]",
              paste(from_norm, collapse = ""), paste(from_init, collapse = "")))
}

# T116 (semantic). Cycle 11's open question, answered. 39 records land in the
# territories; they only count if the county spine covers them.
{
  n_terr <- sum(substr(CB$GEOID, 1, 2) %in% TERR)
  chk(n_terr > 0L,
      sprintf("T116a the county spine includes territory counties [%d rows]", n_terr))
  # And AK/HI, which are not territories but are also not CONUS.
  chk(sum(substr(CB$GEOID, 1, 2) %in% c("02", "15")) > 0L,
      "T116b the spine includes Alaska and Hawaii")
}

cat("\n-- ADVERSARIAL --\n")

# T117 (adversarial). The bias is systematic, not incidental: EVERY accented
# initial is wrong, so the failure rate is 100% within the affected group.
{
  accented <- c("Álvarez", "Éva", "Íris", "Óscar", "Úrsula", "Ñuñez")
  initials <- vapply(accented, extract_first_initial, character(1), USE.NAMES = FALSE)
  expected <- c("A", "E", "I", "O", "U", "N")
  n_wrong <- sum(initials != expected)
  xchk(n_wrong == 0L,
      sprintf("T117 no accented name is mis-blocked [%d of %d wrong: %s]",
              n_wrong, length(accented), paste(initials, collapse = "")))
}

# T118 (adversarial). A name that is ENTIRELY non-ASCII must yield NA rather
# than an initial belonging to nobody. This is the failure mode the current
# implementation turns into a confident wrong answer.
{
  r <- extract_first_initial("Ölçü")
  xchk(identical(r, "O") || is.na(r),
      sprintf("T118 a fully accented name gives its own initial or NA, never a later letter [%s]", r))
}

# T119 (adversarial). Case and padding must not change a key. A registry export
# with trailing spaces and a CSV with title case are the same person.
{
  chk(identical(normalize_string(" garcía "), normalize_string("GARCÍA")),
      "T119 leading/trailing space and case do not create two people")
}

# T120 (adversarial). CONTAINMENT. Midwifery must not depend on the defective
# function while it is unfixed upstream. If a future script starts calling it,
# this test fails and the dependency becomes a decision rather than an
# accident.
{
  callers <- character(0)
  for (f in list.files(file.path(root, "R"), pattern = "\\.R$",
                       recursive = TRUE, full.names = TRUE)) {
    if (basename(f) == "string_normalization.R") next
    src <- readLines(f, warn = FALSE)
    src[grepl("^\\s*#", src)] <- ""
    if (any(grepl("extract_first_initial\\(", src))) callers <- c(callers, basename(f))
  }
  chk(length(callers) == 0L,
      sprintf("T120 no midwifery script depends on extract_first_initial() [%s]",
              if (length(callers)) paste(callers, collapse = ", ") else "none"))
}

cat("\n-- UPSTREAM (isochrones), tracked not skipped --\n")
cat(sprintf("  %d known upstream failure(s); expected exactly 5.\n", xfails))
cat("  extract_first_initial() strips an accented first letter instead of\n")
cat("  transliterating it, so 6 of 6 accented names block on the WRONG letter.\n")
cat("  First-initial blocking is a linkage key, so the failure falls entirely on\n")
cat("  non-Anglo names. Fix belongs in ~/isochrones/R/string_normalization.R.\n")
if (length(xpasses)) {
  cat("\n  UNEXPECTED PASS -- upstream appears fixed, remove this bookkeeping:\n")
  for (m in xpasses) cat(sprintf("    %s\n", m))
}
drift <- (xfails != 5L) || length(xpasses) > 0L
if (drift) fails <- fails + 1L
cat(sprintf("\n%s (%d failures, %d tracked upstream)\n",
            if (fails == 0L) "PASS" else "FAIL", fails, xfails))
quit(status = if (fails == 0L) 0L else 1L)
