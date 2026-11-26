# =============================================================================
# Eleven claims the pipeline makes about the data it moves
# =============================================================================
# WHY THIS SUITE EXISTS. Its two siblings gate claims made in PROSE:
# test_claim_integrity_saboteurs.R the ones the repository makes about itself,
# test_doc_integrity_saboteurs.R the ones its documentation makes about the
# tree. This one gates the claims the PIPELINE makes -- which script produced
# an artifact, what that artifact was built from, when, and from inputs of
# what hash. 304 tracked `*.provenance.json` sidecars assert all of it, and
# until now the only thing checked about them was that they exist.
#
# THE DEFECTS THAT MOTIVATED IT.
#   * docs/spec-completion-matrix.md said "79 pre-existing artifacts carry
#     `code_sha256: null`", at line 109 and again at 177. The measurement is
#     75 under `artifacts/` and 5 under `data/`, 80 in all -- so the number
#     was stale under either reading of "artifacts", and the population it
#     meant was never stated. Both lines now name the population.
#   * One sidecar input path, `data/facility_affiliation_refresh/
#     Facility_Affiliation_2026-06.csv`, is neither tracked nor ignored: the
#     provenance names a file the repository cannot account for at all.
#   * tests/helper-repo-scan.R, added by the commit before this one, broke all
#     16 testthat files in tests/ and nothing said so in a way anyone reads.
#     M8 is that defect's gate.
#
# WHAT THESE DO NOT CLAIM. M2 checks that a sidecar names the file it sits
# beside, not that its row counts or hashes describe that file's CONTENTS. M6
# checks a timestamp's shape and that it is not in the future, not that it is
# when the artifact was really written. The contents-level claim needs the
# producer re-run, which is ci_frozen_staleness.R's job and not this one's.
#
# THREE CANDIDATES MEASURED AND DROPPED.
#   * "every recorded input hash still matches the file" -- 97 of 280 tracked
#     input entries do not, and almost all are
#     `live_*_bon_ingested_midwives_from_tracked_roster.csv`, re-ingested on
#     every run. A sidecar recording the hash its artifact was BUILT FROM is
#     supposed to differ from a later refresh of that input. That is a
#     pipeline working, and staleness of that kind is already gated elsewhere.
#   * "every function defined under R/ is called somewhere" -- 15 are not, all
#     but one dot-prefixed internals. That is dead code, a complexity finding,
#     not a false claim, and a 15-entry baseline on that premise buys nothing.
#   * "no top-level constant is defined in two files" -- 180 are (`ART` in 24
#     files, `FROZEN` in 18). ci_hygiene.R's H4 forbids that for FUNCTIONS,
#     where two copies diverge in behaviour. This repository is a pipeline of
#     numbered scripts by design and a per-script path constant is its idiom.
# =============================================================================

.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
source(file.path(root, "tests", "helper-saboteur.R"))
source(file.path(root, "tests", "lib_repo_scan.R"))
SAB_PREFIX <- "M"

SIDECARS <- grep("\\.provenance\\.json$", TRACKED, value = TRUE)
SIDE <- lapply(SIDECARS, function(rel)
  tryCatch(jsonlite::fromJSON(file.path(root, rel), simplifyVector = FALSE),
           error = function(e) structure(list(), class = "unparseable")))
names(SIDE) <- SIDECARS

#' Every input entry across every sidecar, as a flat table
#'
#' An `inputs` entry is a list with `path` and usually `sha256`. Read as a
#' flat table because every claim below is about one entry, not one sidecar.
#' @return [list] `file`, `path`, `sha` -- three character vectors, aligned.
input_entries <- function() {
  f <- character(0); p <- character(0); h <- character(0)
  for (rel in SIDECARS) {
    for (it in (SIDE[[rel]]$inputs %||% list())) {
      if (!is.list(it) || is.null(it$path)) next
      f <- c(f, rel); p <- c(p, as.character(it$path))
      h <- c(h, if (is.null(it$sha256)) NA_character_ else as.character(it$sha256))
    }
  }
  list(file = f, path = p, sha = h)
}
# %||% is base R since 4.4; a local copy shadows it and fails C3a.
ENTRIES <- input_entries()

# --- M1 an artifact nothing names -----------------------------------------------
sab(1, "a committed artifact that no script, document or workflow mentions")
# RUN-STAMPED NAMES ARE NOT ORPHANS. Three artifacts are built by sprintf --
# `trilliant_demographics_validation_1a7bd6a8.csv` carries a commit hash,
# `cohort_flow_17224_to_16775.csv` two cohort counts -- so no literal in any
# script can ever match them. The first version of this gate called all three
# dead. The stem is what the producer actually writes.
#
# ONE PASS OVER THE CORPUS, NOT ONE PER ARTIFACT. Scanning 17MB once per
# artifact is 336 scans; the filename-shaped tokens are extracted once and
# answered from a set.
ART_FILES <- grep("^(artifacts|data)/.*\\.(csv|tsv)$", TRACKED, value = TRUE)
ART_FILES <- ART_FILES[!grepl("provenance", ART_FILES)]
CORPUS <- unlist(lapply(
  grep("\\.(R|py|md|ya?ml|sh|tsv|txt)$", TRACKED, value = TRUE),
  function(rel) readLines(file.path(root, rel), warn = FALSE)))
# PREFILTER WITH fixed = TRUE BEFORE THE REGEX. Running gregexpr over all 17MB
# cost 17 of this suite's 76 seconds. Only lines containing ".csv" or ".tsv"
# can yield a token, and that test is a plain substring search.
CORPUS <- CORPUS[grepl(".csv", CORPUS, fixed = TRUE) |
                   grepl(".tsv", CORPUS, fixed = TRUE)]
TOKENS <- unique(unlist(regmatches(
  CORPUS, gregexpr("[A-Za-z0-9_.-]+\\.(csv|tsv)", CORPUS))))
art_stem <- function(b) {
  b <- sub("\\.(csv|tsv)$", "", b)
  b <- sub("_[0-9a-f]{8,40}$", "", b)
  b <- sub("_[0-9]{4,6}_to_[0-9]{4,6}$", "", b)
  sub("_[0-9]{8}T[0-9]{6}$", "", b)
}
named <- function(a) {
  b <- basename(a)
  b %in% TOKENS || any(startsWith(TOKENS, art_stem(b)))
}
m1_bad <- Filter(function(a) !named(a), ART_FILES)
chk(length(ART_FILES) >= 200L && length(TOKENS) >= 200L,
    sprintf("M1a the tracked artifacts and the names the tree uses are both read (%d artifacts, %d distinct filename tokens)",
            length(ART_FILES), length(TOKENS)))
chk(!length(m1_bad),
    sprintf("M1b every tracked artifact is named somewhere in the tree%s",
            if (length(m1_bad)) paste0(" [", paste(utils::head(m1_bad, 4), collapse = ", "), "]") else ""))
chk(identical(art_stem("trilliant_demographics_validation_1a7bd6a8.csv"),
              "trilliant_demographics_validation") &&
      identical(art_stem("cohort_flow_17224_to_16775.csv"), "cohort_flow"),
    "M1c a run stamp is stripped to the stem the producer writes")

# --- M2 a sidecar that names the wrong file -------------------------------------
sab(2, "provenance filed against a different artifact than the one it sits beside")
m2_bad <- character(0)
for (rel in SIDECARS) {
  want <- basename(sub("\\.provenance\\.json$", "", rel))
  got <- SIDE[[rel]]$artifact
  if (!is.null(got) && !identical(basename(as.character(got)), want))
    m2_bad <- c(m2_bad, sprintf("%s says artifact=%s", rel, got))
}
chk(length(SIDECARS) >= 100L,
    sprintf("M2a the sidecars are read (%d), so a clean result is not an empty one",
            length(SIDECARS)))
chk(!length(m2_bad),
    sprintf("M2b every sidecar's artifact field names the file it sits beside%s",
            if (length(m2_bad)) paste0(" [", paste(utils::head(m2_bad, 3), collapse = "; "), "]") else ""))

# --- M3 provenance naming a file the repository never heard of ------------------
sab(3, "an input path that is neither committed nor deliberately uncommitted")
# ABSOLUTE PATHS ARE EXCLUDED, NOT FAILED. `/Volumes/MufflySamsung 1/...` is a
# real external drive holding the historical NPPES downloads; provenance that
# records where a file actually came from is doing its job. Only
# repository-relative paths are this repository's to account for.
rel_idx <- !grepl("^(/|~)", ENTRIES$path)
m3_paths <- ENTRIES$path[rel_idx]
m3_ok <- known_paths(m3_paths)
m3_bad <- unique(sprintf("%s -> %s", ENTRIES$file[rel_idx][!m3_ok],
                         m3_paths[!m3_ok]))
chk(length(m3_paths) >= 500L,
    sprintf("M3a the repository-relative input paths are read (%d of %d entries)",
            length(m3_paths), length(ENTRIES$path)))
chk(!length(m3_bad),
    sprintf("M3b every repository-relative input is tracked or deliberately ignored%s",
            if (length(m3_bad)) paste0(" [", paste(utils::head(m3_bad, 3), collapse = "; "), "]") else ""))

# --- M4 a documented count of its own gaps --------------------------------------
sab(4, "a count of what is unverified, itself unverified")
MATRIX <- file.path(root, "docs", "spec-completion-matrix.md")
mx <- readLines(MATRIX, warn = FALSE)
null_code <- vapply(SIDECARS, function(rel) {
  v <- SIDE[[rel]]$code_sha256
  is.null(v) || identical(as.character(v), "") || identical(as.character(v), "null")
}, logical(1))
n_null <- sum(null_code)
n_null_art <- sum(null_code & startsWith(SIDECARS, "artifacts/"))
n_null_data <- sum(null_code & startsWith(SIDECARS, "data/"))
#' The three numbers the matrix states about `code_sha256: null`
#' @param ln [character] the document's lines.
#' @return [integer] total, artifacts/, data/ -- or integer(0) if unstated.
stated_nulls <- function(ln) {
  hit <- grep("code_sha256: `?null`?|`code_sha256: null`", ln)
  for (i in hit) {
    m <- regmatches(ln[i], regexec(
      "\\*?\\*?([0-9]+)\\*?\\*? (?:tracked )?(?:sidecars|artifacts) carry|^([0-9]+)\\. ([0-9]+) sidecars",
      ln[i]))[[1]]
    tot <- suppressWarnings(as.integer(
      regmatches(ln[i], regexpr("[0-9]+(?= (tracked )?(sidecars|artifacts))", ln[i], perl = TRUE))))
    a <- suppressWarnings(as.integer(regmatches(ln[i], regexpr(
      "[0-9]+(?= under `artifacts/`)", ln[i], perl = TRUE))))
    d <- suppressWarnings(as.integer(regmatches(ln[i], regexpr(
      "[0-9]+(?= under\\s*$|[0-9]+(?= under `data/`))", ln[i], perl = TRUE))))
    if (length(tot) && !is.na(tot) && length(a) && !is.na(a))
      return(c(tot, a))
  }
  integer(0)
}
sn <- stated_nulls(mx)
chk(length(SIDECARS) >= 100L && n_null > 0L,
    sprintf("M4a the sidecars' code_sha256 fields are read (%d null of %d: %d under artifacts/, %d under data/)",
            n_null, length(SIDECARS), n_null_art, n_null_data))
chk(length(sn) == 2L,
    sprintf("M4b the matrix states both the total and the artifacts/ figure%s",
            if (length(sn) != 2L) " [neither was found, so the claim cannot be checked]" else ""))
chk(length(sn) == 2L && sn[1] == n_null && sn[2] == n_null_art,
    sprintf("M4c the documented counts match this run%s",
            if (length(sn) == 2L && (sn[1] != n_null || sn[2] != n_null_art))
              sprintf(" [document says %d total / %d artifacts/, measured %d / %d]",
                      sn[1], sn[2], n_null, n_null_art) else ""))

# --- M5 a sidecar that outlived its artifact ------------------------------------
sab(5, "provenance for a file that is no longer there")
tgt <- sub("\\.provenance\\.json$", "", SIDECARS)
m5_ok <- known_paths(tgt)
m5_bad <- tgt[!m5_ok]
chk(length(tgt) >= 100L,
    sprintf("M5a every sidecar's artifact path is resolved (%d)", length(tgt)))
chk(!length(m5_bad),
    sprintf("M5b no sidecar outlives its artifact%s",
            if (length(m5_bad)) paste0(" [", paste(utils::head(m5_bad, 4), collapse = ", "), "]") else ""))

# --- M6 a timestamp that cannot be true -----------------------------------------
sab(6, "a write time in the future, or in no format at all")
# THREE FIELDS, BECAUSE THE PRODUCERS SPELL IT THREE WAYS. 20 sidecars carry
# `accessed_utc` and no `written_utc`: the `cms_ndh_*` and
# `live_*_bon_ingested_*` files are FETCHED, and when the source was read is
# the honest claim about them. A gate demanding `written_utc` fires on those
# 20 correct files -- which is how this one was first written. One more,
# op_linkage_adjudication_summary, spells it `generated_at`; the gate found
# that by failing on it. Unifying the three spellings is a producer-side
# change and a different task; reading all three is this gate's job.
TS_FIELDS <- c("written_utc", "accessed_utc", "generated_at")
# TWO SIDECARS RECORD NO TIME AT ALL, and the list may only SHRINK. Both carry
# `artifact`, `inputs` and `summary` and nothing else. The fix is for their
# producers to record a time on the next write; backfilling one from a commit
# date would be inventing provenance to satisfy a gate. M6d fails if either
# gains a timestamp, so the list cannot outlive its reason.
TIMELESS <- c("artifacts/nppes_license_concordance.csv.provenance.json",
              "artifacts/nursys_qa_sample.csv.provenance.json")
TS_PAT <- "^([0-9]{4}-[0-9]{2}-[0-9]{2})[ T]([0-9]{2}:[0-9]{2}:[0-9]{2})"
now <- Sys.time()
m6_none <- character(0); m6_bad <- character(0); n_ts <- 0L
sidecar_time <- function(rel) {
  for (k in TS_FIELDS) {
    v <- SIDE[[rel]][[k]]
    if (!is.null(v)) return(as.character(v))
  }
  NULL
}
for (rel in SIDECARS) {
  v <- sidecar_time(rel)
  if (is.null(v)) { m6_none <- c(m6_none, rel); next }
  n_ts <- n_ts + 1L
  m <- regmatches(as.character(v), regexec(TS_PAT, as.character(v)))[[1]]
  if (length(m) != 3L) {
    m6_bad <- c(m6_bad, sprintf("%s %s (unparseable)", rel, v)); next
  }
  t <- as.POSIXct(paste(m[2], m[3]), tz = "UTC")
  if (!is.na(t) && t > now + 86400)
    m6_bad <- c(m6_bad, sprintf("%s %s (in the future)", rel, v))
}
chk(n_ts >= 100L,
    sprintf("M6a a timestamp is read from %d of %d sidecars (%d carry neither field)",
            n_ts, length(SIDECARS), length(m6_none)))
m6_new <- setdiff(m6_none, TIMELESS)
m6_stale <- setdiff(TIMELESS, m6_none)
chk(!length(m6_new),
    sprintf("M6b no sidecar outside the named two records no time at all%s",
            if (length(m6_new)) paste0(" [", paste(utils::head(m6_new, 3), collapse = ", "), "]") else ""))
chk(!length(m6_bad),
    sprintf("M6c every timestamp parses and none is in the future%s",
            if (length(m6_bad)) paste0(" [", paste(utils::head(m6_bad, 3), collapse = "; "), "]") else ""))
chk(!length(m6_stale),
    sprintf("M6d both named timeless sidecars still record no time, so the list is not forgiving something that was fixed%s",
            if (length(m6_stale)) paste0(" [", paste(m6_stale, collapse = ", "), " now has one; drop it from TIMELESS]") else ""))
chk(identical(sidecar_time(
      "artifacts/op_linkage_adjudication_summary.csv.provenance.json"),
      as.character(SIDE[[
        "artifacts/op_linkage_adjudication_summary.csv.provenance.json"]]$generated_at)),
    "M6e a producer that spells it generated_at is read, not reported timeless")

# --- M7 a hash that is not a hash -----------------------------------------------
sab(7, "a truncated or placeholder sha256, which verifies nothing")
have <- !is.na(ENTRIES$sha)
m7_bad <- unique(sprintf("%s -> %s", ENTRIES$file[have][
  !grepl("^[0-9a-f]{64}$", ENTRIES$sha[have])],
  ENTRIES$sha[have][!grepl("^[0-9a-f]{64}$", ENTRIES$sha[have])]))
chk(sum(have) >= 500L,
    sprintf("M7a the recorded input hashes are read (%d of %d entries)",
            sum(have), length(ENTRIES$sha)))
chk(!length(m7_bad),
    sprintf("M7b every recorded hash is 64 lowercase hex digits%s",
            if (length(m7_bad)) paste0(" [", paste(utils::head(m7_bad, 3), collapse = "; "), "]") else ""))

# --- M8 a helper that takes the directory down with it --------------------------
sab(8, "a testthat helper that errors at load and silences every test beside it")
# THE DEFECT THIS GATE EXISTS FOR, COMMITTED ONE COMMIT AGO. testthat sources
# every tests/helper-*.R ALPHABETICALLY before it runs any test file in the
# directory. helper-repo-scan.R sorted before helper-saboteur.R and read
# SAB_ROOT at load time: "object 'SAB_ROOT' not found", and all 16 testthat
# files in tests/ stopped producing a summary line. Nothing reported an error.
# ci_skip_budget.R caught it, as 16 gates whose skips "could not be counted".
HELPERS <- sort(grep("^tests/helper-[^/]*\\.R$", TRACKED, value = TRUE))
# ONE PROCESS, IN ORDER, BECAUSE THAT IS WHAT TESTTHAT DOES. Nine separate
# Rscript processes cost 53 of this suite's 76 seconds, and they tested the
# wrong thing: testthat sources every helper into ONE environment in
# alphabetical order, so a helper may legitimately use what an earlier one
# defined. The defect this gate exists for was precisely an ORDERING defect --
# helper-repo-scan.R sorted first and read a name helper-saboteur.R had not
# yet defined -- and only the in-order load reproduces it.
m8_probe <- paste(sprintf(
  'cat("%s\t", tryCatch({source("%s"); "OK"}, error = conditionMessage), "\n", sep = "")',
  HELPERS, HELPERS), collapse = "; ")
m8_out <- suppressWarnings(system2(
  "Rscript", c("--vanilla", "-e", shQuote(m8_probe)),
  stdout = TRUE, stderr = TRUE))
m8_seen <- sub("\t.*$", "", grep("\t", m8_out, value = TRUE))
m8_bad <- sub("\t", ": ", grep("\tOK$", grep("\t", m8_out, value = TRUE),
                                invert = TRUE, value = TRUE))
chk(length(HELPERS) >= 5L,
    sprintf("M8a the auto-sourced helpers are found (%d), so a clean result is not an empty one",
            length(HELPERS)))
chk(identical(sort(m8_seen), HELPERS),
    sprintf("M8b all %d helpers were reached by the in-order load, so a clean result is not a truncated one (%d reported)",
            length(HELPERS), length(m8_seen)))
chk(!length(m8_bad),
    sprintf("M8c loading every helper in testthat's own order raises no error%s",
            if (length(m8_bad)) paste0(" [", paste(utils::head(m8_bad, 2), collapse = "; "), "]") else ""))
chk(!any(grepl("^tests/helper-repo-scan\\.R$", TRACKED)),
    "M8d the shared scan library is named lib_, outside that namespace")

# --- M9 a source() target that moved --------------------------------------------
sab(9, "a sourced file that is not there, read from the parse tree and not a grep")
# WHY THE PARSE TREE. A grep for `source("...")` reports
# R/ci_repo_integrity_gates.R:263, which is a COMMENT explaining the function
# below it. And the walker must recurse with lapply: `for (k in as.list(e))`
# dies on a missing argument like `x[, 1]`, because binding an empty symbol
# errors. Both mistakes were made before this gate was written.
SRC <- new.env(parent = emptyenv())
walk_source <- function(e) {
  if (!is.call(e)) return(invisible(NULL))
  fn <- if (is.name(e[[1]])) as.character(e[[1]]) else ""
  if (identical(fn, "source") && length(e) >= 2L && is.character(e[[2]]))
    assign("v", c(get("v", envir = SRC), e[[2]]), envir = SRC)
  lapply(as.list(e), walk_source)
  invisible(NULL)
}
n_src <- 0L; n_parsed <- 0L; m9_bad <- character(0)
ALL_R <- grep("\\.R$", TRACKED, value = TRUE)
for (rel in ALL_R) {
  ex <- tryCatch(parse(file.path(root, rel)), error = function(e) NULL)
  if (is.null(ex)) next
  n_parsed <- n_parsed + 1L
  assign("v", character(0), envir = SRC)
  lapply(as.list(ex), walk_source)
  for (p in get("v", envir = SRC)) {
    n_src <- n_src + 1L
    cand <- c(p, file.path(dirname(rel), p))
    if (!any(file.exists(file.path(root, cand))))
      m9_bad <- c(m9_bad, sprintf("%s source(%s)", rel, p))
  }
}
chk(n_parsed == length(ALL_R),
    sprintf("M9a every tracked R file parses (%d of %d)", n_parsed, length(ALL_R)))
chk(n_src >= 50L,
    sprintf("M9b the literal source() targets are found (%d)", n_src))
chk(!length(m9_bad),
    sprintf("M9c every sourced file exists%s",
            if (length(m9_bad)) paste0(" [", paste(utils::head(m9_bad, 4), collapse = "; "), "]") else ""))

# --- M10 the numbered pipeline's numbering --------------------------------------
sab(10, "two stages numbered the same, or a stage number with nothing behind it")
NUM <- grep("^R/[0-9]+-", TRACKED, value = TRUE)
k <- as.integer(sub("^R/([0-9]+)-.*$", "\\1", NUM))
dups <- k[duplicated(k)]
gaps <- if (length(k)) setdiff(seq(min(k), max(k)), k) else integer(0)
chk(length(NUM) >= 10L,
    sprintf("M10a the numbered stages are found (%d, numbered %d to %d)",
            length(NUM), min(k), max(k)))
chk(!length(dups),
    sprintf("M10b no two stages share a number%s",
            if (length(dups)) paste0(" [", paste(unique(dups), collapse = ", "), "]") else ""))
chk(!length(gaps),
    sprintf("M10c the numbering has no gap%s",
            if (length(gaps)) paste0(" [missing ", paste(gaps, collapse = ", "), "]") else ""))

# --- M11 a runner naming a suite that moved -------------------------------------
sab(11, "a regression runner that names a suite the tree no longer has")
RUNNER <- "RUN_REGRESSION_TESTS.R"
m11_refs <- character(0)
if (RUNNER %in% TRACKED) {
  ln <- readLines(file.path(root, RUNNER), warn = FALSE)
  m11_refs <- unique(unlist(regmatches(
    ln, gregexpr("tests/[A-Za-z0-9_.-]+\\.R", ln))))
}
m11_bad <- m11_refs[!m11_refs %in% TRACKED]
chk(length(m11_refs) >= 10L,
    sprintf("M11a the runner's suite list is read (%d suites)", length(m11_refs)))
chk(!length(m11_bad),
    sprintf("M11b every suite the runner names is tracked%s",
            if (length(m11_bad)) paste0(" [", paste(m11_bad, collapse = ", "), "]") else ""))

saboteur_report(11)
