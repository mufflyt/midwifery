#!/usr/bin/env Rscript
# =============================================================================
# Put a person-level input into the shared data vault
# =============================================================================
# Usage:
#   Rscript publish_to_data_vault.R
#       Publishes artifacts/amcb_npi_linkage_FROZEN.csv -- but only if it is
#       the freeze the tracked manifest describes. A stale copy is refused, so
#       the vault can never be handed the wrong freeze by mistake.
#   Rscript publish_to_data_vault.R <file> <stem> [YYYY-MM-DD]
#       Publishes any other file under <stem>_<sha8>_<date>.<ext>.
#
# Never overwrites; see R/lib/data_vault.R and docs/DATA_VAULT.md.
# =============================================================================
source(file.path("R", "lib", "data_vault.R"))

args <- commandArgs(trailingOnly = TRUE)
if (!length(args)) {
  manifest_path <- "artifacts/amcb_npi_linkage_FROZEN.csv.manifest.json"
  local <- "artifacts/amcb_npi_linkage_FROZEN.csv"
  if (!file.exists(local)) stop("no ", local, " on this machine; nothing to publish.", call. = FALSE)
  m <- jsonlite::read_json(manifest_path)
  sha <- digest::digest(file = local, algo = "sha256")
  if (!identical(sha, tolower(m$artifact_sha256)))
    stop(sprintf("%s is %s..., but the manifest's current freeze is %s... (%s rows). Not publishing a stale freeze.",
                 local, substr(sha, 1, 8), substr(m$artifact_sha256, 1, 8),
                 format(m$artifact_rows, big.mark = ",")), call. = FALSE)
  # The freeze's date is its run_id's, not the file's mtime, which a copy resets.
  run_date <- sub("^[^0-9]*([0-9]{4})([0-9]{2})([0-9]{2}).*$", "\\1-\\2-\\3", m$run_id)
  dest <- vault_publish(local, "amcb_npi_linkage_FROZEN", date = run_date)
} else {
  if (length(args) < 2L) stop("usage: Rscript publish_to_data_vault.R <file> <stem> [YYYY-MM-DD]", call. = FALSE)
  dest <- if (length(args) >= 3L) vault_publish(args[1], args[2], date = args[3]) else vault_publish(args[1], args[2])
}
cat("in the vault:", dest, "\n")
