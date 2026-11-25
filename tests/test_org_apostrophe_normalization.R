#!/usr/bin/env Rscript
# =============================================================================
# Organization-side apostrophe normalization (D15 extension)
# =============================================================================
# Person-name keys were fixed under D15 by delegating to
# mysterynpi::phrase_key(); the organization-side copies kept spacing
# apostrophes, so "ST JOHN'S" keyed as "ST JOHN S" and never met "ST JOHNS".
# These pins hold the delegated contract on every migrated function:
#
#   O1  Apostrophe spellings of one name unify: ST JOHN'S == ST JOHNS ==
#       ST JOHN S-free variants, across straight, curly, and okina forms.
#   O2  The fix does not manufacture matches: names that differ by more
#       than an apostrophe stay distinct (ST JOHN vs ST JOHNS; ST THOMAS
#       vs SAINT THOMAS -- abbreviation equivalence is NOT assumed).
#   O3  Each function's own contract survives delegation: & -> AND and
#       leading-The stripping for schools, street-suffix folding for
#       street_key, "" (not NA) for an empty street key so paste() does
#       not inject a literal "NA", extraction behaviour for
#       embedded_org_text.
#   O4  Adversarial: removing apostrophe handling (space instead of
#       delete), collapsing punctuation distinctions, or treating NA as
#       an empty key must fail these pins.
#
# Script-embedded functions are extracted from their producers, not
# retyped -- same pattern as test_embedded_org_name_guards.R, so a drifted
# copy cannot pass while the script does something else.
# =============================================================================
root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
suppressPackageStartupMessages({library(stringr); library(dplyr)})
stopifnot(requireNamespace("mysterynpi", quietly = TRUE))

source(file.path(root, "R", "lib", "training_institution.R"))

SCRIPT_ED <- file.path(root, "build_embedded_org_name_arm.R")
SCRIPT_WS <- file.path(root, "build_worksite_setting_crosswalk.R")
SCRIPT_AC <- file.path(root, "validate_training_institution_against_acme.R")
for (s in c(SCRIPT_ED, SCRIPT_WS, SCRIPT_AC)) stopifnot(file.exists(s))

# Extract a top-level definition by name, balancing delimiters (the
# regex-close approach breaks on definitions containing ")" inside
# strings, per test_embedded_org_name_guards.R's own header note).
extract_fn <- function(script, pattern) {
  src <- readLines(script, warn = FALSE)
  s <- grep(pattern, src)
  if (!length(s)) stop("not found in ", script, ": ", pattern, call. = FALSE)
  s <- s[1]
  depth <- 0L
  for (i in s:length(src)) {
    ln <- gsub('"[^"]*"|\'[^\']*\'|#.*$', "", src[i])
    depth <- depth + lengths(regmatches(ln, gregexpr("[({]", ln))) -
      lengths(regmatches(ln, gregexpr("[)}]", ln)))
    if (i > s || depth == 0L) if (depth <= 0L)
      return(paste(src[s:i], collapse = "\n"))
  }
  stop("unbalanced definition in ", script, call. = FALSE)
}
eval(parse(text = extract_fn(SCRIPT_ED, "^embedded_org_text <- function")))
eval(parse(text = extract_fn(SCRIPT_WS, "^clean <- function")))
eval(parse(text = extract_fn(SCRIPT_WS, "^street_key <- function")))
eval(parse(text = extract_fn(SCRIPT_AC, "^norm_institution_name <- function")))

failures <- character(0)
chk <- function(ok, msg) {
  if (isTRUE(ok)) cat(sprintf("  ok   %s\n", msg))
  else { cat(sprintf("  FAIL %s\n", msg)); failures <<- c(failures, msg) }
}

apos <- c("'", "\u2019", "\u02bb", "\uff07")   # straight, curly, okina, fullwidth

cat("\n-- O1 apostrophe spellings of one institution unify --\n")
base <- "ST JOHN'S HOSPITAL"
for (a in apos) {
  v <- paste0("ST JOHN", a, "S HOSPITAL")
  chk(identical(training_norm_school(v), "ST JOHNS HOSPITAL") &&
      identical(norm_institution_name(v), "ST JOHNS HOSPITAL") &&
      identical(street_key(paste("100", v, "AVE")), "100 ST JOHNS HOSPITAL AVE") &&
      identical(embedded_org_text(v), "ST JOHNS HOSPITAL"),
      sprintf("apostrophe '%s' unifies across all four functions", a))
}
chk(identical(training_norm_school("O'NEILL UNIVERSITY"), "ONEILL UNIVERSITY") &&
    identical(training_norm_school("D'YOUVILLE COLLEGE"), "DYOUVILLE COLLEGE") &&
    identical(training_norm_school("L'ABBÉ MEDICAL CTR"), "LABBE MEDICAL CTR"),
    "O1b possessive prefixes join (O'NEILL, D'YOUVILLE, L'ABBÉ)")

cat("\n-- O2 the fix does not manufacture matches --\n")
chk(!identical(training_norm_school("ST JOHN HOSPITAL"),
               training_norm_school("ST JOHNS HOSPITAL")),
    "ST JOHN and ST JOHNS remain distinct institutions")
chk(!identical(training_norm_school("UNIVERSITY OF ST THOMAS"),
               training_norm_school("UNIVERSITY OF SAINT THOMAS")),
    "ST and SAINT are not assumed equivalent (no unapproved synonym rule)")
chk(identical(street_key("1 O'BRIEN ST"), street_key("1 OBRIEN ST")) &&
    !identical(street_key("1 O'BRIEN ST"), street_key("1 O BRIEN ST")),
    "street_key unifies O'BRIEN with OBRIEN but not with a literal spaced 'O BRIEN'")
chk(!identical(embedded_org_text("JOHN'S HOPKINS HOSPITAL"),
               embedded_org_text("JOHN HOPKINS HOSPITAL")),
    "embedded_org_text keeps JOHN'S and JOHN distinct")

cat("\n-- O3 each contract survives delegation --\n")
chk(identical(training_norm_school(c("Texas A\\U0026M", "Texas A\\u0026M",
                                     "Texas A&AMP;M", "Texas A&amp;M")),
            rep("TEXAS AANDM", 4)),
    "school: all four ampersand-entity forms still become AND")
chk(identical(training_norm_school("The Ohio State University"),
              "OHIO STATE UNIVERSITY") &&
    identical(training_norm_school("Better Than The Rest University"),
              "BETTER THAN THE REST UNIVERSITY"),
    "school: leading THE stripped, mid-name THE untouched")
chk(identical(street_key("1 MAIN STREET"), "1 MAIN ST") &&
    identical(street_key("9 OAK AVENUE"), "9 OAK AVE") &&
    identical(street_key("5 ROUTE 1 HWY"), "5 ROUTE 1 HWY"),
    "street: suffix canonicalisation (STREET->ST, AVENUE->AVE) preserved")
chk(identical(street_key(NA_character_), "") &&
    identical(street_key(""), ""),
    "street: empty input is \"\" not NA, so paste() never emits a literal 'NA'")
chk(identical(embedded_org_text("MADIGAN ARMY MEDICAL CTR 9040 JACKSON AVE"),
              "MADIGAN ARMY MEDICAL CTR") &&
    identical(embedded_org_text("SAINT MARY'S 500 ELM AVE UNIT 4"),
              "SAINT MARYS 500 ELM AVE"),
    "embedded: street-tail and unit stripping still run before the key")
chk(is.na(training_norm_school("***")) && is.na(training_norm_school(NA)) &&
    is.na(norm_institution_name("   ")),
    "schools: punctuation-only, NA, and blank inputs stay NA")

cat("\n-- O4 adversarial mutations must fail these pins --\n")
# Reimplement the defect inline: apostrophe -> SPACE instead of delete.
mut_space <- function(x) {
  y <- toupper(str_squish(as.character(x)))
  y <- str_replace_all(y, "['’ʼʻ]", " ")
  y <- str_replace_all(y, "[^A-Z0-9 ]", " ")
  str_squish(y)
}
chk(!identical(mut_space("ST JOHN'S HOSPITAL"), "ST JOHNS HOSPITAL") &&
    identical(training_norm_school("ST JOHN'S HOSPITAL"), "ST JOHNS HOSPITAL"),
    "O4a space-instead-of-delete reproduces the original defect and the real function does not")
# A local re-implementation that skips phrase_key entirely must not pass:
# the pins above call the extracted/ sourced functions, so drift is caught
# by construction. Assert the delegation is actually wired:
src_ti <- paste(readLines(file.path(root, "R", "lib", "training_institution.R"),
                          warn = FALSE), collapse = "\n")
src_ws <- paste(readLines(SCRIPT_WS, warn = FALSE), collapse = "\n")
src_ed <- paste(readLines(SCRIPT_ED, warn = FALSE), collapse = "\n")
src_ac <- paste(readLines(SCRIPT_AC, warn = FALSE), collapse = "\n")
chk(grepl("mysterynpi::phrase_key", src_ti, fixed = TRUE) &&
    !grepl('str_replace_all\\(y, "\\[\\^A-Z0-9 \\]"', src_ti),
    "O4b training_norm_school delegates to phrase_key; no local punct pass remains")
chk(grepl("mysterynpi::phrase_key", src_ws, fixed = TRUE) &&
    !grepl('street_key <- function\\(x\\) \\{\\s*x <- clean', src_ws),
    "O4c street_key delegates to phrase_key")
chk(grepl("mysterynpi::phrase_key", src_ed, fixed = TRUE) &&
    !grepl('embedded_org_text[\\s\\S]*str_replace_all\\(x, "\\[\\^A-Z0-9 \\]"', src_ed),
    "O4d embedded_org_text delegates its final normalisation")
chk(grepl("mysterynpi::phrase_key", src_ac, fixed = TRUE),
    "O4e norm_institution_name delegates to phrase_key")
chk(!grepl("\\.norm_school <- function", paste(readLines(
      file.path(root, "build_table1_midwives.R"), warn = FALSE), collapse = "\n")),
    "O4f the duplicate .norm_school definition is gone from build_table1_midwives.R")

cat("\n")
if (length(failures)) {
  for (f in failures) cat(sprintf("FAIL %s\n", f))
  cat(sprintf("\nFAILED (%d)\n", length(failures)))
  quit(status = 1)
}
cat("PASS (0 failures)\n")
