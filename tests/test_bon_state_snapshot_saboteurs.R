#!/usr/bin/env Rscript
# =============================================================================
# Thirteen saboteurs: the Boards of Nursing bon_snapshot
# =============================================================================
# read_bon_state_snapshot() produces the 1,221-record / 94.2% boards-of-
# nursing figure that manuscript/federal_database_accuracy.qmd prints, and it
# exists because the same eleven lines of board-reading code were copy-pasted
# into three producers and all three silently lost 1,411 of 2,269 records when
# four board files turned up without a live_bon_state column
# (docs/state-source-audit-bon-reharvest.md).
#
# Centralising that code removed the drift but not the failure mode. The
# coverage contract validates the two columns the manifest names -- `npi` and
# the declared state column -- and nothing else. The verified filter turns on
# live_bon_match_status, which the manifest does not name, so the original
# defect still had one column left to hide behind. S1 is that defect.
#
# The standard every saboteur is held to:
#
#   A board file with rows but a missing column this function reads must FAIL
#   LOUDLY, naming the file and the column.
#   A board file that is present, complete and EMPTY must PASS -- a harvest
#   that legitimately matched nothing is evidence of absence, and Delaware's
#   file is exactly that.
#   The published label must describe the sample that was read, never the
#   sample that was declared.
#
# S4, S5, S11 and S13 are inverted on purpose: they sabotage this code into being
# too strict, and pass only if valid absence still survives. Without them a
# later "fix" could satisfy the other eight by refusing every input.
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr)})
.harness <- grep("--file=", commandArgs(), value = TRUE)
source(file.path(if (length(.harness)) dirname(sub("--file=", "", .harness[1]))
                 else "tests", "helper-saboteur.R"))
root <- test_repo_root()
source(file.path(root, "R", "lib", "source_year.R"))
source(file.path(root, "R", "lib", "source_coverage.R"))
source(file.path(root, "R", "lib", "clean_state.R"))
source(file.path(root, "R", "lib", "bon_state_snapshot.R"))


# --- the crime scene ---------------------------------------------------------
# Three boards, standing in for the real eight: two that publish a state
# (colorado, connecticut) and one that declares it publishes none (texas).
sandbox <- file.path(tempdir(), "bon_saboteurs")
STATE_BOARDS <- c("colorado", "connecticut")
NO_STATE_BOARDS <- "texas"
BOARDS <- c(STATE_BOARDS, NO_STATE_BOARDS)

board_path <- function(board)
  file.path("artifacts",
            sprintf("live_%s_bon_ingested_midwives_from_tracked_roster.csv",
                    board))

# `npi_from` keeps each board's NPIs distinct so a double-read is visible as a
# row count rather than hidden by a distinct().
bon_write_board <- function(board, n_rows = 3L, npi_from = 1L,
                        states = c("CO", "NM", "AZ"),
                        statuses = "VERIFIED_LIVE_BON",
                        drop_columns = character(0), npis = NULL) {
  board_rows <- tibble::tibble(
    npi = npis %||% sprintf("1%09d", npi_from + seq_len(n_rows) - 1L),
    live_bon_match_status = rep(statuses, length.out = n_rows),
    live_bon_state = rep(states, length.out = n_rows))
  if (board %in% NO_STATE_BOARDS) board_rows$live_bon_state <- NULL
  for (dropped in drop_columns) board_rows[[dropped]] <- NULL
  readr::write_csv(board_rows[seq_len(n_rows), , drop = FALSE],
                   file.path(sandbox, board_path(board)))
}

bon_write_manifest <- function(boards = BOARDS, extra_year_for = character(0)) {
  declared <- tibble::tibble(
    source_id = "state_boards_of_nursing", source_name = "saboteur fixture",
    expected_year = 2026L, required = TRUE, source_type = "bon_snapshot",
    input_path = board_path(boards), producer = "fixture",
    date_field = NA_character_,
    state_field = ifelse(boards %in% NO_STATE_BOARDS, NA_character_,
                         "live_bon_state"),
    validation_method = "producer_declared", source_vintage = "fixture",
    artifact_sha256 = NA_character_, cnm_reportable = NA_character_,
    availability_status = "available", notes = "saboteur fixture")
  if (length(extra_year_for)) {
    # The manifest's duplicate check keys on source_id + expected_year +
    # input_path, so the SAME path under a different declared year passes it.
    twice <- declared %>% dplyr::filter(.data$input_path %in%
                                          board_path(extra_year_for))
    twice$expected_year <- 2025L
    declared <- dplyr::bind_rows(declared, twice)
  }
  readr::write_csv(declared,
                   file.path(sandbox, "config",
                             "state_source_audit_sources.csv"))
}

bon_restore_scene <- function(...) {
  unlink(sandbox, recursive = TRUE)
  dir.create(file.path(sandbox, "artifacts"), recursive = TRUE,
             showWarnings = FALSE)
  dir.create(file.path(sandbox, "config"), recursive = TRUE,
             showWarnings = FALSE)
  for (board_index in seq_along(BOARDS))
    bon_write_board(BOARDS[board_index], npi_from = 1L + 100L * board_index)
  bon_write_manifest(...)
}

# Runs the bon_snapshot inside the sandbox and returns either the result or the
# refusal text, never letting an error end the suite.
bon_snapshot <- function(publication_mode = TRUE) {
  owd <- setwd(sandbox); on.exit(setwd(owd), add = TRUE)
  tryCatch(suppressMessages(read_bon_state_snapshot(publication_mode)),
           error = function(e) structure(conditionMessage(e),
                                         class = "refusal"))
}
names_what <- function(x, ...) {
  if (!refused(x)) return(FALSE)
  all(vapply(c(...), function(needle) grepl(needle, x, fixed = TRUE),
             logical(1)))
}

cat("\n=== baseline: the scene is intact before each saboteur ===\n")
bon_restore_scene()
baseline <- bon_snapshot()
chk(!refused(baseline), "B1 an intact scene publishes")
chk(!refused(baseline) && nrow(baseline$verified) == 6L,
    "B2 both state-publishing boards contribute all 3 records each")
chk(!refused(baseline) && nrow(baseline$comparable) == 6L,
    "B3 every record carries a resolvable state")
chk(!refused(baseline) &&
      identical(baseline$label,
                paste0("2026-11 (3 boards harvested; 2 publish a state: ",
                       "CO/CT; TX publish none)")),
    "B4 the label names the boards read and the board that publishes none")

# --- S1: the original defect, one column to the right ------------------------
cat("\n=== S1 a board with rows loses live_bon_match_status ===\n")
bon_restore_scene()
bon_write_board("connecticut", npi_from = 201L,
            drop_columns = "live_bon_match_status")
s1 <- bon_snapshot()
chk(names_what(s1, "live_bon_match_status", "live_connecticut_bon"),
    "S1 refuses, naming the file and the missing column")
chk(refused(s1) || nrow(s1$verified) != 3L,
    "S1 does not publish connecticut's records as if they never existed")

# --- S2: every board loses it, which used to be a cryptic dplyr error --------
cat("\n=== S2 every board loses live_bon_match_status ===\n")
bon_restore_scene()
for (board in STATE_BOARDS)
  bon_write_board(board, drop_columns = "live_bon_match_status")
s2 <- bon_snapshot()
chk(names_what(s2, "live_bon_match_status"),
    "S2 refuses with the column named, not an unattributed lookup error")

# --- S3: the column the coverage contract does name --------------------------
cat("\n=== S3 a board loses its npi column ===\n")
bon_restore_scene()
bon_write_board("colorado", drop_columns = "npi")
s3 <- bon_snapshot()
chk(refused(s3), "S3 refuses a board file with no npi column")

# --- S4 (INVERTED): present, complete and empty is evidence of absence -------
cat("\n=== S4 one board is present and empty (Delaware's real case) ===\n")
bon_restore_scene()
bon_write_board("connecticut", n_rows = 0L)
s4 <- bon_snapshot()
chk(!refused(s4), "S4 an empty board file does NOT fail the build")
chk(!refused(s4) && nrow(s4$verified) == 3L,
    "S4 colorado's three records survive the empty sibling")
chk(!refused(s4) && identical(s4$boards_excluded, character(0)),
    "S4 an empty board counts as read, not as excluded")

# --- S5 (INVERTED): all of them empty ----------------------------------------
cat("\n=== S5 every state-publishing board is present and empty ===\n")
bon_restore_scene()
for (board in STATE_BOARDS) bon_write_board(board, n_rows = 0L)
s5 <- bon_snapshot()
chk(!refused(s5), "S5 an all-empty harvest returns a verdict, not an error")
chk(!refused(s5) && nrow(s5$comparable) == 0L,
    "S5 zero comparable records, reported as zero")

# --- S6: the same file declared under two years ------------------------------
cat("\n=== S6 one board file is declared under two expected_years ===\n")
bon_restore_scene(extra_year_for = "colorado")
s6 <- bon_snapshot()
chk(!refused(s6) && nrow(s6$verified) == 6L,
    "S6 a twice-declared board file is read once, not counted twice")
chk(!refused(s6) && length(s6$boards_with_state) == 2L,
    "S6 the label counts two state-publishing boards, not three")

# --- S7: a board that publishes no state must not enter the denominator -----
cat("\n=== S7 the no-state board's file carries verified rows ===\n")
bon_restore_scene()
texas_rows <- tibble::tibble(
  npi = sprintf("9%09d", 1:5),
  live_bon_match_status = rep("VERIFIED_LIVE_BON", 5))
readr::write_csv(texas_rows, file.path(sandbox, board_path("texas")))
s7 <- bon_snapshot()
chk(!refused(s7) && nrow(s7$verified) == 6L,
    "S7 texas's rows never enter `verified`, which is the published denominator")
chk(!refused(s7) && !any(grepl("^9", s7$comparable$npi)),
    "S7 no record from a board that publishes no state reaches `comparable`")

# --- S8: unresolvable state values are not comparable ------------------------
cat("\n=== S8 a board publishes state values nothing can resolve ===\n")
bon_restore_scene()
bon_write_board("connecticut", npi_from = 201L,
            states = c("N/A", "UNKNOWN", "--"))
s8 <- bon_snapshot()
chk(!refused(s8) && nrow(s8$verified) == 6L,
    "S8 the junk rows stay in `verified`, so the denominator is honest")
chk(!refused(s8) && nrow(s8$comparable) == 3L,
    "S8 none of the three junk values is scored as an observed state")

# --- S9: a row with no npi is not a record -----------------------------------
# Florida's real file carries exactly one such row. readr trims whitespace and
# maps the resulting empty string to NA, so a whitespace-only npi arrives here
# already NA -- which is why the nzchar() guard downstream of trimws() is
# belt-and-braces rather than the thing doing the work.
cat("\n=== S9 a board file carries blank and whitespace-only npis ===\n")
bon_restore_scene()
bon_write_board("connecticut", n_rows = 3L,
            npis = c("1000000201", "   ", NA_character_))
s9 <- bon_snapshot()
chk(!refused(s9) && nrow(s9$comparable) == 4L,
    "S9 two unidentifiable rows are dropped; the one real npi is kept")
chk(!refused(s9) && !any(is.na(s9$comparable$npi)),
    "S9 no record reaches the published count without an identifier")

# --- S10: a board name is not a state code -----------------------------------
cat("\n=== S10 a ninth board is declared with no state-code entry ===\n")
bon_restore_scene()
bon_write_board("colorado", npi_from = 101L)
oregon_path <- file.path(sandbox, board_path("oregon"))
write_board_oregon <- {
  readr::write_csv(tibble::tibble(
    npi = sprintf("2%09d", 1:2),
    live_bon_match_status = rep("VERIFIED_LIVE_BON", 2),
    live_bon_state = c("OR", "OR")), oregon_path)
}
bon_write_manifest(boards = c(BOARDS, "oregon"))
s10 <- bon_snapshot()
chk(names_what(s10, "oregon", "BOARD_STATE_CODE"),
    "S10 refuses rather than abbreviating a board name as a state code")

# --- S11 (INVERTED): an exploratory run must not claim what it did not read --
cat("\n=== S11 a declined board in exploratory mode ===\n")
bon_restore_scene()
unlink(file.path(sandbox, board_path("connecticut")))
s11_published <- bon_snapshot(publication_mode = TRUE)
chk(refused(s11_published),
    "S11a publication mode refuses when a declared board file is absent")
s11 <- bon_snapshot(publication_mode = FALSE)
chk(!refused(s11) && identical(s11$boards_excluded, "connecticut"),
    "S11b exploratory mode names connecticut as excluded")
chk(!refused(s11) && grepl("CT EXCLUDED", s11$label, fixed = TRUE),
    "S11c the published label says CT was excluded instead of counting it")
chk(!refused(s11) && nrow(s11$verified) == 3L,
    "S11d only the board actually read contributes records")

# --- S12: a zero-byte file is not a harvest that matched nothing -------------
# This saboteur started out inverted, asserting that a headerless file is
# valid absence like Delaware's. It is not, and the existing contract was
# right to refuse it. Delaware's real present-and-empty file is 163 bytes of
# header: it proves the harvester ran, connected and wrote its schema, and
# matched nobody. A zero-byte file proves only that something created a file
# -- a truncated write, an interrupted producer, a placeholder `touch` -- and
# is indistinguishable from a harvest that never happened. The two must get
# different verdicts, which is the whole distinction the coverage contract
# exists to draw.
cat("\n=== S12 every state-publishing board file is zero bytes ===\n")
bon_restore_scene()
for (board in STATE_BOARDS)
  file.create(file.path(sandbox, board_path(board)))
s12 <- bon_snapshot()
chk(names_what(s12, "live_colorado_bon"),
    "S12 refuses a zero-byte board file, naming it")
chk(refused(s12) || nrow(s12$comparable) == 0L,
    "S12 never treats a zero-byte file as a harvest that matched nobody")

# --- S13 (INVERTED): nothing resolved at all ---------------------------------
cat("\n=== S13 exploratory run where every state-publishing board is absent ===\n")
bon_restore_scene()
for (board in STATE_BOARDS) unlink(file.path(sandbox, board_path(board)))
s13 <- bon_snapshot(publication_mode = FALSE)
chk(!refused(s13) && nrow(s13$comparable) == 0L,
    "S13 an empty resolved set returns zero records, not an error")
chk(!refused(s13) &&
      identical(sort(s13$boards_excluded), sort(STATE_BOARDS)),
    "S13 both boards are named as excluded rather than counted as read")

cat(sprintf("\n%s  %d failure(s)\n",
            if (fails == 0L) "ALL SABOTEURS HELD" else "SABOTEURS FOUND GAPS",
            fails))
quit(status = if (fails == 0L) 0L else 1L)
