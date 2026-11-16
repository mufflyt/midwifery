# =============================================================================
# The Boards of Nursing state snapshot, read once and labelled honestly
# =============================================================================
# WHY THIS EXISTS. Three producers consumed the board files with the same
# eleven lines of copy-pasted code:
#
#   bon_files <- Sys.glob("artifacts/live_*_bon_ingested_midwives_...csv")
#   bon <- bind_rows(lapply(bon_files, read_csv)) %>% ...
#     transmute(npi, state = clean_state(live_bon_state))
#
# -- build_state_source_audit.R, build_state_source_pairwise_audit.R and
# build_cross_source_comparison.R. Four of the eight board files had no
# live_bon_state column, dplyr::bind_rows() fills an absent column with NA,
# and so 1,411 of 2,269 verified records -- 62% -- silently left the state
# comparison in all three. Each producer also carried its own hand-written
# "7 states: CO/CT/FL/IL/PA/TX/WA" label, which no longer described the
# sample and had no way to notice.
#
# Fixing that in three places invites the three from drifting apart again, so
# the manifest lookup, the state-publishing filter and the label live here
# and the producers call one function. See
# docs/state-source-audit-bon-reharvest.md.
# =============================================================================

#' Which boards publish a licensee state at all
#'
#' Reads `config/state_source_audit_sources.csv` rather than the filesystem.
#' A board declares an EMPTY `state_field` when its upstream source carries
#' no state: Texas (data.texas.gov `jnzg-cr4w`, which publishes only a Texas
#' county and a free-text employer address) and Washington (data.wa.gov
#' `qxh8-f4bd`, which publishes no address field at all). That is a property
#' of the source, not a defect, and no re-harvest can change it -- which is
#' exactly why it must be declared rather than inferred from a missing
#' column, since a missing column is how Colorado's and Pennsylvania's real
#' state data went unnoticed for three months.
#'
#' @return [tbl_df] the declared board rows, with `board` added.
#' @export
bon_declared_boards <- function() {
  declared <- read_source_manifest() %>%
    dplyr::filter(.data$source_id == "state_boards_of_nursing") %>%
    dplyr::mutate(
      board = sub("_bon_.*$", "", sub("^live_", "", basename(.data$input_path))),
      publishes_state = !is.na(.data$state_field) & nzchar(.data$state_field))
  if (!nrow(declared)) {
    stop("bon_declared_boards(): no state_boards_of_nursing rows are ",
         "declared in config/state_source_audit_sources.csv", call. = FALSE)
  }
  declared
}

#' Read the verified Boards of Nursing records that can carry a state
#'
#' Resolves inputs through the declared-coverage contract rather than
#' `Sys.glob()`, so a board file that is missing, unparseable or has lost its
#' declared state column fails the build instead of shrinking the sample.
#'
#' Returns only `VERIFIED_LIVE_BON` rows from boards that publish a state,
#' and reports the comparable subset separately from the verified total so
#' that the difference is a number a caller can print rather than a silent
#' subtraction.
#'
#' @param publication_mode [logical] stop when a declared board cannot be
#'   used. TRUE for any run whose numbers will be published.
#' @return [list] `verified`, `comparable` (state observed), `label`,
#'   `boards_with_state`, `boards_without_state`, `states_seen`.
#' @export
read_bon_state_snapshot <- function(publication_mode = TRUE) {
  declared <- bon_declared_boards()
  coverage_audit <- validate_source_coverage(
    declared, publication_mode = publication_mode)

  with_state <- declared %>% dplyr::filter(.data$publishes_state)
  usable_paths <- resolve_source_inputs(coverage_audit,
                                        "state_boards_of_nursing") %>%
    dplyr::filter(.data$input_path %in% with_state$input_path) %>%
    dplyr::pull(.data$input_path)

  verified <- dplyr::bind_rows(lapply(usable_paths, function(board_file) {
    readr::read_csv(board_file, col_types = readr::cols(.default = "c"),
                    progress = FALSE)
  })) %>%
    dplyr::filter(.data$live_bon_match_status == "VERIFIED_LIVE_BON") %>%
    dplyr::transmute(npi = trimws(.data$npi),
                     state = clean_state(.data$live_bon_state)) %>%
    dplyr::filter(!is.na(.data$npi), nzchar(.data$npi))
  comparable <- verified %>% dplyr::filter(!is.na(.data$state))

  boards_with_state <- sort(with_state$board)
  boards_without_state <- sort(declared$board[!declared$publishes_state])
  states_seen <- sort(unique(comparable$state))

  abbreviate_board <- function(board_names) {
    toupper(substr(board_names, 1, 2))
  }
  label <- sprintf(
    "2026-11 (%d boards harvested; %d publish a state: %s; %s publish none)",
    nrow(declared), length(boards_with_state),
    paste(abbreviate_board(boards_with_state), collapse = "/"),
    paste(abbreviate_board(boards_without_state), collapse = "/"))

  base::message(sprintf(
    "  state_boards_of_nursing: %d verified records from %d state-publishing boards",
    nrow(verified), length(boards_with_state)))
  base::message(sprintf(
    "  state_boards_of_nursing: %d carry an observed state, across %d states",
    nrow(comparable), length(states_seen)))
  if (nrow(verified) > nrow(comparable)) {
    # Florida's board answers "NOT PRACTICING" or "No current practice
    # location in Florida" in the address field for 191 of its verified
    # records. That is the board affirmatively reporting absence, not a gap,
    # and it is logged rather than passed over so the gap is never read as
    # a harvest failure.
    base::message(sprintf(
      "  state_boards_of_nursing: %d verified records report no state -- affirmative absence, not a gap",
      nrow(verified) - nrow(comparable)))
  }
  base::message(
    "  state_boards_of_nursing: agreement here is ADDRESS CONCORDANCE WITHIN ",
    "A STATE-MATCHED SAMPLE -- every harvester selects on nppes_state, so ",
    "this is not independent agreement and is not comparable to the other pairs")

  list(verified = verified, comparable = comparable, label = label,
       boards_with_state = boards_with_state,
       boards_without_state = boards_without_state,
       states_seen = states_seen)
}
