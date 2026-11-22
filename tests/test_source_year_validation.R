#!/usr/bin/env Rscript
# =============================================================================
# Source-year validation contract (spec Workstream D)
# =============================================================================
# assert_source_year() exists so that no series takes its observation year
# from a filename alone. These cases pin the five-level hierarchy, and in
# particular the refusals -- a validator that cannot say no is decoration.
#
# The spec asks specifically for deliberately renamed files and wrong date
# fields. Both are here: a 2019 file renamed to claim 2020, and a file whose
# date column says something incompatible with its name.
# =============================================================================
source(file.path("R", "lib", "source_year.R"))

fails <- 0L
chk <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", msg))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", msg)) }
}
mk <- function(name, df) {
  p <- file.path(tempdir(), name)
  utils::write.csv(df, p, row.names = FALSE)
  p
}

# ---- level 1: a date column inside the data -------------------------------
p1 <- mk("plain_file.csv", data.frame(npi = c("1", "2"),
                                      claim_month = c("2019-04", "2019-11")))
r <- assert_source_year(p1, 2019L, date_columns = "claim_month")
chk(identical(r$status, "in_file_date") && identical(r$confidence, "high"),
    "an in-file date column proves the year, at high confidence")

chk(identical(assert_source_year(p1, 2019L,
      date_columns = c("CLAIM_MONTH"))$status, "in_file_date"),
    "the date column is matched case-insensitively")

# THE RENAMED FILE. Contents are 2019; the caller was told 2020.
r2 <- assert_source_year(p1, 2020L, date_columns = "claim_month",
                         strict = FALSE)
chk(identical(r2$status, "refuted"),
    "a 2019 file claimed as 2020 is REFUTED, not accepted")
chk(grepl("2019", r2$detail) && grepl("2020", r2$detail),
    "and the refusal names both the observed and the claimed year")

err <- tryCatch({ assert_source_year(p1, 2020L, date_columns = "claim_month"); NULL },
                error = function(e) conditionMessage(e))
chk(!is.null(err), "strict = TRUE (the default) stops rather than returning")

# ---- mixed years ----------------------------------------------------------
p2 <- mk("mixed.csv", data.frame(npi = c("1", "2"),
                                 claim_month = c("2019-12", "2020-01")))
chk(identical(assert_source_year(p2, 2019L, date_columns = "claim_month",
                                 strict = FALSE)$status, "refuted"),
    "a file mixing 2019 and 2020 is refuted by default")
chk(identical(assert_source_year(p2, 2019L, date_columns = "claim_month",
                                 multiyear = TRUE, strict = FALSE)$status,
              "in_file_date"),
    "unless the caller declares the source legitimately spans years")

# ---- implausible dates ----------------------------------------------------
p3 <- mk("implausible.csv", data.frame(npi = "1", claim_month = "1899-04"))
chk(identical(assert_source_year(p3, 1899L, date_columns = "claim_month",
                                 strict = FALSE)$status, "refuted"),
    "a year before NPPES existed is refuted even if the caller expects it")

# ---- level 2: a release identifier in the path ----------------------------
p4 <- mk("extract_2021-07-01.csv", data.frame(npi = "1", state = "CO"))
r4 <- assert_source_year(p4, 2021L)
chk(identical(r4$status, "release_id") && identical(r4$confidence, "medium"),
    "with no date column, a dated path gives a medium-confidence release_id")
chk(identical(assert_source_year(p4, 2022L, strict = FALSE)$status, "refuted"),
    "and a path dated 2021 refutes a claim of 2022")

# THE CENTRAL REFUSAL: a bare four-digit year in a name is NOT evidence.
p5 <- mk("part_d_by_provider_2016.csv", data.frame(npi = "1", state = "CO"))
r5 <- assert_source_year(p5, 2016L)
chk(identical(r5$status, "unverified"),
    "a bare YYYY in the filename does NOT verify a year -- it is unverified")
chk(identical(assert_source_year(p5, 1999L, strict = FALSE)$status,
              "unverified"),
    "and the same file does not 'refute' a wrong year either, having no evidence")

# ---- level 3: a previously validated checksum -----------------------------
if (requireNamespace("digest", quietly = TRUE)) {
  good <- digest::digest(p5, algo = "sha256", file = TRUE)
  chk(identical(assert_source_year(p5, 2016L, fingerprint = good)$status,
                "fingerprint"),
      "a matching sha256 verifies the year at medium confidence")
  chk(identical(assert_source_year(p5, 2016L,
        fingerprint = paste(rep("0", 64), collapse = ""),
        strict = FALSE)$status, "refuted"),
      "a non-matching sha256 is refuted")
} else cat("  skip digest unavailable\n")

# ---- level 4: nothing available -------------------------------------------
chk(identical(assert_source_year(p5, 2016L)$observed_years, NA_integer_),
    "an unverified result reports no observed year rather than inventing one")

# ---- ordering: stronger evidence wins -------------------------------------
# A file with BOTH a date column and a dated path must be judged on the
# column, because the bytes outrank the name.
p6 <- mk("extract_2021-07-01_but_2019_inside.csv",
         data.frame(npi = "1", claim_month = "2019-03"))
chk(identical(assert_source_year(p6, 2019L, date_columns = "claim_month",
                                 strict = FALSE)$status, "in_file_date"),
    "an in-file date outranks a conflicting date in the path")
chk(identical(assert_source_year(p6, 2021L, date_columns = "claim_month",
                                 strict = FALSE)$status, "refuted"),
    "so a path-derived year that contradicts the data is refuted, not preferred")

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
