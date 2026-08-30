#!/usr/bin/env Rscript
# =============================================================================
# AMCB name normalisation -- Unicode/accent regression tests
# =============================================================================
# Guards the defect described at the top of R/amcb_name_keys.R: the AMCB
# matcher normalised names with toupper(trimws(...)) only, so accented names
# could not join their unaccented NPPES spellings by any strategy.
#
# The adversarial loop reported this as "the initial character is deleted".
# That is NOT what happens and the distinction matters for what we assert:
# the accent is PRESERVED, not stripped -- "Álvarez" became "ÁLVAREZ" and its
# first initial "Á". So a test asserting nchar() is unchanged would pass
# against the broken code. These tests assert the transliterated VALUE.
#
# Run: Rscript tests/test_amcb_name_normalization.R
# =============================================================================

source(file.path("tests", "helper-external-data.R"))
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path(root, "R", "amcb_name_keys.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# The old normaliser, reproduced here ONLY so the tests can prove they
# discriminate. If a test passes under both, it is not testing the fix.
old_norm <- function(x) toupper(trimws(gsub("\\s+", " ", as.character(x))))

cat("\n-- BVA --\n")

# T1 (BVA). The literal names the adversarial loop named. Each must
# transliterate to its ASCII spelling, which is what NPPES stores.
{
  cases <- c("Álvarez" = "ALVAREZ", "Élodie" = "ELODIE", "Ñuñez" = "NUNEZ",
             "García" = "GARCIA", "Muñoz" = "MUNOZ", "Cotè" = "COTE",
             "Renée" = "RENEE", "Frómeta" = "FROMETA", "González" = "GONZALEZ")
  got <- amcb_name_key(names(cases))
  bad <- names(cases)[got != unname(cases)]
  chk(length(bad) == 0L,
      sprintf("T1 accented names transliterate to their ASCII spelling [%d/%d]%s",
              sum(got == unname(cases)), length(cases),
              if (length(bad)) paste0(" bad: ", paste(bad, collapse = ", ")) else ""))
}

# T2 (BVA). The initial character is transliterated, NOT deleted. Both halves
# matter: "Á" -> "A" (not "Á", the real defect) and NOT "" (the reported one).
{
  init <- amcb_first_initial(c("Álvarez", "Élodie", "Ñuñez", "Alvarez"))
  chk(identical(init, c("A", "E", "N", "A")),
      sprintf("T2 first initial of an accented name is its ASCII letter [%s]",
              paste(init, collapse = ",")))
}

# T3 (BVA). Length is preserved -- no character is dropped. This is the
# assertion that specifically refutes the "deletes the initial character"
# reading, and it must hold for names accented anywhere in the string.
{
  v <- c("Álvarez", "García", "Ñuñez", "Élodie")
  chk(all(nchar(amcb_name_key(v)) == nchar(v)),
      sprintf("T3 transliteration preserves character count [%s vs %s]",
              paste(nchar(amcb_name_key(v)), collapse = ","),
              paste(nchar(v), collapse = ",")))
}

cat("\n-- semantic --\n")

# T4 (semantic). The join that the defect broke. An accented roster name and
# its unaccented NPPES spelling must produce the SAME key, and must not have
# done so under the old normaliser -- otherwise this test proves nothing.
{
  now_joins <- amcb_name_key("Álvarez") == amcb_name_key("ALVAREZ")
  used_to   <- old_norm("Álvarez") == old_norm("ALVAREZ")
  chk(now_joins && !used_to,
      sprintf("T4 accented roster name now joins NPPES spelling (was %s, is %s)",
              used_to, now_joins))
}

# T5 (semantic). German romanisation is inherited from the canonical
# normaliser, not reinvented: ü -> UE, not U. NPPES stores the romanised form.
{
  chk(identical(amcb_name_key(c("Müller", "Weiß")), c("MUELLER", "WEISS")),
      sprintf("T5 German umlaut/eszett romanise to digraphs [%s]",
              paste(amcb_name_key(c("Müller", "Weiß")), collapse = ",")))
}

# T6 (semantic). The curly apostrophe is real in this roster (D'Annunzio,
# Y'Vonne) and is a different codepoint from ASCII "'". If it survives, those
# names cannot join either.
{
  k <- amcb_name_key("D’Annunzio")
  chk(identical(k, "D'ANNUNZIO"),
      sprintf("T6 curly apostrophe folds to ASCII [%s]", k))
}

# T7 (semantic). AMCB fuses middle names into first_name. The split must
# happen on the NORMALISED string, so an accented given name still splits.
{
  s <- amcb_split_first("René Richard")
  chk(identical(s$given, "RENE") && identical(s$middle_from_first, "RICHARD"),
      sprintf("T7 fused first/middle splits after transliteration [%s | %s]",
              s$given, s$middle_from_first))
}

cat("\n-- adversarial --\n")

# T8 (adversarial). Missingness must not become evidence. This is the
# 2026-08-08 defect: paste() renders NA as "NA" and nzchar(NA) is TRUE, so
# every absent middle name agreed with every other absent middle name.
{
  chk(is.na(amcb_name_key(NA_character_)) &&
        is.na(amcb_first_initial(NA_character_)) &&
        identical(amcb_blank_na(NA_character_), "") &&
        !amcb_has_name_information(NA_character_) &&
        !amcb_has_name_information(""),
      "T8 NA stays NA, blanks carry no identity information")
}

# T9 (adversarial). "NA" and "Na" are REAL names (and a real first initial N).
# A guard against missingness must not swallow them.
{
  chk(identical(amcb_name_key("Na"), "NA") &&
        identical(amcb_first_initial("Na"), "N") &&
        amcb_has_name_information(amcb_name_key("Na")),
      "T9 the literal name 'Na' survives the missingness guard")
}

# T10 (adversarial). Empty and zero-length input must not error or recycle
# into a value. length-0 in, length-0 out.
{
  ok <- length(amcb_name_key(character(0))) == 0L &&
    identical(amcb_first_initial(""), NA_character_)
  chk(ok, "T10 zero-length and empty-string input degrade safely")
}

# T11 (adversarial). Unicode normal form drift. The SAME name composed (NFC,
# U+00C1) and decomposed (NFD, "A" + U+0301) is byte-different but is the same
# person. Both must yield one key, or a roster and a registry that disagree
# only on normal form will silently fail to join.
{
  nfc <- "ÁLVAREZ"          # composed
  nfd <- "ÁLVAREZ"         # decomposed
  chk(nfc != nfd && amcb_name_key(nfc) == amcb_name_key(nfd) &&
        amcb_name_key(nfd) == "ALVAREZ",
      sprintf("T11 NFC and NFD spellings collapse to one key [%s / %s]",
              amcb_name_key(nfc), amcb_name_key(nfd)))
}

# T12 (adversarial). The real roster, not a fixture. Every AMCB row carrying
# non-ASCII name characters must produce a pure-ASCII key -- if any survives,
# it cannot match NPPES and the fix is incomplete.
{
  # midwives.csv is gitignored, so a worktree has none; MIDWIFERY_TEST_DATA_DIR
  # supplies it. Without this T12 fails on a missing file and reads as a code
  # regression when it is only an unmet data contract.
  roster <- mw_data_path("midwives.csv")
  if (!file.exists(roster)) roster <- file.path(root, "midwives.csv")
  if (!file.exists(roster)) {
    chk(FALSE, "T12 midwives.csv present")
  } else {
    a <- read_csv(roster, show_col_types = FALSE, progress = FALSE)
    nonascii <- function(x) !is.na(x) & grepl("[^\\x01-\\x7F]", x, perl = TRUE)
    hit <- nonascii(a$last_name) | nonascii(a$first_name) | nonascii(a$middle_name)
    keys <- c(amcb_name_key(a$last_name[hit]), amcb_name_key(a$first_name[hit]),
              amcb_name_key(a$middle_name[hit]))
    keys <- keys[!is.na(keys)]
    left <- keys[grepl("[^\\x01-\\x7F]", keys, perl = TRUE)]
    chk(sum(hit) > 0L && length(left) == 0L,
        sprintf("T12 all %d non-ASCII roster rows yield ASCII keys [%d residual]%s",
                sum(hit), length(left),
                if (length(left)) paste0(": ", paste(left, collapse = ", ")) else ""))
  }
}

# T13 (adversarial). Transliteration must not MERGE distinct people. It is a
# recall fix, and a recall fix that collapses different surnames into one key
# would buy matches by manufacturing collisions.
{
  distinct_pairs <- list(c("Nunez", "Nunes"), c("Alvarez", "Alvares"),
                         c("Cote", "Cotter"), c("Mueller", "Miller"))
  merged <- vapply(distinct_pairs,
                   function(p) amcb_name_key(p[1]) == amcb_name_key(p[2]), logical(1))
  chk(!any(merged),
      sprintf("T13 transliteration does not merge genuinely different surnames [%d merged]",
              sum(merged)))
}

cat("\n-- surname components --\n")

# T14 (BVA). The compound forms that actually appear in the roster: hyphen and
# space separated. Both must yield both components.
{
  a <- amcb_surname_tokens("McCarthy-Dervin")
  b <- amcb_surname_tokens("Harvey Capista")
  chk(identical(a, c("MCCARTHY", "DERVIN")) && identical(b, c("HARVEY", "CAPISTA")),
      sprintf("T14 hyphen and space compounds split into components [%s | %s]",
              paste(a, collapse = "+"), paste(b, collapse = "+")))
}

# T15 (semantic). The join the gap requires: AMCB holds the compound, NPPES
# holds one component. They must share a token.
{
  shared <- intersect(amcb_surname_tokens("Walker-Schrader"),
                      amcb_surname_tokens("Schrader"))
  chk(identical(shared, "SCHRADER"),
      sprintf("T15 compound and single-component surname share a token [%s]",
              paste(shared, collapse = ",")))
}

# T16 (adversarial). Particles must NOT become join keys. "DE" shared between
# two unrelated Spanish surnames is a naming convention, not identity evidence.
{
  x <- amcb_surname_tokens("De La Cruz"); y <- amcb_surname_tokens("De Leon")
  chk(length(intersect(x, y)) == 0L,
      sprintf("T16 particles are not join keys: De La Cruz [%s] vs De Leon [%s]",
              paste(x, collapse = "+"), paste(y, collapse = "+")))
}

# T17 (adversarial). Short tokens are dropped. "NG" or "LI" standing alone
# after a compound is discarded would join far too much.
{
  chk(!"NG" %in% amcb_surname_tokens("Ng-Patterson") &&
        "PATTERSON" %in% amcb_surname_tokens("Ng-Patterson"),
      sprintf("T17 sub-%d-character tokens dropped [%s]", AMCB_MIN_SURNAME_TOKEN,
              paste(amcb_surname_tokens("Ng-Patterson"), collapse = "+")))
}

# T18 (adversarial). A surname made ENTIRELY of particles/short tokens must
# yield NO key rather than a weak one -- returning "" would join everything.
{
  t <- amcb_surname_tokens("De La")
  chk(length(t) == 0L, sprintf("T18 all-particle surname yields no join key [%d]",
                               length(t)))
}

# T19 (adversarial). Components compose with transliteration: the accented
# compound must tokenise to ASCII, or the two fixes do not stack.
{
  t <- amcb_surname_tokens("Schupp-López")
  chk(identical(t, c("SCHUPP", "LOPEZ")),
      sprintf("T19 accented compound tokenises to ASCII components [%s]",
              paste(t, collapse = "+")))
}

# T20 (adversarial). Missing and empty input yield no tokens, never NA_character_
# masquerading as one.
{
  chk(length(amcb_surname_tokens(NA_character_)) == 0L &&
        length(amcb_surname_tokens("")) == 0L,
      "T20 missing/empty surname yields zero tokens")
}

# T21 (adversarial). THE TOKEN-SET RULE ITSELF. amcb_person_matches() requires
# the surname AND a shared given-name token. Nothing tested that conjunction:
# mutation testing changed `same_last & shared` to `same_last | shared` and the
# entire suite still passed, which means the central identity rule in this
# repository was unguarded.
#
# Loosened to OR, every "Mary" matches every other "Mary" regardless of
# surname. That is not a near-miss; it is the difference between an identity
# system and a first-name lookup.
{
  tok <- function(...) list(c(...))

  # Both conditions hold -> match.
  chk(isTRUE(amcb_person_matches("SMITH", tok("MARY"), "SMITH", tok("MARY"))),
      "T21a same surname and a shared given token is a match")

  # Surname only -> NOT a match. This is what the OR mutation broke.
  chk(!isTRUE(amcb_person_matches("SMITH", tok("MARY"), "SMITH", tok("JANE"))),
      "T21b same surname with NO shared given token is NOT a match")

  # Given token only -> NOT a match. The other half of the conjunction.
  chk(!isTRUE(amcb_person_matches("SMITH", tok("MARY"), "JONES", tok("MARY"))),
      "T21c a shared given token with a DIFFERENT surname is NOT a match")

  # Neither -> obviously not.
  chk(!isTRUE(amcb_person_matches("SMITH", tok("MARY"), "JONES", tok("JANE"))),
      "T21d neither surname nor given token shared is not a match")

  # A missing surname is an absence, not a wildcard.
  chk(!isTRUE(amcb_person_matches(NA_character_, tok("MARY"), NA_character_, tok("MARY"))),
      "T21e two missing surnames do not match each other")
  chk(!isTRUE(amcb_person_matches("", tok("MARY"), "", tok("MARY"))),
      "T21f two empty surnames do not match each other")

  # Middle names count as given tokens: the set intersects on any element.
  chk(isTRUE(amcb_person_matches("SMITH", tok("MARY", "ANNE"),
                                 "SMITH", tok("ANNE", "ELIZABETH"))),
      "T21g the given-name sets need only intersect, not be equal")

  # An empty given set cannot intersect anything.
  chk(!isTRUE(amcb_person_matches("SMITH", list(character(0)),
                                  "SMITH", tok("MARY"))),
      "T21h an empty given-name set matches nobody")
}

# T22 (adversarial). The minimum surname-token length is a real threshold, not
# a formatting detail: at 2 characters, particles and initials become blocking
# keys and unrelated people collide. Pinned by VALUE so lowering it fails here
# rather than quietly widening every candidate pool.
{
  chk(AMCB_MIN_SURNAME_TOKEN == 4L,
      sprintf("T22 the surname-token floor is 4 characters [%d]",
              AMCB_MIN_SURNAME_TOKEN))
}

# T23. Parenthesised preferred names. The roster publishes "Cynthia (Cindi)".
# The bracket survived normalisation, amcb_split_first() put "(CINDI)" in the
# middle slot, and its initial "(" conflicted with every recorded NPPES middle
# initial -- so the middle-name veto deleted the candidate set. All 9 affected
# roster rows failed to resolve. Asserted by VALUE: a test that only checked
# for the absence of "(" would pass against a rule that deleted the name too.
{
  chk(amcb_name_key("Cynthia (Cindi)") == "CYNTHIA",
      sprintf("T23a the nickname is dropped, the given name kept [%s]",
              amcb_name_key("Cynthia (Cindi)")))
  chk(amcb_split_first("Cynthia (Cindi)")$given == "CYNTHIA",
      "T23b the given name survives the split")
  chk(amcb_split_first("Cynthia (Cindi)")$middle_from_first == "",
      sprintf("T23c no middle name is FABRICATED from a nickname [%s]",
              amcb_split_first("Cynthia (Cindi)")$middle_from_first))
  chk(substr(amcb_split_first("Cynthia (Cindi)")$middle_from_first, 1, 1) != "(",
      "T23d the middle initial is never a bracket")

  # A real middle name alongside a nickname keeps the middle name. Asserted on
  # the INITIAL, which is what the veto compares: the key does not strip the
  # period, and substr(.., 1, 1) never sees it.
  chk(substr(amcb_split_first("Patty (Pepita) B.")$middle_from_first, 1, 1) == "B",
      sprintf("T23e a genuine middle initial outlives the nickname [%s]",
              amcb_split_first("Patty (Pepita) B.")$middle_from_first))
  # Word-internal brackets are OPTIONAL LETTERS, not a nickname. Real roster
  # row. Dropping the group here would leave a given name of "C", which blocks
  # against every NPPES first name recorded as a bare initial.
  chk(amcb_name_key("C(arolyn) Diane") == "CAROLYN DIANE",
      sprintf("T23f word-internal brackets are unwrapped, not deleted [%s]",
              amcb_name_key("C(arolyn) Diane")))
  chk(amcb_split_first("C(arolyn) Diane")$given == "CAROLYN",
      "T23f the given name is a name, not an initial")
  # Unbalanced brackets leave no residue and fabricate no middle name.
  chk(amcb_name_key("Anna (Katie") == "ANNA",
      sprintf("T23i an unclosed bracket leaves no residue [%s]",
              amcb_name_key("Anna (Katie")))
  # Transliteration still happens: this must not become a punctuation-only pass.
  chk(amcb_name_key("Renée (Ren)") == "RENEE",
      sprintf("T23g accents are still transliterated alongside the strip [%s]",
              amcb_name_key("Renée (Ren)")))
  chk(is.na(amcb_name_key(NA_character_)),
      "T23h NA in, NA out is unchanged")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
