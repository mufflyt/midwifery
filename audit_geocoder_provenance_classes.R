#!/usr/bin/env Rscript
# =============================================================================
# How much of the geocoding cache names a geocoder, and how much names a date
# =============================================================================
# Reads ~/isochrones/data/geocoding_cache.duckdb and reports, for every
# coordinate the study rests on, whether its recorded provenance identifies the
# service that produced it or only the batch it arrived in -- and, where the
# attempt log can say, which geocoder was actually behind an import label.
#
# SEPARATE FROM audit_coordinate_provenance.R ON PURPOSE. That script answers
# "why does a given midwife have no county", and needs person-level files that
# are gitignored and absent from every checkout. This one answers "what is the
# provenance of the cache itself", needs only the cache, and writes an
# AGGREGATE -- counts by provenance class, no address, no coordinate, no
# address_hash -- so the answer is reviewable in the repository rather than
# only on the machine holding the person-level data. Issue #225.
#
# THE OUTPUT IS A LEDGER, NOT A PASS. A run that cannot reach the cache says so
# and stops; a provenance label the registry does not know stops too, by
# classify_geocoder_provenance(). What it does NOT do is fail on the debt
# itself: 13,303 legacy coordinates have no recoverable producer, and that is a
# fact to be recorded and reduced, not a build to be broken.
#
# Inputs : $GEOCODING_CACHE_PATH (default ~/isochrones/data/geocoding_cache.duckdb)
# Output : artifacts/geocoder_provenance_classes.csv
#
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(DBI); library(duckdb); library(tibble)
})
source(file.path("R", "lib", "geocoder_provenance.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

CACHE <- Sys.getenv("GEOCODING_CACHE_PATH",
                    path.expand("~/isochrones/data/geocoding_cache.duckdb"))
OUT   <- "artifacts/geocoder_provenance_classes.csv"

if (!file.exists(CACHE)) {
  stop(sprintf(paste0(
    "geocoding cache not found at %s.\n",
    "  Set GEOCODING_CACHE_PATH, or run on the machine that holds it. This\n",
    "  stops rather than writing an empty ledger, which would read as 'no\n",
    "  undescribed coordinates' instead of 'nothing was looked at'."), CACHE),
    call. = FALSE)
}

con <- dbConnect(duckdb::duckdb(), CACHE, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

cache <- tbl(con, "geocoding_cache")
have_log <- "geocoding_attempt_log" %in% dbListTables(con)

# The provider of a SUCCESSFUL attempt, one per address. A failed attempt says
# which service was asked, not which one produced the coordinate that was kept.
success <- if (have_log) {
  tbl(con, "geocoding_attempt_log") |>
    filter(status == "success") |>
    distinct(address_hash, provider)
} else NULL

rows <- cache |>
  {\(x) if (is.null(success)) mutate(x, provider = NA_character_)
        else left_join(x, success, by = "address_hash")}() |>
  count(geocoder_provenance, match_type, validation_status, log_provider = provider) |>
  collect()

# Stops on an unregistered label. See classify_geocoder_provenance().
cls <- classify_geocoder_provenance(rows$geocoder_provenance)

led <- rows |>
  mutate(class = cls$class,
         is_defect = cls$is_defect,
         note = cls$note,
         precision_class = geocode_precision_class(geocoder_provenance, match_type),
         effective_provenance = resolve_effective_provenance(geocoder_provenance,
                                                             log_provider),
         provider_recovered = effective_provenance != geocoder_provenance) |>
  group_by(geocoder_provenance, class, is_defect, match_type, validation_status,
           precision_class, effective_provenance, provider_recovered, note) |>
  summarise(n = sum(n), .groups = "drop") |>
  arrange(desc(n))

total <- sum(led$n)
by_class <- led |> group_by(class) |> summarise(n = sum(n), .groups = "drop")
recovered <- sum(led$n[led$provider_recovered])
named_before <- sum(led$n[led$class == "geocoder"])

fmt <- function(x) format(x, big.mark = ",", trim = TRUE)
# Not `pct`: geocode_midwives.R already defines a top-level `pct`, and
# tests/ci_hygiene.R H4 rejects one name defined at top level in two files --
# a rule that exists because norm_addr() once existed four times with
# divergent behaviour.
share_of_cache <- function(x) sprintf("%.1f%%", 100 * x / total)

cat(sprintf("coordinates in the cache: %s\n\n", fmt(total)))
cat("--- what the recorded label identifies ---\n")
for (i in seq_len(nrow(by_class)))
  cat(sprintf("  %-14s %8s  (%s)\n", by_class$class[i], fmt(by_class$n[i]),
              share_of_cache(by_class$n[i])))
cat(sprintf("\n--- recovery from the attempt log ---\n"))
cat(sprintf("  named a geocoder already      %8s  (%s)\n", fmt(named_before), share_of_cache(named_before)))
cat(sprintf("  provider recovered from log   %8s  (%s)\n", fmt(recovered), share_of_cache(recovered)))
cat(sprintf("  still undescribed             %8s  (%s)\n",
            fmt(total - named_before - recovered), share_of_cache(total - named_before - recovered)))

cat("\n--- precision ---\n")
prec <- led |> group_by(precision_class) |> summarise(n = sum(n), .groups = "drop") |>
  arrange(desc(n))
for (i in seq_len(nrow(prec)))
  cat(sprintf("  %-16s %8s  (%s)\n", prec$precision_class[i], fmt(prec$n[i]),
              share_of_cache(prec$n[i])))

defect <- sum(led$n[led$is_defect])
if (defect > 0)
  cat(sprintf(paste0(
    "\nDEFECT CLASS: %s coordinate(s) carry a provenance that says, explicitly,\n",
    "  that nobody knows where they came from. Exclude them from any use where\n",
    "  precision matters rather than treating the label as a value.\n"), fmt(defect)))

stopifnot(sum(led$n) == total)
write_with_provenance(led, OUT, inputs = character(0))
cat(sprintf("\nwritten: %s (%d rows)\n", OUT, nrow(led)))
