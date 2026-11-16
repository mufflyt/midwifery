#!/usr/bin/env Rscript
# =============================================================================
# Saboteurs against ZIP normalization: the quiet way a cohort shrinks
# =============================================================================
# WHY THIS FILE EXISTS, AND WHY NOW. Every defect found in this repository
# during the 2026-11 audit had one signature: a transformation that degraded
# the data without failing. A wildcard that found four fewer years. A
# row-bind that filled an absent state column with NA. A program year read
# from a filename. A "union" whose input held one row per provider, so it
# unioned nothing. And, in the script written to investigate the last of
# those, a hand-rolled five-digit helper that returned NA for any ZIP which
# had already lost its leading zero -- silently deleting New England from a
# comparison about geography.
#
# None of those errored. Each produced a smaller or wrong study that looked
# right. ZIP normalization is the same class of code and had no saboteurs, so
# these exist before the call sites are rewritten rather than after.
#
# THE TWO FUNCTIONS ARE NOT INTERCHANGEABLE, and that is the single most
# important thing these tests pin. norm_str_zip5() is for a value that was
# stored as text. norm_pecos_bigint_zip5() is for one stored as a number,
# where a nine-digit ZIP+4 missing its leading zero must be padded to NINE
# before truncation. Truncating first yields a real, valid-looking, wrong
# ZIP in a different state. Z6 and Z7 are that failure.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(stringr)})
source(file.path(root, "R", "lib", "oig_zip_normalizers.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
eq <- function(actual, expected) {
  (is.na(actual) && is.na(expected)) ||
    (!is.na(actual) && !is.na(expected) && identical(actual, expected))
}
sab <- function(n, name) cat(sprintf("\nZ%d %s\n", n, name))

# =============================================================================
# PART 1 -- A LEADING ZERO THAT WAS LOST UPSTREAM
# =============================================================================

sab(1, "a five-digit ZIP whose leading zero was dropped by a spreadsheet")
{
  # 01234 is Massachusetts. Read through anything that treats the column as a
  # number and it arrives as 1234. A normalizer that returns NA here deletes
  # every ZIP in MA, RI, NH, ME, VT, CT, NJ and PR from the analysis, and
  # does it without a warning.
  chk(eq(norm_str_zip5("1234"), "01234"),
      sprintf("padded to five digits, not dropped [%s]", norm_str_zip5("1234")))
  chk(eq(norm_pecos_bigint_zip5(1234), "01234"),
      sprintf("the numeric-stored path pads too [%s]",
              norm_pecos_bigint_zip5(1234)))
}

sab(2, "a three-digit ZIP, two zeros gone")
{
  chk(eq(norm_str_zip5("123"), "00123"),
      sprintf("padded to five [%s]", norm_str_zip5("123")))
}

sab(3, "an entire New England column arriving four digits wide")
{
  new_england <- c("1234", "2134", "3031", "4101", "5401", "6511", "7102")
  normalized <- norm_str_zip5(new_england)
  chk(all(!is.na(normalized)) && all(nchar(normalized) == 5),
      sprintf("all %d padded, none dropped [%d kept]", length(new_england),
              sum(!is.na(normalized))))
  chk(all(substr(normalized, 1, 1) == "0"),
      "every one keeps the leading zero that identifies the region")
}

# =============================================================================
# PART 2 -- ZIP+4, WHERE TRUNCATING BEFORE PADDING INVENTS A REAL WRONG ZIP
# =============================================================================

sab(4, "a genuine nine-digit ZIP+4")
{
  chk(eq(norm_str_zip5("012345678"), "01234"),
      sprintf("first five of the padded nine [%s]",
              norm_str_zip5("012345678")))
}

sab(5, "a ZIP+4 written with the conventional hyphen")
{
  chk(eq(norm_str_zip5("12345-6789"), "12345"),
      sprintf("punctuation stripped, first five kept [%s]",
              norm_str_zip5("12345-6789")))
}

sab(6, "THE DANGEROUS ONE: a numeric ZIP+4 that lost its leading zero")
{
  # 012345678 stored as a number is 12345678. Truncate first and you get
  # "12345", which is a real ZIP in a different state. Pad to nine first and
  # you get "01234", which is the right one. This is not a dropped record --
  # it is a confidently wrong one, and nothing downstream can detect it.
  chk(eq(norm_pecos_bigint_zip5(12345678), "01234"),
      sprintf("padded to nine BEFORE truncating [%s]",
              norm_pecos_bigint_zip5(12345678)))
  chk(!eq(norm_pecos_bigint_zip5(12345678), "12345"),
      "and is NOT the valid-looking wrong ZIP that truncating first produces")
}

sab(7, "INVERTED: the two normalizers must not be interchangeable")
{
  # If someone 'simplifies' by routing numeric-stored ZIPs through the string
  # normalizer, Z6 silently regresses. This test fails if the two ever agree
  # on the case that distinguishes them.
  chk(!eq(norm_str_zip5("12345678"), norm_pecos_bigint_zip5(12345678)),
      sprintf("string path gives %s, numeric path gives %s",
              norm_str_zip5("12345678"), norm_pecos_bigint_zip5(12345678)))
}

# =============================================================================
# PART 3 -- PLACEHOLDERS THAT MUST NOT PASS AS GEOGRAPHY
# =============================================================================

sab(8, "the 00000 placeholder")
{
  # 00000 is not a ZIP. Carried through, it becomes a location: records
  # cluster at a nonexistent place and any map or join silently gains a
  # phantom site.
  chk(is.na(norm_str_zip5("00000")),
      sprintf("refused as a location [%s]", norm_str_zip5("00000")))
  chk(is.na(norm_pecos_bigint_zip5(0)),
      sprintf("and refused on the numeric path [%s]",
              norm_pecos_bigint_zip5(0)))
}

sab(9, "empty, missing and non-numeric values")
{
  chk(is.na(norm_str_zip5("")), "empty string is NA")
  chk(is.na(norm_str_zip5(NA_character_)), "NA is NA")
  chk(is.na(norm_str_zip5("N/A")), "non-numeric text is NA, not a ZIP")
  chk(is.na(norm_str_zip5("--")), "punctuation alone is NA")
}

sab(10, "INVERTED: a correct ZIP must pass through untouched")
{
  # A normalizer that fails everything satisfies every test above. These
  # three keep it honest.
  chk(eq(norm_str_zip5("80204"), "80204"), "a Denver ZIP is unchanged")
  chk(eq(norm_str_zip5("99999"), "99999"), "the top of the range survives")
  chk(eq(norm_str_zip5(" 80204 "), "80204"), "surrounding whitespace is trimmed")
}

sab(11, "INVERTED: a valid ZIP beginning with zero is not mistaken for a placeholder")
{
  chk(eq(norm_str_zip5("01234"), "01234"),
      "a real leading-zero ZIP is kept, not refused alongside 00000")
  chk(eq(norm_str_zip5("00501"), "00501"),
      "00501, the lowest assigned ZIP in the United States, survives")
}

# =============================================================================
# PART 4 -- THE REPOSITORY'S OWN DATA
# =============================================================================

sab(12, "the tracked inputs must not already be carrying damaged ZIPs")
{
  # A guard, not a unit test. If a producer ever starts writing four-digit
  # ZIPs into a tracked artifact, the normalizer will rescue the analysis but
  # the artifact is still wrong, and the next reader may not normalize.
  check_file <- function(path, column) {
    if (!file.exists(path)) return(NULL)
    rows <- utils::read.csv(path, colClasses = "character", nrows = 200000)
    if (!column %in% names(rows)) return(NULL)
    digits <- gsub("[^0-9]", "", rows[[column]])
    digits <- digits[nzchar(digits)]
    sum(nchar(digits) == 4)
  }
  for (spec in list(c("dac_midwives.csv", "practice_zip"),
                    c("midwife_panel.csv", "practice_zip"))) {
    n_damaged <- check_file(spec[1], spec[2])
    if (is.null(n_damaged)) {
      cat(sprintf("  skip %s absent from this checkout\n", spec[1]))
    } else {
      chk(n_damaged == 0L,
          sprintf("%s carries no four-digit ZIP [%d]", spec[1], n_damaged))
    }
  }
}

sab(13, "normalizing is idempotent")
{
  # A pipeline that normalizes twice -- once in a producer and once in a
  # consumer -- must not change the value on the second pass.
  once <- norm_str_zip5(c("1234", "012345678", "80204", "00000"))
  twice <- norm_str_zip5(once)
  chk(identical(once, twice), "a second pass changes nothing")
}

cat(sprintf("\n%s (%d failures across 13 saboteurs)\n",
            if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
