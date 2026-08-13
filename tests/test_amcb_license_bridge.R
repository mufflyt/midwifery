#!/usr/bin/env Rscript
# =============================================================================
# Deterministic AMCB license bridge -- unit + end-to-end tests
# =============================================================================
# Locks in the two guards that make a deterministic key trustworthy, plus the
# normalizers the key is built from:
#
#   1. A license key that maps to >1 NPI is never auto-accepted.
#   2. A unique-key match whose LEGAL SURNAME contradicts the roster is
#      quarantined, not accepted (a data-entry error in a license field must
#      not launder a wrong person into the crosswalk). A missing name does not
#      block -- only an actual disagreement does.
#
# The end-to-end cases run the real read -> pivot -> classify -> link path over
# tiny CSV fixtures in a tempdir, so the guards are tested as production runs
# them rather than through reconstructed intermediate frames.
#
# Run: Rscript tests/test_amcb_license_bridge.R   (exit 1 on any failure)
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}

# Sourcing runs the script's library() calls but, thanks to its
# sys.nframe() guard, NOT its pipeline.
source(file.path(root, "amcb_license_bridge.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# -----------------------------------------------------------------------------
cat("\n-- license-number normalization --\n")
# -----------------------------------------------------------------------------

chk(normalize_license_number("  012-345  ") == "012345",
    "strips spaces and dashes, keeps leading zeros")
chk(normalize_license_number("rn 12345") == "RN12345",
    "upper-cases and keeps a letter prefix (never coerces to numeric)")
chk(is.na(normalize_license_number("")),
    "blank normalizes to NA")
chk(identical(normalize_license_number(c("a1", NA)), c("A1", NA_character_)),
    "vectorized, NA-preserving")

# -----------------------------------------------------------------------------
cat("\n-- license key (state :: number) --\n")
# -----------------------------------------------------------------------------

chk(make_license_key("012345", "California") == "CA::012345",
    "state name resolves to code and joins the number")
chk(is.na(make_license_key(NA, "CA")),
    "no key without a license number")
chk(is.na(make_license_key("012345", NA)),
    "no key without a state (license number is never nationally unique)")

# -----------------------------------------------------------------------------
cat("\n-- state normalization --\n")
# -----------------------------------------------------------------------------

chk(normalize_state("California") == "CA", "full state name -> code")
chk(normalize_state("tx") == "TX", "two-letter code passes through, upper-cased")
chk(normalize_state("District of Columbia") == "DC", "DC handled")
chk(normalize_state("Puerto Rico") == "PR", "territory handled")
chk(is.na(normalize_state(NA)), "NA -> NA")

# -----------------------------------------------------------------------------
cat("\n-- name helpers --\n")
# -----------------------------------------------------------------------------

chk(normalize_person_name("Jane-Marie  Q") == "JANE MARIE Q",
    "punctuation to space, squished, upper-cased")
chk(first_initial("  bob smith") == "B", "first initial from a normalized name")
chk(is.na(first_initial("")), "no initial from a blank")

# -----------------------------------------------------------------------------
cat("\n-- blank_to_na --\n")
# -----------------------------------------------------------------------------

chk(is.na(blank_to_na("   ")), "whitespace-only -> NA")
chk(identical(blank_to_na(c("a", " ", NA)), c("a", NA_character_, NA_character_)),
    "mixed vector normalized")

# -----------------------------------------------------------------------------
cat("\n-- classify_nppes_license_keys: collision detection --\n")
# -----------------------------------------------------------------------------

license_long <- tibble::tibble(
  npi = c("1", "2", "3"),
  license_key = c("CA::1", "CA::1", "TX::2")
)
classified <- classify_nppes_license_keys(license_long)

chk(classified$n_npi_for_license[classified$license_key == "TX::2"] == 1L,
    "a key used by one NPI counts as 1")
chk(all(classified$n_npi_for_license[classified$license_key == "CA::1"] == 2L),
    "a key shared by two NPIs counts as 2")
chk(isTRUE(classified$license_key_unique[classified$license_key == "TX::2"]),
    "unique key flagged unique")
chk(!any(classified$license_key_unique[classified$license_key == "CA::1"]),
    "shared key flagged NOT unique")

# -----------------------------------------------------------------------------
cat("\n-- end-to-end deterministic link over tiny fixtures --\n")
# -----------------------------------------------------------------------------

tmp <- tempfile("amcb_bridge_fixtures_")
dir.create(tmp)
on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

roster_csv <- file.path(tmp, "midwives.csv")
bridge_csv <- file.path(tmp, "amcb_license_bridge.csv")
nppes_csv  <- file.path(tmp, "nppes.csv")

readr::write_csv(
  tibble::tibble(
    certification_number = c("CNM0001", "CNM0002", "CNM0003"),
    first_name = c("JANE", "MARY", "ANNA"),
    middle_name = c("Q", "", ""),
    last_name = c("SMITH", "JONES", "LEE")
  ),
  roster_csv
)

readr::write_csv(
  tibble::tibble(
    certification_number = c("CNM0001", "CNM0002", "CNM0003"),
    license_number = c("0012345", "0099999", "0055000"),
    # "California" also exercises the full-name -> code path.
    license_state = c("California", "TX", "NY")
  ),
  bridge_csv
)

readr::write_csv(
  tibble::tibble(
    `NPI` = c("1000000001", "1000000002", "1000000003", "1000000004"),
    `Provider First Name` = c("JANE", "MARY", "ANNA", "BOB"),
    `Provider Middle Name` = c("Q", "", "", ""),
    # 1000000002 is a SURNAME conflict for CNM0002 (JONES vs WILLIAMS).
    `Provider Last Name (Legal Name)` = c("SMITH", "WILLIAMS", "LEE", "OTHER"),
    `Provider Business Practice Location Address City Name` =
      c("DENVER", "AUSTIN", "NEW YORK", "ALBANY"),
    `Provider Business Practice Location Address State Name` =
      c("CO", "TX", "NY", "NY"),
    # 1000000003 and 1000000004 share license key NY::0055000 (collision).
    `Provider License Number_1` = c("0012345", "0099999", "0055000", "0055000"),
    `Provider License Number State Code_1` = c("CA", "TX", "NY", "NY")
  ),
  nppes_csv
)

roster <- read_amcb_roster(roster_csv)
bridge <- read_amcb_license_bridge(bridge_csv)
nppes_wide <- read_nppes_license_fields(nppes_csv, slots = 15L)
nppes_licenses <- classify_nppes_license_keys(
  pivot_nppes_licenses(nppes_wide, slots = 15L)
)
linked <- link_amcb_by_license(roster, bridge, nppes_licenses)

cw <- linked$crosswalk
row_for <- function(id) cw[cw$amcb_id == id, , drop = FALSE]

chk(row_for("CNM0001")$deterministic_status == "license_exact",
    "exact name + unique license key -> accepted")
chk(row_for("CNM0001")$deterministic_npi == "1000000001",
    "the accepted NPI is the license-matched one")

chk(row_for("CNM0002")$deterministic_status == "license_match_surname_conflict",
    "unique key but conflicting surname -> quarantined")
chk(is.na(row_for("CNM0002")$deterministic_npi),
    "surname-conflict row carries no NPI")

chk(row_for("CNM0003")$deterministic_status == "license_conflict",
    "license key mapping to two NPIs -> not accepted")
chk(is.na(row_for("CNM0003")$deterministic_npi),
    "collision row carries no NPI")

# -----------------------------------------------------------------------------
cat(sprintf("\n%s\n", if (fails == 0L) "ALL PASS" else sprintf("%d FAILED", fails)))
if (fails > 0L) quit(status = 1L, save = "no")
