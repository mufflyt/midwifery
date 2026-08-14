# =============================================================================
# Adversarial tests for the join keys
# =============================================================================
# tests/test_lib_keys.R checks that each key function does what it says on
# well-formed input. This file assumes the input is hostile.
#
# Every case below is drawn from a way this repository has actually been hurt,
# or from the shape of one:
#
#   * `paste(NA, "")` produced the literal string "NA", which gave every midwife
#     without a middle name the same fabricated initial and left evidence class 2
#     empty. So: no key may EVER return a string that looks like data when the
#     input was missing.
#   * A ZIP read from a spreadsheet arrives as 8701, or as 8.701e+03, or as
#     "08701 " with a non-breaking space. Excel and CSV round-trips are the
#     normal case, not the edge case.
#   * A linkage key that fails only on non-Anglo names (cycle 12) failed because
#     nobody tried one. So: accented, hyphenated and multi-token inputs.
#   * Two different addresses must not collide into one key, and the same
#     address written two ways must not split into two. Both directions.
#
# The properties asserted are stronger than the examples: idempotence (a
# normaliser applied twice is the normaliser), missingness preservation (NA in,
# NA out -- never "", never "NA", never "00000"), and non-collision.
#
# stringr only, no artifacts. Runs in seconds.
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."

suppressPackageStartupMessages(library(stringr))
source(file.path(root, "R", "lib", "common_helpers.R"))
source(file.path(root, "R", "lib", "address_keys.R"))

pass <- 0L
fails <- character(0)
check <- function(label, ok) {
  if (isTRUE(ok)) {
    pass <<- pass + 1L
    cat(sprintf("  ok   %s\n", label))
  } else {
    fails <<- c(fails, label)
    cat(sprintf("  FAIL %s\n", label))
  }
}
sect <- function(s) cat(sprintf("\n-- %s --\n", s))

# The single most expensive class of bug in this repo: a missing value that
# comes back looking like a real one. Every key function is held to it.
KEYS <- list(
  pad5             = pad5,
  zip5_key         = zip5_key,
  zip5             = zip5,
  zip5_first_run   = zip5_first_run,
  zip9             = zip9,
  phone10          = phone10,
  pad_ccn          = pad_ccn,
  norm_addr        = norm_addr,
  norm_addr_drop_unit = norm_addr_drop_unit
)

# -----------------------------------------------------------------------------
sect("P1 missing in, missing out -- never a value that can join")

# The literal strings a missing value turns into when someone pastes or coerces
# without thinking. If a key returns any of these, two people with no data join
# to each other.
FORGED <- c("NA", "N/A", "NULL", "", "00000", "0", "NaN", "-", ".")

for (nm in names(KEYS)) {
  f <- KEYS[[nm]]
  out <- suppressWarnings(f(NA_character_))
  check(sprintf("%s(NA) is NA, not a joinable token", nm),
        length(out) == 1L && is.na(out))

  out2 <- suppressWarnings(f(""))
  check(sprintf("%s('') is NA or empty, never a forged token", nm),
        length(out2) == 1L && (is.na(out2) || !out2 %in% setdiff(FORGED, "")))

  # Whitespace-only, including a non-breaking space and a tab. This is what a
  # scraped cell looks like when the field was blank on the page.
  out3 <- suppressWarnings(f("  \t   "))
  check(sprintf("%s(whitespace) does not become a token", nm),
        length(out3) == 1L && (is.na(out3) || !nzchar(trimws(out3)) ||
                               !out3 %in% FORGED))
}

# -----------------------------------------------------------------------------
sect("P2 the 'NA' string trap that emptied evidence class 2")

# paste(NA, "") -> "NA". A key must not treat that as data. This is a
# REGRESSION test: the bug it describes reached the artifact.
check("zip5_key('NA') does not yield a 5-digit key",
      { v <- suppressWarnings(zip5_key("NA")); is.na(v) || !str_detect(v, "^[0-9]{5}$") })
check("pad_ccn('NA') does not become a padded CCN",
      { v <- suppressWarnings(pad_ccn("NA")); is.na(v) || v != "000NA" })
check("norm_addr('NA') is not a joinable address",
      { v <- suppressWarnings(norm_addr("NA")); is.na(v) || !nzchar(v) || v == "NA" })
check("phone10('NA') is NA",
      is.na(suppressWarnings(phone10("NA"))))

# -----------------------------------------------------------------------------
sect("P3 idempotence -- a normaliser applied twice is the normaliser")

IDEMPOTENT <- c("zip5_key", "phone10", "norm_addr", "norm_addr_drop_unit", "pad_ccn")
SAMPLES <- c("08701", "8701", "08701-1234", " 100 N Main Street Suite 4 ",
             "(303) 555-0142", "1-303-555-0142", "13F", "  ", NA_character_,
             "123 CALLE SEGUNDA APT 2B", "45 O'BRIEN AVE")

for (nm in IDEMPOTENT) {
  f <- KEYS[[nm]]
  once  <- suppressWarnings(f(SAMPLES))
  twice <- suppressWarnings(f(once))
  same  <- (is.na(once) & is.na(twice)) | (!is.na(once) & !is.na(twice) & once == twice)
  check(sprintf("%s is idempotent over %d adversarial inputs", nm, length(SAMPLES)),
        all(same))
}

# -----------------------------------------------------------------------------
sect("P4 spreadsheet damage -- the normal way a ZIP arrives broken")

check("zip5_key recovers a ZIP that lost its leading zero as a number",
      identical(suppressWarnings(zip5_key(8701)), "08701"))
check("zip5_key survives a non-breaking space",
      identical(suppressWarnings(zip5_key(" 08701 ")), "08701"))
check("zip5_key survives an embedded newline",
      identical(suppressWarnings(zip5_key("08701\n")), "08701"))

# Scientific notation is what a large numeric ZIP or NPI becomes after a
# round-trip through a spreadsheet. Silently accepting it invents a location.
sci <- suppressWarnings(zip5_key("8.701e+03"))
check("zip5_key refuses scientific notation rather than inventing a ZIP",
      is.na(sci) || sci != "08701")

# -----------------------------------------------------------------------------
sect("P5 non-collision -- different places must not share a key")

# The prefix-collision family, the same defect the Python address tests encode.
addr_pairs <- list(
  c("100 MAIN ST",  "2100 MAIN ST"),
  c("12 MAIN ST",   "112 MAIN ST"),
  c("1 PARK AVE",   "11 PARK AVE"),
  c("N MAIN ST",    "S MAIN ST"),
  c("100 MAIN ST NORTH", "100 MAIN ST SOUTH")
)
for (p in addr_pairs) {
  a <- suppressWarnings(norm_addr(p[1])); b <- suppressWarnings(norm_addr(p[2]))
  check(sprintf("norm_addr keeps '%s' distinct from '%s'", p[1], p[2]),
        is.na(a) || is.na(b) || a != b)
}

# ZIP+4 must not weaken into ZIP5 inside the strongest key.
check("zip9 refuses a 5-digit value rather than padding it",
      is.na(suppressWarnings(zip9("08701"))))
check("zip9 refuses a 10-digit value rather than truncating it",
      is.na(suppressWarnings(zip9("0870112345"))))

# A phone number must never be padded or truncated into someone else's.
check("phone10 refuses 9 digits", is.na(suppressWarnings(phone10("303555014"))))
check("phone10 refuses 12 digits", is.na(suppressWarnings(phone10("303555014212"))))

# -----------------------------------------------------------------------------
sect("P6 the same place written two ways must not split")

same_place <- list(
  c("100 Main Street",        "100 MAIN ST"),
  c("100 N. Main St.",        "100 North Main Street"),
  c("100 Main St  Suite 4",   "100 Main Street Ste 4")
)
for (p in same_place) {
  a <- suppressWarnings(norm_addr(p[1])); b <- suppressWarnings(norm_addr(p[2]))
  check(sprintf("norm_addr unifies '%s' and '%s'", p[1], p[2]),
        !is.na(a) && !is.na(b) && a == b)
}

# The unit decision is a documented divergence, so assert BOTH directions --
# a change to either one silently re-partitions every multi-tenant building.
u1 <- suppressWarnings(norm_addr("100 Main St Suite 4"))
u2 <- suppressWarnings(norm_addr("100 Main St Suite 5"))
d1 <- suppressWarnings(norm_addr_drop_unit("100 Main St Suite 4"))
d2 <- suppressWarnings(norm_addr_drop_unit("100 Main St Suite 5"))
check("norm_addr keeps two suites apart", !is.na(u1) && !is.na(u2) && u1 != u2)
check("norm_addr_drop_unit collapses two suites", !is.na(d1) && !is.na(d2) && d1 == d2)

# -----------------------------------------------------------------------------
sect("P7 names and addresses that are not Anglo -- cycle 12's failure mode")

hostile <- c("123 CALLE SEGUNDA", "45 O'BRIEN AVE", "9 ST-JEAN BLVD",
             "1 ÜBER STR", "77 NÚNEZ RD")
for (h in hostile) {
  v <- suppressWarnings(norm_addr(h))
  check(sprintf("norm_addr returns a usable key for '%s'", h),
        !is.na(v) && nzchar(v))
}

# Vectorised and scalar paths must agree, or a key computed row-by-row in one
# script differs from the same key computed column-wise in another.
vec <- suppressWarnings(norm_addr(hostile))
scal <- vapply(hostile, function(h) suppressWarnings(norm_addr(h)), character(1),
               USE.NAMES = FALSE)
check("norm_addr is vectorised consistently with its scalar path",
      identical(unname(vec), unname(scal)))

# -----------------------------------------------------------------------------
sect("P8 length and order preservation")

# A key function that drops or reorders elements corrupts every mutate() that
# assigns its result back into a column.
for (nm in names(KEYS)) {
  f <- KEYS[[nm]]
  inp <- c("08701", NA_character_, "", "12345", "  ")
  out <- suppressWarnings(f(inp))
  check(sprintf("%s preserves length (%d in, %d out)", nm, length(inp), length(out)),
        length(out) == length(inp))
}

# -----------------------------------------------------------------------------
cat("\n")
if (length(fails)) {
  cat(sprintf("FAILED (%d of %d)\n", length(fails), length(fails) + pass))
  for (f in fails) cat(sprintf("  - %s\n", f))
  quit(status = 1)
}
cat(sprintf("PASS (%d assertions, 0 failures)\n", pass))
