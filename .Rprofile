# Pin CRAN to a dated snapshot so every install.packages() call -- in CI, in
# the nightly cron, and on anyone's own machine -- gets the same package
# versions on every run, instead of "whatever happened to be newest that
# day." There is no lockfile in this repo; this is the smallest fix that
# still makes a dependency-version break traceable (the snapshot date tells
# you what to diff against) instead of invisible. Bump the date deliberately,
# not as a side effect of an unrelated change.
options(repos = c(CRAN = "https://packagemanager.posit.co/cran/2026-10-19"))
