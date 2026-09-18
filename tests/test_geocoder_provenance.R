#!/usr/bin/env Rscript
# =============================================================================
# The rules that separate a geocoder from a delivery date
# =============================================================================
# 58.6% of the coordinates behind every access map and every rurality
# assignment carry a label that says WHEN they arrived, not WHO produced them
# (issue #225). R/lib/geocoder_provenance.R makes that distinction
# machine-readable; these are the cases where getting it wrong would let an
# undescribed coordinate read as a described one.
#
# Run: Rscript tests/test_geocoder_provenance.R
# =============================================================================
src <- file.path(dirname(sub("--file=", "", grep("--file=", commandArgs(), value = TRUE)[1])),
                 "..", "R", "lib", "geocoder_provenance.R")
source(if (file.exists(src)) src else "R/lib/geocoder_provenance.R")

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("\n-- the registry --\n")

chk(!anyDuplicated(GEOCODER_PROVENANCE_REGISTRY$geocoder_provenance),
    "no provenance value is registered twice")
chk(all(GEOCODER_PROVENANCE_REGISTRY$class %in%
          c("geocoder", "import_event", "unknown")),
    "every registered value has one of the three classes")
chk(all(nzchar(GEOCODER_PROVENANCE_REGISTRY$note)),
    "every registered value says what it means")

# The whole point: a date-suffixed label is NOT a geocoder.
chk(identical(classify_geocoder_provenance("legacy_csv_20251011")$class, "import_event"),
    "legacy_csv_20251011 classifies as an import event, not a geocoder")
chk(identical(classify_geocoder_provenance("cohort_backfill_20260603")$class, "import_event"),
    "cohort_backfill_20260603 classifies as an import event, not a geocoder")
chk(isTRUE(classify_geocoder_provenance("unknown+shared_merge")$is_defect),
    "unknown+shared_merge is a defect class, not a value")
chk(!any(classify_geocoder_provenance(c("census_batch", "ArcGIS_World"))$is_defect),
    "a named geocoder is not a defect")

cat("\n-- an unregistered label is an error, not a silent 'unknown' --\n")
# A new import label appearing unannounced is the drift the registry exists to
# catch. Defaulting it to "unknown" would hide the one event worth noticing.
e <- tryCatch({ classify_geocoder_provenance("backfill_20270101"); NULL },
              error = function(e) conditionMessage(e))
chk(!is.null(e), "an unregistered provenance value stops")
chk(!is.null(e) && grepl("backfill_20270101", e, fixed = TRUE),
    "the error names the value it did not recognise")

cat("\n-- precision --\n")

chk(identical(geocode_precision_class("census_batch", "interpolated"), "interpolated"),
    "a census batch interpolation is reported as interpolated")
chk(identical(geocode_precision_class("ArcGIS_World", "match"), "address_match"),
    "an ArcGIS match is reported as an address match")
# cache_merge describes the TRANSFER, not the geocode -- it must not read as a
# precision claim of any kind.
chk(identical(geocode_precision_class("legacy_csv_20251011", "cache_merge"), "unknown"),
    "cache_merge yields unknown precision, not a match")
# The case the issue singles out: a city centroid is a legitimate fallback and a
# completely different claim from a rooftop match. It must survive any
# match_type, including one that would otherwise say "match".
chk(identical(geocode_precision_class("City_Centroid_Dataset", "match"), "city_centroid"),
    "a city centroid stays a centroid even when match_type says 'match'")
chk(identical(geocode_precision_class("City_Centroid_Dataset", NA), "city_centroid"),
    "a city centroid is a centroid with no match_type at all")
chk(identical(geocode_precision_class(NA, NA), "unknown"),
    "nothing recorded yields unknown, not a default precision")

cat("\n-- recovering the provider from the attempt log --\n")

p <- c("legacy_csv_20251011", "cohort_backfill_20260603", "unknown+shared_merge",
       "census_batch", "ArcGIS_World", "legacy_csv_20251011")
l <- c("US_Census_Bureau", "ArcGIS_World", "US_Census_Bureau",
       "ArcGIS_World", NA, NA)
r <- resolve_effective_provenance(p, l)

chk(identical(r[1], "US_Census_Bureau"),
    "an import label is replaced by the provider of a successful attempt")
chk(identical(r[2], "ArcGIS_World"),
    "a backfill label is replaced the same way")
chk(identical(r[3], "US_Census_Bureau"),
    "the defect class is resolvable when the log happens to have a provider")
# A RECORDED PRODUCER BEATS AN INFERENCE. census_batch already names the
# geocoder; letting a log row overwrite it would silently rewrite provenance
# that was correct, which is the opposite of the repair this is for.
chk(identical(r[4], "census_batch"),
    "a label that already names a geocoder is NEVER overwritten by the log")
chk(identical(r[5], "ArcGIS_World"),
    "a named geocoder with no log row is left alone")
chk(identical(r[6], "legacy_csv_20251011"),
    "an import label with no log row keeps its label rather than becoming NA")

chk(identical(length(resolve_effective_provenance(character(0), character(0))), 0L),
    "an empty input returns an empty result rather than erroring")

e2 <- tryCatch({ resolve_effective_provenance(c("a", "b"), "x"); NULL },
               error = function(e) conditionMessage(e))
chk(!is.null(e2), "mismatched lengths stop rather than recycling")

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAIL",
            fails, if (fails == 1L) "" else "s"))
if (fails > 0L) quit(status = 1L)
