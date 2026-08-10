#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 21 (3 BVA / 3 semantic / 4 adversarial)
# =============================================================================
# Closes the ACTION cycle 18 opened: write_with_provenance() existed and nothing
# called it. A provenance mechanism that no writer uses is documentation.
#
# WHAT IS WIRED, AND WHY NOT ALL 43. There are 43 write_csv sites across 14
# scripts. Converting them wholesale is the same shape of risky mechanical edit
# as the .keep_all sites (c5) and the bare joins (c10), and would be justified by
# nothing that has actually gone wrong. What HAS gone wrong is precise: cycles 16
# and 17 rebuilt data/county_base.csv and left downstream files describing the
# old fertility rates. So the three artifacts on that path are wired --
#
#   data/county_base.csv                     the root of the graph
#   county_profiles/county_birth_profiles.csv one join away from it
#   district_profiles/district_profiles.csv   cached ACS + roster underneath it
#
# -- and T217 ratchets the count so coverage can only grow.
#
# THE DISTINCTION THIS FILE DEFENDS. mtime says "this file is older", which is a
# fact about a clock. A content hash says "this file was built from bytes that
# no longer exist", which is a fact about the data. Only the second survives a
# clone, a copy or a restore, and only the second is worth acting on.
#
# Run: Rscript tests/test_cycle21_provenance_wiring.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(readr); library(jsonlite)})
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
source(file.path(root, "R", "lib", "artifact_provenance.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
WIRED <- c("data/county_base.csv",
           "artifacts/county_profiles/county_birth_profiles.csv",
           "artifacts/district_profiles/district_profiles.csv")

cat("\n-- BVA --\n")

# T211 (BVA). Every wired artifact has a sidecar, and the sidecar names at
# least one input. A sidecar with an empty input list records nothing.
{
  present <- vapply(WIRED, function(p) file.exists(paste0(p, ".provenance.json")),
                    logical(1))
  chk(all(present),
      sprintf("T211a every wired artifact has a sidecar [%d of %d]",
              sum(present), length(WIRED)))
  n_in <- vapply(WIRED, function(p) nrow(check_provenance(p)), integer(1))
  chk(all(n_in > 0L),
      sprintf("T211b each sidecar records at least one input [%s]",
              paste(n_in, collapse = ", ")))
}

# T212 (BVA). Freshly written artifacts must be clean. If a sidecar is stale the
# moment it is created, the hash is being taken of the wrong thing.
{
  st <- vapply(WIRED, function(p) any(check_provenance(p)$stale), logical(1))
  chk(!any(st),
      sprintf("T212 no freshly built artifact is already stale [%s]",
              paste(names(st)[st], collapse = ", ")))
}

# T213 (BVA). A hash is 64 lowercase hex characters. A truncated or uppercase
# digest compares unequal to itself across platforms.
{
  h <- check_provenance(WIRED[1])$recorded
  chk(length(h) > 0 && all(grepl("^[0-9a-f]{64}$", h)),
      sprintf("T213 recorded digests are full lowercase SHA-256 [%s...]",
              substr(h[1], 1, 12)))
}

cat("\n-- SEMANTIC --\n")

# T214 (semantic). The recorded input must be the file the script actually
# reads. A sidecar naming a path the pipeline never opens is decorative.
{
  co <- paste(readLines("R/10-county-birth-profiles.R", warn = FALSE), collapse = "\n")
  rec <- check_provenance("artifacts/county_profiles/county_birth_profiles.csv")$path
  chk(any(grepl("county_base", rec)) && grepl("county_base\\.csv", co),
      sprintf("T214 the county profile records the file it reads [%s]",
              paste(basename(rec), collapse = ", ")))
}

# T215 (semantic). Content, not clock -- restated against the LIVE artifacts
# rather than a tempdir fixture. Touching an input must not make a real
# artifact stale.
{
  # SIDE-EFFECT FREE. The first version advanced the real county_base.csv mtime
  # by two hours and never put it back, so every downstream artifact became
  # stale BY CLOCK on the next run and cycles 18 and 19 failed -- but only when
  # this file ran first. That is test-order dependence, introduced by the very
  # test arguing that clocks are the wrong thing to trust. The original time is
  # restored on exit.
  p <- WIRED[1]; inp <- check_provenance(p)$path[1]
  orig_mtime <- file.mtime(inp)
  on.exit(Sys.setFileTime(inp, orig_mtime), add = TRUE)
  before <- any(check_provenance(p)$stale)
  Sys.setFileTime(inp, Sys.time() + 7200)
  after <- any(check_provenance(p)$stale)
  Sys.setFileTime(inp, orig_mtime)
  chk(!before && !after,
      "T215 advancing a real input's mtime by two hours leaves the artifact fresh")
}

# T216 (semantic). The root artifact records the RAW sources it is built from,
# not itself. A file that lists itself as its own input can never go stale.
{
  rec <- check_provenance("data/county_base.csv")$path
  chk(length(rec) > 0 && !any(grepl("county_base\\.csv$", rec)),
      sprintf("T216 county_base does not record itself as an input [%s]",
              paste(basename(rec), collapse = ", ")))
}

cat("\n-- ADVERSARIAL --\n")

# T217 (adversarial). Coverage ratchet. Provenance may spread but must not
# retreat; a future edit that drops write_with_provenance() fails here.
{
  n <- sum(vapply(WIRED, function(p) file.exists(paste0(p, ".provenance.json")),
                  logical(1)))
  chk(n >= 3L,
      sprintf("T217 provenance coverage does not shrink below the recorded three [%d]", n))

  # CYCLE 21b. Wiring extended from 3 artifacts to EVERY write in the numbered
  # pipeline, on request. The ratchet is now the inverse: no bare write_csv may
  # remain in a numbered script, because a single unwired writer is the one
  # whose staleness nobody detects.
  scripts <- list.files("R", pattern = "^[0-9]{2}-.*\\.R$", full.names = TRUE)
  bare <- unlist(lapply(scripts, function(f) {
    x <- readLines(f, warn = FALSE); x[grepl("^\\s*#", x)] <- ""
    if (any(grepl("(?<![_a-zA-Z.])write_csv\\(", x, perl = TRUE))) basename(f) else NULL
  }))
  chk(length(bare) == 0L,
      sprintf("T217b no numbered script still writes without provenance [%s]",
              if (length(bare)) paste(bare, collapse = ", ") else "none"))
  wired <- sum(vapply(scripts, function(f)
    any(grepl("write_with_provenance\\(", readLines(f, warn = FALSE))), logical(1)))
  chk(wired >= 14L,
      sprintf("T217c every numbered script that writes is wired [%d]", wired))
}

# T218 (adversarial). THE REAL SCENARIO. Rebuild an input and confirm the
# dependant is reported stale -- this is cycles 16 and 17 replayed.
{
  p <- "artifacts/county_profiles/county_birth_profiles.csv"
  inp <- check_provenance(p)$path[1]
  keep <- file.path(tempdir(), "cb_backup.csv")
  file.copy(inp, keep, overwrite = TRUE)
  d <- suppressWarnings(read_csv(inp, show_col_types = FALSE, progress = FALSE,
                                 col_types = cols(GEOID = col_character())))
  d$GEOID[1] <- d$GEOID[1]                       # rewrite with one cell touched
  d[[2]][1] <- d[[2]][1]
  orig_mtime <- file.mtime(inp)
  readr::write_csv(rbind(d, d[1, ]), inp)        # genuinely different content
  stale_now <- any(check_provenance(p)$stale)
  file.copy(keep, inp, overwrite = TRUE)         # restore bytes...
  Sys.setFileTime(inp, orig_mtime)               # ...and the clock, so the
                                                 # mtime-based checks in cycles
                                                 # 18 and 19 see no change
  restored_clean <- !any(check_provenance(p)$stale)
  chk(stale_now, "T218a changing the input marks the dependant stale")
  chk(restored_clean,
      "T218b restoring the original bytes clears it, because the check is on content")
}

# T219 (adversarial). A corrupt or truncated sidecar must not be read as
# "everything is fine". Absence of evidence is not evidence of freshness.
{
  p <- file.path(tempdir(), "t219.csv"); s <- file.path(tempdir(), "t219_in.csv")
  readr::write_csv(data.frame(x = 1), s)
  write_with_provenance(data.frame(a = 1), p, inputs = s)
  writeLines("{ not json", paste0(p, ".provenance.json"))
  r <- tryCatch(check_provenance(p), error = function(e) "error")
  chk(identical(r, "error") || (is.data.frame(r) && nrow(r) == 0L),
      "T219 a corrupt sidecar errors or reports nothing, never a clean bill of health")
}

# T220a (adversarial). PORTABILITY, and a defect in my own helper. The first
# version recorded absolute paths, so on any clone check_provenance() would find
# no file and declare every artifact stale -- the exact opposite of the property
# cycle 18 claimed for content hashing over mtime. Recorded paths must be
# repo-relative.
{
  recs <- unlist(lapply(WIRED, function(p) check_provenance(p)$path))
  chk(length(recs) > 0 && !any(startsWith(recs, "/")) && !any(grepl("^[A-Za-z]:", recs)),
      sprintf("T220a recorded input paths are repo-relative, so a clone can verify them [%s]",
              paste(unique(recs), collapse = ", ")))
}

# T220 (adversarial). The sidecar must not be mistaken for an artifact. A
# *.provenance.json sitting in artifacts/ must never be picked up as data by a
# glob that expects CSVs.
{
  sidecars <- list.files(c("data", "artifacts"), pattern = "\\.provenance\\.json$",
                         recursive = TRUE, full.names = TRUE)
  chk(length(sidecars) > 0 && !any(grepl("\\.csv$", sidecars)),
      sprintf("T220 sidecars are .json and cannot be swept up by a CSV glob [%d]",
              length(sidecars)))
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
