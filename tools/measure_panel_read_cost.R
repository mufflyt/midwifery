#!/usr/bin/env Rscript
# =============================================================================
# The measurement behind Review_AI_performance.qmd
# =============================================================================
# A report whose numbers cannot be re-derived is an assertion, not a
# measurement. This is the script that produced that report's tables, kept so
# the next round can be compared against this one rather than restarted. It is
# the performance sibling of tools/measure_code_complexity.R.
#
# It reads midwife_panel.csv and nothing else, writes nothing, and changes no
# repository file. The panel is gitignored and is NOT regenerable from a fresh
# clone (it needs the full NPPES historical download set), so this script will
# refuse rather than invent a fixture: a timing from a toy file would be worse
# than no timing.
#
# FOUR THINGS THIS SCRIPT EXISTS TO GET RIGHT, each of which produced a wrong
# number first:
#
#   1. ONE ARM PER PROCESS. Peak memory is only attributable if nothing else
#      ran in the same R session. Six reads in one process also pay for each
#      other's garbage collection: the full-width read measures 60.8s alone and
#      89.3s alongside five others. Pass ARM=<name> and run the script once per
#      arm; `ARM=driver` prints the loop.
#
#   2. PEAK MEMORY IS OS RSS, NOT gc(). The first pass of this measurement
#      computed a peak from gc()'s "max used" column with the Ncells and Vcells
#      byte widths reversed (Ncells are 56 bytes, Vcells 8) and reported a
#      3,501 MB peak that did not exist. Run every arm under
#      `/usr/bin/time -l` and read "maximum resident set size". This script
#      prints object.size() as the PERSISTENT cost and says so; it does not
#      pretend to know the transient peak.
#
#   3. A READR READ THAT IS NOT TOUCHED HAS NOT HAPPENED. readr 2.x returns
#      lazy ALTREP columns, so timing read_csv() and stopping measures the cost
#      of not having read the file. Every timed arm here forces materialisation
#      inside the timed region with force_cols().
#
#   4. EQUIVALENCE IS CHECKED, NOT ASSERTED. The narrowing arms compare the
#      narrowed frame against the same columns of the full-width frame with
#      identical(), over every row. That is the whole basis for calling
#      col_select a free change.
#
# USAGE
#   ARM=driver Rscript tools/measure_panel_read_cost.R    # prints the loop
#   /usr/bin/time -l Rscript tools/measure_panel_read_cost.R   # ARM=inventory
#
#   ARM=inventory   rows, distinct NPIs, snapshot years, taxonomy split (DuckDB)
#   ARM=full        read_csv(cols(.default = "c")) -- all 13 columns
#   ARM=select      read_csv(col_select = <3 used>)
#   ARM=skip        read_csv(cols(<10 x col_skip>))
#   ARM=baseR       read.csv(colClasses = "character")
#   ARM=tail        F1: the base-R summary tail vs one DuckDB query
#   ARM=resume      F5: read.csv for done_years vs SELECT DISTINCT
#   ARM=types       F6: guess_max = Inf partial spec vs all thirteen named
#   ARM=equiv       F2: the four narrowed column sets vs full width, identical()
#
# MIDWIFE_PANEL overrides the path, as it does for the scripts that read it.
# =============================================================================

PANEL <- Sys.getenv("MIDWIFE_PANEL", "midwife_panel.csv")
ARM   <- Sys.getenv("ARM", "inventory")

ARMS <- c("inventory", "full", "select", "skip", "baseR",
          "tail", "resume", "types", "equiv")

if (identical(ARM, "driver")) {
  cat("# one process per arm, peak RSS from the OS, not from gc():\n")
  cat(sprintf("for a in %s; do\n", paste(ARMS, collapse = " ")))
  cat("  echo \"== $a\"\n")
  cat("  ARM=$a /usr/bin/time -l Rscript tools/measure_panel_read_cost.R 2>&1 |\n")
  cat("    grep -E 'STEP|ARM|identical|maximum resident set size'\n")
  cat("done\n")
  quit(save = "no", status = 0)
}

if (!ARM %in% ARMS)
  stop(sprintf("ARM=%s is not one of: %s (or `driver`)", ARM,
               paste(ARMS, collapse = ", ")), call. = FALSE)

if (!file.exists(PANEL))
  stop(sprintf(paste("%s is absent. It is gitignored and not regenerable from a",
                     "fresh clone -- build it with build_midwife_panel.R against",
                     "the NPPES historical downloads, or point MIDWIFE_PANEL at",
                     "an existing copy. This script does not substitute a",
                     "fixture: a timing from a toy file is worse than none."),
               PANEL), call. = FALSE)

# The size and identity of the file every number below is relative to. Two
# builds of this panel with the same 20 snapshot years can differ in row count
# and distinct-NPI count, so a timing is only comparable against a stated hash.
cat(sprintf("FILE %s  %s bytes\n", PANEL,
            format(file.size(PANEL), big.mark = ",")))

timed <- function(label, expr) {
  t0 <- Sys.time()
  v <- force(expr)
  cat(sprintf("STEP %-28s %.1fs\n", label,
              as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  invisible(v)
}

# readr 2.x columns are lazy. Touching every value is what makes the read real;
# nchar(as.character(x)) materialises without caring about the column's type.
#
# WHICH columns to touch is a methodological choice, not a detail. Forcing
# every column read makes the full-width arm pay for materialising ten columns
# the narrowed arm never has -- real work, but work the SCRIPTS BEING FIXED
# never do either: they parse thirteen and use three. Forcing the same three in
# both arms isolates what the fix actually changes, which is parse width. Pass
# cols = NULL to force everything, which is the right choice for the `types`
# arm, where both arms read all thirteen and the question is inference, not
# width.
force_cols <- function(d, cols = USED) {
  take <- if (is.null(cols)) names(d) else intersect(cols, names(d))
  invisible(sum(vapply(d[take], function(x) sum(nchar(as.character(x))),
                       numeric(1))))
  d
}

held <- function(d)
  cat(sprintf("     rows=%s cols=%d object_size_MB=%.1f\n",
              format(nrow(d), big.mark = ","), ncol(d),
              as.numeric(utils::object.size(d)) / 1024^2))

USED <- c("npi", "snapshot_year", "practice_state")   # the three the five
                                                      # (npi, year, state)
                                                      # reductions keep
ALL13 <- c("npi", "last_name", "first_name", "middle_name", "credential",
           "practice_address", "practice_city", "practice_state",
           "practice_zip", "deactivation_date", "tax_class",
           "snapshot_year", "snapshot_date")

# The types guess_max = Inf arrives at on this panel. npi is a DOUBLE: naming
# it "c" because an NPI is obviously an identifier would silently zero every
# join against a linkage file that is itself read with guessing on.
GUESSED <- readr::cols(
  npi = "d", last_name = "c", first_name = "c", middle_name = "c",
  credential = "c", practice_address = "c", practice_city = "c",
  practice_state = "c", practice_zip = "c", deactivation_date = "c",
  tax_class = "c", snapshot_year = "d", snapshot_date = "d")

# duckdb_connect(), not a bare dbConnect(): it is the one place the encoding
# bootstrap and the spill directory are set, build_midwife_panel.R:317 opens its
# connection through it, and a timing taken on a differently-configured
# connection is not a timing of the code being measured.
# ci_duckdb_ingestion_bootstrap.R enforces this.
duck <- function() {
  suppressMessages(library(duckdb))
  source("R/lib/medicare_duckdb.R")   # run from the repo root, as PANEL's default assumes
  duckdb_connect()
}
# all_varchar = TRUE: there is nothing to infer, and the panel's npi must not
# be read as a number by a query that only counts it.
src <- function() sprintf("read_csv_auto('%s', all_varchar = TRUE)", PANEL)

cat(sprintf("ARM=%s\n", ARM))

if (ARM == "inventory") {
  con <- duck(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  q <- function(s) DBI::dbGetQuery(con, sprintf(s, PANEL))
  # `rows` is a DuckDB keyword; a bare alias of that name is a parser error,
  # which is why every alias here is spelled out with AS.
  timed("totals", print(q(paste(
    "SELECT count(*) AS n_rows, count(DISTINCT npi) AS npis,",
    "count(DISTINCT snapshot_year) AS years,",
    "min(snapshot_year) AS y0, max(snapshot_year) AS y1",
    "FROM read_csv_auto('%s', all_varchar = TRUE)"))))
  timed("by taxonomy class", print(q(paste(
    "SELECT tax_class, count(*) AS n_rows, count(DISTINCT npi) AS npis",
    "FROM read_csv_auto('%s', all_varchar = TRUE) GROUP BY 1 ORDER BY 1"))))
  timed("by snapshot year", print(q(paste(
    "SELECT snapshot_year, count(*) AS n_rows, count(DISTINCT npi) AS npis,",
    "min(snapshot_date) AS d0, max(snapshot_date) AS d1",
    "FROM read_csv_auto('%s', all_varchar = TRUE) GROUP BY 1 ORDER BY 1"))))

} else if (ARM == "full") {
  suppressMessages(library(readr))
  # Forces only the three columns the narrowed arm has, so the two arms differ
  # in parse width and nothing else.
  d <- timed("read_csv all 13 columns",
             force_cols(read_csv(PANEL, col_types = cols(.default = "c"),
                                 progress = FALSE)))
  held(d)

} else if (ARM == "select") {
  suppressMessages(library(readr))
  d <- timed("read_csv col_select 3",
             force_cols(read_csv(PANEL, col_types = cols(.default = "c"),
                                 col_select = all_of(USED), progress = FALSE)))
  held(d)

} else if (ARM == "skip") {
  suppressMessages(library(readr))
  spec <- stats::setNames(
    lapply(ALL13, function(n) if (n %in% USED) col_character() else col_skip()),
    ALL13)
  d <- timed("read_csv 10 x col_skip",
             force_cols(read_csv(PANEL, col_types = do.call(cols, spec),
                                 progress = FALSE)))
  held(d)

} else if (ARM == "baseR") {
  d <- timed("read.csv colClasses character",
             read.csv(PANEL, colClasses = "character"))
  held(d)

} else if (ARM == "tail") {
  # F1. What build_midwife_panel.R's summary tail used to do, against what it
  # does now. The four values must match exactly; they are the whole claim.
  d <- timed("read.csv", read.csv(PANEL, colClasses = "character"))
  held(d)
  n_npi <- timed("unique + pairs", {
    a <- length(unique(d$npi))
    b <- nrow(unique(d[, c("npi", "last_name")]))
    c(a, b)
  })
  # aggregate()'s formula method calls an R closure ONCE PER GROUP, and there
  # are ~472k groups. This step is the single most expensive statement found in
  # the whole review.
  multi <- timed("aggregate last_name ~ npi", {
    ch <- aggregate(last_name ~ npi, d, function(x) length(unique(x)))
    sum(ch$last_name > 1)
  })
  base_vals <- as.numeric(c(nrow(d), n_npi[1], n_npi[2], multi))
  cat(sprintf("     baseR  rows=%s npis=%s pairs=%s multi_surname=%s\n",
              format(base_vals[1], big.mark = ","), format(base_vals[2], big.mark = ","),
              format(base_vals[3], big.mark = ","), format(base_vals[4], big.mark = ",")))
  # Drop the 534 MB frame before timing the replacement, or the second arm pays
  # the first one's garbage collection.
  rm(d); invisible(gc())
  con <- duck(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  row <- timed("one DuckDB query", DBI::dbGetQuery(con, sprintf("
    WITH p AS (SELECT npi, last_name FROM read_csv_auto('%s', all_varchar = TRUE))
    SELECT (SELECT count(*) FROM p) AS rows,
           (SELECT count(DISTINCT npi) FROM p) AS npis,
           (SELECT count(*) FROM (SELECT DISTINCT npi, last_name FROM p)) AS pairs,
           (SELECT count(*) FROM (SELECT npi FROM p GROUP BY npi
                                  HAVING count(DISTINCT last_name) > 1)) AS multi_surname",
    PANEL)))
  duck_vals <- as.numeric(c(row$rows, row$npis, row$pairs, row$multi_surname))
  cat(sprintf("     duckdb rows=%s npis=%s pairs=%s multi_surname=%s\n",
              format(duck_vals[1], big.mark = ","), format(duck_vals[2], big.mark = ","),
              format(duck_vals[3], big.mark = ","), format(duck_vals[4], big.mark = ",")))
  cat(sprintf("     identical=%s\n", identical(base_vals, duck_vals)))

} else if (ARM == "resume") {
  # F5. The resume path asked which snapshot years are already written.
  y_old <- timed("read.csv$snapshot_year",
                 unique(as.integer(read.csv(PANEL, colClasses = "character")$snapshot_year)))
  con <- duck(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  y_new <- timed("SELECT DISTINCT snapshot_year",
                 as.integer(DBI::dbGetQuery(con, sprintf(
                   "SELECT DISTINCT snapshot_year FROM %s", src()))$snapshot_year))
  cat(sprintf("     years=%d identical=%s\n", length(y_new),
              identical(sort(y_old), sort(y_new))))

} else if (ARM == "types") {
  # F6. guess_max is NOT ignored when the spec is partial: readr scans every
  # row to guess the columns .default = col_guess() left open.
  suppressMessages(library(readr))
  # cols = NULL: both arms read all thirteen columns here, so both materialise
  # all thirteen. The question is the cost of inferring the types, not of width.
  old <- timed("guess_max=Inf, partial spec",
               force_cols(read_csv(PANEL, show_col_types = FALSE, guess_max = Inf,
                                   col_types = cols(practice_zip = "c",
                                                    .default = col_guess()),
                                   progress = FALSE), cols = NULL))
  new <- timed("all thirteen types named",
               force_cols(read_csv(PANEL, col_types = GUESSED, progress = FALSE),
                          cols = NULL))
  cat(sprintf("     identical=%s\n",
              identical(as.data.frame(old), as.data.frame(new))))

} else if (ARM == "equiv") {
  # F2. Four narrowed column sets against the full-width read. This arm reads
  # the file five times in one process on purpose -- the comparison is the
  # point, not the clock -- so do NOT quote its elapsed times as the arm
  # figures. Use ARM=full and ARM=select for those.
  suppressMessages(library(readr))
  full <- timed("full width (for comparison only)",
                read_csv(PANEL, col_types = cols(.default = "c"), progress = FALSE))
  sets <- list(
    state = USED,
    zip   = c("npi", "snapshot_year", "practice_zip"),
    medi  = c("npi", "snapshot_year", "snapshot_date", "practice_state"),
    deact = c("npi", "deactivation_date"))
  for (nm in names(sets)) {
    cs <- sets[[nm]]
    nar <- timed(sprintf("col_select %s", nm),
                 read_csv(PANEL, col_types = cols(.default = "c"),
                          col_select = all_of(cs), progress = FALSE))
    cat(sprintf("     %-6s c(%s) identical=%s\n", nm, paste(cs, collapse = ", "),
                identical(as.data.frame(nar), as.data.frame(full[, cs]))))
  }
}
