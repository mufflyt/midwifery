#!/usr/bin/env Rscript
# =============================================================================
# Adjudication queue/import/status: the machinery around the 327 decisions
# =============================================================================
# Every behavior the closure spec demands, proven on a synthetic truth world
# (so it runs anywhere), plus a LOCAL-ONLY snapshot section that pins the
# real starting state at exactly 327 unresolved cases.
#
# Run: Rscript tests/test_adjudication_queue.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
source(file.path(root, "R", "truth_set_checks.R"))
source(file.path(root, "R", "adjudication_queue.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat("  ok:", m, "\n")
  else { fails <<- fails + 1L; cat("  FAIL:", m, "\n") }
}
trips <- function(expr) inherits(try(expr, silent = TRUE), "try-error")
trip_msg <- function(expr) {
  e <- try(expr, silent = TRUE)
  if (inherits(e, "try-error")) attr(e, "condition")$message else ""
}

# ---- a synthetic truth world in tempdir --------------------------------------
make_world <- function(ids = c("ADJ-A1-1111111111", "ADJ-A2-2222222222",
                               "ADJ-A3-3333333333"),
                       shuffle = FALSE) {
  td <- file.path(tempfile("truth"), "truth")
  dir.create(td, recursive = TRUE)
  inst <- data.frame(adjudication_id = ids,
                     amcb_id = sub("ADJ-([^-]+)-.*", "\\1", ids),
                     npi = sub(".*-", "", ids),
                     nppes_first_name = "PAT", nppes_last_name = "EXAMPLE",
                     workflow_state = "not_started",
                     stringsAsFactors = FALSE)
  if (shuffle) inst <- inst[rev(seq_len(nrow(inst))), , drop = FALSE]
  pi <- file.path(td, "adjudication_instrument_v1.csv")
  pr <- file.path(td, "adjudication_reviews_v1.csv")
  utils::write.csv(inst, pi, row.names = FALSE, na = "")
  utils::write.csv(data.frame(adjudication_id = character(0),
                              reviewer_id = character(0),
                              verdict = character(0),
                              evidence_source = character(0),
                              locator = character(0), reason = character(0),
                              review_date = character(0)),
                   pr, row.names = FALSE)
  utils::write.csv(data.frame(adjudication_id = character(0),
                              final_verdict = character(0),
                              resolution_method = character(0),
                              resolver = character(0),
                              resolution_date = character(0),
                              resolution_reason = character(0)),
                   file.path(td, "adjudication_resolution_v1.csv"),
                   row.names = FALSE)
  utils::write.csv(data.frame(adjudication_id = sort(ids),
                              batch = 1L, stringsAsFactors = FALSE),
                   file.path(td, "adjudication_batches_v1.csv"),
                   row.names = FALSE)
  manifest <- list(rows_instrument = length(ids),
                   population_hash = population_hash(ids),
                   files = list(instrument = list(file = pi,
                                                  sha256 = sha256_file(pi)),
                                reviews = list(file = pr,
                                               sha256 = sha256_file(pr))))
  writeLines(jsonlite::toJSON(manifest, auto_unbox = TRUE, pretty = TRUE),
             file.path(td, "adjudication_instrument_v1.manifest.json"))
  td
}
fill <- function(q, i, reviewer = "R1", verdict = "MATCH",
                 reason = "CV and practice city align") {
  q$reviewer_id[i] <- reviewer; q$verdict[i] <- verdict
  q$evidence_source[i] <- "primary_person_source"
  q$locator[i] <- "cv p2"; q$reason[i] <- reason
  q$review_date[i] <- "2026-09-10"
  q
}
write_batch <- function(q) {
  f <- tempfile(fileext = ".csv")
  utils::write.csv(q, f, row.names = FALSE, na = "")
  f
}

cat("\n-- queue determinism and identity --\n")
td <- make_world()
q1 <- adjudication_queue(td); q2 <- adjudication_queue(td)
chk(identical(q1, q2), "queue generation is byte-stable on repeated runs")
tds <- make_world(shuffle = TRUE)
qs <- adjudication_queue(tds)
chk(identical(q1$adjudication_id, qs$adjudication_id),
    "input row reordering does not change case ids or their order")
chk(all(c("adjudication_batch", ENTRY_FIELDS) %in% names(q1)),
    "queue carries batch tag and empty entry columns")
tdd <- make_world(ids = c("ADJ-A1-1111111111", "ADJ-A1-1111111111",
                          "ADJ-A3-3333333333"))
chk(trips(adjudication_queue(tdd)),
    "duplicate source rows fail closed, never two review cases")

cat("\n-- import validation fails closed --\n")
td <- make_world()
q <- adjudication_queue(td)
bad <- fill(q, 1); bad$adjudication_id[1] <- "ADJ-ZZ-0000000000"
chk(trips(import_adjudication_verdicts(write_batch(bad), td)),
    "unknown case id fails")
bad2 <- fill(q, 1, verdict = "yes")
chk(trips(import_adjudication_verdicts(write_batch(bad2), td)),
    "invalid verdict fails (yes/no vocabulary refused)")
bad3 <- fill(q, 1, verdict = "match")
chk(trips(import_adjudication_verdicts(write_batch(bad3), td)),
    "lowercase alternate spelling refused at entry")
part <- q; part$verdict[1] <- "MATCH"   # started row, everything else blank
chk(trips(import_adjudication_verdicts(write_batch(part), td)),
    "a started row with blank required fields fails")
conf <- fill(fill(q, 1, verdict = "MATCH"), 2, verdict = "NONMATCH")
conf$adjudication_id[2] <- conf$adjudication_id[1]
chk(trips(import_adjudication_verdicts(write_batch(conf), td)),
    "two different verdicts for one case in one file fail")
dirty <- fill(q, 1, reason = "state board shows active license")
chk(trips(import_adjudication_verdicts(write_batch(dirty), td)),
    "board contamination is rejected at the door")
leaky <- fill(q, 1, reason = "matcher said exact_last_first so fine")
chk(trips(import_adjudication_verdicts(write_batch(leaky), td)),
    "matcher vocabulary in a reason is rejected at the door")

cat("\n-- import success, bijection, idempotence, append-only --\n")
td <- make_world()
q <- adjudication_queue(td)
good <- fill(fill(q, 1, verdict = "MATCH"), 2, verdict = "INSUFFICIENT")
f <- write_batch(good)
s1 <- import_adjudication_verdicts(f, td)
rv <- utils::read.csv(file.path(td, "adjudication_reviews_v1.csv"),
                      stringsAsFactors = FALSE)
chk(identical(sort(rv$verdict), c("indeterminate", "match")),
    "entry vocabulary maps by fixed bijection into frozen storage")
s2 <- import_adjudication_verdicts(f, td)
rv2 <- utils::read.csv(file.path(td, "adjudication_reviews_v1.csv"),
                       stringsAsFactors = FALSE)
chk(identical(rv, rv2), "importing the same batch twice is idempotent")
flip <- fill(q, 1, verdict = "NONMATCH")
msg <- trip_msg(import_adjudication_verdicts(write_batch(flip), td))
chk(grepl("DIFFERS", msg) && grepl("ADJ-A1-1111111111", msg),
    "changing a recorded verdict fails closed and names the case")
q_after <- adjudication_queue(td)
chk(identical(q_after$adjudication_id, "ADJ-A3-3333333333"),
    "adjudicated cases disappear from the next queue")
chk(nrow(q_after) + s2$adjudicated_cases == s2$total_cases,
    "conservation: no unresolved case vanishes without a recorded verdict")

cat("\n-- completion is 327/327-or-nothing (here 3/3) --\n")
chk(identical(s2$adjudicated_cases, 2L) && !isTRUE(s2$complete),
    "completion cannot report true at n-1 of n")
last <- fill(adjudication_queue(td), 1, verdict = "NONMATCH")
import_adjudication_verdicts(write_batch(last), td)
s3 <- adjudication_status(td)
chk(isTRUE(s3$complete) && s3$unresolved_cases == 0L &&
      s3$conflicting_verdicts == 0L && s3$invalid_verdicts == 0L,
    "completion true only at full count, zero conflicts, zero invalid")
chk(s3$match == 1L && s3$nonmatch == 1L && s3$insufficient == 1L,
    "status counts verdicts by final source")
sj <- jsonlite::fromJSON(file.path("artifacts/adjudication",
                                   "adjudication_status.json"))
chk(identical(sj$total_cases, 3L) && !is.null(sj$git_sha) &&
      !is.null(sj$source_checksum),
    "status artifact carries sha, checksum, and counts")

cat("\n-- dual review still flows to resolution, not to import conflict --\n")
td <- make_world()
q <- adjudication_queue(td)
r1 <- fill(q, 1, reviewer = "R1", verdict = "MATCH")
r2 <- fill(q, 1, reviewer = "R2", verdict = "NONMATCH")
import_adjudication_verdicts(write_batch(r1), td)
import_adjudication_verdicts(write_batch(r2), td)
s <- adjudication_status(td)
chk(s$needs_resolution == 1L && !isTRUE(s$complete),
    "a cross-reviewer split is needs_resolution and blocks completion")

cat("\n-- LOCAL-ONLY: the real starting snapshot --\n")
if (file.exists("artifacts/truth/adjudication_instrument_v1.csv")) {
  qr <- adjudication_queue("artifacts/truth")
  sr <- adjudication_status("artifacts/truth")
  chk(sr$total_cases == 327L, "real population is 327")
  chk(nrow(qr) + sr$adjudicated_cases == 327L,
      "real queue + adjudicated conserves the population")
  cat(sprintf("  snapshot: %d unresolved, %d adjudicated\n",
              sr$unresolved_cases, sr$adjudicated_cases))
} else cat("  skip: local truth artifacts not present (CI runner)\n")

cat(sprintf("\n%s: %d failures\n", if (fails) "RED" else "GREEN", fails))
if (fails) quit(status = 1L)
