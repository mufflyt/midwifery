# Pin CRAN to a dated snapshot so every install.packages() call -- in CI, in
# the nightly cron, and on anyone's own machine -- gets the same package
# versions on every run, instead of "whatever happened to be newest that
# day." There is no lockfile in this repo; this is the smallest fix that
# still makes a dependency-version break traceable (the snapshot date tells
# you what to diff against) instead of invisible. Bump the date deliberately,
# not as a side effect of an unrelated change.
#
# BUG FIX: the plain (no "__linux__/<codename>/") snapshot URL serves SOURCE
# packages on Linux, not prebuilt binaries -- Posit Package Manager only
# switches to binaries for a Linux client when the distro codename is in the
# path. Without it, every install (duckdb especially, a large C++ build)
# compiles from source on every CI run and the nightly cron, which is what
# timed out two required CI jobs (15 and 30 minute budgets) on 2026-10-20.
# macOS and Windows need no such segment -- R's own binary mechanism handles
# those independent of this URL. The codename is read from the runner's own
# /etc/os-release rather than hardcoded, because the CI image is scheduled to
# migrate off its current codename within days of this fix.
.cran_snapshot <- "2026-10-19"
.cran_repo <- local({
  base <- sprintf("https://packagemanager.posit.co/cran/%s", .cran_snapshot)
  if (Sys.info()[["sysname"]] != "Linux") return(base)
  os_release <- "/etc/os-release"
  codename <- if (file.exists(os_release)) {
    lines <- readLines(os_release, warn = FALSE)
    m <- grep("^VERSION_CODENAME=", lines, value = TRUE)
    if (length(m)) sub("^VERSION_CODENAME=\"?([^\"]*)\"?$", "\\1", m[1]) else NA_character_
  } else NA_character_
  if (is.na(codename) || !nzchar(codename)) base
  else sprintf("https://packagemanager.posit.co/cran/__linux__/%s/%s", codename, .cran_snapshot)
})
options(repos = c(CRAN = .cran_repo))
rm(.cran_snapshot, .cran_repo)
