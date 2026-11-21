# =============================================================================
# Ten claims this repository's prose makes, and nothing read back
# =============================================================================
# WHY THIS SUITE EXISTS. test_claim_integrity_saboteurs.R gated ten claims the
# repository made about ITSELF -- badges, figure numbers, baselines. This one
# gates the claims its DOCUMENTATION makes about the tree: a status table
# saying a file is missing, a citation pointing at a line, a command shown in
# a fenced block. Each reads as true, each is mechanically checkable, and
# until now none was checked.
#
# THE DEFECTS THAT MOTIVATED IT. docs/spec-completion-matrix.md said
# `artifacts/longitudinal_reconstruction_audit.csv` was NOT DONE and "MISSING"
# while the file was tracked, built by build_longitudinal_reconstruction_audit.R
# and carrying 12 columns across 63 rows; the same table said
# `longitudinal-reconstruction-changelog.md` was NOT DONE while the file was
# tracked with 92 lines, and headed that section "3 of 4". A status table is
# the first thing a reader consults and the last thing anyone re-reads.
#
# WHAT THESE DO NOT CLAIM. D1 reads a verdict against a path's EXISTENCE, not
# against its contents: a DONE row pointing at a real but wrong file passes.
# D2 checks that a cited line is inside the file, not that the line still says
# what the citing prose says it says. Both are the honest narrow form; the
# wider one needs a human.
#
# FIVE CANDIDATES MEASURED AND DROPPED, because measuring first is the point:
#   * "every commit SHA a doc cites resolves" -- 1 of 11 does not, and it is
#     correct: docs/CI_BEST_PRACTICES.md:1405 cites `a631aa226` in
#     `mufflyt/isochrones`, by name, in the same sentence.
#   * "every path DEBT.md cites exists" -- 11 do not, and a debt ledger is
#     where they SHOULD not: one entry names an upstream file
#     (`R/npi_resolution.R`, under "belongs to: mufflyt/isochrones"), another
#     records an artifact deliberately deleted on withdrawal.
#   * "every docs/*.md is linked from another doc" -- 14 are not, which is
#     drift, not a claim the repository makes anywhere.
#   * "every *_detect.R is in the law registry" -- 6 are not, correctly: they
#     detect for gates, and the registry is for laws.
#   * "every tracked ci_*.R is named in a workflow" -- 6 looked unrun and all
#     six are run by nightly.yml under a path form the first scan missed.
# =============================================================================

.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
source(file.path(root, "tests", "helper-saboteur.R"))
source(file.path(root, "tests", "helper-repo-scan.R"))
SAB_PREFIX <- "D"

ALL_MD <- grep("\\.md$", TRACKED, value = TRUE)
WF <- list.files(file.path(root, ".github", "workflows"),
                 pattern = "[.]ya?ml$", full.names = TRUE)
#' Read a tracked file once, however many saboteurs want it
#'
#' D1 and D8 want every tracked script as one string; D2 wants every tracked
#' `.R`, `.md` and `.py` as lines. Reading each set separately read the 653
#' tracked R files twice and put this suite over 45 seconds.
#' @param rel [character(1)] repository-relative path.
#' @return [character] the file's lines.
LINES <- new.env(parent = emptyenv())
file_lines_of <- function(rel) {
  if (!exists(rel, envir = LINES, inherits = FALSE))
    assign(rel, readLines(file.path(root, rel), warn = FALSE), envir = LINES)
  get(rel, envir = LINES, inherits = FALSE)
}
MD_LINES <- lapply(ALL_MD, file_lines_of)
names(MD_LINES) <- ALL_MD
CODE <- grep("\\.(R|sh|ya?ml|py)$", TRACKED, value = TRUE)
CODE_TEXT <- vapply(CODE, function(rel)
  paste(file_lines_of(rel), collapse = "\n"),
  character(1), USE.NAMES = FALSE)

#' Which lines of a markdown file sit inside a fenced code block?
#'
#' A fence opens with three or more backticks and closes only on a run at
#' least as long, so a four-backtick block quoting three-backtick blocks is
#' read as one block and not as three. Counting markers instead reports such
#' a file as unbalanced, which is how a naive version of D7 began.
#' @param ln [character] markdown lines.
#' @return [list] `inside` (logical, the fence lines themselves FALSE) and
#'   `open_at` (line number of an unclosed fence, or NA).
fence_state <- function(ln) {
  inside <- logical(length(ln))
  depth <- 0L
  open_at <- NA_integer_
  for (i in seq_along(ln)) {
    run <- regmatches(ln[i], regexpr("^[[:space:]]*`{3,}", ln[i]))
    n <- if (length(run)) nchar(gsub("[^`]", "", run)) else 0L
    if (n == 0L) {
      inside[i] <- depth > 0L
    } else if (depth == 0L) {
      depth <- n
      open_at <- i
    } else if (n >= depth) {
      depth <- 0L
      open_at <- NA_integer_
    } else {
      inside[i] <- TRUE
    }
  }
  list(inside = inside, open_at = if (depth > 0L) open_at else NA_integer_)
}

# FIVE SABOTEURS ASKED THE SAME QUESTION OF THE SAME LINES. fence_state() is
# an interpreted loop over every line, and D1, D4, D6, D7 and D10 each called
# it per file: six passes over 60,000 lines, which was most of this suite's
# first 54 seconds. One pass, held here.
MD_FENCE <- lapply(ALL_MD, function(rel) fence_state(MD_LINES[[rel]]))
names(MD_FENCE) <- ALL_MD

# --- D1 a status table's verdict ----------------------------------------------
sab(1, "a table saying a file is missing, next to the file")
# THE TWO DIRECTIONS ARE NOT SYMMETRIC. DONE is checked against "tracked or
# deliberately ignored", because most artifacts this repository ships are
# gitignored build outputs and absent from a fresh clone by design. NOT DONE
# is checked against TRACKED alone: an ignored path proves nothing either way,
# but a committed file standing under "NOT DONE" is a contradiction on its
# face. PARTIAL and BLOCKED rows are skipped deliberately -- partial means
# some of the evidence exists, which is not a claim about any one path.
STATUS_PAT <- "\\*\\*(DONE|NOT DONE|MISSING)\\*\\*"
# `[A-Za-z0-9_]` first, so the truncation `` `..._field_coverage.csv` `` in
# this very table is read as the ellipsis it is and not as a path.
CITE_PAT <- paste0("`[A-Za-z0-9_][A-Za-z0-9_./-]*",
                   "\\.(csv|R|md|py|tsv|json|parquet|rds|txt)`")
#' Is a cited path one the repository can account for?
#'
#' THREE WAYS, AND THEY ARE NOT INTERCHANGEABLE. A source file -- `.R`, `.md`,
#' `.py`, `.tsv` -- must be TRACKED, because this repository never generates
#' one; a DONE row citing a source file absent from the tree points at
#' nothing. A data artifact may instead be deliberately gitignored, or simply
#' named as an output by a tracked script: four of the CSVs this table calls
#' DONE (`medicaid_billing_by_state.csv` among them) are real outputs of
#' tracked producers that no `.gitignore` rule happens to name, and failing on
#' those would be failing on a true claim.
#'
#' WHAT THE THIRD WAY DOES NOT ESTABLISH. A basename appearing in a script may
#' be a read rather than a write. The claim is only that the repository knows
#' the name, which is what a DONE row pointing at nothing would not.
#' @param p [character(1)] path or bare filename, as the prose wrote it.
#' @return [logical(1)]
tracked_as <- function(p)
  p %in% TRACKED || any(endsWith(TRACKED, paste0("/", p)))
accounted_for <- function(p) {
  if (tracked_as(p)) return(TRUE)
  if (grepl("\\.(R|md|py|tsv)$", p)) return(FALSE)
  any(known_paths(c(p, file.path("artifacts", basename(p))))) ||
    any(grepl(basename(p), CODE_TEXT, fixed = TRUE))
}
status_rows <- function(ln) {
  keep <- grepl("^[[:space:]]*\\|", ln) & grepl(STATUS_PAT, ln)
  lapply(which(keep), function(i) {
    st <- gsub("\\*", "", regmatches(ln[i], regexpr(STATUS_PAT, ln[i])))
    p <- gsub("`", "", regmatches(ln[i], gregexpr(CITE_PAT, ln[i]))[[1]])
    list(line = i, status = st, paths = p)
  })
}
d1_rows <- 0L; d1_paths <- 0L; d1_bad <- character()
for (rel in ALL_MD) {
  fs <- MD_FENCE[[rel]]
  for (r in status_rows(MD_LINES[[rel]])) {
    if (fs$inside[r$line] || !length(r$paths)) next
    d1_rows <- d1_rows + 1L
    d1_paths <- d1_paths + length(r$paths)
    if (identical(r$status, "DONE")) {
      miss <- r$paths[!vapply(r$paths, accounted_for, logical(1))]
      if (length(miss)) d1_bad <- c(d1_bad, sprintf(
        "%s:%d DONE cites %s, which this repository cannot account for",
        rel, r$line, paste(miss, collapse = ", ")))
    } else {
      here <- r$paths[vapply(r$paths, tracked_as, logical(1))]
      if (length(here)) d1_bad <- c(d1_bad, sprintf(
        "%s:%d %s cites %s, which is tracked",
        rel, r$line, r$status, paste(here, collapse = ", ")))
    }
  }
}
chk(d1_rows >= 10L,
    sprintf("D1a status rows citing a path are found (%d rows, %d paths), so a clean result is not an empty one",
            d1_rows, d1_paths))
chk(!length(d1_bad),
    sprintf("D1b no status verdict contradicts the tree%s",
            if (length(d1_bad)) paste0(" [", paste(d1_bad, collapse = "; "), "]") else ""))
d1_probe <- status_rows(
  "| `tests/ci_hygiene.R` | **NOT DONE** | nothing yet |")
chk(length(d1_probe) == 1L &&
      identical(d1_probe[[1]]$status, "NOT DONE") &&
      identical(d1_probe[[1]]$paths, "tests/ci_hygiene.R"),
    "D1c the row reader takes the verdict and the path out of one table row")
chk(!length(status_rows("| a thing | **PARTIAL** | `x.csv` partly |")),
    "D1d a PARTIAL row is skipped rather than judged against one path")
chk(accounted_for("tests/ci_hygiene.R") &&
      !accounted_for("tests/no_such_gate_xyz.R"),
    "D1e a source file is accounted for only by being tracked")

# --- D2 a citation with a line number -----------------------------------------
sab(2, "a line number that was true when it was written")
# AMBIGUOUS AND UNRESOLVABLE CITATIONS ARE SKIPPED, NOT FAILED. 12 of the 89
# name a basename this tree does not have, and some of those are correct:
# cross-repository citations into `mufflyt/isochrones` read exactly like local
# ones. Judging them would be the overstatement this suite's sibling is named
# for; what is left is the 77 that do resolve, and for those the line number
# is a checkable claim.
BY_BASE <- split(TRACKED, basename(TRACKED))
cite_target <- function(p) {
  if (p %in% TRACKED) return(p)
  hits <- BY_BASE[[basename(p)]]
  if (is.null(hits)) return(NA_character_)
  hits <- hits[endsWith(hits, p)]
  if (length(hits) == 1L) hits else NA_character_
}
d2_seen <- 0L; d2_checked <- 0L; d2_bad <- character()
for (rel in grep("\\.(R|md|py)$", TRACKED, value = TRUE)) {
  ln <- file_lines_of(rel)
  hits <- gregexpr("[A-Za-z0-9_/.-]+\\.(R|py|yml|tsv):[0-9]+", ln)
  for (i in seq_along(ln)) {
    for (cit in regmatches(ln[i], list(hits[[i]]))[[1]]) {
      parts <- strsplit(cit, ":", fixed = TRUE)[[1]]
      d2_seen <- d2_seen + 1L
      tgt <- cite_target(parts[1])
      if (is.na(tgt)) next
      d2_checked <- d2_checked + 1L
      want <- as.integer(parts[2])
      n <- length(file_lines_of(tgt))
      if (want > n) d2_bad <- c(d2_bad, sprintf(
        "%s:%d cites %s:%d but that file has %d lines", rel, i, tgt, want, n))
    }
  }
}
chk(d2_checked >= 50L,
    sprintf("D2a file-and-line citations resolve to a tracked file (%d of %d seen)",
            d2_checked, d2_seen))
chk(!length(d2_bad),
    sprintf("D2b every resolvable citation points inside its file%s",
            if (length(d2_bad)) paste0(" [", paste(utils::head(d2_bad, 4), collapse = "; "), "]") else ""))
chk(is.na(cite_target("no/such/file_xyz.R")) &&
      identical(cite_target("tests/ci_hygiene.R"), "tests/ci_hygiene.R"),
    "D2c the resolver answers NA for a path this tree does not have")

# --- D3 a link out of a document ----------------------------------------------
sab(3, "a relative link that survived the rename of its target")
# R3 in test_claim_integrity_saboteurs.R makes the stricter claim about README
# alone: the file must be PRESENT on disk. Across the other 100-odd tracked
# markdown files that claim would be false by design -- they cite gitignored
# build outputs -- so the predicate here is "tracked or deliberately ignored",
# and the surface is every tracked markdown file instead of one.
resolve_rel <- function(from, p) {
  parts <- strsplit(file.path(dirname(from), p), "/", fixed = TRUE)[[1]]
  out <- character(0)
  for (q in parts) {
    if (q == "." || !nzchar(q)) next
    if (q == "..") out <- utils::head(out, -1L) else out <- c(out, q)
  }
  paste(out, collapse = "/")
}
d3_links <- character(); d3_where <- character()
for (rel in ALL_MD) {
  for (p in link_paths(MD_LINES[[rel]])) {
    d3_links <- c(d3_links, resolve_rel(rel, p))
    d3_where <- c(d3_where, sprintf("%s -> %s", rel, p))
  }
}
d3_ok <- known_paths(d3_links)
chk(length(d3_links) >= 200L,
    sprintf("D3a the markdown corpus's repository links are read (%d links across %d files)",
            length(d3_links), length(ALL_MD)))
chk(all(d3_ok),
    sprintf("D3b every linked path is tracked or deliberately ignored%s",
            if (any(!d3_ok)) paste0(" [", paste(utils::head(d3_where[!d3_ok], 4), collapse = "; "), "]") else ""))
chk(identical(resolve_rel("docs/a.md", "../artifacts/x.csv"), "artifacts/x.csv"),
    "D3c a link out of docs/ resolves against the linking file, not the root")

# --- D4 an anchor into the same document --------------------------------------
sab(4, "a table of contents pointing at a heading that was renamed")
# GITHUB'S SLUG RULE, INCLUDING THE DUPLICATE SUFFIX. Two headings that slug
# alike become `name` and `name-1`; a gate that did not know that would fail
# on a correct link. There is no such link in the tree today, which is exactly
# when to encode the rule -- before the first one is written.
heading_slugs <- function(ln, inside = fence_state(ln)$inside) {
  h <- sub("^#+[[:space:]]*", "", ln[grepl("^#+[[:space:]]", ln) & !inside])
  s <- tolower(h)
  s <- gsub("`|\\*|_|\\[|\\]|\\(|\\)|:|,|\\.|'|\"|\\?|!|\\||/|\\+", "", s)
  s <- gsub("[^a-z0-9 -]", "", s)
  # ONE HYPHEN PER SPACE, NOT PER RUN. "Key Visualizations & Data Gallery"
  # loses the `&` and keeps both spaces around it, so GitHub's anchor is
  # `key-visualizations--data-gallery`. Collapsing the run produced a single
  # hyphen, and this gate's first run called two correct README links broken.
  s <- gsub(" ", "-", trimws(s))
  seen <- new.env(parent = emptyenv())
  vapply(s, function(x) {
    k <- if (exists(x, envir = seen, inherits = FALSE))
      get(x, envir = seen, inherits = FALSE) + 1L else 0L
    assign(x, k, envir = seen)
    if (k == 0L) x else paste0(x, "-", k)
  }, character(1), USE.NAMES = FALSE)
}
d4_seen <- 0L; d4_bad <- character()
for (rel in ALL_MD) {
  ln <- MD_LINES[[rel]]
  slugs <- heading_slugs(ln, MD_FENCE[[rel]]$inside)
  hits <- gregexpr("\\]\\(#[a-z0-9-]+\\)", ln)
  for (i in seq_along(ln)) {
    for (x in regmatches(ln[i], list(hits[[i]]))[[1]]) {
      a <- sub("\\)$", "", sub("^\\]\\(#", "", x))
      d4_seen <- d4_seen + 1L
      if (!a %in% slugs)
        d4_bad <- c(d4_bad, sprintf("%s:%d #%s", rel, i, a))
    }
  }
}
chk(d4_seen >= 20L,
    sprintf("D4a in-document anchors are found (%d), so a clean result is not an empty one",
            d4_seen))
chk(!length(d4_bad),
    sprintf("D4b every anchor names a heading in its own file%s",
            if (length(d4_bad)) paste0(" [", paste(utils::head(d4_bad, 4), collapse = ", "), "]") else ""))
chk(identical(heading_slugs(c("## The Gate", "## The Gate")),
              c("the-gate", "the-gate-1")),
    "D4c two headings that slug alike get GitHub's -1 suffix, not one slug")
chk(identical(heading_slugs("## Key Visualizations & Data Gallery"),
              "key-visualizations--data-gallery"),
    "D4d a dropped `&` leaves both of its spaces, and so two hyphens")

# --- D5 the law registry's own references -------------------------------------
sab(5, "a registry row naming the gate that was supposed to enforce it")
REG <- file.path(root, "tests", "science_law_registry.tsv")
reg <- utils::read.delim(REG, comment.char = "#", stringsAsFactors = FALSE,
                         check.names = FALSE)
reg_refs <- unique(unlist(reg[, c("gate", "mutation")], use.names = FALSE))
reg_refs <- reg_refs[nzchar(reg_refs) & reg_refs != "—"]
d5_bad <- reg_refs[!reg_refs %in% TRACKED]
chk(nrow(reg) >= 10L && length(reg_refs) >= 5L,
    sprintf("D5a the registry is read (%d laws naming %d distinct files)",
            nrow(reg), length(reg_refs)))
chk(!length(d5_bad),
    sprintf("D5b every gate and mutation file the registry names is tracked%s",
            if (length(d5_bad)) paste0(" [", paste(d5_bad, collapse = ", "), "]") else ""))
chk(!anyDuplicated(reg$law),
    sprintf("D5c no law id appears twice%s",
            if (anyDuplicated(reg$law)) paste0(" [", reg$law[anyDuplicated(reg$law)], "]") else ""))

# --- D6 a table that renders with a cell missing ------------------------------
sab(6, "a table row whose cells silently do not line up with its header")
# CODE SPANS FIRST. The first version reported four ragged rows and all four
# were `%||%` written in backticks: the pipes inside a code span are text, not
# cell separators. A gate that cannot tell those apart fires on correct prose,
# gets ignored, and then fires on a real one.
table_cells <- function(l) {
  l <- gsub("`[^`]*`", "X", l)
  length(strsplit(gsub("^[[:space:]]*\\||\\|[[:space:]]*$", "", l),
                  "(?<!\\\\)\\|", perl = TRUE)[[1]])
}
ragged <- function(ln, inside = fence_state(ln)$inside) {
  out <- integer(0); got <- integer(0); n_tbl <- 0L
  i <- 1L
  while (i < length(ln)) {
    if (!inside[i] && grepl("^[[:space:]]*\\|", ln[i]) &&
        grepl("^[[:space:]]*\\|[ :|-]+\\|?[[:space:]]*$", ln[i + 1L])) {
      n <- table_cells(ln[i]); n_tbl <- n_tbl + 1L
      j <- i + 2L
      while (j <= length(ln) && grepl("^[[:space:]]*\\|", ln[j])) {
        if (table_cells(ln[j]) != n) { out <- c(out, j); got <- c(got, n) }
        j <- j + 1L
      }
      i <- j
    } else i <- i + 1L
  }
  list(rows = out, header = got, n_tables = n_tbl)
}
d6_tbl <- 0L; d6_bad <- character()
for (rel in ALL_MD) {
  r <- ragged(MD_LINES[[rel]], MD_FENCE[[rel]]$inside)
  d6_tbl <- d6_tbl + r$n_tables
  if (length(r$rows)) d6_bad <- c(d6_bad, sprintf(
    "%s:%s", rel, paste(r$rows, collapse = ",")))
}
chk(d6_tbl >= 100L,
    sprintf("D6a the markdown tables are found (%d), so a clean result is not an empty one",
            d6_tbl))
chk(!length(d6_bad),
    sprintf("D6b every table row has as many cells as its header%s",
            if (length(d6_bad)) paste0(" [", paste(utils::head(d6_bad, 4), collapse = "; "), "]") else ""))
chk(identical(table_cells("| `%||%` | 2 | identical |"), 3L),
    "D6c a pipe inside a code span is text and not a cell boundary")
chk(length(ragged(c("| a | b |", "|---|---|", "| 1 | 2 | 3 |"))$rows) == 1L,
    "D6d KILLED: a row with one cell too many is detected")

# --- D7 a code fence that never closed ----------------------------------------
sab(7, "an unclosed fence, which renders the rest of the document as code")
d7_bad <- character()
for (rel in ALL_MD) {
  st <- MD_FENCE[[rel]]
  if (!is.na(st$open_at))
    d7_bad <- c(d7_bad, sprintf("%s:%d", rel, st$open_at))
}
n_fenced <- sum(vapply(ALL_MD, function(rel) sum(MD_FENCE[[rel]]$inside),
                       integer(1)))
chk(n_fenced >= 500L,
    sprintf("D7a fenced lines are found (%d across %d files)", n_fenced,
            length(ALL_MD)))
chk(!length(d7_bad),
    sprintf("D7b every fence this corpus opens is closed%s",
            if (length(d7_bad)) paste0(" [", paste(d7_bad, collapse = ", "), "]") else ""))
chk(is.na(fence_state(c("````", "```", "x", "```", "````"))$open_at),
    "D7c a four-backtick block quoting three-backtick blocks is one block")
chk(identical(fence_state(c("text", "```r", "code"))$open_at, 2L),
    "D7d KILLED: a fence with no closing marker is reported, at its opening")

# --- D8 a baseline nobody reads -----------------------------------------------
sab(8, "a forgiveness list that forgives nothing because no gate opens it")
LEDGERS <- grep("^tests/.*(baseline|budget|exceptions|registry)\\.(txt|tsv)$",
                TRACKED, value = TRUE)
d8_bad <- character()
for (b in LEDGERS) {
  n <- sum(grepl(basename(b), CODE_TEXT, fixed = TRUE))
  if (n == 0L) d8_bad <- c(d8_bad, b)
}
chk(length(LEDGERS) >= 10L,
    sprintf("D8a the ledgers are found (%d baseline, budget, exception and registry files)",
            length(LEDGERS)))
chk(!length(d8_bad),
    sprintf("D8b every ledger is opened by at least one tracked script%s",
            if (length(d8_bad)) paste0(" [", paste(d8_bad, collapse = ", "), "]") else ""))
# THE SENTINEL IS BUILT, NOT WRITTEN. Spelled out, the name would sit in this
# very file, which `CODE_TEXT` reads the moment the file is tracked -- and the
# control would fail the first time the suite was staged, which is exactly how
# it did fail. A negative control has to name something the corpus cannot
# contain, and a literal in the corpus is not that.
d8_sentinel <- paste0("no_such", "_ledger_", "xyz.txt")
chk(!any(grepl(d8_sentinel, CODE_TEXT, fixed = TRUE)),
    "D8c the reader search answers no for a basename this tree does not have")

# --- D9 one action, one version -----------------------------------------------
sab(9, "the same action pinned two ways, so two jobs run two versions")
uses_refs <- function(path) {
  ln <- readLines(path, warn = FALSE)
  m <- regmatches(ln, regexpr("uses:[[:space:]]*[^[:space:]]+", ln))
  trimws(sub("^uses:[[:space:]]*", "", unlist(m)))
}
d9_all <- unlist(lapply(WF, uses_refs), use.names = FALSE)
unpinned <- d9_all[!grepl("@", d9_all, fixed = TRUE) |
                     grepl("@(main|master|HEAD)$", d9_all)]
act <- sub("@.*$", "", d9_all)
ref <- sub("^[^@]*@?", "", d9_all)
spread <- tapply(ref, act, function(x) length(unique(x)))
d9_bad <- names(spread)[spread > 1L]
chk(length(d9_all) >= 20L && length(unique(act)) >= 3L,
    sprintf("D9a the workflows' action references are read (%d uses of %d actions across %d workflows)",
            length(d9_all), length(unique(act)), length(WF)))
chk(!length(unpinned),
    sprintf("D9b every action is pinned to a ref, never to a moving branch%s",
            if (length(unpinned)) paste0(" [", paste(unpinned, collapse = ", "), "]") else ""))
chk(!length(d9_bad),
    sprintf("D9c no action is used at two different versions%s",
            if (length(d9_bad)) paste0(" [", paste(vapply(d9_bad, function(a)
              sprintf("%s: %s", a, paste(unique(ref[act == a]), collapse = "/")),
              character(1)), collapse = "; "), "]") else ""))

# --- D10 a command a document tells you to run --------------------------------
sab(10, "a documented command naming a script that has since moved")
# PLACEHOLDERS ARE NOT CLAIMS. docs/CI_BEST_PRACTICES.md:72 shows
# `Rscript path/to/test.R`, which is a shape, not a path. Failing on it would
# teach the next writer to stop showing shapes.
PLACEHOLDER <- "path/to/|<|\\.\\.\\.|your-|example|my-|foo|bar\\.R"
d10_seen <- 0L; d10_bad <- character()
for (rel in ALL_MD) {
  ln <- MD_LINES[[rel]]
  inside <- MD_FENCE[[rel]]$inside
  for (i in which(inside)) {
    pat <- "(Rscript|python3?|bash|source)[[:space:]]+[A-Za-z0-9_./-]+\\.(R|py|sh)"
    for (x in regmatches(ln[i], gregexpr(pat, ln[i]))[[1]]) {
      p <- sub("^[A-Za-z0-9]+[[:space:]]+", "", x)
      if (grepl(PLACEHOLDER, p)) next
      d10_seen <- d10_seen + 1L
      if (!file.exists(file.path(root, p)))
        d10_bad <- c(d10_bad, sprintf("%s:%d %s", rel, i, x))
    }
  }
}
chk(d10_seen >= 50L,
    sprintf("D10a the commands the documentation shows are found (%d), so a clean result is not an empty one",
            d10_seen))
chk(!length(d10_bad),
    sprintf("D10b every script a documented command runs exists%s",
            if (length(d10_bad)) paste0(" [", paste(utils::head(unique(d10_bad), 4), collapse = "; "), "]") else ""))
chk(grepl(PLACEHOLDER, "path/to/test.R") &&
      !grepl(PLACEHOLDER, "tests/ci_hygiene.R"),
    "D10c a placeholder path is skipped and a real one is not")

saboteur_report(10)
