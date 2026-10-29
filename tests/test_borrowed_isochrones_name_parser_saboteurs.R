#!/usr/bin/env Rscript
# =============================================================================
# Saboteurs borrowed directly from /isochrones against the SAME code
# =============================================================================
# R/lib/isochrones_dep.R::load_isochrones_name_tools() does not vendor a copy
# of parse_physician_name_enhanced() -- it live-sources
# ~/isochrones/R/name_parsing_protocol_enhanced.R (plus the string-
# normalization and nickname files it depends on) out of the isochrones
# checkout every time. So, same as tests/test_borrowed_isochrones_saboteurs.R
# for luhn_check_npi(), there is no "drift" question for the cases below: this
# file runs isochrones' own regression assertions against the exact function
# isochrones' own suite tests, just invoked from this repo.
#
# Four isochrones test files are the source, chosen because each pins a real,
# documented production bug rather than an invented edge case:
#   - tests/testthat/test-name-parser-comma-format-2026-06-15.R
#     ("Smith, John" flipped to first=Smith/suffix=John before this fix;
#     NEW-330: dotted "M.D." silently zeroed ~59% of one roster's NPI match)
#   - tests/testthat/test-name-parser-last-first.R (particle/suffix cases not
#     already covered by the comma-format file above)
#   - tests/testthat/test-name-parser-allcaps-do-ambiguity-2026-09-18.R (an
#     all-caps "JOHN SMITH DO" -- the exact shape of a bulk NPPES/roster
#     export, which is what this repo's own provider rosters look like --
#     silently demoted the real surname to middle_name at HIGH confidence)
#   - tests/testthat/test-name-parser-double-credential-2026-09-18.R (a second
#     post-nominal, e.g. "MD, MBA", made the FIRST become the first name;
#     measured against isochrones' own 71-pair gold standard, 63/71 -> 66/71)
#
# NOT INCLUDED: the comma-format file's last test_that() additionally sources
# R/canonical_abms_npi_matching_FIXED_STABLE_2026-02-08.R for
# parse_abms_name() -- a second file load_isochrones_name_tools() does not
# pull in, so it is left out rather than adding an ad hoc second source() call
# this repo does not otherwise need. are_nickname_variants(), the third
# function load_isochrones_name_tools() exposes, has no isochrones test file
# asserting concrete input/output pairs against it (grep of tests/ turns up
# nothing) -- there is nothing of that shape to borrow for it today.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "lib", "isochrones_dep.R"))
load_isochrones_name_tools(quiet = TRUE)

fails <- 0L
chk <- function(ok, label) {
  cat(sprintf("  %-4s %s\n", if (isTRUE(ok)) "ok" else "FAIL", label))
  if (!isTRUE(ok)) fails <<- fails + 1L
}
.p <- function(x) parse_physician_name_enhanced(x)

cat("\n-- borrowed from test-name-parser-comma-format-2026-06-15.R --\n")

r <- .p("Smith, John")
chk(identical(r$first_name[1], "John") && identical(r$last_name[1], "Smith") &&
      is.na(r$suffix[1]), "N1 two-part comma 'Last, First' flips to first=First, last=Last")

r <- .p("Smith, John Robert")
chk(identical(r$first_name[1], "John") && identical(r$middle_name[1], "Robert") &&
      identical(r$last_name[1], "Smith"), "N2 two-part comma with middle parses correctly")

r <- .p("Smith, John, Jr.")
chk(identical(r$first_name[1], "John") && identical(r$last_name[1], "Smith") &&
      identical(r$suffix[1], "Jr."), "N3 three-part 'Last, First, Suffix' still parses")

r <- .p("Smith, John, Jr., MD")
chk(identical(r$first_name[1], "John") && identical(r$last_name[1], "Smith") &&
      identical(r$suffix[1], "Jr., MD"),
    "N4 four-part 'Last, First, Suffix, Credential' parses correctly (NEW-330 sibling)")

r <- .p("Smith, John, MD")
chk(identical(r$first_name[1], "John") && identical(r$last_name[1], "Smith"),
    "N5 'Last, First, Credential' strips credential and flips name")

r <- .p("John Smith, Jr.")
chk(identical(r$first_name[1], "John") && identical(r$last_name[1], "Smith") &&
      identical(r$suffix[1], "Jr."), "N6 'First Last, Jr.' suffix-comma is NOT flipped")

r <- .p("John Smith, MD")
chk(identical(r$first_name[1], "John") && identical(r$last_name[1], "Smith"),
    "N7 'First Last, Credential' credential-comma is NOT flipped")

r <- .p("van der Berg, Hans")
chk(identical(r$first_name[1], "Hans") && identical(r$last_name[1], "van der Berg"),
    "N8 multi-part surname 'van der Berg, Hans' preserves compound surname")

r <- .p("John Smith")
chk(identical(r$first_name[1], "John") && identical(r$last_name[1], "Smith"),
    "N9 no-comma input is untouched (no-op safe)")

r <- .p("Maria de la Cruz-Garcia")
chk(identical(r$first_name[1], "Maria") && identical(r$last_name[1], "de la Cruz-Garcia"),
    "N10 compound surname without comma is untouched")

r <- .p("")
chk(is.na(r$first_name[1]) && is.na(r$last_name[1]) && identical(r$parse_confidence[1], "low"),
    "N11 blank input returns all-NA row at low confidence")

r <- .p(NA_character_)
chk(is.na(r$first_name[1]) && is.na(r$last_name[1]), "N12 NA input returns all-NA row")

r <- .p(c("Smith, John", "John Smith, Jr.", "Mary Jones", "van der Berg, Hans", NA_character_))
chk(identical(r$first_name, c("John", "John", "Mary", "Hans", NA)) &&
      identical(r$last_name, c("Smith", "Smith", "Jones", "van der Berg", NA)) &&
      identical(r$suffix, c(NA, "Jr.", NA, NA, NA)),
    "N13 vectorized input handles mixed formats together")

r <- .p("John Smith, M.D.")
chk(identical(r$first_name[1], "John") && identical(r$last_name[1], "Smith") &&
      !identical(r$first_name[1], "M.D."),
    "N14 NEW-330: dotted 'First Last, M.D.' credential is stripped, NOT flipped")

r <- .p("Ernest Y Normington, M.D.")
chk(identical(r$first_name[1], "Ernest") && identical(r$middle_name[1], "Y") &&
      identical(r$last_name[1], "Normington"),
    "N15 NEW-330: exact production failure 'Ernest Y Normington, M.D.' parses correctly")

r <- .p("Jane A Doe, M.D")
chk(identical(r$first_name[1], "Jane") && identical(r$last_name[1], "Doe") &&
      !identical(r$first_name[1], "M.D"),
    "N16 NEW-330: dotted 'M.D' (no trailing dot) is also stripped")

r <- .p(c("Ernest Y Normington, M.D.", "John Smith, MD", "Mary Beth OConnor, D.O.", "Jane A Doe, M.D"))
chk(identical(r$first_name, c("Ernest", "John", "Mary", "Jane")) &&
      !any(r$first_name %in% c("M.D.", "M.D", "MD", "D.O.")),
    "N17 NEW-330: batch of dotted + bare credentials all keep real first names")

cat("\n-- borrowed from test-name-parser-last-first.R (non-duplicate cases) --\n")

r <- .p("O'Brien, Mary")
chk(identical(r$first_name[1], "Mary") && identical(r$last_name[1], "O'Brien"),
    "N18 particle surname 'O'Brien, Mary' survives the reversal")

r <- .p("Smith, III")
chk(identical(r$suffix[1], "III"), "N19 generational suffix 'Smith, III' is not treated as a first name")

cat("\n-- borrowed from test-name-parser-allcaps-do-ambiguity-2026-09-18.R --\n")

r <- .p("JOHN SMITH DO")
chk(identical(r$parse_confidence[1], "low") &&
      identical(r$parse_warnings[1], "ambiguous_do_credential_or_surname"),
    "N20 an all-caps 3-token DO credential is flagged, not silently trusted")

r <- .p("NGUYEN VAN DO")
chk(identical(r$parse_confidence[1], "low") &&
      identical(r$parse_warnings[1], "ambiguous_do_credential_or_surname"),
    "N21 an all-caps 3-token 'Do' compound surname is flagged the same way")

ok22 <- TRUE
for (nm in c("JOHN MICHAEL SMITH DO", "DE LA CRUZ JUAN DO")) {
  r <- .p(nm)
  ok22 <- ok22 && identical(r$parse_confidence[1], "low") &&
    identical(r$parse_warnings[1], "ambiguous_do_credential_or_surname")
}
chk(ok22, "N22 a 4+ token all-caps name ending in DO is flagged too")

r <- .p("JOHN SMITH D.O.")
chk(identical(r$first_name[1], "JOHN") && identical(r$last_name[1], "SMITH") &&
      identical(r$suffix[1], "D.O.") && identical(r$parse_confidence[1], "high") &&
      is.na(r$parse_warnings[1]),
    "N23 NEGATIVE CONTROL: all-caps dotted D.O. is unambiguous and unaffected")

r1 <- .p("John Michael Smith DO"); r2 <- .p("Nguyen Van Do")
chk(identical(r1$last_name[1], "Smith") && identical(r1$parse_confidence[1], "high") &&
      is.na(r1$parse_warnings[1]) &&
      identical(r2$last_name[1], "Van Do") && identical(r2$parse_confidence[1], "high") &&
      is.na(r2$parse_warnings[1]),
    "N24 NEGATIVE CONTROL: mixed-case names are unaffected by the new flag")

r <- .p("ANH DO")
chk(identical(r$last_name[1], "DO") && identical(r$parse_confidence[1], "high") &&
      is.na(r$parse_warnings[1]), "N25 NEGATIVE CONTROL: an all-caps 2-token name is unaffected")

r <- .p("SMITH, JOHN, DO")
chk(identical(r$first_name[1], "JOHN") && identical(r$last_name[1], "SMITH") &&
      identical(r$parse_confidence[1], "high"),
    "N26 NEGATIVE CONTROL: comma-form names are unaffected")

r <- .p(c(NA_character_, ""))
chk(identical(r$parse_confidence, c("low", "low")) &&
      all(is.na(r$parse_warnings) | r$parse_warnings == "parsing_failed") &&
      !any(r$parse_warnings %in% "ambiguous_do_credential_or_surname"),
    "N27 NEGATIVE CONTROL: NA and blank input are still low/no-flag, not double-flagged")

chk(identical(.handle_edge_case_do_credential("JOHN SMITH D.O."), "JOHN SMITH, D.O."),
    "N28 the .handle_edge_case_do_credential() helper is actually wired in")

cat("\n-- borrowed from test-name-parser-double-credential-2026-09-18.R --\n")

dbl_cases <- list(
  list(nm = "Gunhilde M. Buchsbaum, MD, MBA", first = "Gunhilde", last = "Buchsbaum"),
  list(nm = "Philip Dempsey Darney, MD, MSc", first = "Philip",   last = "Darney"),
  list(nm = "Paul D. Blumenthal, MD, MPH",    first = "Paul",     last = "Blumenthal"))
ok29 <- TRUE
for (case in dbl_cases) {
  r <- .p(case$nm)
  ok29 <- ok29 && identical(as.character(r$first_name[1]), case$first) &&
    identical(as.character(r$last_name[1]), case$last) &&
    !(toupper(as.character(r$first_name[1])) %in% c("MD", "M.D.", "DO", "PHD", "MBA", "MSC", "MPH"))
}
chk(ok29, "N29 two credentials do not become the first name (71-pair gold standard, 63/71 -> 66/71)")

r <- .p("Jane Doe, MD, PhD, MPH")
chk(identical(as.character(r$first_name[1]), "Jane") && identical(as.character(r$last_name[1]), "Doe"),
    "N30 three credentials are handled too (strip-until-stable, not twice)")

r <- .p("Smith, John, MD"); r2 <- .p("John W. Larsen Jr., MD")
chk(identical(as.character(r$first_name[1]), "John") && identical(as.character(r$last_name[1]), "Smith") &&
      identical(as.character(r2$first_name[1]), "John") && identical(as.character(r2$last_name[1]), "Larsen"),
    "N31 NEGATIVE CONTROL: single-credential names still parse")

r <- .p("Cosmas J. M. van de Ven, MD")
chk(identical(as.character(r$last_name[1]), "van de Ven") && identical(as.character(r$first_name[1]), "Cosmas"),
    "N32 NEGATIVE CONTROL: a particle surname is not split")

r <- .p("Robert Ba, MD")
chk(identical(as.character(r$last_name[1]), "Ba") && identical(as.character(r$first_name[1]), "Robert"),
    "N33 NEGATIVE CONTROL: a real surname resembling a credential survives")

r <- .p("Gunhilde M. Buchsbaum, MD, MBA")
chk(grepl("MD", as.character(r$suffix[1]), fixed = TRUE) &&
      grepl("MBA", as.character(r$suffix[1]), fixed = TRUE),
    "N34 the credentials still land in the suffix slot, not discarded")

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
