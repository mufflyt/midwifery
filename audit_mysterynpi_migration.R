#!/usr/bin/env Rscript
# =============================================================================
# mysterynpi dependency migration: a differential audit of the name functions
# =============================================================================
#
# WHAT THIS ANSWERS. When the pinned version of mysterynpi moves, the name
# handling underneath the AMCB->NPPES linkage moves with it. This script
# measures that, function by function, over the real corpus -- not over a
# sample and not over hand-picked examples.
#
# WHY IT EXISTS. The 2026-11 reconciliation spent days on the wrong hypothesis.
# Two freezes built three days apart from byte-identical input differed by 123
# cohort members, and the first suspects (norm_name(), first_initial()) turned
# out never to have changed: first_initial() was not even called on that path.
# The real cause was split_given(), which nobody had listed as a suspect,
# silently gaining punctuation stripping in cb86e56. Selective reasoning about
# which function "should" matter is what cost those days, so this script is
# deliberately EXHAUSTIVE: every mysterynpi entry point the matcher touches is
# probed, and the diff decides what mattered.
#
# THE SECOND LESSON IS ABOUT WHAT A CHANGED CLASSIFICATION MEANS. A verdict
# that changes is not the same event as a cohort member that changes. The
# buckets below exist so the two are never conflated:
#
#   representational -- the normalised string moved, but no decision reads it
#   blocking         -- a key the matcher JOINS on moved, so candidate PAIRS
#                       can appear or vanish; this is upstream of every verdict
#   evidence         -- a name-agreement verdict moved (middle / person / type)
#   class5           -- the surname-component index moved, i.e. class-5
#                       eligibility
#   parse            -- parse_person() output moved, in shape or content
#
# A function that is not called by the production linkage path cannot move a
# cohort member however much its output changes. surname_agreement() is the
# worked example: three of its classifications changed between 0.3.1.9000 and
# 0.9.0, and it appears nowhere in match_amcb_to_npi.R, R/amcb_match_rules.R or
# R/amcb_name_keys.R -- only in the Trilliant identity experiment. The audit
# records the change and refuses to attribute linkage effects to it. Check
# CALLED_BY_MATCHER below before reading any row as a linkage effect.
#
# THIS SCRIPT DECIDES NOTHING ABOUT THE COHORT. It compares functions. Whether
# a changed verdict actually changes an accepted NPI is answered only by a
# shadow rebuild (see docs/TECHNICAL_APPENDIX_MYSTERYNPI_MIGRATION.md), because
# a lifted veto restores CANDIDACY -- the candidate re-enters ranking and must
# still win on the evidence.
#
# Run (three invocations -- the two probes need different library paths, which
# cannot both be loaded in one R session):
#
#   Rscript audit_mysterynpi_migration.R probe <lib-or-"default"> <outdir>
#   Rscript audit_mysterynpi_migration.R probe default            <outdir2>
#   Rscript audit_mysterynpi_migration.R diff  <outdir> <outdir2> <reportdir>
#
# To build the "old" library for the first probe, install the previous pin into
# a directory of its own so the current one stays intact:
#
#   R CMD INSTALL --no-multiarch -l <lib> <checkout-of-old-pin>
#
# Inputs (read-only, never written): artifacts/amcb_npi_linkage_FROZEN.csv for
# the roster side and midwife_panel.csv for the registry side. Both are
# person-level and gitignored by repo convention; this script only reads them
# and writes nothing into artifacts/.
# =============================================================================

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}

argv <- commandArgs(trailingOnly = TRUE)
MODE <- if (length(argv)) argv[1] else ""
if (!MODE %in% c("probe", "diff")) {
  stop("usage: audit_mysterynpi_migration.R probe <lib|default> <outdir>\n",
       "       audit_mysterynpi_migration.R diff <old-dir> <new-dir> <report-dir>",
       call. = FALSE)
}

# Every mysterynpi symbol reachable from the production AMCB linkage path,
# established by enumerating match_amcb_to_npi.R, R/amcb_match_rules.R and
# R/amcb_name_keys.R rather than from memory. A function absent from this list
# may still change between versions; it cannot change a linkage decision.
CALLED_BY_MATCHER <- c(
  "name_key", "split_given", "blank_na", "middle_tokens", "middle_agreement",
  "given_tokens", "person_matches", "has_name_information", "first_initial",
  "surname_tokens", "surname_token_table", "strip_name_noise",
  "strip_parenthetical", "parse_person", "name_surname_match_type")
NOT_CALLED_BY_MATCHER <- c("surname_agreement", "nickname_agreement")

# Which bucket each probed column belongs to. Keep this beside the probe: a
# column added without a bucket shows up as "unclassified" in the report
# rather than being silently filed as harmless.
BUCKET <- c(
  nk_first = "representational", nk_mid = "representational",
  nk_last = "representational", nk_alt = "representational",
  snn = "representational", spar = "representational",
  bn_last = "representational", hni_last = "representational",
  bn_lastfh = "blocking", sg_given = "blocking", sg_mid = "blocking",
  fi = "blocking",
  mt_mid = "evidence", gt = "evidence", mid = "evidence", pm = "evidence",
  nst = "evidence",
  st_last = "class5", token = "class5",
  first = "parse", middle = "parse", last = "parse", suffix = "parse")

# -------------------------------------------------------------------- probe --
if (identical(MODE, "probe")) {
  lib <- argv[2]; outdir <- argv[3]
  if (nzchar(lib) && !identical(lib, "default")) .libPaths(c(lib, .libPaths()))
  suppressMessages(library(mysterynpi))
  suppressMessages(library(data.table))
  d <- utils::packageDescription("mysterynpi")
  sha <- if (is.null(d$RemoteSha)) "none" else d$RemoteSha
  cat("## mysterynpi ", d$Version, "  sha=", sha, "\n", sep = "")
  dir.create(outdir, showWarnings = FALSE, recursive = TRUE)
  writeLines(c(paste0("version=", d$Version), paste0("sha=", sha)),
             file.path(outdir, "VERSION"))
  W <- function(nm, dt) data.table::fwrite(dt, file.path(outdir, paste0(nm, ".csv")))

  FROZEN <- "artifacts/amcb_npi_linkage_FROZEN.csv"
  PANEL  <- Sys.getenv("MIDWIFE_PANEL", "midwife_panel.csv")
  for (f in c(FROZEN, PANEL)) if (!file.exists(f))
    stop("missing input: ", f, call. = FALSE)
  # VERIFY THE FREEZE, don't just read it. This script's output is a claim
  # about which name decisions a PARTICULAR cohort would have made, so reading
  # a different freeze than the one named in the tracked manifest makes every
  # row of the report describe a population the reader is not looking at. That
  # is not hypothetical: this whole audit exists because two freezes were
  # compared without anything recording which was which.
  #
  # The canonical check (R/lib/cohort_definitions.R) hashes the file against
  # the manifest and refuses a mismatch unless a pin for THIS consumer is
  # declared in artifacts/freeze_pins.tsv. tests/test_frozen_dependency.R T14
  # caught the first version of this script for skipping it, which is the gate
  # working as designed.
  source(file.path(root_dir, "R", "lib", "cohort_definitions.R"))
  freeze_sha <- verify_linkage_freeze(FROZEN)
  cat("freeze verified: ", substr(freeze_sha, 1, 8), "...\n", sep = "")
  # The hashes go in the report so two probe runs can be PROVEN to have seen
  # the same bytes. Two freezes that differed only by a dependency were read
  # as an arithmetic error once; a recorded hash ends that argument.
  hashes <- vapply(c(FROZEN, PANEL), function(f)
    as.character(tools::md5sum(f)), character(1))
  writeLines(paste(hashes, c(FROZEN, PANEL)), file.path(outdir, "INPUT_MD5"))

  fr <- data.table::fread(FROZEN, select = c("amcb_id", "first_name",
                                             "middle_name", "last_name"),
                          colClasses = "character")
  fr <- unique(fr, by = "amcb_id"); data.table::setorder(fr, amcb_id)
  pan <- data.table::fread(PANEL, select = c("npi", "first_name",
                                             "middle_name", "last_name"),
                           colClasses = "character")
  pan <- unique(pan, by = c("npi", "first_name", "middle_name", "last_name"))
  data.table::setorder(pan, npi, first_name, middle_name, last_name)
  cat("roster rows:", nrow(fr), " panel name-variants:", nrow(pan), "\n")

  # 1. Per-string primitives, on both sides' raw name fields.
  probe_strings <- function(tag, ids, first, middle, last) {
    sp <- split_given(first)
    mid_full <- trimws(paste(blank_na(middle), sp$middle_from_given))
    dt <- data.table::data.table(
      id = ids,
      nk_first = name_key(first), nk_mid = name_key(middle),
      nk_last = name_key(last), nk_alt = name_key(last, strip_alternates = TRUE),
      bn_last = blank_na(last), bn_lastfh = blank_na(last, fold_hyphens = TRUE),
      sg_given = sp$given, sg_mid = sp$middle_from_given,
      fi = first_initial(first), hni_last = has_name_information(last),
      snn = strip_name_noise(last), spar = strip_parenthetical(last))
    dt[, mt_mid := vapply(middle_tokens(mid_full),
                          function(z) paste(z, collapse = "|"), character(1))]
    dt[, gt := vapply(given_tokens(sp$given, mid_full),
                      function(z) paste(z, collapse = "|"), character(1))]
    # surname_tokens() takes ONE name, not a vector, in both pinned versions.
    dt[, st_last := vapply(last, function(one) {
         if (is.na(one)) return(NA_character_)
         paste(surname_tokens(one), collapse = "|")
       }, character(1), USE.NAMES = FALSE)]
    W(paste0("str_", tag), dt)
  }
  probe_strings("roster", fr$amcb_id, fr$first_name, fr$middle_name, fr$last_name)
  probe_strings("panel",
                paste(pan$npi, pan$first_name, pan$middle_name, pan$last_name),
                pan$first_name, pan$middle_name, pan$last_name)

  # 2. parse_person(), in the call shape link_theses_to_amcb.R uses. This is
  # where the 0.9.0 `suffix` column shows up; see T1b/T1c in
  # tests/test_amcb_name_keys_saboteur.R.
  pp <- data.table::as.data.table(mysterynpi::parse_person(
    paste0(fr$last_name, ", ", fr$first_name, " ",
           ifelse(is.na(fr$middle_name), "", fr$middle_name))))
  pp[, id := fr$amcb_id]
  W("parse_person_roster", pp)

  # 3. surname_token_table(), the class-5 component index. Signature is
  # (x, id, strip_alternates) in both versions; the matcher calls it with the
  # roster's own ids at match_amcb_to_npi.R:580.
  nm <- unique(c(fr$last_name, pan$last_name)); nm <- nm[!is.na(nm)]
  stt <- data.table::as.data.table(surname_token_table(nm, seq_along(nm)))
  data.table::setorderv(stt, names(stt))
  W("surname_token_table", stt)

  # 4. Pairwise verdicts over the PRE-VETO candidate corpus.
  #
  # WHY NOT linkage_candidate_audit.csv. That artifact is written at
  # match_amcb_to_npi.R:709, AFTER `filter(mid_conflict == 0L)`, so a vetoed
  # pair is already absent from it and a veto being LIFTED is invisible. A
  # first attempt at this comparison used it and reported zero changes.
  #
  # Blocking mirrors the matcher: exact folded surname, then class 1/2 (exact
  # first) or class 3 (shared first initial). Each probe run rebuilds its own
  # blocks, because blank_na(fold_hyphens=) is itself under comparison -- one
  # shared corpus from one version's keys would hide any pair only one version
  # blocks. The diff reports keyset changes separately for that reason.
  fr2 <- data.table::copy(fr)
  sp <- split_given(fr2$first_name)
  fr2[, `:=`(r_last = blank_na(last_name, fold_hyphens = TRUE),
             r_first = sp$given,
             r_mid = trimws(paste(blank_na(middle_name), sp$middle_from_given)))]
  fr2[, r_init := substr(r_first, 1L, 1L)]
  pan2 <- data.table::copy(pan)
  pan2[, `:=`(p_last = blank_na(last_name, fold_hyphens = TRUE),
              p_first = blank_na(first_name), p_mid = blank_na(middle_name))]
  pan2[, p_init := substr(p_first, 1L, 1L)]
  x <- merge(fr2[nzchar(r_last), .(amcb_id, r_last, r_first, r_mid, r_init)],
             pan2[nzchar(p_last), .(npi, p_last, p_first, p_mid, p_init)],
             by.x = "r_last", by.y = "p_last", allow.cartesian = TRUE)
  x <- x[r_first == p_first | (nzchar(r_init) & r_init == p_init)]
  data.table::setorder(x, amcb_id, npi, r_mid, p_mid, p_first)
  cat("pre-veto candidate rows:", nrow(x), "\n")
  x[, mid := as.character(middle_agreement(middle_tokens(r_mid),
                                           middle_tokens(p_mid)))]
  x[, pm := person_matches(r_last, given_tokens(r_first, r_mid),
                           r_last, given_tokens(p_first, p_mid))]
  x[, nst := as.character(name_surname_match_type(r_mid, p_mid))]
  W("pairs", x[, .(amcb_id, npi, r_last, r_first, r_mid, p_first, p_mid,
                   mid, pm, nst)])
  cat("middle-name verdicts:\n"); print(table(x$mid, useNA = "ifany"))
  cat("DONE\n")
  quit(save = "no")
}

# --------------------------------------------------------------------- diff --
OLD <- argv[2]; NEW <- argv[3]; OUT <- argv[4]
suppressMessages(library(data.table))
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)
vers <- function(p) if (file.exists(file.path(p, "VERSION")))
  paste(readLines(file.path(p, "VERSION")), collapse = " ") else "unknown"
cat("OLD:", vers(OLD), "\nNEW:", vers(NEW), "\n")
for (p in c(OLD, NEW)) {
  f <- file.path(p, "INPUT_MD5")
  if (file.exists(f)) cat("inputs(", basename(p), "): ",
                          paste(readLines(f), collapse = " | "), "\n", sep = "")
}
# Both probes must have read the same bytes, or the comparison is measuring
# two different corpora and every row of it is uninterpretable.
h <- lapply(c(OLD, NEW), function(p) {
  f <- file.path(p, "INPUT_MD5"); if (file.exists(f)) readLines(f) else NA_character_ })
if (!anyNA(unlist(h)) && !identical(h[[1]], h[[2]])) {
  stop("the two probe runs read DIFFERENT inputs; the diff would be ",
       "uninterpretable. Re-run both probes against the same corpus.",
       call. = FALSE)
}

TABLES <- list(
  str_roster = "id", str_panel = "id", parse_person_roster = "id",
  surname_token_table = NULL,
  pairs = c("amcb_id", "npi", "r_mid", "p_mid", "p_first"))

summary <- data.table::data.table(
  table = character(), bucket = character(), column = character(),
  changed = integer(), of = integer(), pct = numeric())
record_diff <- function(...) summary <<- rbind(summary, data.table::data.table(...))

for (nm in names(TABLES)) {
  keys <- TABLES[[nm]]
  fo <- file.path(OLD, paste0(nm, ".csv")); fn <- file.path(NEW, paste0(nm, ".csv"))
  if (!file.exists(fo) || !file.exists(fn)) {
    record_diff(table = nm, bucket = "MISSING", column = "", changed = 0L, of = 0L, pct = 0)
    next
  }
  a <- data.table::fread(fo, colClasses = "character")
  b <- data.table::fread(fn, colClasses = "character")
  if (!identical(names(a), names(b))) {
    record_diff(table = nm, bucket = "SCHEMA",
        column = paste0("old[", paste(setdiff(names(a), names(b)), collapse = ","),
                        "] new[", paste(setdiff(names(b), names(a)), collapse = ","), "]"),
        changed = 0L, of = 0L, pct = 0)
  }
  if (is.null(keys)) { a[, .rk := .I]; b[, .rk := .I]; keys <- ".rk" }
  data.table::setkeyv(a, keys); data.table::setkeyv(b, keys)
  only_old <- a[!b, on = keys]; only_new <- b[!a, on = keys]
  if (nrow(only_old) || nrow(only_new)) {
    record_diff(table = nm, bucket = "KEYSET", column = "rows in one run only",
        changed = nrow(only_old), of = nrow(only_new), pct = 0)
    data.table::fwrite(rbind(
      cbind(side = "old_only", only_old[, ..keys]),
      cbind(side = "new_only", only_new[, ..keys])),
      file.path(OUT, paste0(nm, "__keyset.csv")))
  }
  m <- merge(a, b, by = keys, suffixes = c(".o", ".n"))
  cols <- setdiff(intersect(names(a), names(b)), keys)
  for (c0 in cols) {
    o <- m[[paste0(c0, ".o")]]; n <- m[[paste0(c0, ".n")]]
    chg <- which(!(o == n | (is.na(o) & is.na(n))))
    if (!length(chg)) next
    record_diff(table = nm, bucket = if (c0 %in% names(BUCKET)) BUCKET[[c0]] else "unclassified",
        column = c0, changed = length(chg), of = nrow(m),
        pct = 100 * length(chg) / max(nrow(m), 1))
    data.table::fwrite(cbind(m[chg, ..keys],
                             data.table::data.table(old = o[chg], new = n[chg])),
                       file.path(OUT, paste0(nm, "__", c0, ".csv")))
  }
}
if (!nrow(summary)) {
  cat("\nNO DIFFERENCES IN ANY PROBED TABLE.\n")
} else {
  cat("\n"); print(summary, nrows = 200)
}
cat("\ncalled by the production matcher:  ", paste(CALLED_BY_MATCHER, collapse = ", "), "\n")
cat("NOT called by the matcher (cannot move a cohort member): ",
    paste(NOT_CALLED_BY_MATCHER, collapse = ", "), "\n")
data.table::fwrite(summary, file.path(OUT, "summary.csv"))
cat("per-record changes written to", OUT, "\n")
